#!/usr/bin/env python3
"""Copies SiliconWin's virtualization runtime into an app bundle.

    bundle-runtime.py <SiliconWin.app>

  * QEMU binaries (qemu-system-aarch64, qemu-system-x86_64, qemu-img) -> Contents/MacOS
  * swtpm (software TPM 2.0 for Windows 11)                          -> Contents/MacOS
  * every non-system dylib they need (Homebrew glib, pixman, ...)     -> Contents/Frameworks
    with install names rewritten so the app is self-contained
  * firmware: SiliconWin's high-resolution edk2 build + QEMU data     -> Contents/Resources/qemu
  * VirtIO drivers for Windows (from the virtio-win ISO)              -> Contents/Resources/Drivers
  * guest tools (SetupComplete hook, agent)                           -> Contents/Resources/GuestTools
"""
import os
import re
import shutil
import subprocess
import sys

# Build area and versions come from Scripts/env.sh (via build-app.sh).
WORK = os.environ.get("SILICONWIN_BUILD", os.path.expanduser("~/SiliconWin-build"))
PREFIX = os.path.join(WORK, "prefix")
PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VIRTIO_WIN_VERSION = os.environ.get("VIRTIO_WIN_VERSION", "0.1.302")
VIRTIO_ISO = os.path.join(WORK, "downloads", f"virtio-win-{VIRTIO_WIN_VERSION}.iso")
ENTITLEMENTS = os.path.join(PROJECT, "App", "Resources", "qemu.entitlements")

BINARIES = ["qemu-system-aarch64", "qemu-system-x86_64", "qemu-img", "swtpm"]
HYPERVISOR = {"qemu-system-aarch64", "qemu-system-x86_64"}   # need com.apple.security.hypervisor
SYSTEM_PREFIXES = ("/usr/lib/", "/System/")

# Firmware and option ROMs the generated machines use.
DATA_FILES = [
    "edk2-arm-vars.fd",            # UEFI variable store template (Arm)
    "bios-256k.bin",               # SeaBIOS (x64 guests)
    "vgabios-stdvga.bin",          # VGA BIOS (x64 guests)
    "kvmvapic.bin", "linuxboot_dma.bin",
    "efi-virtio.rom", "efi-e1000e.rom", "efi-e1000.rom",
]

# virtio-win folders -> drivers per guest architecture.
DRIVERS = {
    "arm64": ["NetKVM/w11/ARM64", "viorng/w11/ARM64", "vioserial/w11/ARM64", "Balloon/w11/ARM64", "pvpanic/w11/ARM64"],
    "amd64": ["NetKVM/w10/amd64", "viorng/w10/amd64", "vioserial/w10/amd64", "Balloon/w10/amd64", "pvpanic/w10/amd64"],
}


def remove_tree(path):
    """rmtree that also copes with read-only folders (files extracted from ISOs)."""
    if os.path.lexists(path):
        subprocess.run(["chmod", "-R", "u+w", path], capture_output=True)
        shutil.rmtree(path)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout


def rpaths(binary):
    out = run("otool", "-l", binary)
    return re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset", out)


def install_name(binary):
    lines = run("otool", "-D", binary).splitlines()
    return lines[1].strip() if len(lines) > 1 else None


def dependencies(binary):
    own = install_name(binary)
    deps = []
    for line in run("otool", "-L", binary).splitlines()[1:]:
        path = line.strip().split(" (compatibility")[0]
        if path and path != own and not path.startswith(SYSTEM_PREFIXES):
            deps.append(path)
    return deps


def resolve(dep, binary):
    if dep.startswith("@rpath/"):
        for rp in rpaths(binary):
            rp = rp.replace("@loader_path", os.path.dirname(binary)).replace("@executable_path", os.path.dirname(binary))
            candidate = os.path.join(rp, dep[len("@rpath/"):])
            if os.path.exists(candidate):
                return os.path.realpath(candidate)
        for base in (os.path.join(PREFIX, "lib"), "/opt/homebrew/lib"):
            candidate = os.path.join(base, dep[len("@rpath/"):])
            if os.path.exists(candidate):
                return os.path.realpath(candidate)
        raise SystemExit(f"cannot resolve {dep} for {binary}")
    if dep.startswith("@loader_path/"):
        return os.path.realpath(os.path.join(os.path.dirname(binary), dep[len("@loader_path/"):]))
    return os.path.realpath(dep)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    app = os.path.abspath(sys.argv[1])
    contents = os.path.join(app, "Contents")
    macos = os.path.join(contents, "MacOS")
    frameworks = os.path.join(contents, "Frameworks")
    resources = os.path.join(contents, "Resources")
    qemu_data = os.path.join(resources, "qemu")
    for d in (macos, frameworks, qemu_data):
        os.makedirs(d, exist_ok=True)

    # 1. Binaries + transitive dylib closure.
    copied = {}      # real source path -> bundled file name
    queue = []
    for name in BINARIES:
        src = os.path.join(PREFIX, "bin", name)
        dst = os.path.join(macos, name)
        shutil.copy2(src, dst)
        os.chmod(dst, 0o755)
        queue.append((src, dst, True))

    while queue:
        src, dst, is_executable = queue.pop()
        changes = []
        for dep in dependencies(src):
            real = resolve(dep, src)
            name = os.path.basename(real)
            if real not in copied:
                copied[real] = name
                lib_dst = os.path.join(frameworks, name)
                shutil.copy2(real, lib_dst)
                os.chmod(lib_dst, 0o644)
                queue.append((real, lib_dst, False))
            prefix = "@executable_path/../Frameworks/" if is_executable else "@loader_path/"
            changes += ["-change", dep, prefix + name]
        args = ["install_name_tool"] + changes
        if not is_executable:
            args += ["-id", "@rpath/" + os.path.basename(dst)]
        if len(args) > 1:
            subprocess.run(args + [dst], check=True, capture_output=True)
        for rp in rpaths(dst):
            subprocess.run(["install_name_tool", "-delete_rpath", rp, dst], capture_output=True)
        subprocess.run(["strip", "-S", dst], check=True, capture_output=True)

    # 2. Code signatures (ad-hoc). QEMU for Arm needs the hypervisor entitlement.
    for name in sorted(os.listdir(frameworks)):
        run("codesign", "--force", "--sign", "-", os.path.join(frameworks, name))
    for name in BINARIES:
        args = ["codesign", "--force", "--sign", "-"]
        if name in HYPERVISOR:
            args += ["--entitlements", ENTITLEMENTS]
        run(*args, os.path.join(macos, name))

    # 3. Firmware and QEMU data files.
    shutil.copy2(os.path.join(WORK, "firmware", "siliconwin-aarch64-code.fd"), qemu_data)
    for name in DATA_FILES:
        shutil.copy2(os.path.join(PREFIX, "share", "qemu", name), qemu_data)
    shutil.copy2(os.path.join(PREFIX, "share", "qemu", "edk2-licenses.txt"), qemu_data)
    # The VNC server loads a keymap at startup even though SiliconWin sends raw scan codes.
    remove_tree(os.path.join(qemu_data, "keymaps"))
    shutil.copytree(os.path.join(PREFIX, "share", "qemu", "keymaps"), os.path.join(qemu_data, "keymaps"))

    # 4. VirtIO drivers for Windows.
    drivers_root = os.path.join(resources, "Drivers")
    remove_tree(drivers_root)
    staging = os.path.join(WORK, "tmp", "virtio-extract")
    remove_tree(staging)
    os.makedirs(staging)
    # The ISO stores most files as hard links into other folders (even of other
    # drivers), so extract all of it and copy out what we need.
    subprocess.run(["bsdtar", "-xf", VIRTIO_ISO, "-C", staging], check=True)
    for arch, paths in DRIVERS.items():
        for path in paths:
            target = os.path.join(drivers_root, arch, path.split("/")[0])
            shutil.copytree(os.path.join(staging, path), target, ignore=shutil.ignore_patterns("*.pdb"))
            subprocess.run(["chmod", "-R", "u+w", target], check=True)
    remove_tree(staging)

    # 5. Guest tools.
    tools = os.path.join(resources, "GuestTools")
    remove_tree(tools)
    shutil.copytree(os.path.join(PROJECT, "App", "Resources", "GuestTools"), tools)

    total = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(app) for f in fs)
    print(f"Bundled {len(BINARIES)} QEMU tools, {len(copied)} libraries, firmware, drivers "
          f"({', '.join(DRIVERS)}) into {app} ({total / 1e6:.0f} MB)")


if __name__ == "__main__":
    main()
