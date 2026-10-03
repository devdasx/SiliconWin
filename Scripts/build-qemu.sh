#!/bin/bash
# Builds the custom QEMU runtime used by SiliconWin (plus libslirp for VM networking).
#
# Everything is built in $SILICONWIN_BUILD (see Scripts/env.sh), a path without
# spaces because QEMU's configure refuses directories that contain them.
#
#   Scripts/build-qemu.sh            # build + install into $SILICONWIN_BUILD/prefix
#
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=env.sh
. "$(dirname "$0")/env.sh"
PREFIX="$WORK/prefix"
SRC="$WORK/src"
VENV="$WORK/venv"
JOBS="$(sysctl -n hw.ncpu)"

# Keep temporary and cache files in the build area (which can live on an external drive).
export TMPDIR="$WORK/tmp"
export PIP_CACHE_DIR="$WORK/cache/pip"
mkdir -p "$PREFIX" "$SRC" "$TMPDIR" "$PIP_CACHE_DIR"

log() { printf '\n==> %s\n' "$*"; }

# 1. meson + ninja in a private virtualenv ------------------------------------
if [ ! -x "$VENV/bin/ninja" ] || [ ! -x "$VENV/bin/meson" ]; then
  log "Creating build virtualenv with meson + ninja"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip meson ninja
fi

export PATH="$VENV/bin:$PREFIX/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig:/opt/homebrew/opt/libffi/lib/pkgconfig"

# 2. libslirp (user-mode networking: gives the VM internet without root) -----
if [ ! -f "$PREFIX/lib/libslirp.dylib" ]; then
  log "Building libslirp $SLIRP_VERSION"
  cd "$SRC"
  curl -fsSL -o "libslirp-$SLIRP_VERSION.tar.gz" \
    "https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v$SLIRP_VERSION/libslirp-v$SLIRP_VERSION.tar.gz"
  rm -rf "libslirp-v$SLIRP_VERSION"
  tar xf "libslirp-$SLIRP_VERSION.tar.gz"
  cd "libslirp-v$SLIRP_VERSION"
  meson setup build --prefix="$PREFIX" --buildtype=release -Ddefault_library=shared
  ninja -C build install
fi

# 3. QEMU ---------------------------------------------------------------------
cd "$SRC"
if [ ! -d "qemu-$QEMU_VERSION" ]; then
  log "Downloading QEMU $QEMU_VERSION"
  curl -fSL -o "qemu-$QEMU_VERSION.tar.xz" "https://download.qemu.org/qemu-$QEMU_VERSION.tar.xz"
  tar xf "qemu-$QEMU_VERSION.tar.xz"
fi

cd "qemu-$QEMU_VERSION"

# SiliconWin patches (Scripts/patches/qemu/*.patch); skipped when already applied.
for p in "$SCRIPT_DIR"/patches/qemu/*.patch; do
  [ -f "$p" ] || continue
  if patch -p1 -N --dry-run -s < "$p" >/dev/null 2>&1; then
    log "Applying $(basename "$p")"
    patch -p1 -N -s < "$p"
  fi
done

mkdir -p build
cd build

if [ ! -f build.ninja ]; then
  log "Configuring QEMU $QEMU_VERSION"
  # aarch64: Windows 11 on ARM at native speed via Apple's Hypervisor.framework (HVF)
  # x86_64:  Windows 10/11 x64 through full CPU emulation (TCG)
  ../configure \
    --prefix="$PREFIX" \
    --target-list=aarch64-softmmu,x86_64-softmmu \
    --enable-hvf \
    --enable-cocoa \
    --enable-vnc \
    --enable-slirp \
    --enable-png \
    --enable-zstd \
    --enable-tools \
    --audio-drv-list=coreaudio \
    --disable-rust \
    --disable-docs \
    --disable-werror \
    --disable-gtk --disable-sdl --disable-sdl-image --disable-spice --disable-curses \
    --disable-gnutls --disable-nettle --disable-gcrypt \
    --disable-libssh --disable-curl --disable-capstone --disable-vde \
    --disable-libusb --disable-usb-redir --disable-smartcard \
    --disable-vnc-jpeg --disable-vnc-sasl --disable-dbus-display \
    --disable-guest-agent --disable-xkbcommon --disable-snappy --disable-lzo \
    --disable-bzip2 --disable-lzfse --disable-libnfs --disable-libiscsi \
    --disable-brlapi --disable-virglrenderer --disable-opengl \
    --disable-pvg  # apple-gfx (macOS-guest GPU) uses APIs removed in the macOS 27 SDK
fi

log "Compiling QEMU with $JOBS jobs"
ninja -j"$JOBS"

log "Installing QEMU into $PREFIX"
ninja install

log "Done"
"$PREFIX/bin/qemu-system-aarch64" --version
"$PREFIX/bin/qemu-system-x86_64" --version
"$PREFIX/bin/qemu-img" --version | head -1
