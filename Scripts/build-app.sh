#!/bin/bash
# Builds SiliconWin.app: compiles the Swift app, bundles the QEMU runtime,
# firmware, TPM and Windows drivers into it, and signs it.
#
#   Scripts/build-app.sh            # -> $SILICONWIN_APP_DIR/SiliconWin.app (default: dist/)
#
# The QEMU runtime, firmware and TPM come from Scripts/build-qemu.sh,
# Scripts/build-firmware.sh and Scripts/build-tpm.sh (they run automatically
# the first time). Settings: Scripts/env.sh.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=env.sh
. "$(dirname "$0")/env.sh"
DEST_DIR="$SILICONWIN_APP_DIR"
APP="$DEST_DIR/SiliconWin.app"
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR" "$DEST_DIR"

[ -x "$WORK/prefix/bin/qemu-system-aarch64" ] || "$PROJECT/Scripts/build-qemu.sh"
[ -f "$WORK/firmware/siliconwin-aarch64-code.fd" ] || "$PROJECT/Scripts/build-firmware.sh"
[ -x "$WORK/prefix/bin/swtpm" ] || "$PROJECT/Scripts/build-tpm.sh"
VIRTIO_ISO="$WORK/downloads/virtio-win-$VIRTIO_WIN_VERSION.iso"
if [ ! -f "$VIRTIO_ISO" ]; then
  echo "==> Downloading the VirtIO drivers for Windows ($VIRTIO_WIN_VERSION)"
  mkdir -p "$WORK/downloads"
  curl -fL -o "$VIRTIO_ISO.part" \
    "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-$VIRTIO_WIN_VERSION-1/virtio-win-$VIRTIO_WIN_VERSION.iso"
  mv "$VIRTIO_ISO.part" "$VIRTIO_ISO"
fi

echo "==> Compiling SiliconWin"
cd "$PROJECT/App"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/SiliconWin"

echo "==> Assembling $APP"
STAGE="$WORK/SiliconWin.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/SiliconWin"
cp "$PROJECT/App/Resources/Info.plist" "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
if [ ! -f "$WORK/AppIcon.icns" ] || [ "$PROJECT/Scripts/make-icon.swift" -nt "$WORK/AppIcon.icns" ]; then
  swift "$PROJECT/Scripts/make-icon.swift" "$WORK/AppIcon.icns"
fi
cp "$WORK/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"

echo "==> Bundling the QEMU runtime, firmware and drivers"
python3 "$PROJECT/Scripts/bundle-runtime.py" "$STAGE"

echo "==> Signing"
# Ad-hoc signatures are identified by their code hash, which changes with every
# build, so macOS privacy prompts (e.g. access to the external drive) would
# come back after each rebuild. An explicit designated requirement based on
# the bundle identifier lets macOS remember the user's approval.
REQ='=designated => identifier "app.siliconwin.SiliconWin"'
codesign --force --sign - -r "$REQ" "$STAGE/Contents/MacOS/SiliconWin"
codesign --force --sign - -r "$REQ" "$STAGE"
codesign --verify --strict "$STAGE" && echo "signature OK"

rm -rf "$APP"
mv "$STAGE" "$APP"
echo "==> Built $APP"
