import Foundation

/// Locates the QEMU engine, firmware, drivers and guest tools that ship
/// inside SiliconWin.app:
///
///     Contents/MacOS/qemu-system-aarch64, qemu-system-x86_64, qemu-img
///     Contents/Frameworks/*.dylib
///     Contents/Resources/qemu/              firmware + QEMU data files
///     Contents/Resources/Drivers/<arch>/    VirtIO drivers for Windows
///     Contents/Resources/GuestTools/        scripts copied into Windows
struct BundledRuntime {
    static let shared = BundledRuntime(bundle: .main)

    let contentsURL: URL

    init(bundle: Bundle) {
        contentsURL = bundle.bundleURL.appendingPathComponent("Contents", isDirectory: true)
    }

    var executablesURL: URL { contentsURL.appendingPathComponent("MacOS", isDirectory: true) }
    var resourcesURL: URL { contentsURL.appendingPathComponent("Resources", isDirectory: true) }
    var qemuDataURL: URL { resourcesURL.appendingPathComponent("qemu", isDirectory: true) }
    var guestToolsURL: URL { resourcesURL.appendingPathComponent("GuestTools", isDirectory: true) }

    func qemuSystem(for architecture: GuestArchitecture) -> URL {
        executablesURL.appendingPathComponent(architecture == .arm64 ? "qemu-system-aarch64" : "qemu-system-x86_64")
    }

    var qemuImg: URL { executablesURL.appendingPathComponent("qemu-img") }

    /// Software TPM 2.0 emulator (optional; VMs run without a TPM if missing).
    var swtpm: URL { executablesURL.appendingPathComponent("swtpm") }
    var hasTPM: Bool { FileManager.default.isExecutableFile(atPath: swtpm.path) }

    /// SiliconWin's own edk2 build with high-resolution ramfb support.
    var armFirmwareCode: URL { qemuDataURL.appendingPathComponent("siliconwin-aarch64-code.fd") }
    var armFirmwareVarsTemplate: URL { qemuDataURL.appendingPathComponent("edk2-arm-vars.fd") }

    func driversURL(for architecture: GuestArchitecture) -> URL {
        resourcesURL.appendingPathComponent("Drivers", isDirectory: true)
            .appendingPathComponent(architecture.driverFolder, isDirectory: true)
    }

    /// Files that must exist to run a guest of the given architecture.
    func missingComponents(for architecture: GuestArchitecture) -> [String] {
        var required = [qemuSystem(for: architecture), qemuImg, guestToolsURL]
        if architecture == .arm64 {
            required += [armFirmwareCode, armFirmwareVarsTemplate]
        } else {
            required.append(qemuDataURL.appendingPathComponent("bios-256k.bin"))
        }
        return required.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent)
    }
}

/// Paths inside a virtual machine bundle (`<name>.winvm`).
struct VMBundle {
    let url: URL

    var configURL: URL { url.appendingPathComponent("config.json") }
    var diskURL: URL { url.appendingPathComponent("disk.img") }
    var efiVarsURL: URL { url.appendingPathComponent("efi-vars.fd") }
    var toolsISOURL: URL { url.appendingPathComponent("siliconwin-tools.iso") }
    var screenshotURL: URL { url.appendingPathComponent("screenshot.png") }
    var logsURL: URL { url.appendingPathComponent("Logs", isDirectory: true) }
    var logURL: URL { logsURL.appendingPathComponent("qemu.log") }
    var snapshotsURL: URL { url.appendingPathComponent("Snapshots", isDirectory: true) }
    var tpmStateURL: URL { url.appendingPathComponent("TPM", isDirectory: true) }
}
