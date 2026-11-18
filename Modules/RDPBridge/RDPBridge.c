// FreeRDP client glue for RemoteKit. See include/RDPBridge.h for the contract.

#include "RDPBridge.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include <winpr/clipboard.h>
#include <winpr/crt.h>
#include <winpr/input.h>
#include <winpr/string.h>
#include <winpr/synch.h>

#include <freerdp/channels/channels.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/file.h>
#include <freerdp/codec/color.h>
#include <freerdp/error.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/graphics.h>
#include <freerdp/input.h>
#include <freerdp/scancode.h>
#include <freerdp/settings.h>
#include <freerdp/update.h>
#include <freerdp/version.h>

typedef struct {
  rdpClientContext common; // must stay first
  RDPBSession *session;
} RDPBContext;

struct RDPBSession {
  rdpContext *context;
  RDPBCallbacks callbacks;

  pthread_t thread;
  bool threadStarted;
  atomic_bool stopRequested;
  atomic_bool framePending;
  atomic_bool connected;

  DispClientContext *disp;
  atomic_bool dispReady;

  pthread_mutex_t clipboardLock;
  CliprdrClientContext *cliprdr;
  wClipboard *clipboard;
  bool clipboardReady;
  bool clipboardHasLocalText;
  UINT32 requestedFormat;
};

static RDPBSession *session_of(rdpContext *context) {
  return context ? ((RDPBContext *)context)->session : NULL;
}

static void report_state(RDPBSession *s, RDPBState state, RDPBEndReason reason, uint32_t code,
                         const char *message) {
  if (s->callbacks.state)
    s->callbacks.state(s->callbacks.context, state, reason, code, message);
}

// MARK: - Errors

static RDPBEndReason classify_error(RDPBSession *s, uint32_t code) {
  if (code == FREERDP_ERROR_SUCCESS)
    return atomic_load(&s->stopRequested) ? RDPBEndUserDisconnect : RDPBEndNone;

  const uint32_t cls = GET_FREERDP_ERROR_CLASS(code);
  const uint32_t type = GET_FREERDP_ERROR_TYPE(code);

  if (cls == FREERDP_ERROR_ERRINFO_CLASS) {
    switch (type) {
      case ERRINFO_RPC_INITIATED_DISCONNECT:
      case ERRINFO_RPC_INITIATED_LOGOFF:
      case ERRINFO_RPC_INITIATED_DISCONNECT_BY_USER:
      case ERRINFO_LOGOFF_BY_USER:
        return RDPBEndUserDisconnect;
      case ERRINFO_IDLE_TIMEOUT:
      case ERRINFO_LOGON_TIMEOUT:
        return RDPBEndIdleTimeout;
      case ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION:
        return RDPBEndOtherConnection;
      case ERRINFO_SERVER_DENIED_CONNECTION:
      case ERRINFO_SERVER_INSUFFICIENT_PRIVILEGES:
        return RDPBEndServerDenied;
      case ERRINFO_SERVER_FRESH_CREDENTIALS_REQUIRED:
        return RDPBEndAuthentication;
      default:
        return RDPBEndOther;
    }
  }

  switch (code) {
    case FREERDP_ERROR_CONNECT_CANCELLED:
      return atomic_load(&s->stopRequested) ? RDPBEndUserDisconnect : RDPBEndCancelled;
    case FREERDP_ERROR_AUTHENTICATION_FAILED:
    case FREERDP_ERROR_CONNECT_LOGON_FAILURE:
    case FREERDP_ERROR_CONNECT_WRONG_PASSWORD:
    case FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS:
      return RDPBEndAuthentication;
    case FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED:
    case FREERDP_ERROR_CONNECT_PASSWORD_MUST_CHANGE:
    case FREERDP_ERROR_CONNECT_PASSWORD_CERTAINLY_EXPIRED:
      return RDPBEndPasswordExpired;
    case FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT:
    case FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED:
    case FREERDP_ERROR_CONNECT_ACCOUNT_EXPIRED:
    case FREERDP_ERROR_CONNECT_ACCOUNT_RESTRICTION:
    case FREERDP_ERROR_CONNECT_CLIENT_REVOKED:
      return RDPBEndAccountProblem;
    case FREERDP_ERROR_CONNECT_ACCESS_DENIED:
    case FREERDP_ERROR_SERVER_DENIED_CONNECTION:
      return RDPBEndServerDenied;
    case FREERDP_ERROR_DNS_NAME_NOT_FOUND:
      return RDPBEndHostNotFound;
    case FREERDP_ERROR_CONNECT_FAILED:
    case FREERDP_ERROR_CONNECT_TRANSPORT_FAILED:
    case FREERDP_ERROR_CONNECT_KDC_UNREACHABLE:
      return RDPBEndUnreachable;
    case FREERDP_ERROR_TLS_CONNECT_FAILED:
    case FREERDP_ERROR_SECURITY_NEGO_CONNECT_FAILED:
      return RDPBEndSecurity;
    default:
      return RDPBEndOther;
  }
}

// MARK: - Painting

static BOOL bridge_begin_paint(rdpContext *context) {
  rdpGdi *gdi = context->gdi;
  if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd)
    return TRUE;
  gdi->primary->hdc->hwnd->invalid->null = TRUE;
  return TRUE;
}

static BOOL bridge_end_paint(rdpContext *context) {
  RDPBSession *s = session_of(context);
  rdpGdi *gdi = context->gdi;
  if (!s || !gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd)
    return TRUE;
  HGDI_WND hwnd = gdi->primary->hdc->hwnd;
  if (hwnd->invalid->null)
    return TRUE;
  hwnd->ninvalid = 0;
  if (!atomic_exchange(&s->framePending, true) && s->callbacks.frame)
    s->callbacks.frame(s->callbacks.context);
  return TRUE;
}

static BOOL bridge_desktop_resize(rdpContext *context) {
  RDPBSession *s = session_of(context);
  rdpSettings *settings = context->settings;
  const UINT32 w = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
  const UINT32 h = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);

  rdp_update_lock(context->update);
  const BOOL ok = context->gdi ? gdi_resize(context->gdi, w, h) : TRUE;
  rdp_update_unlock(context->update);

  if (s && s->callbacks.resize)
    s->callbacks.resize(s->callbacks.context, w, h);
  if (s && !atomic_exchange(&s->framePending, true) && s->callbacks.frame)
    s->callbacks.frame(s->callbacks.context);
  return ok;
}

bool RDPBSessionCopyFrame(RDPBSession *s, uint8_t *buffer, size_t bufferSize, uint32_t *width,
                          uint32_t *height) {
  if (!s || !s->context)
    return false;
  rdpContext *context = s->context;
  bool copied = false;

  rdp_update_lock(context->update);
  atomic_store(&s->framePending, false);
  rdpGdi *gdi = context->gdi;
  if (gdi && gdi->primary_buffer && gdi->width > 0 && gdi->height > 0) {
    const UINT32 w = (UINT32)gdi->width;
    const UINT32 h = (UINT32)gdi->height;
    const size_t rowBytes = (size_t)w * 4;
    if (width)
      *width = w;
    if (height)
      *height = h;
    if (buffer && bufferSize >= rowBytes * h) {
      if (gdi->stride == rowBytes) {
        memcpy(buffer, gdi->primary_buffer, rowBytes * h);
      } else {
        for (UINT32 y = 0; y < h; y++)
          memcpy(buffer + y * rowBytes, gdi->primary_buffer + (size_t)y * gdi->stride, rowBytes);
      }
      copied = true;
    }
  }
  rdp_update_unlock(context->update);
  return copied;
}

// MARK: - Pointer

static BOOL bridge_pointer_new(rdpContext *context, rdpPointer *pointer) {
  RDPBSession *s = session_of(context);
  if (!s || !pointer || pointer->width == 0 || pointer->height == 0)
    return TRUE;
  const size_t size = (size_t)pointer->width * pointer->height * 4;
  BYTE *rgba = calloc(1, size);
  if (!rgba)
    return FALSE;
  if (freerdp_image_copy_from_pointer_data(rgba, PIXEL_FORMAT_RGBA32, 0, 0, 0, pointer->width,
                                           pointer->height, pointer->xorMaskData,
                                           pointer->lengthXorMask, pointer->andMaskData,
                                           pointer->lengthAndMask, pointer->xorBpp, NULL)) {
    if (s->callbacks.cursorNew)
      s->callbacks.cursorNew(s->callbacks.context, (uintptr_t)pointer, rgba, pointer->width,
                             pointer->height, pointer->xPos, pointer->yPos);
  }
  free(rgba);
  return TRUE;
}

static void bridge_pointer_free(rdpContext *context, rdpPointer *pointer) {
  RDPBSession *s = session_of(context);
  if (s && s->callbacks.cursorFree)
    s->callbacks.cursorFree(s->callbacks.context, (uintptr_t)pointer);
}

static BOOL bridge_pointer_set(rdpContext *context, rdpPointer *pointer) {
  RDPBSession *s = session_of(context);
  if (s && s->callbacks.cursorSet)
    s->callbacks.cursorSet(s->callbacks.context, RDPBCursorCustom, (uintptr_t)pointer);
  return TRUE;
}

static BOOL bridge_pointer_set_null(rdpContext *context) {
  RDPBSession *s = session_of(context);
  if (s && s->callbacks.cursorSet)
    s->callbacks.cursorSet(s->callbacks.context, RDPBCursorHidden, 0);
  return TRUE;
}

static BOOL bridge_pointer_set_default(rdpContext *context) {
  RDPBSession *s = session_of(context);
  if (s && s->callbacks.cursorSet)
    s->callbacks.cursorSet(s->callbacks.context, RDPBCursorDefault, 0);
  return TRUE;
}

static BOOL bridge_pointer_set_position(rdpContext *context, UINT32 x, UINT32 y) {
  WINPR_UNUSED(context);
  WINPR_UNUSED(x);
  WINPR_UNUSED(y);
  return TRUE;
}

// MARK: - Clipboard (text only)

static UINT clip_send_format_list(RDPBSession *s) {
  // Called with clipboardLock held.
  CliprdrClientContext *cliprdr = s->cliprdr;
  if (!cliprdr || !s->clipboard)
    return CHANNEL_RC_OK;

  UINT32 *ids = NULL;
  UINT32 count = s->clipboardHasLocalText ? ClipboardGetFormatIds(s->clipboard, &ids) : 0;
  CLIPRDR_FORMAT *formats = count ? calloc(count, sizeof(CLIPRDR_FORMAT)) : NULL;
  UINT32 sent = 0;
  for (UINT32 i = 0; i < count && formats; i++) {
    // Offer only the plain text formats Windows understands natively.
    if (ids[i] == CF_UNICODETEXT || ids[i] == CF_TEXT || ids[i] == CF_OEMTEXT) {
      formats[sent].formatId = ids[i];
      formats[sent].formatName = NULL;
      sent++;
    }
  }
  CLIPRDR_FORMAT_LIST list = { 0 };
  list.common.msgType = CB_FORMAT_LIST;
  list.numFormats = sent;
  list.formats = formats;
  const UINT rc = cliprdr->ClientFormatList(cliprdr, &list);
  free(formats);
  free(ids);
  return rc;
}

static UINT clip_monitor_ready(CliprdrClientContext *cliprdr, const CLIPRDR_MONITOR_READY *ready) {
  WINPR_UNUSED(ready);
  RDPBSession *s = cliprdr->custom;
  if (!s)
    return CHANNEL_RC_OK;

  CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
  general.capabilitySetType = CB_CAPSTYPE_GENERAL;
  general.capabilitySetLength = 12;
  general.version = CB_CAPS_VERSION_2;
  general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
  CLIPRDR_CAPABILITIES caps = { 0 };
  caps.cCapabilitiesSets = 1;
  caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
  UINT rc = cliprdr->ClientCapabilities(cliprdr, &caps);
  if (rc != CHANNEL_RC_OK)
    return rc;

  pthread_mutex_lock(&s->clipboardLock);
  s->clipboardReady = true;
  rc = clip_send_format_list(s);
  pthread_mutex_unlock(&s->clipboardLock);
  return rc;
}

static UINT clip_server_capabilities(CliprdrClientContext *cliprdr,
                                     const CLIPRDR_CAPABILITIES *caps) {
  WINPR_UNUSED(cliprdr);
  WINPR_UNUSED(caps);
  return CHANNEL_RC_OK;
}

static UINT clip_server_format_list(CliprdrClientContext *cliprdr,
                                    const CLIPRDR_FORMAT_LIST *list) {
  RDPBSession *s = cliprdr->custom;
  CLIPRDR_FORMAT_LIST_RESPONSE response = { 0 };
  response.common.msgType = CB_FORMAT_LIST_RESPONSE;
  response.common.msgFlags = CB_RESPONSE_OK;
  UINT rc = cliprdr->ClientFormatListResponse(cliprdr, &response);
  if (rc != CHANNEL_RC_OK || !s)
    return rc;

  UINT32 wanted = 0;
  for (UINT32 i = 0; i < list->numFormats; i++) {
    const UINT32 id = list->formats[i].formatId;
    if (id == CF_UNICODETEXT)
      wanted = id;
    else if ((id == CF_TEXT || id == CF_OEMTEXT) && wanted == 0)
      wanted = id;
  }
  if (wanted == 0)
    return CHANNEL_RC_OK;

  pthread_mutex_lock(&s->clipboardLock);
  s->requestedFormat = wanted;
  pthread_mutex_unlock(&s->clipboardLock);

  CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
  request.common.msgType = CB_FORMAT_DATA_REQUEST;
  request.requestedFormatId = wanted;
  return cliprdr->ClientFormatDataRequest(cliprdr, &request);
}

static UINT clip_server_format_list_response(CliprdrClientContext *cliprdr,
                                             const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
  WINPR_UNUSED(cliprdr);
  WINPR_UNUSED(response);
  return CHANNEL_RC_OK;
}

static UINT clip_server_lock(CliprdrClientContext *cliprdr, const CLIPRDR_LOCK_CLIPBOARD_DATA *d) {
  WINPR_UNUSED(cliprdr);
  WINPR_UNUSED(d);
  return CHANNEL_RC_OK;
}

static UINT clip_server_unlock(CliprdrClientContext *cliprdr,
                               const CLIPRDR_UNLOCK_CLIPBOARD_DATA *d) {
  WINPR_UNUSED(cliprdr);
  WINPR_UNUSED(d);
  return CHANNEL_RC_OK;
}

static UINT clip_server_data_request(CliprdrClientContext *cliprdr,
                                     const CLIPRDR_FORMAT_DATA_REQUEST *request) {
  RDPBSession *s = cliprdr->custom;
  CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
  response.common.msgType = CB_FORMAT_DATA_RESPONSE;
  response.common.msgFlags = CB_RESPONSE_FAIL;

  BYTE *data = NULL;
  UINT32 size = 0;
  if (s) {
    pthread_mutex_lock(&s->clipboardLock);
    if (s->clipboard && s->clipboardHasLocalText)
      data = ClipboardGetData(s->clipboard, request->requestedFormatId, &size);
    pthread_mutex_unlock(&s->clipboardLock);
  }
  if (data && size > 0) {
    response.common.msgFlags = CB_RESPONSE_OK;
    response.common.dataLen = size;
    response.requestedFormatData = data;
  }
  const UINT rc = cliprdr->ClientFormatDataResponse(cliprdr, &response);
  free(data);
  return rc;
}

static char *normalize_newlines(char *text) {
  // Windows sends \r\n; the Mac uses \n.
  char *out = text;
  for (char *in = text; *in; in++) {
    if (in[0] == '\r' && in[1] == '\n')
      continue;
    *out++ = *in;
  }
  *out = '\0';
  return text;
}

static UINT clip_server_data_response(CliprdrClientContext *cliprdr,
                                      const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
  RDPBSession *s = cliprdr->custom;
  if (!s || (response->common.msgFlags & CB_RESPONSE_FAIL) || !response->requestedFormatData)
    return CHANNEL_RC_OK;

  pthread_mutex_lock(&s->clipboardLock);
  const UINT32 format = s->requestedFormat;
  pthread_mutex_unlock(&s->clipboardLock);

  const size_t length = response->common.dataLen;
  char *text = NULL;
  if (format == CF_UNICODETEXT) {
    size_t utf8Length = 0;
    text = ConvertWCharNToUtf8Alloc((const WCHAR *)response->requestedFormatData,
                                    length / sizeof(WCHAR), &utf8Length);
  } else {
    text = calloc(1, length + 1);
    if (text)
      memcpy(text, response->requestedFormatData, length);
  }
  if (text && s->callbacks.clipboardText)
    s->callbacks.clipboardText(s->callbacks.context, normalize_newlines(text));
  free(text);
  return CHANNEL_RC_OK;
}

static UINT clip_file_contents_request(CliprdrClientContext *cliprdr,
                                       const CLIPRDR_FILE_CONTENTS_REQUEST *request) {
  CLIPRDR_FILE_CONTENTS_RESPONSE response = { 0 };
  response.common.msgType = CB_FILECONTENTS_RESPONSE;
  response.common.msgFlags = CB_RESPONSE_FAIL;
  response.streamId = request->streamId;
  return cliprdr->ClientFileContentsResponse(cliprdr, &response);
}

static UINT clip_file_contents_response(CliprdrClientContext *cliprdr,
                                        const CLIPRDR_FILE_CONTENTS_RESPONSE *response) {
  WINPR_UNUSED(cliprdr);
  WINPR_UNUSED(response);
  return CHANNEL_RC_OK;
}

static void clipboard_attach(RDPBSession *s, CliprdrClientContext *cliprdr) {
  pthread_mutex_lock(&s->clipboardLock);
  s->cliprdr = cliprdr;
  s->clipboardReady = false;
  pthread_mutex_unlock(&s->clipboardLock);

  cliprdr->custom = s;
  cliprdr->MonitorReady = clip_monitor_ready;
  cliprdr->ServerCapabilities = clip_server_capabilities;
  cliprdr->ServerFormatList = clip_server_format_list;
  cliprdr->ServerFormatListResponse = clip_server_format_list_response;
  cliprdr->ServerLockClipboardData = clip_server_lock;
  cliprdr->ServerUnlockClipboardData = clip_server_unlock;
  cliprdr->ServerFormatDataRequest = clip_server_data_request;
  cliprdr->ServerFormatDataResponse = clip_server_data_response;
  cliprdr->ServerFileContentsRequest = clip_file_contents_request;
  cliprdr->ServerFileContentsResponse = clip_file_contents_response;
}

static void clipboard_detach(RDPBSession *s, CliprdrClientContext *cliprdr) {
  cliprdr->custom = NULL;
  pthread_mutex_lock(&s->clipboardLock);
  s->cliprdr = NULL;
  s->clipboardReady = false;
  pthread_mutex_unlock(&s->clipboardLock);
}

void RDPBSessionSetClipboardText(RDPBSession *s, const char *text) {
  if (!s || !text)
    return;

  // Windows expects \r\n line breaks.
  size_t extra = 0;
  for (const char *p = text; *p; p++)
    if (*p == '\n' && (p == text || p[-1] != '\r'))
      extra++;
  const size_t length = strlen(text);
  char *converted = malloc(length + extra + 1);
  if (!converted)
    return;
  char *out = converted;
  for (const char *p = text; *p; p++) {
    if (*p == '\n' && (p == text || p[-1] != '\r'))
      *out++ = '\r';
    *out++ = *p;
  }
  *out = '\0';

  pthread_mutex_lock(&s->clipboardLock);
  if (s->clipboard) {
    ClipboardLock(s->clipboard);
    ClipboardEmpty(s->clipboard);
    const UINT32 utf8 = ClipboardRegisterFormat(s->clipboard, "text/plain;charset=utf-8");
    s->clipboardHasLocalText = ClipboardSetData(s->clipboard, utf8, converted,
                                                (UINT32)(length + extra + 1));
    ClipboardUnlock(s->clipboard);
    if (s->clipboardReady)
      (void)clip_send_format_list(s);
  }
  pthread_mutex_unlock(&s->clipboardLock);
  free(converted);
}

// MARK: - Display control

static UINT disp_caps(DispClientContext *disp, UINT32 maxNumMonitors, UINT32 maxFactorA,
                      UINT32 maxFactorB) {
  WINPR_UNUSED(maxNumMonitors);
  WINPR_UNUSED(maxFactorA);
  WINPR_UNUSED(maxFactorB);
  RDPBSession *s = disp->custom;
  if (s)
    atomic_store(&s->dispReady, true);
  return CHANNEL_RC_OK;
}

bool RDPBSessionResize(RDPBSession *s, uint32_t width, uint32_t height, uint32_t desktopScale,
                       uint32_t deviceScale) {
  if (!s || !atomic_load(&s->connected) || !atomic_load(&s->dispReady) || !s->disp)
    return false;
  if (!freerdp_settings_get_bool(s->context->settings, FreeRDP_DynamicResolutionUpdate))
    return false;

  // MS-RDPEDISP: width 200...8192 and even, height 200...8192.
  width = width < 200 ? 200 : (width > 8192 ? 8192 : width);
  height = height < 200 ? 200 : (height > 8192 ? 8192 : height);
  width &= ~1u;

  DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
  layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
  layout.Width = width;
  layout.Height = height;
  layout.Orientation = ORIENTATION_LANDSCAPE;
  layout.DesktopScaleFactor = desktopScale ? desktopScale : 100;
  layout.DeviceScaleFactor = deviceScale ? deviceScale : 100;
  layout.PhysicalWidth = 0;
  layout.PhysicalHeight = 0;
  return s->disp->SendMonitorLayout(s->disp, 1, &layout) == CHANNEL_RC_OK;
}

// MARK: - Channels

static void on_channel_connected(void *ctx, const ChannelConnectedEventArgs *e) {
  RDPBContext *context = ctx;
  RDPBSession *s = context->session;

  if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
    clipboard_attach(s, (CliprdrClientContext *)e->pInterface);
  } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
    s->disp = (DispClientContext *)e->pInterface;
    s->disp->custom = s;
    s->disp->DisplayControlCaps = disp_caps;
  } else {
    freerdp_client_OnChannelConnectedEventHandler(ctx, e);
  }
}

static void on_channel_disconnected(void *ctx, const ChannelDisconnectedEventArgs *e) {
  RDPBContext *context = ctx;
  RDPBSession *s = context->session;

  if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
    clipboard_detach(s, (CliprdrClientContext *)e->pInterface);
  } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
    atomic_store(&s->dispReady, false);
    if (s->disp)
      s->disp->custom = NULL;
    s->disp = NULL;
  } else {
    freerdp_client_OnChannelDisconnectedEventHandler(ctx, e);
  }
}

// MARK: - Connection callbacks

static BOOL bridge_pre_connect(freerdp *instance) {
  rdpContext *context = instance->context;
  rdpSettings *settings = context->settings;
  if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH) ||
      !freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH))
    return FALSE;
  if (PubSub_SubscribeChannelConnected(context->pubSub, on_channel_connected) < 0 ||
      PubSub_SubscribeChannelDisconnected(context->pubSub, on_channel_disconnected) < 0)
    return FALSE;
  return TRUE;
}

static BOOL bridge_post_connect(freerdp *instance) {
  rdpContext *context = instance->context;
  if (!gdi_init(instance, PIXEL_FORMAT_BGRX32))
    return FALSE;

  rdpPointer pointer = { 0 };
  pointer.size = sizeof(rdpPointer);
  pointer.New = bridge_pointer_new;
  pointer.Free = bridge_pointer_free;
  pointer.Set = bridge_pointer_set;
  pointer.SetNull = bridge_pointer_set_null;
  pointer.SetDefault = bridge_pointer_set_default;
  pointer.SetPosition = bridge_pointer_set_position;
  graphics_register_pointer(context->graphics, &pointer);

  context->update->BeginPaint = bridge_begin_paint;
  context->update->EndPaint = bridge_end_paint;
  context->update->DesktopResize = bridge_desktop_resize;

  RDPBSession *s = session_of(context);
  if (s) {
    const UINT32 w = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    const UINT32 h = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (s->callbacks.resize)
      s->callbacks.resize(s->callbacks.context, w, h);
  }
  return TRUE;
}

static void bridge_post_disconnect(freerdp *instance) {
  if (!instance || !instance->context)
    return;
  PubSub_UnsubscribeChannelConnected(instance->context->pubSub, on_channel_connected);
  PubSub_UnsubscribeChannelDisconnected(instance->context->pubSub, on_channel_disconnected);
  rdp_update_lock(instance->context->update);
  gdi_free(instance);
  rdp_update_unlock(instance->context->update);
}

static void copy_into(char *buffer, size_t size, const char *value) {
  if (!buffer || size == 0)
    return;
  buffer[0] = '\0';
  if (value)
    (void)strncpy(buffer, value, size - 1);
  buffer[size - 1] = '\0';
}

static BOOL bridge_authenticate(freerdp *instance, char **username, char **password,
                                char **domain, rdp_auth_reason reason) {
  RDPBSession *s = session_of(instance->context);
  if (!s || !s->callbacks.authenticate || atomic_load(&s->stopRequested))
    return FALSE;

  bool gateway = false;
  switch (reason) {
    case AUTH_NLA:
      break;
    case AUTH_TLS:
    case AUTH_RDP:
      if (*username && *password)
        return TRUE;
      break;
    case GW_AUTH_HTTP:
    case GW_AUTH_RDG:
    case GW_AUTH_RPC:
      gateway = true;
      break;
    default:
      return FALSE; // smartcard PIN and others are not supported
  }

  char user[512], dom[512], pass[512];
  copy_into(user, sizeof(user), *username);
  copy_into(dom, sizeof(dom), *domain);
  copy_into(pass, sizeof(pass), *password);

  const bool ok = s->callbacks.authenticate(s->callbacks.context, gateway, user, sizeof(user), dom,
                                            sizeof(dom), pass, sizeof(pass));
  if (ok) {
    free(*username);
    free(*domain);
    free(*password);
    *username = _strdup(user);
    *domain = dom[0] ? _strdup(dom) : NULL;
    *password = _strdup(pass);
  }
  memset(pass, 0, sizeof(pass));
  if (!ok)
    freerdp_set_last_error_if_not(instance->context, FREERDP_ERROR_CONNECT_CANCELLED);
  return ok ? TRUE : FALSE;
}

static DWORD bridge_verify_certificate(freerdp *instance, const char *host, UINT16 port,
                                       const char *common_name, const char *subject,
                                       const char *issuer, const char *fingerprint, DWORD flags) {
  RDPBSession *s = session_of(instance->context);
  if (!s || !s->callbacks.verifyCertificate || atomic_load(&s->stopRequested))
    return 0;
  return s->callbacks.verifyCertificate(s->callbacks.context, host, port, common_name, subject,
                                        issuer, fingerprint, NULL,
                                        (flags & VERIFY_CERT_FLAG_MISMATCH) != 0);
}

static DWORD bridge_verify_changed_certificate(freerdp *instance, const char *host, UINT16 port,
                                               const char *common_name, const char *subject,
                                               const char *issuer, const char *fingerprint,
                                               const char *old_subject, const char *old_issuer,
                                               const char *old_fingerprint, DWORD flags) {
  WINPR_UNUSED(old_subject);
  WINPR_UNUSED(old_issuer);
  RDPBSession *s = session_of(instance->context);
  if (!s || !s->callbacks.verifyCertificate || atomic_load(&s->stopRequested))
    return 0;
  return s->callbacks.verifyCertificate(s->callbacks.context, host, port, common_name, subject,
                                        issuer, fingerprint,
                                        old_fingerprint ? old_fingerprint : "",
                                        (flags & VERIFY_CERT_FLAG_MISMATCH) != 0);
}

static BOOL bridge_present_gateway_message(freerdp *instance, UINT32 type, BOOL display,
                                           BOOL consent, size_t length, const WCHAR *message) {
  WINPR_UNUSED(instance);
  WINPR_UNUSED(type);
  WINPR_UNUSED(display);
  WINPR_UNUSED(consent);
  WINPR_UNUSED(length);
  WINPR_UNUSED(message);
  return TRUE; // accept the gateway's notice
}

static int bridge_logon_error_info(freerdp *instance, UINT32 data, UINT32 type) {
  WINPR_UNUSED(instance);
  WINPR_UNUSED(data);
  WINPR_UNUSED(type);
  return 1;
}

static SSIZE_T bridge_retry_dialog(freerdp *instance, const char *what, size_t current,
                                   void *userarg) {
  WINPR_UNUSED(userarg);
  RDPBSession *s = session_of(instance->context);
  if (!s || atomic_load(&s->stopRequested))
    return -1;
  if (strcmp(what, "connection") != 0 && strcmp(what, "arm-transport") != 0)
    return -1;
  const rdpSettings *settings = instance->context->settings;
  if (!freerdp_settings_get_bool(settings, FreeRDP_AutoReconnectionEnabled))
    return -1;
  if (current >= freerdp_settings_get_uint32(settings, FreeRDP_AutoReconnectMaxRetries))
    return -1;
  report_state(s, RDPBStateReconnecting, RDPBEndNone, 0, NULL);
  return 2000;
}

static BOOL bridge_client_new(freerdp *instance, rdpContext *context) {
  WINPR_UNUSED(context);
  instance->PreConnect = bridge_pre_connect;
  instance->PostConnect = bridge_post_connect;
  instance->PostDisconnect = bridge_post_disconnect;
  instance->AuthenticateEx = bridge_authenticate;
  instance->VerifyCertificateEx = bridge_verify_certificate;
  instance->VerifyChangedCertificateEx = bridge_verify_changed_certificate;
  instance->PresentGatewayMessage = bridge_present_gateway_message;
  instance->LogonErrorInfo = bridge_logon_error_info;
  instance->RetryDialog = bridge_retry_dialog;
  instance->ChooseSmartcard = NULL;
  return TRUE;
}

static void bridge_client_free(freerdp *instance, rdpContext *context) {
  WINPR_UNUSED(instance);
  WINPR_UNUSED(context);
}

static int bridge_client_start(rdpContext *context) {
  WINPR_UNUSED(context);
  return 0;
}

static int bridge_client_stop(rdpContext *context) {
  WINPR_UNUSED(context);
  return 0;
}

// MARK: - Session

static bool set_string(rdpSettings *settings, FreeRDP_Settings_Keys_String key, const char *value) {
  if (!value || !value[0])
    return true;
  return freerdp_settings_set_string(settings, key, value);
}

static bool apply_config(rdpSettings *settings, const RDPBConfig *c) {
  if (c->rdpFileText && c->rdpFileText[0]) {
    rdpFile *file = freerdp_client_rdp_file_new();
    if (file) {
      if (freerdp_client_parse_rdp_file_buffer(file, (const BYTE *)c->rdpFileText,
                                               strlen(c->rdpFileText)))
        (void)freerdp_client_populate_settings_from_rdp_file(file, settings);
      freerdp_client_rdp_file_free(file);
    }
  }

  if (!freerdp_settings_set_string(settings, FreeRDP_ServerHostname, c->host) ||
      !freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, c->port ? c->port : 3389))
    return false;

  if (c->username && c->username[0]) {
    char *user = NULL, *domain = NULL;
    if (freerdp_parse_username(c->username, &user, &domain)) {
      const bool ok = freerdp_settings_set_string(settings, FreeRDP_Username, user) &&
                      (domain ? freerdp_settings_set_string(settings, FreeRDP_Domain, domain)
                              : set_string(settings, FreeRDP_Domain, c->domain));
      free(user);
      free(domain);
      if (!ok)
        return false;
    }
  } else if (!set_string(settings, FreeRDP_Domain, c->domain)) {
    return false;
  }
  if (!set_string(settings, FreeRDP_Password, c->password))
    return false;

  if (c->gatewayHost && c->gatewayHost[0]) {
    if (!freerdp_settings_set_string(settings, FreeRDP_GatewayHostname, c->gatewayHost) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_GatewayPort,
                                     c->gatewayPort ? c->gatewayPort : 443) ||
        !freerdp_settings_set_bool(settings, FreeRDP_GatewayEnabled, TRUE) ||
        !freerdp_settings_set_uint32(settings, FreeRDP_GatewayUsageMethod, TSC_PROXY_MODE_DIRECT) ||
        !freerdp_settings_set_bool(settings, FreeRDP_GatewayHttpTransport, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_GatewayRpcTransport, TRUE) ||
        !freerdp_settings_set_bool(settings, FreeRDP_GatewayUseSameCredentials,
                                   c->gatewayUseSameCredentials))
      return false;
    if (!c->gatewayUseSameCredentials) {
      if (!set_string(settings, FreeRDP_GatewayUsername, c->gatewayUsername) ||
          !set_string(settings, FreeRDP_GatewayDomain, c->gatewayDomain) ||
          !set_string(settings, FreeRDP_GatewayPassword, c->gatewayPassword))
        return false;
    }
  }

  if (!set_string(settings, FreeRDP_ConfigPath, c->configDirectory))
    return false;

  const UINT32 width = c->width ? c->width : 1600;
  const UINT32 height = c->height ? c->height : 1000;
  if (!freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, width & ~1u) ||
      !freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, height) ||
      !freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32) ||
      !freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor,
                                   c->desktopScale ? c->desktopScale : 100) ||
      !freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor,
                                   c->deviceScale ? c->deviceScale : 100))
    return false;

  if (c->keyboardLayout &&
      !freerdp_settings_set_uint32(settings, FreeRDP_KeyboardLayout, c->keyboardLayout))
    return false;

  const bool dynamic = c->dynamicResolution;
  if (!freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, dynamic) ||
      !freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, dynamic) ||
      !freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE) ||
      !freerdp_settings_set_bool(settings, FreeRDP_GfxH264, TRUE) ||
      !freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, TRUE) ||
      !freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444v2, TRUE) ||
      !freerdp_settings_set_bool(settings, FreeRDP_GfxProgressive, TRUE) ||
      !freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, TRUE) ||
      !freerdp_settings_set_bool(settings, FreeRDP_NetworkAutoDetect, TRUE) ||
      !freerdp_settings_set_uint32(settings, FreeRDP_ConnectionType, CONNECTION_TYPE_AUTODETECT) ||
      !freerdp_settings_set_bool(settings, FreeRDP_AllowFontSmoothing, TRUE) ||
      !freerdp_settings_set_bool(settings, FreeRDP_AllowDesktopComposition, TRUE) ||
      !freerdp_settings_set_bool(settings, FreeRDP_SupportHeartbeatPdu, TRUE))
    return false;

  if (!freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, c->audio) ||
      !freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, c->clipboard) ||
      !freerdp_settings_set_bool(settings, FreeRDP_ConsoleSession, c->adminSession) ||
      !freerdp_settings_set_bool(settings, FreeRDP_AutoReconnectionEnabled, c->autoReconnect) ||
      !freerdp_settings_set_uint32(settings, FreeRDP_AutoReconnectMaxRetries, 20))
    return false;

  if (c->sharedFolderPath && c->sharedFolderPath[0]) {
    const char *name = (c->sharedFolderName && c->sharedFolderName[0]) ? c->sharedFolderName : "Mac";
    char value[2048];
    (void)snprintf(value, sizeof(value), "%s(%s)", c->sharedFolderPath, name);
    if (!freerdp_settings_set_string(settings, FreeRDP_DrivesToRedirect, value))
      return false;
  }

  // We show the fingerprint; no PEM needed.
  return freerdp_settings_set_bool(settings, FreeRDP_CertificateCallbackPreferPEM, FALSE);
}

RDPBSession *RDPBSessionCreate(const RDPBConfig *config, const RDPBCallbacks *callbacks) {
  if (!config || !config->host || !config->host[0] || !callbacks)
    return NULL;

  RDPBSession *s = calloc(1, sizeof(RDPBSession));
  if (!s)
    return NULL;
  s->callbacks = *callbacks;
  pthread_mutex_init(&s->clipboardLock, NULL);
  s->clipboard = ClipboardCreate();

  RDP_CLIENT_ENTRY_POINTS entry = { 0 };
  entry.Version = RDP_CLIENT_INTERFACE_VERSION;
  entry.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
  entry.ContextSize = sizeof(RDPBContext);
  entry.ClientNew = bridge_client_new;
  entry.ClientFree = bridge_client_free;
  entry.ClientStart = bridge_client_start;
  entry.ClientStop = bridge_client_stop;

  s->context = freerdp_client_context_new(&entry);
  if (!s->context) {
    ClipboardDestroy(s->clipboard);
    pthread_mutex_destroy(&s->clipboardLock);
    free(s);
    return NULL;
  }
  ((RDPBContext *)s->context)->session = s;

  if (!apply_config(s->context->settings, config)) {
    freerdp_client_context_free(s->context);
    ClipboardDestroy(s->clipboard);
    pthread_mutex_destroy(&s->clipboardLock);
    free(s);
    return NULL;
  }
  return s;
}

static void *session_thread(void *arg) {
  RDPBSession *s = arg;
  rdpContext *context = s->context;
  freerdp *instance = context->instance;

  report_state(s, RDPBStateConnecting, RDPBEndNone, 0, NULL);

  if (!freerdp_connect(instance)) {
    const uint32_t code = freerdp_get_last_error(context);
    freerdp_disconnect(instance);
    report_state(s, RDPBStateDisconnected, classify_error(s, code), code,
                 freerdp_get_last_error_string(code));
    return NULL;
  }

  atomic_store(&s->connected, true);
  report_state(s, RDPBStateConnected, RDPBEndNone, 0, NULL);

  HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
  bool lostConnection = false;
  while (!freerdp_shall_disconnect_context(context)) {
    const DWORD count = freerdp_get_event_handles(context, handles, ARRAYSIZE(handles));
    if (count == 0)
      break;
    if (WaitForMultipleObjects(count, handles, FALSE, INFINITE) == WAIT_FAILED)
      break;
    if (!freerdp_check_event_handles(context)) {
      if (atomic_load(&s->stopRequested))
        break;
      if (freerdp_settings_get_bool(context->settings, FreeRDP_AutoReconnectionEnabled) &&
          freerdp_error_info(instance) == ERRINFO_SUCCESS) {
        // The network dropped: FreeRDP reconnects and calls RetryDialog between tries.
        report_state(s, RDPBStateReconnecting, RDPBEndNone, 0, NULL);
        atomic_store(&s->dispReady, false);
        if (client_auto_reconnect_ex(instance, NULL)) {
          report_state(s, RDPBStateConnected, RDPBEndNone, 0, NULL);
          continue;
        }
      }
      lostConnection = freerdp_error_info(instance) == ERRINFO_SUCCESS;
      break;
    }
  }

  atomic_store(&s->connected, false);
  uint32_t code = freerdp_get_last_error(context);
  const UINT32 info = freerdp_error_info(instance);
  if (code == FREERDP_ERROR_SUCCESS && info != ERRINFO_SUCCESS)
    code = MAKE_FREERDP_ERROR(ERRINFO, info);
  freerdp_disconnect(instance);

  RDPBEndReason reason = classify_error(s, code);
  if (reason == RDPBEndNone && lostConnection)
    reason = RDPBEndNetworkLost;
  if (reason == RDPBEndNone)
    reason = RDPBEndUserDisconnect;
  report_state(s, RDPBStateDisconnected, reason, code,
               code ? freerdp_get_last_error_string(code) : NULL);
  return NULL;
}

bool RDPBSessionStart(RDPBSession *s) {
  if (!s || s->threadStarted)
    return false;
  if (pthread_create(&s->thread, NULL, session_thread, s) != 0)
    return false;
  s->threadStarted = true;
  return true;
}

void RDPBSessionStop(RDPBSession *s) {
  if (!s)
    return;
  atomic_store(&s->stopRequested, true);
  freerdp_abort_connect_context(s->context);
}

void RDPBSessionFree(RDPBSession *s) {
  if (!s)
    return;
  RDPBSessionStop(s);
  if (s->threadStarted)
    pthread_join(s->thread, NULL);
  freerdp_client_context_free(s->context);
  ClipboardDestroy(s->clipboard);
  pthread_mutex_destroy(&s->clipboardLock);
  free(s);
}

// MARK: - Input

static rdpInput *input_of(RDPBSession *s) {
  if (!s || !atomic_load(&s->connected) || !s->context)
    return NULL;
  return s->context->input;
}

void RDPBSessionMouseMove(RDPBSession *s, uint16_t x, uint16_t y) {
  rdpInput *input = input_of(s);
  if (input)
    (void)freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, x, y);
}

void RDPBSessionMouseButton(RDPBSession *s, int button, bool down, uint16_t x, uint16_t y) {
  rdpInput *input = input_of(s);
  if (!input)
    return;
  switch (button) {
    case 0:
      (void)freerdp_input_send_mouse_event(input, (down ? PTR_FLAGS_DOWN : 0) | PTR_FLAGS_BUTTON1, x, y);
      break;
    case 1:
      (void)freerdp_input_send_mouse_event(input, (down ? PTR_FLAGS_DOWN : 0) | PTR_FLAGS_BUTTON2, x, y);
      break;
    case 2:
      (void)freerdp_input_send_mouse_event(input, (down ? PTR_FLAGS_DOWN : 0) | PTR_FLAGS_BUTTON3, x, y);
      break;
    case 3:
      (void)freerdp_input_send_extended_mouse_event(input, (down ? PTR_XFLAGS_DOWN : 0) | PTR_XFLAGS_BUTTON1, x, y);
      break;
    case 4:
      (void)freerdp_input_send_extended_mouse_event(input, (down ? PTR_XFLAGS_DOWN : 0) | PTR_XFLAGS_BUTTON2, x, y);
      break;
    default:
      break;
  }
}

void RDPBSessionMouseWheel(RDPBSession *s, bool horizontal, int32_t delta, uint16_t x, uint16_t y) {
  rdpInput *input = input_of(s);
  if (!input || delta == 0)
    return;
  // Each event carries at most 255 units (9-bit two's complement with the negative flag).
  while (delta != 0) {
    int32_t step = delta;
    if (step > 255)
      step = 255;
    if (step < -255)
      step = -255;
    delta -= step;

    UINT16 flags = horizontal ? PTR_FLAGS_HWHEEL : PTR_FLAGS_WHEEL;
    // Windows: a positive horizontal value scrolls right, a negative vertical one scrolls down.
    if (step < 0) {
      flags |= PTR_FLAGS_WHEEL_NEGATIVE;
      flags |= (UINT16)((0x100 + step) & 0xFF);
    } else {
      flags |= (UINT16)(step & 0xFF);
    }
    (void)freerdp_input_send_mouse_event(input, flags, x, y);
  }
}

void RDPBSessionMacKey(RDPBSession *s, uint16_t keyCode, bool down, bool repeat) {
  rdpInput *input = input_of(s);
  if (!input)
    return;
  const DWORD vk = GetVirtualKeyCodeFromKeycode(keyCode, WINPR_KEYCODE_TYPE_APPLE);
  const DWORD scancode = GetVirtualScanCodeFromVirtualKeyCode(vk, 4);
  if ((scancode & 0xFF) == 0)
    return;
  (void)freerdp_input_send_keyboard_event_ex(input, down, repeat, scancode);
}

void RDPBSessionScanCode(RDPBSession *s, uint8_t scanCode, bool extended, bool down) {
  rdpInput *input = input_of(s);
  if (input)
    (void)freerdp_input_send_keyboard_event_ex(input, down, FALSE,
                                               MAKE_RDP_SCANCODE(scanCode, extended));
}

void RDPBSessionUnicode(RDPBSession *s, uint16_t codeUnit, bool down) {
  rdpInput *input = input_of(s);
  if (input)
    (void)freerdp_input_send_unicode_keyboard_event(input, down ? 0 : KBD_FLAGS_RELEASE, codeUnit);
}

void RDPBSessionSynchronize(RDPBSession *s, uint32_t toggleFlags) {
  rdpInput *input = input_of(s);
  if (input)
    (void)freerdp_input_send_focus_in_event(input, (UINT16)toggleFlags);
}

const char *RDPBVersion(void) {
  return freerdp_get_version_string();
}
