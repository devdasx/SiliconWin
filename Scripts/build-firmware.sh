#!/bin/bash
# Builds SiliconWin's UEFI firmware (edk2 ArmVirtQemu, AArch64) with the
# high-resolution ramfb display driver from Firmware/src/QemuRamfb.c.
#
# Toolchain: Homebrew LLVM (clang + lld) through edk2's CLANGDWARF profile.
# Needs the QEMU source tree from Scripts/build-qemu.sh (edk2 ships inside it).
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=env.sh
. "$(dirname "$0")/env.sh"
QEMU_SRC="$WORK/src/qemu-$QEMU_VERSION"
EDK2="$WORK/src/edk2"
LLVM="${LLVM_PREFIX:-/opt/homebrew/opt/llvm}"

export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR" "$WORK/firmware"

if [ ! -d "$QEMU_SRC/roms/edk2" ]; then
  echo "error: $QEMU_SRC not found; run Scripts/build-qemu.sh first" >&2
  exit 1
fi
if [ ! -x "$LLVM/bin/clang" ]; then
  echo "error: LLVM not found at $LLVM (brew install llvm lld, or set LLVM_PREFIX)" >&2
  exit 1
fi
if [ ! -x "$LLVM/bin/ld.lld" ] && ! PATH="/opt/homebrew/bin:$PATH" command -v ld.lld >/dev/null; then
  echo "error: ld.lld not found (brew install lld)" >&2
  exit 1
fi

# 1. Private copy of the edk2 tree that ships inside the QEMU tarball.
if [ ! -d "$EDK2" ]; then
  cp -Rc "$QEMU_SRC/roms/edk2" "$EDK2" 2>/dev/null || cp -R "$QEMU_SRC/roms/edk2" "$EDK2"
fi

# 2. Our patched ramfb driver (CRLF line endings, like the rest of edk2).
for f in QemuRamfb.c QemuRamfbDxe.inf; do
  python3 -c "import sys; d = open(sys.argv[1], 'rb').read().replace(b'\r\n', b'\n'); open(sys.argv[2], 'wb').write(d.replace(b'\n', b'\r\n'))" \
    "$PROJECT/Firmware/src/$f" "$EDK2/OvmfPkg/QemuRamfbDxe/$f"
done

# 3. iasl (ACPI compiler, needed by a few drivers) from ACPICA, built locally.
if [ ! -x "$WORK/prefix/bin/iasl" ]; then
  ACPICA_TAG=$(curl -sL "https://api.github.com/repositories/2173926/releases/latest" |
               python3 -c "import sys, json; print(json.load(sys.stdin)['tag_name'])")
  rm -rf "$WORK/src/acpica-src" && mkdir -p "$WORK/src/acpica-src" "$WORK/prefix/bin"
  curl -fsSL "https://github.com/acpica/acpica/archive/refs/tags/$ACPICA_TAG.tar.gz" |
    tar xz -C "$WORK/src/acpica-src" --strip-components 1
  # Apple's linker rejects ACPICA's unaligned pointers unless chained fixups are off.
  LDFLAGS="-Wl,-no_fixup_chains" make -C "$WORK/src/acpica-src" iasl -j"$(sysctl -n hw.ncpu)" >/dev/null
  cp "$WORK/src/acpica-src/generate/unix/bin/iasl" "$WORK/prefix/bin/"
fi

# 4. Build BaseTools (host tools) with Apple's clang, then the firmware.
export PATH="$LLVM/bin:$WORK/prefix/bin:$WORK/venv/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export IASL_PREFIX="$WORK/prefix/bin/"
export CLANGDWARF_BIN="$LLVM/bin/"
export PYTHON_COMMAND=python3
# The macOS 27 SDK already defines UINT8_MAX etc.; BaseTools builds with -Werror.
make -C "$EDK2/BaseTools" -j"$(sysctl -n hw.ncpu)" CC=/usr/bin/clang CXX=/usr/bin/clang++ \
  EXTRA_OPTFLAGS="-Wno-error" >/dev/null

# edk2 refuses a WORKSPACE (current directory) that contains spaces.
cd "$WORK"
python3 "$QEMU_SRC/roms/edk2-build.py" \
  --config "$PROJECT/Firmware/siliconwin-edk2.config" \
  --core "$EDK2" \
  --match armvirt.aa64 \
  --toolchain CLANGDWARF \
  --jobs "$(sysctl -n hw.ncpu)"

# QEMU's pflash needs the image padded to exactly 64 MiB (edk2-build.py's
# padding step relies on GNU truncate, which macOS doesn't have).
python3 -c "import sys; f = open(sys.argv[1], 'r+b'); f.truncate(64 << 20)" \
  "$WORK/firmware/siliconwin-aarch64-code.fd"
ls -l "$WORK/firmware/siliconwin-aarch64-code.fd"
