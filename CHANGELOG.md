# Changelog

All notable changes to SiliconWin are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-10-03

The first public release.

### Added

- **Native macOS app** (SwiftUI) with a library of virtual machines. Each VM is a self-contained `.winvm` folder.
- **Windows 11 on Arm** at near-native speed with QEMU and Apple's Hypervisor framework: `virt` machine, GICv3, host CPU, NVMe disk, USB keyboard and tablet, VirtIO network, RNG and serial, Intel HD Audio.
- **Windows 10 and Windows 11 x64** (experimental) through QEMU's TCG emulation: q35 machine, SeaBIOS, standard VGA, e1000e network.
- **In-app download** of the official Windows ISOs from Microsoft's website. The download streams to the library drive.
- **Fully automatic installation** from a generated `autounattend.xml` on a per-VM tools disc:
  - It bypasses the Windows 11 hardware checks and sets up a GPT disk layout.
  - It installs the Pro edition with Microsoft's generic installation key.
  - It creates a local account with automatic sign-in and skips every out-of-box question.
  - It copies the Mac's time zone and keyboard layouts into Windows.
  - It answers the firmware's "boot from CD" prompt automatically and detaches the installer once Windows reports that setup has finished.
- **VirtIO drivers** (virtio-win 0.1.302) for ARM64 and x64, installed during Windows Setup through `$WinPEDriver$`.
- **TPM 2.0** for every VM through a bundled swtpm and libtpms.
- **Custom UEFI firmware** (edk2 ArmVirtQemu) with 18 high-resolution display modes and an exact custom mode passed through `fw_cfg`. That mode can be your full-screen size at 2× Retina.
- **Patched QEMU 11.1.2**:
  - The display refreshes at 60 fps instead of about 30.
  - An HVF crash (`HV_BAD_ARGUMENT`) is fixed for memory sections that aren't aligned to 16 KB pages, which affected TPM support on Apple silicon.
- **Metal display** fed by a built-in RFB client over a Unix socket. It supports desktop resizing, full screen with an auto-hiding toolbar, and screenshots of each VM for the library.
- **Mac-friendly keyboard:**
  - ⌘ shortcuts become Ctrl shortcuts, and ⌘ on its own opens Start.
  - ⌃⌥⌦ sends Ctrl+Alt+Delete.
  - Keys are sent by physical position, so every Windows layout works.
  - Text typed by automation tools and text expanders is recognized and typed as characters.
  - Key events are paced to what the USB keyboard can take.
- **Guest agent:** a SYSTEM relay plus a per-user session agent, connected to the Mac through a VirtIO serial port.
  - Clipboard sharing works both ways (text).
  - You can drag and drop files and folders to **Desktop › From Mac**.
  - The agent reports when the installation is complete.
- **Snapshots** of the disk, UEFI variables and TPM state as instant APFS clones.
- **Sparse raw disk images** with TRIM/discard, so Windows only uses the space it writes.
- **Safe quitting:** running VMs are shut down cleanly, or turned off, before the app quits.
- **Build system:**
  - Scripts build QEMU, libslirp, the firmware (with LLVM), ACPICA iasl, swtpm, libtpms and json-glib from source.
  - They bundle everything into a self-contained, ad-hoc-signed `SiliconWin.app`.
  - The app is signed with a stable designated requirement, so macOS privacy approvals survive rebuilds.

### Security

- The guest agent and its SYSTEM relay update themselves only from the SILICONWIN disc that the app attaches, which is an emulated QEMU CD drive. Before this change, a newer script on any drive was accepted, so a disc image mounted inside Windows could have run code as SYSTEM.
- Clipboard sharing never sends items that password managers mark as concealed or transient (`org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`).

[Unreleased]: https://github.com/devdasx/SiliconWin/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/devdasx/SiliconWin/releases/tag/v1.0.0
