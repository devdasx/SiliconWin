import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Virtual hardware settings (only while the VM is off).
struct MachineSettingsSheet: View {
    @ObservedObject var machine: VirtualMachine
    @EnvironmentObject private var library: VMLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VMConfiguration
    @State private var errorText: String?

    init(machine: VirtualMachine) {
        self.machine = machine
        _draft = State(initialValue: machine.config)
    }

    private var hostCores: Int { ProcessInfo.processInfo.activeProcessorCount }
    private var hostMemoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }
    private var maxDiskGB: Int {
        max(machine.config.diskSizeGB, machine.config.diskSizeGB + Int(library.availableBytes / 1_073_741_824) - 24)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    LabeledContent("System", value: draft.guest.displayName)
                    TextField("Name", text: $draft.name)
                }
                Section("Hardware") {
                    Picker("Processor cores", selection: $draft.cpuCount) {
                        ForEach(Array(2...max(2, hostCores)), id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Memory", selection: $draft.memoryMB) {
                        ForEach(Array(stride(from: 4, through: max(4, hostMemoryGB - 4), by: 2)), id: \.self) { gb in
                            Text("\(gb) GB").tag(gb * 1024)
                        }
                    }
                    Stepper(value: $draft.diskSizeGB, in: machine.config.diskSizeGB...maxDiskGB, step: 16) {
                        LabeledContent("Windows disk", value: "\(draft.diskSizeGB) GB")
                    }
                    if draft.diskSizeGB > machine.config.diskSizeGB {
                        Text("After enlarging the disk, extend drive C: in Windows' Disk Management.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ResolutionPicker(resolution: $draft.resolution, guest: draft.guest)
                }
                Section("Devices") {
                    Toggle("Network (shared with the Mac)", isOn: $draft.networkEnabled)
                    Toggle("Sound", isOn: $draft.soundEnabled)
                }
                Section("Installation") {
                    LabeledContent("Status", value: statusText)
                    if draft.installState != .installed {
                        LabeledContent("Installer") {
                            HStack {
                                Text(draft.installerISOPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None")
                                    .lineLimit(1).truncationMode(.middle)
                                Button("Choose…") { chooseISO() }
                            }
                        }
                        Button("Windows is installed — detach the installer") {
                            draft.installState = .installed
                        }
                    } else {
                        Button("Reinstall Windows from an ISO…") {
                            chooseISO()
                            if draft.installerISOPath != nil {
                                draft.installState = .notInstalled
                                draft.installReboots = 0
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let errorText {
                    Text(errorText).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
    }

    private var statusText: String {
        switch draft.installState {
        case .notInstalled: return "Not installed"
        case .installing: return "Installation in progress"
        case .installed: return "Installed"
        }
    }

    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        panel.directoryURL = library.isosURL
        if panel.runModal() == .OK, let url = panel.url {
            draft.installerISOPath = url.path
        }
    }

    private func save() {
        guard machine.state == .stopped else {
            errorText = "Shut down the virtual machine first."
            return
        }
        do {
            if draft.diskSizeGB > machine.config.diskSizeGB {
                let handle = try FileHandle(forWritingTo: machine.bundle.diskURL)
                try handle.truncate(atOffset: UInt64(draft.diskSizeGB) * 1_073_741_824)
                try handle.close()
            }
            machine.config = draft
            try machine.saveConfig()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var library: VMLibrary
    @AppStorage("MacShortcuts") private var macShortcuts = true
    @AppStorage("ClipboardSharing") private var clipboardSharing = true

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Location") {
                    Text(library.rootURL.path)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([library.rootURL]) }
                    Button("Change…") { chooseLibrary() }
                }
            }
            Section {
                Toggle("Mac keyboard shortcuts", isOn: $macShortcuts)
            } header: {
                Text("Keyboard")
            } footer: {
                Text("⌘C, ⌘V, ⌘X, ⌘Z, ⌘A, ⌘S, … become Ctrl+C, Ctrl+V, … in Windows. Pressing ⌘ by itself opens Start. Turn this off to use ⌘ as the Windows key.")
            }
            Section {
                Toggle("Share the clipboard with Windows", isOn: $clipboardSharing)
            } header: {
                Text("Integration")
            } footer: {
                Text("Copied text moves between the Mac and Windows (needs the SiliconWin guest tools, installed automatically).")
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 420)
        .onChange(of: clipboardSharing) { _, enabled in
            library.machines.forEach { $0.clipboardSharing = enabled }
        }
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where SiliconWin keeps virtual machines and installers."
        if panel.runModal() == .OK, let url = panel.url {
            library.changeRoot(to: url)
        }
    }
}
