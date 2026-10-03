# shellcheck shell=bash
# shellcheck disable=SC2034  # the variables are used by the scripts that source this file
# SPDX-License-Identifier: MIT
# Shared build settings, sourced by the Scripts/build-*.sh scripts.
#
# Override any of these in your environment or in Scripts/local.env
# (ignored by git), for example to build on an external drive:
#
#   SILICONWIN_BUILD=/Volumes/MyDrive/siliconwin-build
#   SILICONWIN_APP_DIR=/Volumes/MyDrive/Applications

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -f "$SCRIPT_DIR/local.env" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/local.env"
fi

# Work area for third-party sources, toolchains and build output (~4.5 GB).
# QEMU's configure and edk2 refuse paths that contain spaces.
SILICONWIN_BUILD="${SILICONWIN_BUILD:-$HOME/SiliconWin-build}"
# Where Scripts/build-app.sh puts the finished SiliconWin.app.
SILICONWIN_APP_DIR="${SILICONWIN_APP_DIR:-$PROJECT/dist}"

case "$SILICONWIN_BUILD" in
  *" "*)
    echo "error: SILICONWIN_BUILD must not contain spaces (QEMU and edk2 refuse them): $SILICONWIN_BUILD" >&2
    exit 1
    ;;
esac

export SILICONWIN_BUILD SILICONWIN_APP_DIR
WORK="$SILICONWIN_BUILD"

# Pinned third-party versions.
QEMU_VERSION="${QEMU_VERSION:-11.1.2}"
SLIRP_VERSION="${SLIRP_VERSION:-4.9.5}"
JSONGLIB_VERSION="${JSONGLIB_VERSION:-1.10.8}"
LIBTPMS_VERSION="${LIBTPMS_VERSION:-0.10.2}"
SWTPM_VERSION="${SWTPM_VERSION:-0.10.2}"
VIRTIO_WIN_VERSION="${VIRTIO_WIN_VERSION:-0.1.302}"
export VIRTIO_WIN_VERSION
