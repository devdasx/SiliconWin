# Building SiliconWin

SiliconWin is built from source with a handful of scripts. One command builds everything:

```bash
Scripts/build-app.sh
```

The first run builds the third-party runtime (QEMU, UEFI firmware, TPM), which takes a while. After that, the script only recompiles the app and re-bundles, which takes seconds.

`make app` does the same thing, and `make help` lists the other targets.

- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [What the scripts do](#what-the-scripts-do)
- [Rebuilding parts](#rebuilding-parts)
- [Working on the app](#working-on-the-app)
- [Continuous integration](#continuous-integration)
- [Distributing builds](#distributing-builds)
- [Build problems](#build-problems)

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Mac with Apple silicon | The scripts build arm64 binaries |
| macOS 14 or later | Developed on macOS 27 |
| Xcode 16 or later | Provides Swift 6 and the macOS SDK (macOS 15 SDK or later) |
| [Homebrew](https://brew.sh) | Expected at `/opt/homebrew` |
| Python 3.9+ | The system `python3` works. Meson and Ninja are installed into a private virtualenv automatically. |
| About 5 GB of free space | For sources, toolchains and build output in the build area |
| Internet access | The scripts download QEMU, libslirp, json-glib, libtpms, swtpm, ACPICA and the virtio-win ISO |

Install the Homebrew packages:

```bash
brew install glib pixman libpng zstd llvm lld openssl@3 gnutls libtasn1 \
             autoconf automake libtool pkgconf
```

| Packages | Needed for |
| --- | --- |
| `glib`, `pixman`, `libpng`, `zstd` | QEMU |
| `llvm`, `lld` | The UEFI firmware (edk2's `CLANGDWARF` toolchain) |
| `openssl@3`, `gnutls`, `libtasn1`, `autoconf`, `automake`, `libtool`, `pkgconf` | libtpms and swtpm |

## Configuration

All scripts read their settings from [`Scripts/env.sh`](../Scripts/env.sh). You can override each setting with an environment variable, or permanently in **`Scripts/local.env`**. Git ignores that file, so it's the place for machine-specific paths.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SILICONWIN_BUILD` | `~/SiliconWin-build` | Build area for sources, toolchains and output (about 4.5 GB). **Must not contain spaces**, because QEMU's `configure` and edk2 refuse such paths. |
| `SILICONWIN_APP_DIR` | `<repo>/dist` | Where the finished `SiliconWin.app` goes |
| `QEMU_VERSION` | `11.1.2` | QEMU release to build. The patches in `Scripts/patches/qemu` target this version. |
| `SLIRP_VERSION` | `4.9.5` | libslirp |
| `JSONGLIB_VERSION` / `LIBTPMS_VERSION` / `SWTPM_VERSION` | `1.10.8` / `0.10.2` / `0.10.2` | TPM stack |
| `VIRTIO_WIN_VERSION` | `0.1.302` | VirtIO drivers for Windows |
| `LLVM_PREFIX` | `/opt/homebrew/opt/llvm` | LLVM used for the firmware |
| `OPENSSL_PREFIX` | `/opt/homebrew/opt/openssl@3` | OpenSSL used by libtpms and swtpm |

For example, to keep everything on an external SSD:

```bash
# Scripts/local.env
SILICONWIN_BUILD=/Volumes/MySSD/siliconwin-build
SILICONWIN_APP_DIR=/Volumes/MySSD/Applications
```

If the app lives on an external drive, SiliconWin keeps its VM library on the same drive by default. That makes a dedicated SSD a convenient home for the app, its installers and its Windows disks.

## What the scripts do

`build-app.sh` runs the other scripts the first time their output is missing.

### `Scripts/build-qemu.sh`

1. Creates a Python virtualenv with Meson and Ninja in `$SILICONWIN_BUILD/venv`.
2. Builds **libslirp** into `$SILICONWIN_BUILD/prefix`.
3. Downloads **QEMU** and applies the patches in [`Scripts/patches/qemu`](../Scripts/patches/qemu). Patches that are already applied are skipped.
4. Configures QEMU for the `aarch64-softmmu` and `x86_64-softmmu` targets with HVF, Cocoa, VNC, slirp, PNG, zstd and CoreAudio. Unneeded features are disabled. `--disable-pvg` works around `apple-gfx` APIs that were removed from the macOS 27 SDK.
5. Builds and installs QEMU into the prefix.

### `Scripts/build-firmware.sh`

1. Makes a private copy of the edk2 tree that ships inside the QEMU tarball (`roms/edk2`).
2. Copies SiliconWin's ramfb driver ([`Firmware/src`](../Firmware/src)) over the original, with CRLF line endings like the rest of edk2.
3. Builds **ACPICA `iasl`**, which the firmware needs. It links with `-Wl,-no_fixup_chains`, because Apple's linker rejects ACPICA's unaligned pointers otherwise.
4. Builds edk2's BaseTools with Apple clang. `-Wno-error` is needed because the macOS SDK already defines `UINT8_MAX` and similar macros.
5. Runs QEMU's `edk2-build.py` with [`Firmware/siliconwin-edk2.config`](../Firmware/siliconwin-edk2.config) and the `CLANGDWARF` toolchain from Homebrew LLVM.
6. Pads `siliconwin-aarch64-code.fd` to the 64 MiB that QEMU's pflash device expects. `edk2-build.py` would do this with GNU `truncate`, which macOS doesn't have.

### `Scripts/build-tpm.sh`

Builds **json-glib**, **libtpms** and **swtpm** into the same prefix.

### `Scripts/build-app.sh`

1. Downloads the **virtio-win** ISO if it isn't in `$SILICONWIN_BUILD/downloads` yet.
2. Compiles the app with `swift build -c release --arch arm64`.
3. Assembles `SiliconWin.app`: the executable, `Info.plist` and an icon drawn by [`Scripts/make-icon.swift`](../Scripts/make-icon.swift).
4. Runs [`Scripts/bundle-runtime.py`](../Scripts/bundle-runtime.py), which:
   - copies the QEMU binaries and swtpm, plus every non-system dylib they need,
   - rewrites the install names so the bundle is self-contained,
   - signs the QEMU binaries with the hypervisor entitlement,
   - copies the firmware and QEMU data files,
   - extracts the VirtIO drivers from the ISO, and
   - copies the Windows guest tools.
5. Signs the app ad hoc with a stable designated requirement (see [ARCHITECTURE.md](ARCHITECTURE.md#packaging-and-signing)).
6. Moves the result to `$SILICONWIN_APP_DIR/SiliconWin.app`, replacing any previous build.

> [!WARNING]
> Don't run `build-app.sh` while a VM is running from the app you are replacing. Shut Windows down first.

## Rebuilding parts

Each script skips work whose output already exists. To force a rebuild, remove that output:

| To rebuild | Remove | Then run |
| --- | --- | --- |
| The app only | Nothing | `Scripts/build-app.sh` |
| QEMU (for example after changing a patch) | `$SILICONWIN_BUILD/src/qemu-<version>` and `$SILICONWIN_BUILD/prefix/bin/qemu-system-*` | `Scripts/build-qemu.sh` |
| The firmware | Nothing, it is always rebuilt | `Scripts/build-firmware.sh` |
| The TPM stack | `$SILICONWIN_BUILD/prefix/bin/swtpm` (and its libraries) | `Scripts/build-tpm.sh` |
| Everything | `$SILICONWIN_BUILD` | `Scripts/build-app.sh` |

`build-firmware.sh` always re-copies `Firmware/src` and re-runs the edk2 build, so you can run it directly after you edit the driver.

Updating a pinned version, such as `QEMU_VERSION`, may require refreshing the patches. QEMU's tarball also contains the edk2 tree the firmware is built from.

## Working on the app

The app is a plain Swift package in [`App/`](../App):

```bash
cd App
swift build                     # debug build, quick feedback
open Package.swift              # or work in Xcode
```

Running the bare executable from `.build/` won't find the QEMU runtime, which lives in the app bundle. Use `Scripts/build-app.sh` to test changes end to end. Once the runtime is built, it only recompiles and re-bundles.

## Continuous integration

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on every push and pull request:

- builds the Swift package on macOS runners,
- checks the shell scripts with `bash -n` and [ShellCheck](https://www.shellcheck.net),
- byte-compiles the Python bundler, and
- verifies that the guest tools keep CRLF line endings.

CI doesn't build QEMU, the firmware or the TPM stack, because they take too long for every push.

## Distributing builds

This repository doesn't publish binaries. If you distribute a built `SiliconWin.app`:

- **Comply with the licenses of the bundled components.** QEMU is GPL-2.0, and GLib and json-glib are LGPL. Among other things, this means you must offer the corresponding source code, including SiliconWin's patches. See [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
- **Sign and notarize.** Ad-hoc signed apps from the internet are blocked by Gatekeeper. To distribute, sign every binary and dylib in the bundle with a Developer ID certificate, enable the hardened runtime, and notarize the app. QEMU needs `com.apple.security.hypervisor`. The x86 emulator (TCG) also needs `com.apple.security.cs.allow-jit` under the hardened runtime.

## Build problems

| Symptom | Fix |
| --- | --- |
| `SILICONWIN_BUILD must not contain spaces` | Point `SILICONWIN_BUILD` at a path without spaces. The repository itself may live in a path with spaces. |
| `ERROR: Dependency "glib-2.0" not found` (or `pixman`, `libpng`, …) | Install the Homebrew packages listed above. Check that `/opt/homebrew/bin/pkg-config` exists. |
| `error: LLVM not found` / `ld.lld not found` | Run `brew install llvm lld`, or set `LLVM_PREFIX`. |
| QEMU fails to compile `apple-gfx` | Make sure `--disable-pvg` is in the configure flags (it is by default). |
| BaseTools: `'UINT8_MAX' macro redefined` treated as an error | Already handled by `EXTRA_OPTFLAGS=-Wno-error` in `build-firmware.sh`. |
| `iasl` link error about unaligned pointers | Already handled by `-Wl,-no_fixup_chains`. |
| libtpms/swtpm `configure` can't find OpenSSL | Install `openssl@3`, or set `OPENSSL_PREFIX`. |
| The VM fails with `could not find keymap file` | The app bundle is incomplete. Re-run `Scripts/build-app.sh`, which copies QEMU's keymaps. |
| macOS asks for access to a removable volume after every build | Make sure the app was signed by `build-app.sh`, which uses a stable designated requirement. Approve the prompt once. |
