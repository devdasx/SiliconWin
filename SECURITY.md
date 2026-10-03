# Security policy

## Supported versions

SiliconWin is distributed as source code. Security fixes go to the `main` branch and appear in the next release.

| Version | Supported |
| --- | --- |
| `main` | ✅ |
| Latest release | ✅ |
| Older releases | ❌ |

## Reporting a vulnerability

**Please do not report security vulnerabilities in public issues, discussions or pull requests.**

Report them privately through GitHub:

1. Open the repository's **Security** tab.
2. Click **Report a vulnerability**. This uses GitHub's private vulnerability reporting.
3. Describe the issue, its impact and the steps to reproduce it. Include the SiliconWin commit or version, your macOS version and your Mac model.

You can expect:

- an acknowledgement within **7 days**,
- an assessment and a plan, usually within **30 days**,
- credit in the release notes once a fix ships, unless you'd rather stay anonymous.

Some vulnerabilities are in upstream components such as QEMU, edk2, swtpm or GLib. Please report those to their projects too. We'll update the bundled version or carry a patch once a fix is available.

## Threat model

SiliconWin's job is to keep Windows inside the virtual machine. Keep these boundaries in mind when you assess an issue.

### What runs where

- **SiliconWin.app** runs as your user. It is not sandboxed, because it starts helper processes, uses Unix sockets in `/tmp/siliconwin-<uid>/`, and works with VM folders anywhere you choose.
- **QEMU** runs as your user, with the `com.apple.security.hypervisor` entitlement and nothing else. A guest-to-host escape through a QEMU device-emulation bug would give an attacker your user's privileges on the Mac. To keep the attack surface small, SiliconWin attaches only a minimal set of devices.
- **swtpm** runs as your user and stores TPM state in the VM's `TPM/` folder.
- **The control sockets** (QMP, VNC, guest agent, TPM) are Unix sockets in a per-user directory created with mode `0700`. No network ports are opened. The VM's network uses user-mode NAT (slirp), and nothing is forwarded into the VM.

### Intentional channels between Windows and the Mac

| Channel | Direction | What a malicious guest could do |
| --- | --- | --- |
| Clipboard sharing (optional) | Both | Read text you copy on the Mac, and replace your Mac's clipboard text. Items that password managers mark as concealed or transient (`org.nspasteboard.ConcealedType` / `TransientType`) are never sent. |
| File transfer | Mac → Windows only | Nothing on the Mac side. Windows only receives files that you explicitly drop or send. |
| Guest agent messages | Windows → Mac | Mark the installation as complete, which detaches the installer disc, and show status messages in the app. |

If you don't trust the software running inside Windows, turn off **Share the clipboard with Windows** in SiliconWin's settings.

### Inside Windows

- The guest agent's SYSTEM relay (`agent-host.ps1`) owns the VirtIO serial port and exposes it through the named pipe `\\.\pipe\SiliconWinAgent`. Any signed-in user in the guest may open that pipe, which is how the per-user agent works.
- The relay and the agent update themselves only from the **SILICONWIN** disc that the app attaches, which is an emulated QEMU CD drive. Disc images or drives that someone mounts inside Windows are ignored, so they can't be used to run code as SYSTEM.
- The automatic setup creates a local **administrator** account. If you set a password for it, the password is stored in plain text in the VM's `config.json` and in the answer file on the VM's tools disc (`siliconwin-tools.iso`). Protect the VM folder like any file that contains a password.

### Out of scope

- Vulnerabilities in Microsoft Windows itself.
- Attacks that need write access to your Mac user account or to the VM's folder. Anyone with that access can already change the VM.
- Missing hardening that is a documented limitation, such as unsigned builds or no App Sandbox. Suggestions to improve these are welcome as regular issues.
