# Vendored third-party sources

Copied once from these releases; no package manager is used. Each folder keeps its upstream LICENSE.

| Module | Upstream repo | Version | Commit |
|---|---|---|---|
| Defaults | Defaults | 9.0.9 | `00a7465` |
| KeyboardShortcuts | KeyboardShortcuts | 3.1.0 | `772133d` |
| LaunchAtLogin | LaunchAtLogin-Modern | v1.1.0 | `a04ec1c` |
| Settings | Settings | 3.1.2 | `f414757` |
| Sauce | Sauce | v2.5.2 | `1fce89c` |
| Fuse | fuse-swift | 1.4.0 | `26ba868` |
| Logging | swift-log | 1.15.1 | `9c6fb14` |
| SwiftHEXColors | SwiftHEXColors | 1.4.1 | `1f886cb` |
| ConfettiSwiftUI | ConfettiSwiftUI | 1.1.0 | `f45961f` |
| SmoothGradient | SmoothGradient | 1.0.1 | `77ac160` |

The RDP client behind RemoteKit is too large to copy into the repo, so `FreeRDP/build.sh` builds it from pinned release tarballs (checked against the sha256 in the script) into one static universal library, `FreeRDP/out/lib/libfreerdp-bundle.a`, with headers in `FreeRDP/out/include`. Both `FreeRDP/.build` and `FreeRDP/out` are ignored by git; run the script once after cloning (needs `cmake` and `ninja`).

| Project | Upstream | Version | Source | License |
|---|---|---|---|---|
| FreeRDP | [FreeRDP](https://github.com/FreeRDP/FreeRDP) client libraries (WinPR, libfreerdp, client channels) | 3.33.1 | `freerdp-3.33.1.tar.gz` from the GitHub release, sha256 `4431bbf0…4e7124` | Apache-2.0 (`LICENSES/FreeRDP-Apache-2.0.txt`) |
| OpenSSL | [OpenSSL](https://www.openssl.org) libcrypto and libssl | 3.5.9 (LTS) | `openssl-3.5.9.tar.gz` from the GitHub release, sha256 `603f5602…1eb859a` | Apache-2.0 (`LICENSES/OpenSSL-Apache-2.0.txt`) |

- FreeRDP is built without clients, servers, FFmpeg, Kerberos, smartcards, printers, USB or camera redirection; H.264 is decoded with VideoToolbox. Channels in: clipboard, sound (Core Audio), graphics pipeline, display control, drive redirection. MD4, MD5 and RC4 come from FreeRDP's own code.
- Homebrew's libraries are kept out of the build, and the libraries are installed under a neutral prefix with source paths mapped, so no local path ends up in the app.
- `Modules/RDPBridge` is our C layer over FreeRDP's client API; Swift never includes FreeRDP headers.

Local changes: `Bundle.module` lookups point to the app bundle (KeyboardShortcuts strings live in `App/Resources/Strings/*/KeyboardShortcuts.strings`).

Also: `Modules/DockKit/Utilities/Media/TrackInfo.swift` is the data model from [ejbills/mediaremote-adapter](https://github.com/ejbills/mediaremote-adapter) (`5b6afde`, BSD-3-Clause, © Jonas van den Berg). Its dynamic library and perl loader are not used.
