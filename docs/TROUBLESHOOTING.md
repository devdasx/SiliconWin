# Troubleshooting

If the answer isn't here, please [open an issue](https://github.com/devdasx/SiliconWin/issues/new/choose) and attach the relevant [logs](#log-files).

- [Log files](#log-files)
- [Starting and installing](#starting-and-installing)
- [Display](#display)
- [Keyboard and mouse](#keyboard-and-mouse)
- [Clipboard and file transfer](#clipboard-and-file-transfer)
- [Network and sound](#network-and-sound)
- [Performance](#performance)
- [Storage and snapshots](#storage-and-snapshots)
- [macOS permissions](#macos-permissions)

## Log files

| Log | Where | Contains |
| --- | --- | --- |
| `qemu.log` | `<VM>.winvm/Logs/` (the previous run is kept as `qemu-previous.log`) | The full QEMU command line and QEMU's messages |
| `swtpm.log` | `<VM>.winvm/Logs/` | TPM emulator messages |
| `SiliconWin-install.log` | `C:\Windows\Temp\` in Windows | Guest tools installation at the end of Setup |
| `host.log` | `C:\ProgramData\SiliconWin\` in Windows | The SYSTEM relay that owns the VirtIO serial port |
| `agent.log` | `%LOCALAPPDATA%\SiliconWin\` in Windows | The session agent (clipboard, files) |

To open a VM's folder, right-click the VM in the sidebar and choose **Show in Finder**.

## Starting and installing

<details>
<summary><b>"Missing runtime components" when starting a VM</b></summary>

The app bundle doesn't contain QEMU, the firmware or the drivers. This happens when you run the executable from `App/.build` directly. Build the complete app with `Scripts/build-app.sh` and run `dist/SiliconWin.app`, or the app in your `SILICONWIN_APP_DIR`.
</details>

<details>
<summary><b>"The installer ISO is missing"</b></summary>

The ISO was moved or deleted, or it's on a drive that isn't connected. Open the VM's **Settings…** and choose the ISO again under **Installation**. Or download it again with **Download from Microsoft…**.
</details>

<details>
<summary><b>The VM shows a UEFI menu or "No bootable device" instead of Windows Setup</b></summary>

On the first start, SiliconWin answers the *"Press any key to boot from CD or DVD"* prompt automatically. If the prompt was missed:

1. Click **Restart** in the toolbar.
2. Click into the VM window and press Enter as soon as the prompt appears.

Also make sure the installer matches the edition: an **Arm64** ISO for Windows on Arm, an **x64** ISO otherwise.
</details>

<details>
<summary><b>Windows Setup says "This PC can't run Windows 11"</b></summary>

Automatic setup bypasses these checks. If you install manually, follow these steps:

1. Press Shift+F10 on the first Setup screen.
2. Type `regedit`.
3. Under `HKEY_LOCAL_MACHINE\SYSTEM\Setup`, create the key `LabConfig`.
4. In that key, add the DWORD values `BypassTPMCheck`, `BypassSecureBootCheck` and `BypassRAMCheck`, each set to `1`.
5. Go back one step in Setup and continue.

Alternatively, recreate the VM with **Install Windows automatically** turned on.
</details>

<details>
<summary><b>Windows insists on a network connection or a Microsoft account</b></summary>

Automatic setup handles this with a local account. During a manual setup:

1. Press Shift+F10.
2. Run `reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f`.
3. Run `shutdown /r /t 0`.
4. After the restart, choose **I don't have internet** on the network screen.
</details>

<details>
<summary><b>The installation seems stuck</b></summary>

Installing takes 15–30 minutes, and the screen can stay black or show a spinner for several minutes while Windows works. Windows also installs updates during and after setup ("Updates are underway"). Give it time. As long as QEMU uses CPU in Activity Monitor, Windows is working.

If nothing changes for a very long time, check `qemu.log`. As a last resort, choose **Shut Down › Turn Off Immediately** and start the VM again. If Setup can't recover, recreate the VM.
</details>

<details>
<summary><b>Shut Down does nothing</b></summary>

**Shut Down** asks Windows to shut down, like a power button. Windows may ignore the request while it's starting up, installing updates or showing a dialog. Wait a moment and try again, or hold the **Shut Down** button and choose **Turn Off Immediately**.
</details>

## Display

<details>
<summary><b>I can't change the resolution in Windows</b></summary>

That's expected. Windows on Arm keeps the resolution set by the firmware at startup. Shut Windows down, choose a resolution in the VM's **Settings…** and start it again. See [Display and resolution](USAGE.md#display-and-resolution).
</details>

<details>
<summary><b>Text looks blurry</b></summary>

Use the default **Full screen** resolution and enter full screen (⌃⌘F). Every Windows pixel then maps to exactly 2×2 Retina pixels. For even sharper text, choose the **Retina** resolution and set Windows' scale to 200 %.
</details>

<details>
<summary><b>3D apps or games don't work</b></summary>

The VM has no 3D graphics acceleration yet. Windows uses the Microsoft Basic Display Adapter. See [Limitations](../README.md#limitations).
</details>

## Keyboard and mouse

<details>
<summary><b>Keys type the wrong characters</b></summary>

SiliconWin sends physical key positions. The **Windows** keyboard layout decides the character, not the Mac's input source. Add or select the right layout in Windows (Settings › Time & language › Language & region). Switch layouts with Alt+Shift (⌥⇧).
</details>

<details>
<summary><b>A key seems stuck or repeats endlessly</b></summary>

Click outside the VM and back into it. SiliconWin releases all keys when the VM view loses focus. If it happens regularly, please open an issue and include the steps that trigger it.
</details>

<details>
<summary><b>⌘ doesn't do what I expect</b></summary>

With **Mac keyboard shortcuts** on, ⌘ plus common letters such as C, V or S becomes Ctrl. ⌘ with any other key acts as the Windows key, and ⌘ alone opens Start. Turn the setting off in SiliconWin's settings to make ⌘ always the Windows key. Some combinations, such as ⌘Space and ⌘Tab, are taken by macOS before SiliconWin sees them.
</details>

## Clipboard and file transfer

Both features need the SiliconWin guest tools running in Windows.

<details>
<summary><b>The clipboard doesn't sync, or <i>Send Files</i> is unavailable</b></summary>

1. Make sure **Share the clipboard with Windows** is on in SiliconWin's settings, if the problem is the clipboard.
2. Wait until you're signed in to Windows. The agent starts at sign-in.
3. In Windows, check `%LOCALAPPDATA%\SiliconWin\agent.log` and `C:\ProgramData\SiliconWin\host.log`.
4. Check that the scheduled task **SiliconWin Host** exists and is running (Task Scheduler).
5. To reinstall the guest tools, open the **SILICONWIN** drive in File Explorer and run `SiliconWin\install.cmd` as administrator.

Items that password managers copy as concealed are never sent to Windows on purpose.
</details>

## Network and sound

<details>
<summary><b>Windows has no internet</b></summary>

- Check that **Network** is on in the VM's **Settings…**.
- In Windows' Device Manager, the adapter should appear as **Red Hat VirtIO Ethernet Adapter**. If it shows as an unknown device, reinstall the guest tools from the SILICONWIN drive, which also installs the drivers.
- The VM uses your Mac's connection through NAT. If your Mac is online, Windows should be too.
</details>

<details>
<summary><b>No sound</b></summary>

Check that **Sound** is on in the VM's **Settings…** and that your Mac's output device and volume are set. Windows plays through **High Definition Audio Device**.
</details>

## Performance

<details>
<summary><b>Windows feels slow</b></summary>

- **x64 editions** are fully emulated and several times slower than Windows on Arm. Use Windows 11 on Arm when you can.
- Give the VM at least **4 cores** and **8 GB** of memory if your Mac allows it, but leave enough for macOS.
- **External drives:** use a fast SSD and a **10 Gb/s (or faster) USB-C cable**. A USB 2.0 cable (480 Mb/s) makes Windows extremely slow. To check the link speed, open **System Information › USB**.
- Right after installation, Windows spends a while installing updates, indexing and optimizing in the background.
</details>

## Storage and snapshots

<details>
<summary><b>The VM paused by itself</b></summary>

The disk image grows as Windows writes data. If the drive the library is on runs out of space, QEMU pauses the VM instead of corrupting the disk. Free up space on that drive, then click **Resume**.
</details>

<details>
<summary><b>"Snapshots need an APFS drive"</b></summary>

Snapshots use APFS clones. Keep the library on an APFS-formatted drive, not exFAT or HFS+.
</details>

<details>
<summary><b>The library is empty or shows the wrong drive</b></summary>

If your library is on an external drive, connect the drive before you open SiliconWin. You can also check the location in **SiliconWin › Settings › Library**.
</details>

## macOS permissions

<details>
<summary><b>"SiliconWin would like to access files on a removable volume"</b></summary>

Click **Allow**. SiliconWin needs this permission when the app or its library is on an external drive. If you clicked **Don't Allow**, open **System Settings › Privacy & Security › Files and Folders**, find SiliconWin and turn on **Removable Volumes**.

Builds from `Scripts/build-app.sh` are signed with a stable identity, so macOS remembers your answer across rebuilds.
</details>
