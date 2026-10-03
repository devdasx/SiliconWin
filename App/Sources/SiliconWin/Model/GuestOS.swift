import Foundation

/// CPU architecture of a virtual machine.
enum GuestArchitecture: String, Codable {
    case arm64
    case x86_64

    /// Name used for `processorArchitecture` in Windows answer files.
    var unattendName: String { self == .arm64 ? "arm64" : "amd64" }

    /// Folder name of the matching drivers inside the app bundle.
    var driverFolder: String { self == .arm64 ? "arm64" : "amd64" }
}

/// The Windows editions SiliconWin knows how to install and run.
enum GuestOS: String, Codable, CaseIterable, Identifiable {
    case windows11Arm = "windows11-arm64"
    case windows11x64 = "windows11-x64"
    case windows10x64 = "windows10-x64"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .windows11Arm: return "Windows 11 on Arm"
        case .windows11x64: return "Windows 11 (x64, emulated)"
        case .windows10x64: return "Windows 10 (x64, emulated)"
        }
    }

    var shortName: String {
        switch self {
        case .windows11Arm: return "Windows 11"
        case .windows11x64: return "Windows 11 x64"
        case .windows10x64: return "Windows 10"
        }
    }

    var summary: String {
        switch self {
        case .windows11Arm:
            return "Runs at near-native speed on Apple silicon using Apple's hypervisor. Most x64 Windows apps run through Windows' built-in emulation."
        case .windows11x64:
            return "Every x86 instruction is emulated, so it is several times slower. Only for software that refuses to run on Windows on Arm."
        case .windows10x64:
            return "Every x86 instruction is emulated, so it is several times slower. Windows 10 reached end of support in October 2025."
        }
    }

    var architecture: GuestArchitecture { self == .windows11Arm ? .arm64 : .x86_64 }

    /// True when the guest runs on the hardware through Hypervisor.framework.
    var isHardwareAccelerated: Bool {
        #if arch(arm64)
        return architecture == .arm64
        #else
        return architecture == .x86_64
        #endif
    }

    /// The official Microsoft page that hands out the installation ISO.
    var microsoftDownloadPage: URL {
        switch self {
        case .windows11Arm: return URL(string: "https://www.microsoft.com/en-us/software-download/windows11arm64")!
        case .windows11x64: return URL(string: "https://www.microsoft.com/en-us/software-download/windows11")!
        case .windows10x64: return URL(string: "https://www.microsoft.com/en-us/software-download/windows10ISO")!
        }
    }

    /// Edition picked from the multi-edition ISO during automatic setup.
    var edition: String { self == .windows10x64 ? "Windows 10 Pro" : "Windows 11 Pro" }

    /// Microsoft's published generic installation key for the Pro edition.
    /// It only selects the edition; Windows stays unactivated until the user
    /// enters their own product key.
    var genericInstallKey: String { "VK7JG-NPHTM-C97JM-9MPGT-3V66T" }

    /// Windows 11 checks for TPM 2.0, Secure Boot and 4 GB of RAM.
    var needsRequirementBypass: Bool { self != .windows10x64 }

    /// Boot firmware used by the virtual machine.
    var usesUEFI: Bool { architecture == .arm64 }

    /// Words that identify a matching ISO file name.
    func matchesISO(named name: String) -> Bool {
        let lower = name.lowercased()
        switch self {
        case .windows11Arm:
            return lower.contains("win") && lower.contains("11") && (lower.contains("arm64") || lower.contains("a64"))
        case .windows11x64:
            return lower.contains("win") && lower.contains("11") && lower.contains("x64")
        case .windows10x64:
            return lower.contains("win") && lower.contains("10") && lower.contains("x64")
        }
    }

    var recommendedMemoryMB: Int { self == .windows11Arm ? 8192 : 8192 }
    var minimumDiskGB: Int { self == .windows10x64 ? 32 : 64 }
}
