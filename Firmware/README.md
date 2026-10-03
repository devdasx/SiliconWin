# Firmware

SiliconWin boots Windows on Arm with its own build of the edk2 **ArmVirtQemu** UEFI firmware. The only functional change from QEMU's bundled firmware is a better display driver.

| File | Purpose |
| --- | --- |
| [`src/QemuRamfb.c`](src/QemuRamfb.c) | The ramfb Graphics Output Protocol driver. Offers 18 modes up to 3840×2160, plus an exact custom mode (up to 5120×2880) requested by the app through the `fw_cfg` file `opt/siliconwin/resolution`. |
| [`src/QemuRamfbDxe.inf`](src/QemuRamfbDxe.inf) | The driver's module definition. Adds `PcdLib` and the two video-resolution PCDs that the driver sets. |
| [`patches/0001-QemuRamfbDxe-high-resolution-modes.patch`](patches/0001-QemuRamfbDxe-high-resolution-modes.patch) | The same change as a patch against the edk2 tree in QEMU 11.1.2, for review and upstreaming |
| [`siliconwin-edk2.config`](siliconwin-edk2.config) | Build configuration for QEMU's `roms/edk2-build.py`. It matches QEMU's `armvirt.aa64` build and adds `PcdShadowPeimOnBoot = TRUE`, which the TPM 2.0 stack needs. |

## Why a custom driver?

Windows on Arm has no driver for QEMU's `ramfb` display. It keeps using whatever mode the firmware set up. The stock driver tops out at 1024×768, which looks blurry on a Retina display. The patched driver lets SiliconWin give Windows exactly the resolution you choose, for example your Mac's full-screen size, so each Windows pixel maps to 2×2 Retina pixels.

## Building

```bash
Scripts/build-firmware.sh     # → $SILICONWIN_BUILD/firmware/siliconwin-aarch64-code.fd
```

The build uses Homebrew LLVM (`brew install llvm lld`) through edk2's `CLANGDWARF` toolchain. See [docs/BUILDING.md](../docs/BUILDING.md#scriptsbuild-firmwaresh) for details, and [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md#firmware) for how the firmware fits in.

## License

The files in `src/` and `patches/` are derived from [TianoCore edk2](https://github.com/tianocore/edk2) and are licensed under **BSD-2-Clause-Patent**, like the originals. They aren't covered by SiliconWin's MIT license.
