import AppKit
import Foundation

/// Screen size Windows boots with (the firmware passes it on to Windows).
struct DisplayResolution: Codable, Hashable, Identifiable {
    var width: Int
    var height: Int

    var id: String { "\(width)x\(height)" }
    var label: String { "\(width) × \(height)" }
    var qemuString: String { "\(width)x\(height)" }

    static let presets: [DisplayResolution] = [
        .init(width: 1280, height: 800),
        .init(width: 1440, height: 900),
        .init(width: 1600, height: 900),
        .init(width: 1680, height: 1050),
        .init(width: 1920, height: 1080),
        .init(width: 1920, height: 1200),
        .init(width: 2560, height: 1440),
        .init(width: 2560, height: 1600),
        .init(width: 2880, height: 1800),
        .init(width: 3840, height: 2160),
    ]

    /// The area a full-screen window gets on the main display, in points
    /// (below the camera housing on notched MacBooks). Windows then fills the
    /// screen at an exact 2× scale on Retina displays.
    static var fullScreenNative: DisplayResolution {
        guard let screen = NSScreen.main else { return .init(width: 1920, height: 1080) }
        var size = screen.frame.size
        size.height -= screen.safeAreaInsets.top
        let width = max(1024, Int(size.width) & ~1)
        let height = max(768, Int(size.height) & ~1)
        return .init(width: width, height: height)
    }

    /// Same as `fullScreenNative`, but in physical pixels (Windows at 200 %).
    static var fullScreenRetina: DisplayResolution {
        let native = fullScreenNative
        let scale = Int(NSScreen.main?.backingScaleFactor ?? 1)
        return .init(width: min(5120, native.width * scale), height: min(2880, native.height * scale))
    }
}

/// Answers for an automatic ("unattended") Windows installation.
struct UnattendedSetup: Codable, Equatable {
    var enabled = true
    var userName = "User"
    /// Empty means the account has no password.
    var password = ""
    var computerName = "SILICONWIN"
    /// The user agreed to the Microsoft Software License Terms.
    var acceptedLicense = false
    var timeZone = WindowsLocale.currentTimeZoneID()
    var inputLocales = WindowsLocale.currentInputLocales()
    var language = "en-US"

    init() {}

    // Missing keys fall back to defaults, so older and newer files both load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UnattendedSetup()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? d.userName
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? d.password
        computerName = try c.decodeIfPresent(String.self, forKey: .computerName) ?? d.computerName
        acceptedLicense = try c.decodeIfPresent(Bool.self, forKey: .acceptedLicense) ?? d.acceptedLicense
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone) ?? d.timeZone
        inputLocales = try c.decodeIfPresent(String.self, forKey: .inputLocales) ?? d.inputLocales
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
    }
}

enum InstallState: String, Codable {
    /// Windows has not been installed yet; the installer is attached.
    case notInstalled
    /// Windows Setup is running (at least one boot from the installer happened).
    case installing
    /// Windows reported that setup finished.
    case installed
}

struct VMConfiguration: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var guest: GuestOS
    var cpuCount: Int
    var memoryMB: Int
    var diskSizeGB: Int
    var resolution: DisplayResolution
    var installerISOPath: String?
    var networkEnabled = true
    var soundEnabled = true
    /// Software TPM 2.0 (swtpm), for Windows 11 features like BitLocker.
    var tpmEnabled = true
    var macAddress = VMConfiguration.randomMACAddress()
    var setup = UnattendedSetup()
    var installState = InstallState.notInstalled
    /// Guest reboots seen while installing; the installer is only booted
    /// automatically on the very first start.
    var installReboots = 0
    var createdAt = Date()
    var lastStartedAt: Date?
    var notes = ""

    init(name: String, guest: GuestOS, cpuCount: Int, memoryMB: Int, diskSizeGB: Int, resolution: DisplayResolution) {
        self.name = name
        self.guest = guest
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.diskSizeGB = diskSizeGB
        self.resolution = resolution
    }

    // Missing keys fall back to defaults, so VMs made by older versions load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        guest = try c.decode(GuestOS.self, forKey: .guest)
        cpuCount = try c.decodeIfPresent(Int.self, forKey: .cpuCount) ?? 4
        memoryMB = try c.decodeIfPresent(Int.self, forKey: .memoryMB) ?? 8192
        diskSizeGB = try c.decodeIfPresent(Int.self, forKey: .diskSizeGB) ?? 128
        resolution = try c.decodeIfPresent(DisplayResolution.self, forKey: .resolution) ?? .init(width: 1920, height: 1080)
        installerISOPath = try c.decodeIfPresent(String.self, forKey: .installerISOPath)
        networkEnabled = try c.decodeIfPresent(Bool.self, forKey: .networkEnabled) ?? true
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? true
        tpmEnabled = try c.decodeIfPresent(Bool.self, forKey: .tpmEnabled) ?? true
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress) ?? Self.randomMACAddress()
        setup = try c.decodeIfPresent(UnattendedSetup.self, forKey: .setup) ?? UnattendedSetup()
        installState = try c.decodeIfPresent(InstallState.self, forKey: .installState) ?? .notInstalled
        installReboots = try c.decodeIfPresent(Int.self, forKey: .installReboots) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastStartedAt = try c.decodeIfPresent(Date.self, forKey: .lastStartedAt)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    /// Locally administered, unicast MAC in QEMU's 52:54:00 range.
    static func randomMACAddress() -> String {
        let bytes = (0..<3).map { _ in String(format: "%02x", Int.random(in: 0...255)) }
        return "52:54:00:" + bytes.joined(separator: ":")
    }

    static func makeDefault(for guest: GuestOS, name: String? = nil) -> VMConfiguration {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let hostMemoryMB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024))
        let memory = min(guest.recommendedMemoryMB, max(4096, hostMemoryMB / 3))
        return VMConfiguration(
            name: name ?? guest.shortName,
            guest: guest,
            cpuCount: max(2, min(8, cores - 2)),
            memoryMB: memory - memory % 1024,
            diskSizeGB: 128,
            resolution: .fullScreenNative
        )
    }
}
