// A small C interface over the FreeRDP client library for RemoteKit.
//
// Swift never sees FreeRDP's own headers: it creates a session from a plain config, gets
// callbacks on FreeRDP's threads and sends input back. Each session runs its own connection
// thread. Callbacks marked "blocking" hold that thread until they return, so they must hand
// the question to the main thread and wait; all others must return quickly.

#ifndef RDPBRIDGE_H
#define RDPBRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RDPBSession RDPBSession;

typedef enum {
  RDPBStateConnecting = 0,
  RDPBStateConnected = 1,
  RDPBStateReconnecting = 2,
  RDPBStateDisconnected = 3,
} RDPBState;

/// Why a session ended, grouped so the app can explain it in its own words.
typedef enum {
  RDPBEndNone = 0,             // still running, or ended without an error
  RDPBEndUserDisconnect,       // closed here, or the user signed out / disconnected on the PC
  RDPBEndCancelled,            // a prompt was cancelled
  RDPBEndAuthentication,       // wrong user name or password
  RDPBEndPasswordExpired,      // the password must be changed first
  RDPBEndAccountProblem,       // locked out, disabled, expired or restricted
  RDPBEndHostNotFound,         // the name doesn't resolve
  RDPBEndUnreachable,          // no route, refused or timed out
  RDPBEndSecurity,             // TLS / CredSSP negotiation failed or the certificate was rejected
  RDPBEndOtherConnection,      // someone else connected to the same session
  RDPBEndIdleTimeout,          // the server's idle or logon time limit
  RDPBEndServerDenied,         // the server refused the connection or the user lacks rights
  RDPBEndNetworkLost,          // the connection dropped and couldn't be restored
  RDPBEndOther,
} RDPBEndReason;

typedef enum {
  RDPBCursorCustom = 0,
  RDPBCursorHidden = 1,
  RDPBCursorDefault = 2,
} RDPBCursorKind;

typedef struct {
  const char *host;                // required
  uint16_t port;                   // 0 = 3389
  const char *username;            // may include DOMAIN\ or user@domain
  const char *domain;
  const char *password;

  const char *gatewayHost;         // RD Gateway, NULL for none
  uint16_t gatewayPort;            // 0 = 443
  bool gatewayUseSameCredentials;
  const char *gatewayUsername;
  const char *gatewayDomain;
  const char *gatewayPassword;

  const char *rdpFileText;         // optional .rdp content applied first; the fields here win
  const char *configDirectory;     // where trusted certificates are kept

  uint32_t width;                  // desktop size in pixels
  uint32_t height;
  uint32_t desktopScale;           // 100...500, Windows' display scale
  uint32_t deviceScale;            // 100, 140 or 180
  uint32_t keyboardLayout;         // Windows keyboard layout id (e.g. 0x041F), 0 = server default

  bool dynamicResolution;          // follow the window size through the display control channel
  bool audio;                      // play remote sound here
  bool clipboard;                  // share text through the clipboard
  bool adminSession;               // connect to the console session
  bool autoReconnect;
  const char *sharedFolderPath;    // a local folder shown as a drive on the PC, NULL for none
  const char *sharedFolderName;
} RDPBConfig;

typedef struct {
  void *context;

  /// State changes. `reason`, `errorCode` and `message` describe the end of a session.
  void (*state)(void *context, RDPBState state, RDPBEndReason reason, uint32_t errorCode,
                const char *message);
  /// The framebuffer changed; call RDPBSessionCopyFrame. Not called again until it was read.
  void (*frame)(void *context);
  /// The desktop size changed (after a resize or reconnect).
  void (*resize)(void *context, uint32_t width, uint32_t height);

  /// A cursor image the server will refer to by `cursorID`; `rgba` is width*height*4 bytes,
  /// not premultiplied, and only valid during the call.
  void (*cursorNew)(void *context, uintptr_t cursorID, const uint8_t *rgba, uint32_t width,
                    uint32_t height, uint32_t hotX, uint32_t hotY);
  void (*cursorFree)(void *context, uintptr_t cursorID);
  void (*cursorSet)(void *context, RDPBCursorKind kind, uintptr_t cursorID);

  /// Blocking. Credentials are missing: fill the buffers (they hold what is known) and return
  /// true, or return false to cancel. `gateway` is true for RD Gateway credentials.
  bool (*authenticate)(void *context, bool gateway, char *username, size_t usernameSize,
                       char *domain, size_t domainSize, char *password, size_t passwordSize);
  /// Blocking. The server certificate isn't trusted yet (or changed if `oldFingerprint` is set).
  /// Return 0 to refuse, 1 to trust it from now on, 2 to trust it for this connection only.
  uint32_t (*verifyCertificate)(void *context, const char *host, uint16_t port,
                                const char *commonName, const char *subject, const char *issuer,
                                const char *fingerprint, const char *oldFingerprint,
                                bool hostMismatch);

  /// Text copied on the remote PC, UTF-8 with \n line breaks.
  void (*clipboardText)(void *context, const char *text);
} RDPBCallbacks;

/// Creates a session; nothing happens until RDPBSessionStart. Returns NULL if the
/// configuration is invalid. Strings are copied.
RDPBSession *RDPBSessionCreate(const RDPBConfig *config, const RDPBCallbacks *callbacks);
/// Starts the connection thread.
bool RDPBSessionStart(RDPBSession *session);
/// Asks the session to disconnect; the state callback reports when it is done.
void RDPBSessionStop(RDPBSession *session);
/// Stops if needed, waits for the connection thread and frees everything. No callback runs
/// after it returns.
void RDPBSessionFree(RDPBSession *session);

/// Copies the current desktop image (BGRX, 4 bytes per pixel, rows of width*4 bytes) into
/// `buffer` when it fits, and reports the size. Returns false when there is no image yet or
/// `buffer` is too small (the size is still reported).
bool RDPBSessionCopyFrame(RDPBSession *session, uint8_t *buffer, size_t bufferSize,
                          uint32_t *width, uint32_t *height);

/// Mouse position in desktop pixels.
void RDPBSessionMouseMove(RDPBSession *session, uint16_t x, uint16_t y);
/// button: 0 left, 1 right, 2 middle, 3 back, 4 forward.
void RDPBSessionMouseButton(RDPBSession *session, int button, bool down, uint16_t x, uint16_t y);
/// One notch is 120; positive scrolls up (vertical) or right (horizontal).
void RDPBSessionMouseWheel(RDPBSession *session, bool horizontal, int32_t delta, uint16_t x,
                           uint16_t y);
/// A Mac virtual key code (kVK_*), translated to the PC scan code.
void RDPBSessionMacKey(RDPBSession *session, uint16_t keyCode, bool down, bool repeat);
/// A PC scan code; `extended` for the E0-prefixed keys.
void RDPBSessionScanCode(RDPBSession *session, uint8_t scanCode, bool extended, bool down);
/// Types a character the keyboard layout can't produce.
void RDPBSessionUnicode(RDPBSession *session, uint16_t codeUnit, bool down);
/// Tells the server the lock key states when the window gets focus (bit 1 scroll, 2 num, 4 caps).
void RDPBSessionSynchronize(RDPBSession *session, uint32_t toggleFlags);

/// Asks the server to resize the desktop. Returns false if the server can't (yet).
bool RDPBSessionResize(RDPBSession *session, uint32_t width, uint32_t height,
                       uint32_t desktopScale, uint32_t deviceScale);

/// Offers local text to the remote clipboard.
void RDPBSessionSetClipboardText(RDPBSession *session, const char *text);

/// The FreeRDP version the bridge was built against.
const char *RDPBVersion(void);

#ifdef __cplusplus
}
#endif

#endif
