import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: VMLibrary
    @State private var showingNewMachine = false
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(showingNewMachine: $showingNewMachine)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            if let machine = library.selected {
                MachineDetailView(machine: machine)
                    .id(machine.id)
            } else if library.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Opening the library on \(library.volumeName)…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WelcomeView(showingNewMachine: $showingNewMachine)
            }
        }
        .sheet(isPresented: $showingNewMachine) {
            NewMachineSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newMachineRequested)) { _ in
            showingNewMachine = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            columns = .detailOnly
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            columns = .all
        }
        .modifier(FullScreenToolbarAutoHide())
    }
}

/// In full screen the toolbar only appears when the pointer reaches the top
/// edge, so Windows gets the whole screen (and stays at an exact 2× scale).
struct FullScreenToolbarAutoHide: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.windowToolbarFullScreenVisibility(.onHover)
        } else {
            content
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var library: VMLibrary
    @Binding var showingNewMachine: Bool
    @State private var pendingTrash: VirtualMachine?

    var body: some View {
        List(selection: $library.selectedID) {
            Section("Virtual Machines") {
                ForEach(library.machines) { machine in
                    MachineRow(machine: machine)
                        .tag(machine.id)
                        .contextMenu {
                            Button(machine.state == .stopped ? "Start" : "Shut Down") {
                                machine.state == .stopped ? machine.start() : machine.shutDown()
                            }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([machine.bundle.url])
                            }
                            Divider()
                            Button("Move to Trash…", role: .destructive) { pendingTrash = machine }
                                .disabled(machine.isActive)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                Label {
                    Text(library.isAvailable ? "\(library.volumeName): \(library.availableBytes.formattedBytes) free" : "\(library.volumeName) is not connected")
                } icon: {
                    Image(systemName: library.isAvailable ? "externaldrive.fill" : "externaldrive.badge.xmark")
                }
                .font(.caption)
                .foregroundStyle(library.isAvailable ? Color.secondary : Color.red)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showingNewMachine = true
                } label: {
                    Label("New Virtual Machine", systemImage: "plus")
                }
                .help("Create a new Windows virtual machine")
            }
        }
        .confirmationDialog("Move “\(pendingTrash?.config.name ?? "")” to the Trash?",
                            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let machine = pendingTrash {
                    do { try library.moveToTrash(machine) } catch { library.lastError = error.localizedDescription }
                }
                pendingTrash = nil
            }
        } message: {
            Text("The virtual machine and its Windows disk go to the Trash of \(library.volumeName). You can put it back until you empty the Trash.")
        }
    }
}

struct MachineRow: View {
    @ObservedObject var machine: VirtualMachine

    var body: some View {
        HStack(spacing: 10) {
            MachineArtwork(machine: machine, cornerRadius: 5)
                .frame(width: 46, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.config.name)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(machine.state.color)
                        .frame(width: 7, height: 7)
                    Text(machine.rowStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var library: VMLibrary
    @Binding var showingNewMachine: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "pc")
                .font(.system(size: 64, weight: .thin))
                .foregroundStyle(.tint)
            Text("Run Windows on your Mac")
                .font(.largeTitle.weight(.semibold))
            Text("SiliconWin runs Windows 11 on Arm at near-native speed with Apple's hypervisor.\nEverything is stored on \(library.volumeName).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button {
                showingNewMachine = true
            } label: {
                Label("New Virtual Machine", systemImage: "plus")
                    .padding(.horizontal, 8)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension VirtualMachine.State {
    var color: Color {
        switch self {
        case .running: return .green
        case .paused: return .yellow
        case .starting, .stopping: return .orange
        case .stopped: return .secondary.opacity(0.6)
        }
    }
}

extension VirtualMachine {
    var rowStatus: String {
        if state == .stopped {
            switch config.installState {
            case .notInstalled: return "Ready to install"
            case .installing: return "Installation not finished"
            case .installed: return config.guest.shortName
            }
        }
        if state == .running && config.installState == .installing { return "Installing Windows…" }
        return state.label
    }
}
