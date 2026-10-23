#!/bin/bash
# Downloads and verifies the sources of OpenVPN 2.6.17, OpenSSL, LZO and LZ4, builds the dependencies
# as static libraries, applies the feth patch and builds OpenVPN for macOS arm64. The result links
# only system libraries (/usr/lib).
# $DEPS/lib contains only static .a files, so -lssl etc. link statically.
# Usage:  build.sh [work directory, default /tmp/openvpn-feth]
# Result: <work directory>/build/src/openvpn/openvpn
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-/tmp/openvpn-feth}"
DL="$WORK/dl"
DEPS="$WORK/deps"            # prefix of the static libraries
SRC="$WORK/src"
JOBS="$(sysctl -n hw.ncpu)"
export MACOSX_DEPLOYMENT_TARGET=13.0
export CFLAGS="-arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2"

OVPN_VER=2.6.17
OVPN_SHA=4cc8e63f710d3001493b13d8a32cf22a214d5e4f71dd37d93831e2fd3208b370
OVPN_KEY=F554A3687412CFFEBDEFE0A312F5F7B42F2B01E7   # OpenVPN - Security Mailing List
SSL_VER=3.5.9                                        # LTS series
SSL_SHA=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
LZO_VER=2.10
LZO_SHA=c0f892943208266f9b6543b3ae308fab6284c5c90e627931446fb49b4221a072
LZ4_VER=1.10.0
LZ4_SHA=537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b

fetch() { # $1 = URL, $2 = file, $3 = sha256
    [[ -f "$DL/$2" ]] || curl -fsSL -o "$DL/$2" "$1"
    echo "$3  $DL/$2" | shasum -a 256 -c - > /dev/null || { echo "Bad checksum: $2" >&2; exit 1; }
}
unpack() { # $1 = file, $2 = directory after unpacking
    rm -rf "$SRC/$2"; tar -xzf "$DL/$1" -C "$SRC"
}

mkdir -p "$DL" "$SRC" "$WORK/build"
rm -rf "$DEPS"; mkdir -p "$DEPS"

echo "==> Downloading and verifying sources"
fetch "https://github.com/OpenVPN/openvpn/releases/download/v$OVPN_VER/openvpn-$OVPN_VER.tar.gz" "openvpn-$OVPN_VER.tar.gz" "$OVPN_SHA"
[[ -f "$DL/openvpn-$OVPN_VER.tar.gz.asc" ]] || curl -fsSL -o "$DL/openvpn-$OVPN_VER.tar.gz.asc" \
    "https://github.com/OpenVPN/openvpn/releases/download/v$OVPN_VER/openvpn-$OVPN_VER.tar.gz.asc"
gpg --list-keys "$OVPN_KEY" > /dev/null 2>&1 || gpg --keyserver hkps://keys.openpgp.org --recv-keys "$OVPN_KEY"
gpg --verify "$DL/openvpn-$OVPN_VER.tar.gz.asc" "$DL/openvpn-$OVPN_VER.tar.gz" 2> /dev/null \
    || { echo "Invalid OpenVPN signature" >&2; exit 1; }
fetch "https://github.com/openssl/openssl/releases/download/openssl-$SSL_VER/openssl-$SSL_VER.tar.gz" "openssl-$SSL_VER.tar.gz" "$SSL_SHA"
fetch "https://www.oberhumer.com/opensource/lzo/download/lzo-$LZO_VER.tar.gz" "lzo-$LZO_VER.tar.gz" "$LZO_SHA"
fetch "https://github.com/lz4/lz4/archive/refs/tags/v$LZ4_VER.tar.gz" "lz4-$LZ4_VER.tar.gz" "$LZ4_SHA"

echo "==> OpenSSL $SSL_VER (static)"
unpack "openssl-$SSL_VER.tar.gz" "openssl-$SSL_VER"
( cd "$SRC/openssl-$SSL_VER"
  ./Configure darwin64-arm64-cc no-shared no-tests no-docs no-apps no-engine no-module \
      --prefix="$DEPS" --libdir=lib --openssldir=/private/etc/ssl > "$WORK/openssl.log" 2>&1
  make -j"$JOBS" >> "$WORK/openssl.log" 2>&1
  make install_sw >> "$WORK/openssl.log" 2>&1 )

echo "==> LZO $LZO_VER (static)"
unpack "lzo-$LZO_VER.tar.gz" "lzo-$LZO_VER"
( cd "$SRC/lzo-$LZO_VER"
  ./configure --prefix="$DEPS" --disable-shared --enable-static > "$WORK/lzo.log" 2>&1
  make -j"$JOBS" install >> "$WORK/lzo.log" 2>&1 )

echo "==> LZ4 $LZ4_VER (static)"
unpack "lz4-$LZ4_VER.tar.gz" "lz4-$LZ4_VER"
( cd "$SRC/lz4-$LZ4_VER/lib"
  make -j"$JOBS" liblz4.a CFLAGS="$CFLAGS" > "$WORK/lz4.log" 2>&1
  mkdir -p "$DEPS/lib" "$DEPS/include"
  cp liblz4.a "$DEPS/lib/"; cp lz4.h lz4hc.h lz4frame.h "$DEPS/include/" )

echo "==> OpenVPN $OVPN_VER + feth patch"
unpack "openvpn-$OVPN_VER.tar.gz" "openvpn-$OVPN_VER"
patch -s -d "$SRC/openvpn-$OVPN_VER" -p1 < "$HERE/openvpn-$OVPN_VER-feth.patch"
rm -rf "$WORK/build"; mkdir -p "$WORK/build"
( cd "$WORK/build"
  "$SRC/openvpn-$OVPN_VER/configure" --disable-pkcs11 --disable-plugin-auth-pam --disable-plugin-down-root \
      --disable-dependency-tracking --disable-shared \
      OPENSSL_CFLAGS="-I$DEPS/include" OPENSSL_LIBS="-L$DEPS/lib -lssl -lcrypto" \
      LZO_CFLAGS="-I$DEPS/include" LZO_LIBS="-L$DEPS/lib -llzo2" \
      LZ4_CFLAGS="-I$DEPS/include" LZ4_LIBS="-L$DEPS/lib -llz4" \
      LDFLAGS="-L$DEPS/lib" > configure.log 2>&1
  make -j"$JOBS" > make.log 2>&1 )

BIN="$WORK/build/src/openvpn/openvpn"
strip -S "$BIN"
echo "==> Checking dependencies"
otool -L "$BIN" | tail -n +2
if otool -L "$BIN" | tail -n +2 | grep -v -E '^\s+/usr/lib/|^\s+/System/'; then
    echo "The binary links libraries outside the system" >&2; exit 1
fi
"$BIN" --version | head -2
echo "Done: $BIN"
