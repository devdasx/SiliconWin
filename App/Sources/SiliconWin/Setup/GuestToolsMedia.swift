import Foundation

enum GuestToolsError: LocalizedError {
    case hdiutilFailed(String)

    var errorDescription: String? {
        switch self {
        case .hdiutilFailed(let output): return "Could not create the SiliconWin tools disc: \(output)"
        }
    }
}

/// Builds the small "SILICONWIN" CD that is attached next to the Windows
/// installer:
///
///     autounattend.xml          answers for Windows Setup
///     $WinPEDriver$/…           VirtIO drivers (Setup loads them automatically)
///     SiliconWin/…              guest tools (agent, SetupComplete hook)
enum GuestToolsMedia {
    /// True when the disc is missing or older than the guest tools in the app.
    static func isOutdated(bundle: VMBundle, runtime: BundledRuntime) -> Bool {
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        guard FileManager.default.fileExists(atPath: bundle.toolsISOURL.path) else { return true }
        let tools = (try? FileManager.default.contentsOfDirectory(at: runtime.guestToolsURL, includingPropertiesForKeys: nil)) ?? []
        let newest = tools.map(modified).max() ?? .distantPast
        return newest > modified(bundle.toolsISOURL)
    }

    static func build(config: VMConfiguration, bundle: VMBundle, runtime: BundledRuntime) throws {
        let fm = FileManager.default
        // Stage on the VM's own drive (the internal disk may be full).
        let staging = bundle.url.appendingPathComponent(".tools-staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let xml = UnattendXML.make(for: config)
        try xml.write(to: staging.appendingPathComponent("autounattend.xml"), atomically: true, encoding: .utf8)

        let drivers = runtime.driversURL(for: config.guest.architecture)
        if fm.fileExists(atPath: drivers.path) {
            try fm.copyItem(at: drivers, to: staging.appendingPathComponent("$WinPEDriver$", isDirectory: true))
        }
        try fm.copyItem(at: runtime.guestToolsURL, to: staging.appendingPathComponent("SiliconWin", isDirectory: true))

        let output = bundle.toolsISOURL
        try? fm.removeItem(at: output)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["makehybrid", "-iso", "-joliet", "-default-volume-name", "SILICONWIN",
                             "-joliet-volume-name", "SILICONWIN", "-o", output.path, staging.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let log = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, fm.fileExists(atPath: output.path) else {
            throw GuestToolsError.hdiutilFailed(String(decoding: log, as: UTF8.self))
        }
    }
}
