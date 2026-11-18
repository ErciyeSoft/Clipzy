#!/bin/bash
# Builds the FreeRDP client libraries and OpenSSL from pinned, checksum-verified release
# tarballs into one static universal library for RemoteKit:
#
#   Vendor/FreeRDP/out/lib/libfreerdp-bundle.a   (arm64 + x86_64)
#   Vendor/FreeRDP/out/include/                  (FreeRDP, WinPR and OpenSSL headers)
#
# Run it once after cloning, and again after changing a version below. It needs cmake and
# ninja (brew install cmake ninja). Downloads and build trees stay in Vendor/FreeRDP/.build;
# both folders are ignored by git.
#
#   Vendor/FreeRDP/build.sh            build what is missing
#   Vendor/FreeRDP/build.sh --clean    start over
set -euo pipefail

FREERDP_VERSION=3.33.1
FREERDP_SHA256=4431bbf04d370545cfe2924b9d9f116b95c90c64ff156b2550bbaf82d34e7124
OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
MACOS_MIN=14.5
ARCHS=(arm64 x86_64)

ROOT="$(cd "$(dirname "$0")" && pwd)"
WORK="$ROOT/.build"
OUT="$ROOT/out"
JOBS="$(sysctl -n hw.ncpu)"

if [[ "${1:-}" == "--clean" ]]; then
  rm -rf "$WORK" "$OUT"
fi

for tool in cmake ninja perl; do
  command -v "$tool" >/dev/null || { echo "error: $tool not found (brew install cmake ninja)" >&2; exit 1; }
done

# Paths baked into the libraries (install prefix, source file names) must not reveal where
# they were built: install under a neutral prefix into a staging folder and map source paths.
PREFIX=/usr/local/kitzi-freerdp
# Given to clang through its environment: OpenSSL and FreeRDP record their CFLAGS in the binary.
export CCC_OVERRIDE_OPTIONS="#+-ffile-prefix-map=$WORK=/build"

# Keep Homebrew's libraries out: everything must come from this script or the macOS SDK.
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$WORK/no-pkgconfig"
IGNORE_PREFIXES="/opt/homebrew;/usr/local;/opt/local"

fetch() { # url sha256 file
  local url="$1" sum="$2" file="$WORK/download/$3"
  mkdir -p "$WORK/download"
  if [[ ! -f "$file" ]]; then
    echo "==> Downloading $url"
    curl -fsSL -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  echo "$sum  $file" | shasum -a 256 -c - >/dev/null || { echo "error: checksum mismatch for $file" >&2; rm -f "$file"; exit 1; }
}

unpack() { # file dir
  if [[ ! -d "$WORK/src/$2" ]]; then
    mkdir -p "$WORK/src"
    tar -xzf "$WORK/download/$1" -C "$WORK/src"
  fi
}

fetch "https://github.com/FreeRDP/FreeRDP/releases/download/$FREERDP_VERSION/freerdp-$FREERDP_VERSION.tar.gz" \
  "$FREERDP_SHA256" "freerdp-$FREERDP_VERSION.tar.gz"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" \
  "$OPENSSL_SHA256" "openssl-$OPENSSL_VERSION.tar.gz"
unpack "freerdp-$FREERDP_VERSION.tar.gz" "freerdp-$FREERDP_VERSION"
unpack "openssl-$OPENSSL_VERSION.tar.gz" "openssl-$OPENSSL_VERSION"

build_openssl() { # arch
  local arch="$1" stage="$WORK/$1/stage" dir="$WORK/$1/openssl"
  local prefix="$stage$PREFIX"
  [[ -f "$prefix/lib/libcrypto.a" && -f "$prefix/lib/libssl.a" ]] && return
  echo "==> OpenSSL $OPENSSL_VERSION ($arch)"
  rm -rf "$dir" && mkdir -p "$dir"
  local target=darwin64-arm64-cc
  [[ "$arch" == x86_64 ]] && target=darwin64-x86_64-cc
  (
    cd "$dir"
    "$WORK/src/openssl-$OPENSSL_VERSION/Configure" "$target" \
      --prefix="$PREFIX" --libdir=lib --openssldir=/private/etc/ssl \
      no-shared no-module no-dso no-engine no-apps no-docs no-tests no-ui-console no-quic \
      "-mmacosx-version-min=$MACOS_MIN" >/dev/null
    make -j"$JOBS" build_libs >/dev/null
    make install_dev DESTDIR="$stage" >/dev/null
  )
}

build_freerdp() { # arch
  local arch="$1" stage="$WORK/$1/stage" dir="$WORK/$1/freerdp"
  local prefix="$stage$PREFIX"
  [[ -f "$prefix/lib/libfreerdp3.a" ]] && return
  echo "==> FreeRDP $FREERDP_VERSION ($arch)"
  rm -rf "$dir"
  cmake -S "$WORK/src/freerdp-$FREERDP_VERSION" -B "$dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DCMAKE_IGNORE_PREFIX_PATH="$IGNORE_PREFIXES" \
    -DCMAKE_SYSTEM_IGNORE_PREFIX_PATH="$IGNORE_PREFIXES" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
    -DCMAKE_VERBOSE_MAKEFILE=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DUSE_VERSION_FROM_GIT_TAG=OFF \
    -DWITH_CCACHE=OFF -DWITH_CLANG_FORMAT=OFF -DWITH_MANPAGES=OFF \
    -DWITH_VERBOSE_WINPR_ASSERT=OFF \
    -DWITH_CLIENT_COMMON=ON -DWITH_CLIENT=OFF -DWITH_CLIENT_MAC=OFF -DWITH_CLIENT_SDL=OFF \
    -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF -DWITH_PROXY=OFF -DWITH_SHADOW=OFF -DWITH_PLATFORM_SERVER=OFF \
    -DWITH_SERVER_CHANNELS=OFF -DWITH_WINPR_TOOLS=OFF \
    -DWITH_OPENSSL=ON -DOPENSSL_ROOT_DIR="$prefix" -DOPENSSL_USE_STATIC_LIBS=ON \
    -DWITH_INTERNAL_MD4=ON -DWITH_INTERNAL_MD5=ON -DWITH_INTERNAL_RC4=ON \
    -DWITH_APPLE_VIDEOTOOLBOX=ON \
    -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF -DWITH_CAIRO=OFF -DWITH_JPEG=OFF \
    -DWITH_OPUS=OFF -DWITH_FDK_AAC=OFF -DWITH_LODEPNG=OFF \
    -DWITH_JSON_DISABLED=ON -DWITH_AAD=OFF -DWITH_CJSON=OFF \
    -DWITH_KRB5=OFF -DWITH_PKCS11=OFF -DWITH_SMARTCARD_PCSC=OFF -DWITH_SMARTCARD_EMULATE=OFF \
    -DWITH_CUPS=OFF -DWITH_FUSE=OFF -DWITH_X11=OFF -DWITH_WAYLAND=OFF -DWITH_PULSE=OFF \
    -DWITH_MACAUDIO=ON -DWITH_CLIPRDR_FILE_APPLE=OFF \
    -DCHANNEL_URBDRC=OFF -DCHANNEL_SMARTCARD=OFF -DCHANNEL_PRINTER=OFF -DCHANNEL_SERIAL=OFF \
    -DCHANNEL_PARALLEL=OFF -DCHANNEL_TSMF=OFF -DCHANNEL_RDPECAM=OFF -DCHANNEL_RDPEAR=OFF \
    -DCHANNEL_SSHAGENT=OFF -DCHANNEL_RDP2TCP=OFF -DCHANNEL_AUDIN=OFF -DCHANNEL_RDPEWA=OFF \
    >"$WORK/$arch-freerdp-configure.log"
  cmake --build "$dir" -j "$JOBS" >"$WORK/$arch-freerdp-build.log"
  DESTDIR="$stage" cmake --install "$dir" >/dev/null
}

bundle() { # arch -> one static library with FreeRDP, WinPR, the channels and OpenSSL
  local arch="$1" prefix="$WORK/$1/stage$PREFIX"
  local libs=()
  # Installed libraries, plus the channels' shared helpers that `cmake --install` leaves out.
  while IFS= read -r lib; do libs+=("$lib"); done < <(
    find "$prefix/lib" -maxdepth 1 -name '*.a'
    find "$WORK/$arch/freerdp/channels" -name '*-common.a'
  )
  libtool -static -no_warning_for_no_symbols -o "$WORK/$arch/libfreerdp-bundle.a" "${libs[@]}" 2>/dev/null
}

for arch in "${ARCHS[@]}"; do
  build_openssl "$arch"
  build_freerdp "$arch"
  bundle "$arch"
done

echo "==> Installing into $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
slices=()
for arch in "${ARCHS[@]}"; do slices+=("$WORK/$arch/libfreerdp-bundle.a"); done
lipo -create "${slices[@]}" -output "$OUT/lib/libfreerdp-bundle.a"
strip -S "$OUT/lib/libfreerdp-bundle.a" 2>/dev/null || true
first="$WORK/${ARCHS[0]}/stage$PREFIX/include"
cp -R "$first/freerdp3/freerdp" "$OUT/include/"
cp -R "$first/winpr3/winpr" "$OUT/include/"
cp -R "$first/openssl" "$OUT/include/"
echo "$FREERDP_VERSION" >"$OUT/FREERDP_VERSION"
if strings "$OUT/lib/libfreerdp-bundle.a" | grep -q "$ROOT"; then
  echo "warning: the library still contains build paths" >&2
fi
echo "Done: $(du -h "$OUT/lib/libfreerdp-bundle.a" | cut -f1) $OUT/lib/libfreerdp-bundle.a"
