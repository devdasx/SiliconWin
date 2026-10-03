#!/bin/bash
# Builds a software TPM 2.0 for SiliconWin VMs: json-glib -> libtpms -> swtpm,
# installed into the same prefix as QEMU ($SILICONWIN_BUILD/prefix).
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=env.sh
. "$(dirname "$0")/env.sh"
PREFIX="$WORK/prefix"
SRC="$WORK/src"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
OPENSSL="${OPENSSL_PREFIX:-/opt/homebrew/opt/openssl@3}"

export TMPDIR="$WORK/tmp"
export PATH="$WORK/venv/bin:$PREFIX/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$OPENSSL/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:/opt/homebrew/opt/libffi/lib/pkgconfig"
export CPPFLAGS="-I$PREFIX/include -I$OPENSSL/include -I/opt/homebrew/include"
export LDFLAGS="-L$PREFIX/lib -L$OPENSSL/lib -L/opt/homebrew/lib"
export LIBTOOLIZE=glibtoolize
mkdir -p "$SRC" "$TMPDIR"

log() { printf '\n==> %s\n' "$*"; }

# json-glib (needed by swtpm_setup / swtpm's JSON output)
if [ ! -f "$PREFIX/lib/pkgconfig/json-glib-1.0.pc" ]; then
  log "json-glib $JSONGLIB_VERSION"
  cd "$SRC"
  curl -fsSL -o "json-glib-$JSONGLIB_VERSION.tar.xz" \
    "https://download.gnome.org/sources/json-glib/${JSONGLIB_VERSION%.*}/json-glib-$JSONGLIB_VERSION.tar.xz"
  rm -rf "json-glib-$JSONGLIB_VERSION" && tar xf "json-glib-$JSONGLIB_VERSION.tar.xz"
  cd "json-glib-$JSONGLIB_VERSION"
  meson setup build --prefix="$PREFIX" --buildtype=release -Dintrospection=disabled \
    -Dtests=false -Ddocumentation=disabled -Dman=false -Dnls=disabled
  ninja -C build -j"$JOBS" install
fi

# libtpms (the TPM 2.0 implementation)
if [ ! -f "$PREFIX/lib/pkgconfig/libtpms.pc" ]; then
  log "libtpms $LIBTPMS_VERSION"
  cd "$SRC"
  curl -fsSL -o "libtpms-$LIBTPMS_VERSION.tar.gz" \
    "https://github.com/stefanberger/libtpms/archive/refs/tags/v$LIBTPMS_VERSION.tar.gz"
  rm -rf "libtpms-$LIBTPMS_VERSION" && tar xf "libtpms-$LIBTPMS_VERSION.tar.gz"
  cd "libtpms-$LIBTPMS_VERSION"
  autoreconf -fi >/dev/null
  ./configure --prefix="$PREFIX" --with-openssl --with-tpm2 --disable-static >/dev/null
  make -j"$JOBS" >/dev/null
  make install >/dev/null
fi

# swtpm (TPM emulator process that QEMU talks to)
if [ ! -x "$PREFIX/bin/swtpm" ]; then
  log "swtpm $SWTPM_VERSION"
  cd "$SRC"
  curl -fsSL -o "swtpm-$SWTPM_VERSION.tar.gz" \
    "https://github.com/stefanberger/swtpm/archive/refs/tags/v$SWTPM_VERSION.tar.gz"
  rm -rf "swtpm-$SWTPM_VERSION" && tar xf "swtpm-$SWTPM_VERSION.tar.gz"
  cd "swtpm-$SWTPM_VERSION"
  autoreconf -fi >/dev/null
  ./configure --prefix="$PREFIX" --with-openssl --without-seccomp --disable-tests \
    --with-gnutls >/dev/null
  make -j"$JOBS"
  make install >/dev/null
fi

log "Done"
"$PREFIX/bin/swtpm" --version
