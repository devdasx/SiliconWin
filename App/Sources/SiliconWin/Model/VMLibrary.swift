import AppKit
import Combine
import Foundation

/// The folder that holds every virtual machine and downloaded installer:
///
///     SiliconWin Library/
///         Virtual Machines/<name>.winvm/
///         ISOs/
@MainActor
final class VMLibrary: ObservableObject {
    static let libraryPathKey = "LibraryPath"

    @Published private(set) var machines: [VirtualMachine] = []
    @Published var selectedID: UUID?
    @Published private(set) var rootURL: URL
    @Published var lastError: String?

    /// Re-publish each VM's changes so views and menus that observe the
    /// library (e.g. the Virtual Machine menu) follow VM state changes.
    private var machineObservers: [UUID: AnyCancellable] = [:]

    private func observe(_ machine: VirtualMachine) {
        guard machineObservers[machine.id] == nil else { return }
        machineObservers[machine.id] = machine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Free space, name and presence of the library's drive (refreshed off
    /// the main thread, so a slow drive or a pending privacy prompt never
    /// freezes the window).
    @Published private(set) var availableBytes: Int64 = 0
    @Published private(set) var volumeName: String
    @Published private(set) var isAvailable = true
    @Published private(set) var isLoading = false
    private var volumeTimer: Timer?

    init() {
        let root = Self.storedOrDefaultRoot()
        rootURL = root
        volumeName = root.deletingLastPathComponent().lastPathComponent
        reload()
        volumeTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshVolumeInfo() }
        }
    }

    var machinesURL: URL { rootURL.appendingPathComponent("Virtual Machines", isDirectory: true) }
    var isosURL: URL { rootURL.appendingPathComponent("ISOs", isDirectory: true) }

    var selected: VirtualMachine? { machines.first { $0.id == selectedID } }

    /// Default location: next to the app when it lives on an external drive
    /// (so a dedicated SSD holds everything), otherwise in Application Support.
    static func storedOrDefaultRoot() -> URL {
        if let stored = UserDefaults.standard.string(forKey: libraryPathKey) {
            return URL(fileURLWithPath: stored, isDirectory: true)
        }
        let appURL = Bundle.main.bundleURL
        let components = appURL.pathComponents
        if components.count > 2, components[1] == "Volumes" {
            return URL(fileURLWithPath: "/Volumes/\(components[2])", isDirectory: true)
                .appendingPathComponent("SiliconWin Library", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiliconWin", isDirectory: true)
    }

    func changeRoot(to url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.libraryPathKey)
        rootURL = url
        reload()
    }

    private struct VolumeInfo: Sendable {
        var freeBytes: Int64
        var name: String
        var available: Bool
    }

    nonisolated private static func volumeInfo(for root: URL) -> VolumeInfo {
        let volume = root.deletingLastPathComponent()
        let values = try? volume.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                          .volumeAvailableCapacityKey, .volumeNameKey])
        var free = Int64(values?.volumeAvailableCapacity ?? 0)
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { free = important }
        return VolumeInfo(freeBytes: free, name: values?.volumeName ?? volume.lastPathComponent,
                          available: FileManager.default.fileExists(atPath: volume.path))
    }

    /// Reads every VM bundle's settings (runs on a background thread).
    nonisolated private static func scan(root: URL) -> [(VMBundle, VMConfiguration)] {
        let fm = FileManager.default
        let machinesURL = root.appendingPathComponent("Virtual Machines", isDirectory: true)
        try? fm.createDirectory(at: machinesURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("ISOs", isDirectory: true), withIntermediateDirectories: true)
        let bundles = (try? fm.contentsOfDirectory(at: machinesURL, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "winvm" } ?? []
        return bundles.compactMap { url in
            let bundle = VMBundle(url: url)
            guard let data = try? Data(contentsOf: bundle.configURL),
                  let config = try? JSONDecoder.siliconWin.decode(VMConfiguration.self, from: data) else { return nil }
            return (bundle, config)
        }
    }

    func refreshVolumeInfo() {
        let root = rootURL
        Task {
            let info = await Task.detached { Self.volumeInfo(for: root) }.value
            guard root == rootURL else { return }
            availableBytes = info.freeBytes
            volumeName = info.name
            isAvailable = info.available
        }
    }

    func reload() {
        let root = rootURL
        isLoading = true
        refreshVolumeInfo()
        Task {
            let found = await Task.detached { Self.scan(root: root) }.value
            guard root == rootURL else { return }
            apply(found)
            isLoading = false
        }
    }

    private func apply(_ found: [(VMBundle, VMConfiguration)]) {
        var result: [VirtualMachine] = []
        for (bundle, config) in found {
            if let existing = machines.first(where: { $0.id == config.id }) {
                result.append(existing)
            } else {
                result.append(VirtualMachine(config: config, bundle: bundle))
            }
        }
        // Keep running machines even if their bundle vanished (drive hiccup).
        for machine in machines where machine.isActive && !result.contains(where: { $0.id == machine.id }) {
            result.append(machine)
        }
        machines = result.sorted { $0.config.createdAt < $1.config.createdAt }
        machines.forEach(observe)
        if selectedID == nil || !machines.contains(where: { $0.id == selectedID }) {
            selectedID = machines.first?.id
        }
    }

    /// ISO files already downloaded into the library.
    func availableISOs(for guest: GuestOS? = nil) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: isosURL, includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension.lowercased() == "iso" } ?? []
        guard let guest else { return files }
        return files.filter { guest.matchesISO(named: $0.lastPathComponent) }
    }

    /// Creates the bundle, the sparse disk image and the UEFI variable store.
    func create(_ config: VMConfiguration) throws -> VirtualMachine {
        let fm = FileManager.default
        var name = config.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = config.guest.shortName }
        var url = machinesURL.appendingPathComponent("\(name).winvm", isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: url.path) {
            url = machinesURL.appendingPathComponent("\(name) \(suffix).winvm", isDirectory: true)
            suffix += 1
        }
        let bundle = VMBundle(url: url)
        try fm.createDirectory(at: bundle.logsURL, withIntermediateDirectories: true)

        do {
            // Raw images are sparse on APFS: they only take the space Windows
            // actually writes, and TRIM inside Windows punches holes again.
            fm.createFile(atPath: bundle.diskURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: bundle.diskURL)
            try handle.truncate(atOffset: UInt64(config.diskSizeGB) * 1_073_741_824)
            try handle.close()

            if config.guest.usesUEFI {
                try fm.copyItem(at: BundledRuntime.shared.armFirmwareVarsTemplate, to: bundle.efiVarsURL)
            }

            var stored = config
            stored.name = url.deletingPathExtension().lastPathComponent
            let machine = VirtualMachine(config: stored, bundle: bundle)
            try machine.saveConfig()
            machines.append(machine)
            observe(machine)
            refreshVolumeInfo()
            selectedID = machine.id
            return machine
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
    }

    /// Moves the bundle to the drive's Trash (it can still be restored from there).
    func moveToTrash(_ machine: VirtualMachine) throws {
        guard !machine.isActive else { return }
        try FileManager.default.trashItem(at: machine.bundle.url, resultingItemURL: nil)
        machines.removeAll { $0.id == machine.id }
        machineObservers[machine.id] = nil
        if selectedID == machine.id { selectedID = machines.first?.id }
    }
}

extension JSONDecoder {
    static let siliconWin: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let siliconWin: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

extension Int64 {
    var formattedBytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
