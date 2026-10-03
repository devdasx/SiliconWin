# Scripts

Build tooling for SiliconWin. Start with [docs/BUILDING.md](../docs/BUILDING.md).

| Script | What it does |
| --- | --- |
| [`build-app.sh`](build-app.sh) | **Main entry point.** Builds the runtime when it's missing, compiles the app, bundles everything and signs it. The result is `$SILICONWIN_APP_DIR/SiliconWin.app`. |
| [`build-qemu.sh`](build-qemu.sh) | Builds libslirp and QEMU (with the patches below) into `$SILICONWIN_BUILD/prefix` |
| [`build-firmware.sh`](build-firmware.sh) | Builds the UEFI firmware with the high-resolution display driver from [`Firmware/`](../Firmware) |
| [`build-tpm.sh`](build-tpm.sh) | Builds json-glib, libtpms and swtpm (the software TPM 2.0) |
| [`bundle-runtime.py`](bundle-runtime.py) | Copies QEMU, swtpm and their dylibs into the app bundle, makes it self-contained, signs the binaries, and adds the firmware, drivers and guest tools |
| [`make-icon.swift`](make-icon.swift) | Draws the app icon with Core Graphics and writes `AppIcon.icns` |
| [`env.sh`](env.sh) | Shared settings (paths and pinned versions), sourced by every build script. Put local overrides in `Scripts/local.env`, which git ignores. |

## QEMU patches

| Patch | Why |
| --- | --- |
| [`0001-ui-60fps-display-refresh.patch`](patches/qemu/0001-ui-60fps-display-refresh.patch) | Refreshes the display at 60 fps instead of about 30. Also stops the VNC server from backing off to one update every 3 s when the screen is idle. |
| [`0002-hvf-skip-unaligned-sections.patch`](patches/qemu/0002-hvf-skip-unaligned-sections.patch) | Fixes an `HV_BAD_ARGUMENT` crash when a TPM is attached under HVF on Macs with 16 KB pages |

`build-qemu.sh` applies every `patches/qemu/*.patch` in order and skips patches that are already applied. The patches are licensed like the QEMU files they modify (GPL-2.0-or-later, and MIT for `ui/vnc.c`). They aren't covered by SiliconWin's MIT license.
