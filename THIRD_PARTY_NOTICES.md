# Third-party notices

SiliconWin's own source code is licensed under the [MIT License](LICENSE). This document lists:

- files in this repository that come from or modify other projects, and
- the third-party components that `Scripts/build-app.sh` builds or downloads and bundles into `SiliconWin.app`.

Each component keeps its own license. The links point to the authoritative license texts.

> [!IMPORTANT]
> A built `SiliconWin.app` contains software under the GNU GPL and LGPL. QEMU is the most important example. If you **redistribute** a built app (as a download, a disk image, etc.), you must meet those licenses. In particular, you must make the corresponding source code available, including the patches in this repository. This repository does not publish binaries.

## Files in this repository

| Path | Origin | License |
| --- | --- | --- |
| `Firmware/src/QemuRamfb.c`, `Firmware/src/QemuRamfbDxe.inf` | Modified copies of `OvmfPkg/QemuRamfbDxe` from [TianoCore edk2](https://github.com/tianocore/edk2). Copyright (c) 2018, Red Hat Inc. | [BSD-2-Clause-Patent](https://spdx.org/licenses/BSD-2-Clause-Patent.html) |
| `Firmware/patches/0001-QemuRamfbDxe-high-resolution-modes.patch` | Diff of the files above against edk2 | BSD-2-Clause-Patent |
| `Firmware/siliconwin-edk2.config` | Based on QEMU's `roms/edk2-build.config` | GPL-2.0-or-later (QEMU) |
| `Scripts/patches/qemu/0001-ui-60fps-display-refresh.patch` | Changes to QEMU's `include/ui/console.h` and `ui/vnc.c` | GPL-2.0-or-later and [MIT](https://spdx.org/licenses/MIT.html) (the licenses of those files) |
| `Scripts/patches/qemu/0002-hvf-skip-unaligned-sections.patch` | Change to QEMU's `accel/hvf/hvf-all.c` | [GPL-2.0-or-later](https://spdx.org/licenses/GPL-2.0-or-later.html) |

## Components bundled in SiliconWin.app

`Scripts/build-app.sh` and `Scripts/bundle-runtime.py` put these components into the app.

### Executables (`Contents/MacOS`)

| Component | Version | License | Source |
| --- | --- | --- | --- |
| QEMU (`qemu-system-aarch64`, `qemu-system-x86_64`, `qemu-img`) | 11.1.2 with the patches above | [GPL-2.0-only](https://gitlab.com/qemu-project/qemu/-/blob/master/LICENSE) overall. Individual files may be under compatible licenses. | <https://download.qemu.org> |
| swtpm | 0.10.2 | [BSD-3-Clause](https://github.com/stefanberger/swtpm/blob/master/LICENSE) | <https://github.com/stefanberger/swtpm> |

### Libraries (`Contents/Frameworks`)

| Library | License | Source |
| --- | --- | --- |
| libslirp 4.9.5 | [BSD-3-Clause](https://gitlab.freedesktop.org/slirp/libslirp/-/blob/master/COPYRIGHT) | <https://gitlab.freedesktop.org/slirp/libslirp> |
| libtpms 0.10.2 | [BSD-3-Clause](https://github.com/stefanberger/libtpms/blob/master/LICENSE) | <https://github.com/stefanberger/libtpms> |
| libswtpm_libtpms (part of swtpm) | BSD-3-Clause | <https://github.com/stefanberger/swtpm> |
| json-glib 1.10.8 | [LGPL-2.1-or-later](https://gitlab.gnome.org/GNOME/json-glib/-/blob/master/COPYING) | <https://gitlab.gnome.org/GNOME/json-glib> |
| GLib (libglib, libgio, libgobject, libgmodule) | [LGPL-2.1-or-later](https://gitlab.gnome.org/GNOME/glib/-/blob/main/COPYING) | <https://gitlab.gnome.org/GNOME/glib> (via Homebrew) |
| gettext runtime (libintl) | [LGPL-2.1-or-later](https://www.gnu.org/software/gettext/) | <https://www.gnu.org/software/gettext/> (via Homebrew) |
| PCRE2 (libpcre2-8) | [BSD-3-Clause WITH PCRE2-exception](https://github.com/PCRE2Project/pcre2/blob/master/LICENCE.md) | <https://github.com/PCRE2Project/pcre2> (via Homebrew) |
| pixman | [MIT](https://gitlab.freedesktop.org/pixman/pixman/-/blob/master/COPYING) | <https://gitlab.freedesktop.org/pixman/pixman> (via Homebrew) |
| libpng | [libpng-2.0](http://www.libpng.org/pub/png/src/libpng-LICENSE.txt) | <http://www.libpng.org/pub/png/libpng.html> (via Homebrew) |
| Zstandard (libzstd) | [BSD-3-Clause](https://github.com/facebook/zstd/blob/dev/LICENSE) (dual-licensed with GPL-2.0-only) | <https://github.com/facebook/zstd> (via Homebrew) |
| OpenSSL (libcrypto) 3 | [Apache-2.0](https://www.openssl.org/source/license.html) | <https://www.openssl.org> (via Homebrew) |

The exact versions of the Homebrew libraries depend on the machine that builds the app.

### Firmware and data (`Contents/Resources/qemu`)

| File | Component | License |
| --- | --- | --- |
| `siliconwin-aarch64-code.fd` | edk2 ArmVirtQemu, built from QEMU 11.1.2's `roms/edk2` with the ramfb change above. It includes edk2 modules under BSD-2-Clause-Patent, plus OpenSSL (Apache-2.0) and other components listed in `edk2-licenses.txt`. | BSD-2-Clause-Patent and others |
| `edk2-arm-vars.fd` | edk2 variable store template (from QEMU) | BSD-2-Clause-Patent |
| `edk2-licenses.txt` | The edk2 license summary shipped with QEMU | n/a |
| `bios-256k.bin` | [SeaBIOS](https://www.seabios.org) | LGPL-3.0-only |
| `vgabios-stdvga.bin` | SeaVGABIOS (part of SeaBIOS) | LGPL-3.0-only |
| `efi-e1000.rom`, `efi-e1000e.rom`, `efi-virtio.rom` | [iPXE](https://ipxe.org) option ROMs (from QEMU) | GPL-2.0-or-later (with the UBDL exception where applicable) |
| `kvmvapic.bin`, `linuxboot_dma.bin` | QEMU option ROMs | GPL-2.0-or-later |
| `keymaps/` | QEMU keyboard maps | GPL-2.0-or-later |

### Windows drivers (`Contents/Resources/Drivers`)

| Component | License | Source |
| --- | --- | --- |
| VirtIO drivers for Windows (NetKVM, viorng, vioserial, Balloon, pvpanic), from virtio-win 0.1.302 | [BSD-3-Clause](https://github.com/virtio-win/kvm-guest-drivers-windows/blob/master/LICENSE) source. The binaries come from Red Hat and are distributed by the Fedora Project; see the license files on the virtio-win ISO. | <https://github.com/virtio-win/kvm-guest-drivers-windows>, binaries from <https://fedorapeople.org/groups/virt/virtio-win/> |

## Build-time tools (not bundled)

| Tool | Used for | License |
| --- | --- | --- |
| [ACPICA](https://github.com/acpica/acpica) `iasl` | Compiling ACPI tables in the firmware build | Intel ACPI license, or BSD-3-Clause / GPL-2.0 (triple-licensed) |
| [LLVM](https://llvm.org) (clang, lld) | Building the firmware | Apache-2.0 WITH LLVM-exception |
| [Meson](https://mesonbuild.com), [Ninja](https://ninja-build.org) | Building QEMU, libslirp and json-glib | Apache-2.0 |

## Not included

**Microsoft Windows is not part of SiliconWin.** You download Windows installation media yourself from Microsoft's website, inside the app or elsewhere. Your use of Windows is governed by Microsoft's license terms. SiliconWin uses Microsoft's published generic installation key only to select the edition during setup. That key doesn't activate Windows.
