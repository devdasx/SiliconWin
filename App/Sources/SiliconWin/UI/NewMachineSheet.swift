import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NewMachineSheet: View {
    @EnvironmentObject private var library: VMLibrary
    @EnvironmentObject private var downloads: DownloadCenter
    @Environment(\.dismiss) private var dismiss

    private enum Step: Int, CaseIterable {
        case system, installer, hardware, setup
        var title: String {
            switch self {
            case .system: return "Windows"
            case .installer: return "Installer"
            case .hardware: return "Hardware"
            case .setup: return "Setup"
            }
        }
    }

    @State private var step = Step.system
    @State private var config = VMConfiguration.makeDefault(for: .windows11Arm)
    @State private var useWholeDrive = true
    @State private var showingDownload = false
    @State private var downloadID: UUID?
    @State private var errorText: String?

    private var hostCores: Int { ProcessInfo.processInfo.activeProcessorCount }
    private var hostMemoryGB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }
    /// Leave room on the drive for installers and the app.
    private var maxDiskGB: Int { max(config.guest.minimumDiskGB, Int(library.availableBytes / 1_073_741_824) - 24) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                Group {
                    switch step {
                    case .system: systemStep
                    case .installer: installerStep
                    case .hardware: hardwareStep
                    case .setup: setupStep
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 620)
        .sheet(isPresented: $showingDownload) {
            MicrosoftDownloadSheet(guest: config.guest) { url in
                downloadID = downloads.download(url, into: library.isosURL)
            }
        }
        .onChange(of: downloads.items) { _, _ in
            if let item = downloads.item(downloadID), item.status == .finished {
                config.installerISOPath = item.destination.path
            }
        }
        .onAppear {
            config.diskSizeGB = maxDiskGB
            pickExistingISO()
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 18) {
            Text("New Virtual Machine").font(.title2.weight(.semibold))
            Spacer()
            ForEach(Step.allCases, id: \.self) { item in
                HStack(spacing: 6) {
                    Text("\(item.rawValue + 1)")
                        .font(.caption.weight(.bold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(item.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25)))
                        .foregroundStyle(item.rawValue <= step.rawValue ? .white : .secondary)
                    Text(item.title)
                        .font(.callout)
                        .foregroundStyle(item == step ? .primary : .secondary)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack {
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if step != .system {
                Button("Back") { step = Step(rawValue: step.rawValue - 1)! }
            }
            if step == .setup {
                Button("Create and Install") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            } else {
                Button("Continue") { step = Step(rawValue: step.rawValue + 1)! }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(step == .installer && config.installerISOPath == nil)
            }
        }
        .padding(16)
    }

    // MARK: Steps

    private var systemStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Which Windows do you want to run?").font(.headline)
            ForEach(GuestOS.allCases) { guest in
                Button {
                    select(guest)
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: guest.isHardwareAccelerated ? "bolt.fill" : "tortoise.fill")
                            .font(.title2)
                            .foregroundStyle(guest.isHardwareAccelerated ? Color.accentColor : Color.orange)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(guest.displayName).font(.headline)
                                if guest == .windows11Arm {
                                    Text("Recommended")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                }
                            }
                            Text(guest.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: config.guest == guest ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(config.guest == guest ? Color.accentColor : Color.secondary)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(config.guest == guest ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(config.guest == guest ? Color.accentColor : Color.clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var installerStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Windows installation disc (ISO)").font(.headline)
            Text("Download it from Microsoft right here, or use an ISO you already have. It is saved on \(library.volumeName).")
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    showingDownload = true
                } label: {
                    Label("Download from Microsoft…", systemImage: "arrow.down.circle")
                }
                .controlSize(.large)
                Button {
                    chooseISO()
                } label: {
                    Label("Choose ISO File…", systemImage: "folder")
                }
                .controlSize(.large)
            }

            if let item = downloads.item(downloadID) {
                DownloadRow(item: item)
            }

            let isos = library.availableISOs()
            if !isos.isEmpty {
                Text("In your library").font(.subheadline.weight(.semibold)).padding(.top, 6)
                ForEach(isos, id: \.self) { iso in
                    Button {
                        config.installerISOPath = iso.path
                    } label: {
                        HStack {
                            Image(systemName: config.installerISOPath == iso.path ? "checkmark.circle.fill" : "opticaldisc")
                                .foregroundStyle(config.installerISOPath == iso.path ? Color.accentColor : Color.secondary)
                            Text(iso.lastPathComponent)
                            Spacer()
                            Text(fileSize(iso)).foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
            }

            if let path = config.installerISOPath, !config.guest.matchesISO(named: URL(fileURLWithPath: path).lastPathComponent) {
                Label("This file name doesn't look like \(config.guest.displayName). Make sure it is the right ISO (Arm64 for Windows on Arm, x64 otherwise).",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
    }

    private var hardwareStep: some View {
        Form {
            TextField("Name", text: $config.name)
            Picker("Processor cores", selection: $config.cpuCount) {
                ForEach(Array(stride(from: 2, through: max(2, hostCores), by: 1)), id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Memory", selection: $config.memoryMB) {
                ForEach(Array(stride(from: 4, through: max(4, hostMemoryGB - 4), by: 2)), id: \.self) { gb in
                    Text("\(gb) GB").tag(gb * 1024)
                }
            }
            Toggle("Use all free space on \(library.volumeName) for Windows", isOn: $useWholeDrive)
                .onChange(of: useWholeDrive) { _, whole in if whole { config.diskSizeGB = maxDiskGB } }
            if useWholeDrive {
                LabeledContent("Windows disk", value: "\(maxDiskGB) GB")
            } else {
                Stepper(value: $config.diskSizeGB, in: config.guest.minimumDiskGB...maxDiskGB, step: 16) {
                    LabeledContent("Windows disk", value: "\(config.diskSizeGB) GB")
                }
            }
            Text("The disk grows as Windows stores data; space Windows frees is returned to the drive.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ResolutionPicker(resolution: $config.resolution, guest: config.guest)
        }
        .formStyle(.grouped)
    }

    private var setupStep: some View {
        Form {
            Section {
                Toggle("Install Windows automatically", isOn: $config.setup.enabled)
            } footer: {
                Text(config.setup.enabled
                     ? "No questions during installation. You get a local account and go straight to the desktop."
                     : "You answer Windows Setup's questions yourself in the virtual machine window.")
            }
            if config.setup.enabled {
                Section("Windows account") {
                    TextField("User name", text: $config.setup.userName)
                    SecureField("Password (optional)", text: $config.setup.password)
                    TextField("Computer name", text: $config.setup.computerName)
                }
                Section("Region") {
                    LabeledContent("Time zone", value: config.setup.timeZone)
                    LabeledContent("Keyboards", value: WindowsLocale.describeInputLocales(config.setup.inputLocales))
                }
                Section {
                    Toggle(isOn: $config.setup.acceptedLicense) {
                        Text("I accept the Microsoft Software License Terms for Windows")
                    }
                    Link("Read the license terms", destination: URL(string: "https://www.microsoft.com/en-us/useterms")!)
                        .font(.callout)
                } footer: {
                    Text("Automatic setup answers the license screen for you, so it needs your agreement. Windows installs as \(config.guest.edition) without a product key and stays unactivated until you enter your own.")
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Actions

    private var canCreate: Bool {
        guard config.installerISOPath != nil, !config.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if config.setup.enabled {
            return config.setup.acceptedLicense && !config.setup.userName.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    private func select(_ guest: GuestOS) {
        var updated = VMConfiguration.makeDefault(for: guest)
        updated.setup = config.setup
        updated.diskSizeGB = useWholeDrive ? maxDiskGB : max(guest.minimumDiskGB, config.diskSizeGB)
        config = updated
        pickExistingISO()
    }

    private func pickExistingISO() {
        if let path = config.installerISOPath, config.guest.matchesISO(named: URL(fileURLWithPath: path).lastPathComponent) { return }
        config.installerISOPath = library.availableISOs(for: config.guest).first?.path
    }

    private func chooseISO() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Windows installation ISO"
        if panel.runModal() == .OK, let url = panel.url {
            config.installerISOPath = url.path
        }
    }

    private func fileSize(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Int64(size).formattedBytes
    }

    private func create() {
        do {
            if useWholeDrive { config.diskSizeGB = maxDiskGB }
            config.setup.computerName = String(config.setup.computerName.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(15))
            if config.setup.computerName.isEmpty { config.setup.computerName = "SILICONWIN" }
            let machine = try library.create(config)
            dismiss()
            machine.start()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct ResolutionPicker: View {
    @Binding var resolution: DisplayResolution
    let guest: GuestOS

    var body: some View {
        let native = DisplayResolution.fullScreenNative
        let retina = DisplayResolution.fullScreenRetina
        var choices = [native]
        if retina != native { choices.append(retina) }
        for preset in DisplayResolution.presets where !choices.contains(preset) { choices.append(preset) }
        if !choices.contains(resolution) { choices.append(resolution) }

        return VStack(alignment: .leading, spacing: 4) {
            Picker("Display", selection: $resolution) {
                ForEach(choices) { option in
                    Text(label(for: option, native: native, retina: retina)).tag(option)
                }
            }
            if guest.usesUEFI {
                Text("Windows on Arm keeps this resolution; change it here and restart Windows to switch. With “Retina”, set Windows' scale to 200 % for sharp text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func label(for option: DisplayResolution, native: DisplayResolution, retina: DisplayResolution) -> String {
        if option == native { return "\(option.label) — fills this Mac's screen (recommended)" }
        if option == retina { return "\(option.label) — Retina, sharpest" }
        return option.label
    }
}

struct DownloadRow: View {
    let item: DownloadCenter.Item
    @EnvironmentObject private var downloads: DownloadCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(item.fileName).lineLimit(1).truncationMode(.middle)
                Spacer()
                if item.status == .downloading {
                    Button("Stop") { downloads.cancel(item.id) }.controlSize(.small)
                }
            }
            switch item.status {
            case .downloading:
                ProgressView(value: item.fraction)
                Text(progressText).font(.caption).foregroundStyle(.secondary)
            case .finished:
                Text("Downloaded \(item.received.formattedBytes)").font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }

    private var icon: String {
        switch item.status {
        case .downloading: return "arrow.down.circle"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch item.status {
        case .downloading: return .accentColor
        case .finished: return .green
        case .failed: return .red
        }
    }

    private var progressText: String {
        var text = item.received.formattedBytes
        if item.expected > 0 { text += " of \(item.expected.formattedBytes)" }
        if item.bytesPerSecond > 0 {
            text += " · \(Int64(item.bytesPerSecond).formattedBytes)/s"
            if item.expected > 0 {
                let seconds = Double(item.expected - item.received) / item.bytesPerSecond
                text += " · \(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) left"
            }
        }
        return text
    }
}
