import SwiftUI

/// Take, restore and delete snapshots (while the VM is off).
struct SnapshotsSection: View {
    @ObservedObject var machine: VirtualMachine
    @EnvironmentObject private var library: VMLibrary
    @State private var naming = false
    @State private var name = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var pendingRestore: VMSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Snapshots", systemImage: "clock.arrow.circlepath").font(.headline)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Take Snapshot…") {
                    name = ""
                    naming = true
                }
                .disabled(machine.state != .stopped || busy)
            }

            if machine.snapshots.isEmpty {
                Text("Save the state of Windows before risky changes and return to it any time. Snapshots are instant APFS clones on \(library.volumeName) and only use space for what changes afterwards.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(machine.snapshots) { snapshot in
                    HStack(spacing: 12) {
                        Image(systemName: "camera.on.rectangle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.name)
                            Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore…") { pendingRestore = snapshot }
                            .disabled(machine.state != .stopped || busy)
                        Button(role: .destructive) {
                            run { try await machine.deleteSnapshot(snapshot) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this snapshot")
                        .disabled(busy)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                }
            }

            if machine.state != .stopped {
                Text("Shut down Windows to take or restore snapshots.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }
        }
        .alert("Take Snapshot", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Take Snapshot") { run { try await machine.takeSnapshot(named: name) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current state of the Windows disk and UEFI settings.")
        }
        .confirmationDialog("Restore “\(pendingRestore?.name ?? "")”?",
                            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
            Button("Restore Snapshot", role: .destructive) {
                if let snapshot = pendingRestore {
                    run { try await machine.restoreSnapshot(snapshot) }
                }
                pendingRestore = nil
            }
        } message: {
            Text("Windows returns to the state saved in this snapshot. Anything changed since then is lost unless you take another snapshot first.")
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        errorText = nil
        Task {
            do {
                try await work()
            } catch {
                errorText = error.localizedDescription
            }
            busy = false
        }
    }
}
