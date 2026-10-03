# Contributing to SiliconWin

Thanks for your interest in SiliconWin. Contributions of all sizes are welcome, from typo fixes to new features.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Ways to contribute

- **Report a bug.** Open an issue with the **Bug report** template. Logs make a huge difference, see [Collecting logs](#collecting-logs).
- **Suggest a feature.** Use the **Feature request** template and describe the problem you want solved, not only the solution.
- **Improve the documentation.** Clearer explanations, fixes and translations of the docs are always useful.
- **Send code.** Bug fixes, new features, or items from the [Limitations](README.md#limitations) list. For anything big, please open an issue first so we can agree on the approach before you invest time.

Security issues are the exception. Please report them privately as described in [SECURITY.md](SECURITY.md).

## Development setup

1. Follow [docs/BUILDING.md](docs/BUILDING.md) to install the prerequisites and run `Scripts/build-app.sh` once. That builds QEMU, the firmware and the TPM into the build area.
2. Work on the Swift code in `App/`. You can open `App/Package.swift` in Xcode, or use any editor with SwiftPM:

   ```bash
   cd App
   swift build                 # fast type-check and debug build
   ```

3. To try your changes, rebuild the app bundle. When QEMU, the firmware and the TPM are already built, this takes seconds:

   ```bash
   Scripts/build-app.sh
   open dist/SiliconWin.app
   ```

> [!TIP]
> Put `SILICONWIN_BUILD` and `SILICONWIN_APP_DIR` in `Scripts/local.env` (ignored by git) to keep the build area and the app somewhere else, such as an external SSD. See [docs/BUILDING.md](docs/BUILDING.md#configuration).

> [!WARNING]
> Don't replace `SiliconWin.app` while one of its VMs is running. QEMU runs from inside the bundle. Shut Windows down first.

## Project structure

| Path | What lives there |
| --- | --- |
| `App/Sources/SiliconWin/Engine` | VM lifecycle, the QEMU command line, QMP, sockets, snapshots |
| `App/Sources/SiliconWin/Display` | RFB client, Metal view, keyboard translation |
| `App/Sources/SiliconWin/Setup` | Answer file, tools disc, locale mapping, ISO download |
| `App/Sources/SiliconWin/UI` | SwiftUI views |
| `App/Resources/GuestTools` | Scripts that run inside Windows (CRLF line endings) |
| `Firmware/` | The patched edk2 display driver and the firmware build config |
| `Scripts/` | Build scripts, QEMU patches, the runtime bundler |

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the pieces fit together.

## Coding guidelines

### Swift

- Match the style of the surrounding code: four-space indentation and descriptive names. Use `///` doc comments that explain *why*, not *what*.
- The package builds in the Swift 5 language mode with the Swift 6 toolchain. UI and VM state live on the main actor (`@MainActor`). Do blocking work, such as disk scans, socket I/O and file copies, off the main thread.
- Keep the app free of third-party Swift dependencies unless there is a strong reason to add one.
- Don't block the UI waiting for QEMU. Talk to it asynchronously through QMP and the sockets.

### Guest tools (PowerShell / batch)

- Files in `App/Resources/GuestTools` **must keep CRLF line endings**. `.gitattributes` enforces this.
- If you change `agent.ps1`, bump `$AgentVersion`. If you change `agent-host.ps1`, bump `$HostVersion`. Existing VMs then pick up the new scripts from the SILICONWIN disc.
- Anything that runs as SYSTEM must never execute code from a location that a standard user in Windows can write to or mount.

### Shell and Python scripts

- Scripts start with `set -euo pipefail` and source `Scripts/env.sh` for paths and versions.
- Never hard-code machine-specific paths. Use `SILICONWIN_BUILD`, `SILICONWIN_APP_DIR` and the other settings in `env.sh`.
- Keep `bash -n Scripts/*.sh` and `python3 -m py_compile Scripts/bundle-runtime.py` clean. CI runs both, along with ShellCheck.

### Patches to QEMU and edk2

- Put QEMU patches in `Scripts/patches/qemu/` as `NNNN-short-description.patch`. Add a description header that explains the problem, the fix and the license of the files involved.
- Keep patches small and upstreamable where possible. If a fix belongs upstream, please consider sending it to the QEMU or edk2 project as well.

## Commit messages

- Use the imperative mood and keep the summary under about 72 characters, for example `Add shared folders through virtio-fs`.
- In the body, explain *why* the change is needed and anything non-obvious about *how* it works.
- Reference issues with `Fixes #123` where it applies.

## Pull requests

Before you open a pull request:

- [ ] `swift build` in `App/` succeeds without new warnings.
- [ ] You tested the change with a real VM where it applies. Describe what you tried in the PR.
- [ ] You updated the documentation (`README.md`, `docs/`) when behavior changes.
- [ ] You added an entry under **Unreleased** in [CHANGELOG.md](CHANGELOG.md) for user-visible changes.
- [ ] No personal data, machine-specific paths, ISOs, disk images or binaries are included.

Pull requests are reviewed as time allows. Small, focused PRs are reviewed fastest.

## Collecting logs

Bug reports are much easier to act on with logs:

| Log | Location |
| --- | --- |
| QEMU command line and messages | `<VM>.winvm/Logs/qemu.log` |
| TPM | `<VM>.winvm/Logs/swtpm.log` |
| Guest tools installation (in Windows) | `C:\Windows\Temp\SiliconWin-install.log` |
| Guest agent relay (in Windows) | `C:\ProgramData\SiliconWin\host.log` |
| Guest agent (in Windows) | `%LOCALAPPDATA%\SiliconWin\agent.log` |

Right-click a VM in the sidebar and choose **Show in Finder** to find its `.winvm` folder. Before you attach logs, check them for personal information, such as user names in paths, and redact anything you don't want to share.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE). Changes to files that come from other projects (see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)) are licensed under those files' licenses.
