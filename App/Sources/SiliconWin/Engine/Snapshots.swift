import Darwin
import Foundation

/// A saved state of a VM's disk and UEFI settings.
///
/// Snapshots are APFS clones (`clonefile`): taking or restoring one is instant
/// and costs no space at first; the copies only diverge as Windows writes.
struct VMSnapshot: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var installState: InstallState
    var installReboots: Int
}

enum SnapshotError: LocalizedError {
    case running
    case cloneFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .running:
            return "Shut down the virtual machine before using snapshots."
        case .cloneFailed(let file, let code):
            return "Could not clone \(file): \(String(cString: strerror(code))). Snapshots need an APFS drive."
        }
    }
}

extension VMBundle {
    func snapshotURL(_ snapshot: VMSnapshot) -> URL {
        snapshotsURL.appendingPathComponent(snapshot.id.uuidString, isDirectory: true)
    }

    func loadSnapshots() -> [VMSnapshot] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: snapshotsURL, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("snapshot.json")) else { return nil }
            return try? JSONDecoder.siliconWin.decode(VMSnapshot.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    /// Files that make up the VM's state.
    fileprivate var stateFiles: [String] {
        [diskURL.lastPathComponent, efiVarsURL.lastPathComponent, tpmStateURL.lastPathComponent]
    }

    fileprivate static func clone(_ source: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        guard clonefile(source.path, destination.path, 0) == 0 else {
            throw SnapshotError.cloneFailed(source.lastPathComponent, errno)
        }
    }

    func takeSnapshot(named name: String, config: VMConfiguration) throws -> VMSnapshot {
        let snapshot = VMSnapshot(name: name, installState: config.installState, installReboots: config.installReboots)
        let folder = snapshotURL(snapshot)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for file in stateFiles where FileManager.default.fileExists(atPath: url.appendingPathComponent(file).path) {
                try Self.clone(url.appendingPathComponent(file), to: folder.appendingPathComponent(file))
            }
            try JSONEncoder.siliconWin.encode(snapshot).write(to: folder.appendingPathComponent("snapshot.json"))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return snapshot
    }

    func restore(_ snapshot: VMSnapshot) throws {
        let folder = snapshotURL(snapshot)
        for file in stateFiles {
            let saved = folder.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: saved.path) else { continue }
            // Clone next to the live file, then swap it in atomically.
            let staged = url.appendingPathComponent(".restore-" + file)
            let live = url.appendingPathComponent(file)
            try Self.clone(saved, to: staged)
            if FileManager.default.fileExists(atPath: live.path) {
                _ = try FileManager.default.replaceItemAt(live, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: live)
            }
        }
    }

    func delete(_ snapshot: VMSnapshot) throws {
        try FileManager.default.removeItem(at: snapshotURL(snapshot))
    }
}
