import Foundation

/// Unix sockets QEMU listens on while a VM runs.
struct VMSockets {
    let directory: URL
    var qmp: URL { directory.appendingPathComponent("qmp.sock") }
    var vnc: URL { directory.appendingPathComponent("vnc.sock") }
    var agent: URL { directory.appendingPathComponent("agent.sock") }
    var tpm: URL { directory.appendingPathComponent("tpm.sock") }

    /// Short path under /tmp (socket paths are limited to 104 bytes).
    static func make(for id: UUID) throws -> VMSockets {
        let base = URL(fileURLWithPath: "/tmp/siliconwin-\(getuid())", isDirectory: true)
        let directory = base.appendingPathComponent(String(id.uuidString.prefix(8)).lowercased(), isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        for name in ["qmp.sock", "vnc.sock", "agent.sock", "tpm.sock"] {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        return VMSockets(directory: directory)
    }
}

/// The QEMU command line for a virtual machine.
struct QEMULaunchPlan {
    let executable: URL
    let arguments: [String]

    var commandLine: String {
        ([executable.path] + arguments).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }

    static func make(config: VMConfiguration, bundle: VMBundle, runtime: BundledRuntime,
                     sockets: VMSockets, attachInstaller: Bool, attachTools: Bool, withTPM: Bool = false) -> QEMULaunchPlan {
        var args: [String] = []
        func add(_ values: String...) { args.append(contentsOf: values) }
        /// QEMU option values escape commas by doubling them.
        func q(_ value: String) -> String { value.replacingOccurrences(of: ",", with: ",,") }

        let serial = "SW" + config.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(18)
        let installer = attachInstaller ? config.installerISOPath : nil

        add("-name", q(config.name))
        add("-L", runtime.qemuDataURL.path)
        add("-nodefaults")

        switch config.guest.architecture {
        case .arm64:
            // Apple silicon: hardware virtualization through Hypervisor.framework.
            add("-machine", "virt,highmem=on,gic-version=3")
            add("-accel", "hvf")
            add("-cpu", "host")
            add("-smp", "\(config.cpuCount),sockets=1,cores=\(config.cpuCount),threads=1")
            add("-m", "\(config.memoryMB)")
            add("-drive", "if=pflash,format=raw,unit=0,file=\(q(runtime.armFirmwareCode.path)),readonly=on")
            add("-drive", "if=pflash,format=raw,unit=1,file=\(q(bundle.efiVarsURL.path))")
            // Read by SiliconWin's firmware; Windows keeps this screen mode.
            add("-fw_cfg", "name=opt/siliconwin/resolution,string=\(config.resolution.qemuString)")
            add("-device", "ramfb")
            add("-device", "qemu-xhci,id=xhci,p2=8,p3=8")
            add("-device", "usb-kbd,bus=xhci.0")
            add("-device", "usb-tablet,bus=xhci.0")
            add("-drive", "if=none,id=disk0,file=\(q(bundle.diskURL.path)),format=raw,discard=unmap,detect-zeroes=unmap,cache=writeback")
            add("-device", "nvme,serial=\(serial),drive=disk0,bootindex=1")
            if let installer {
                add("-drive", "if=none,id=installer,media=cdrom,readonly=on,file=\(q(installer))")
                add("-device", "usb-storage,drive=installer,removable=on,bootindex=0")
            }
            if attachTools {
                add("-drive", "if=none,id=tools,media=cdrom,readonly=on,file=\(q(bundle.toolsISOURL.path))")
                add("-device", "usb-storage,drive=tools,removable=on")
            }
            if config.networkEnabled {
                add("-netdev", "user,id=net0")
                add("-device", "virtio-net-pci,netdev=net0,mac=\(config.macAddress)")
            }

        case .x86_64:
            // Intel/AMD Windows on Apple silicon: multithreaded CPU emulation.
            add("-machine", "q35")
            #if arch(x86_64)
            add("-accel", "hvf")
            add("-cpu", "host")
            #else
            add("-accel", "tcg,thread=multi,tb-size=1024")
            add("-cpu", "max")
            #endif
            add("-smp", "\(config.cpuCount),sockets=1,cores=\(config.cpuCount),threads=1")
            add("-m", "\(config.memoryMB)")
            // SeaBIOS + standard VGA: Windows can switch resolutions itself (VBE).
            add("-device", "VGA,vgamem_mb=64")
            add("-device", "qemu-xhci,id=xhci")
            add("-device", "usb-tablet,bus=xhci.0")
            add("-drive", "if=none,id=disk0,file=\(q(bundle.diskURL.path)),format=raw,discard=unmap,detect-zeroes=unmap,cache=writeback")
            add("-device", "nvme,serial=\(serial),drive=disk0,bootindex=1")
            if let installer {
                add("-drive", "if=none,id=installer,media=cdrom,readonly=on,file=\(q(installer))")
                add("-device", "ide-cd,drive=installer,bus=ide.0,bootindex=0")
            }
            if attachTools {
                add("-drive", "if=none,id=tools,media=cdrom,readonly=on,file=\(q(bundle.toolsISOURL.path))")
                add("-device", "ide-cd,drive=tools,bus=ide.1")
            }
            if config.networkEnabled {
                add("-netdev", "user,id=net0")
                add("-device", "e1000e,netdev=net0,mac=\(config.macAddress)")
            }
        }

        if withTPM {
            // TPM 2.0 (TIS interface) backed by the swtpm process SiliconWin starts.
            add("-chardev", "socket,id=chrtpm,path=\(q(sockets.tpm.path))")
            add("-tpmdev", "emulator,id=tpm0,chardev=chrtpm")
            add("-device", config.guest.architecture == .arm64 ? "tpm-tis-device,tpmdev=tpm0" : "tpm-tis,tpmdev=tpm0")
        }

        // Entropy, guest agent channel and sound.
        add("-device", "virtio-rng-pci")
        add("-device", "virtio-serial-pci,id=vser")
        add("-chardev", "socket,id=agent,path=\(q(sockets.agent.path)),server=on,wait=off")
        add("-device", "virtserialport,bus=vser.0,chardev=agent,name=org.siliconwin.agent.0")
        if config.soundEnabled {
            add("-audiodev", "coreaudio,id=audio0")
            add("-device", "intel-hda,id=hda")
            add("-device", "hda-output,bus=hda.0,audiodev=audio0")
        }

        add("-rtc", "base=localtime,clock=host")
        add("-display", "none")
        add("-vnc", "unix:\(q(sockets.vnc.path))")
        add("-qmp", "unix:\(q(sockets.qmp.path)),server=on,wait=off")

        return QEMULaunchPlan(executable: runtime.qemuSystem(for: config.guest.architecture), arguments: args)
    }
}
