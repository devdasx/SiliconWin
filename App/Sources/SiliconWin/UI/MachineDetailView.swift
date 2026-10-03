import AppKit
import SwiftUI

struct MachineDetailView: View {
    @ObservedObject var machine: VirtualMachine
    @State private var showingSettings = false
    @State private var showInstallBanner = true

    private var showsScreen: Bool { machine.isActive && machine.framebuffer != nil }

    var body: some View {
        ZStack {
            if showsScreen {
                VMScreen(machine: machine)
                    .background(Color.black)
                    .ignoresSafeArea()
                    .overlay { screenOverlay }
            } else {
                MachineOverview(machine: machine, showingSettings: $showingSettings)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showsScreen, let status = machine.transferStatus {
                Label(status, systemImage: "doc.on.doc")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(18)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if showsScreen && machine.config.installState == .installing && showInstallBanner {
                InstallBanner(machine: machine)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: machine.state) {
            // Show the hint for a while after each start, then get out of the way.
            showInstallBanner = true
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            withAnimation { showInstallBanner = false }
        }
        .navigationTitle(machine.config.name)
        .navigationSubtitle(subtitle)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingSettings) {
            MachineSettingsSheet(machine: machine)
        }
        .alert("Windows could not continue", isPresented: Binding(
            get: { machine.errorMessage != nil && showsScreen },
            set: { if !$0 { machine.errorMessage = nil } }
        )) {
            Button("OK") { machine.errorMessage = nil }
        } message: {
            Text(machine.errorMessage ?? "")
        }
    }

    private func chooseFilesToSend() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Send to Windows"
        panel.message = "Files appear on the Windows desktop in the “From Mac” folder."
        if panel.runModal() == .OK {
            machine.sendFiles(panel.urls)
        }
    }

    private var subtitle: String {
        switch machine.state {
        case .stopped: return machine.config.guest.displayName
        case .running where machine.config.installState == .installing: return "Installing Windows"
        default: return machine.statusText.isEmpty ? machine.state.label : machine.statusText
        }
    }

    @ViewBuilder
    private var screenOverlay: some View {
        if machine.state == .paused {
            ZStack {
                Color.black.opacity(0.45)
                VStack(spacing: 14) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 54))
                    Text("Paused").font(.title2.weight(.semibold))
                    Button("Resume") { machine.resume() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                .foregroundStyle(.white)
            }
        } else if machine.state == .stopping {
            VStack {
                Spacer()
                Label(machine.statusText.isEmpty ? "Shutting down…" : machine.statusText, systemImage: "power")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 24)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            switch machine.state {
            case .stopped:
                Button {
                    machine.start()
                } label: {
                    Label(machine.config.installState == .installed ? "Start" : "Install", systemImage: "play.fill")
                }
                .help("Start \(machine.config.name)")
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .help("Change the virtual hardware")
            case .starting:
                ProgressView().controlSize(.small)
            case .running, .paused, .stopping:
                Button {
                    chooseFilesToSend()
                } label: {
                    Label("Send Files", systemImage: "square.and.arrow.down.on.square")
                }
                .help("Copy files from the Mac to the Windows desktop (or drag them onto the screen)")
                .disabled(machine.state != .running || !machine.agentConnected)

                Button {
                    machine.sendCtrlAltDelete()
                } label: {
                    Label("Ctrl+Alt+Delete", systemImage: "keyboard")
                }
                .help("Send Ctrl+Alt+Delete to Windows")
                .disabled(machine.state != .running)

                Button {
                    machine.state == .paused ? machine.resume() : machine.pause()
                } label: {
                    Label(machine.state == .paused ? "Resume" : "Pause",
                          systemImage: machine.state == .paused ? "play.fill" : "pause.fill")
                }
                .help(machine.state == .paused ? "Resume Windows" : "Pause Windows")
                .disabled(machine.state == .stopping)

                Button {
                    machine.restart()
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .help("Reset the virtual machine")
                .disabled(machine.state != .running)

                Menu {
                    Button("Shut Down Windows") { machine.shutDown() }
                    Button("Turn Off Immediately", role: .destructive) { machine.forceStop() }
                } label: {
                    Label("Shut Down", systemImage: "power")
                } primaryAction: {
                    machine.shutDown()
                }
                .help("Shut down Windows (hold for more options)")

                Button {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Enter or leave full screen (⌃⌘F)")
            }
        }
    }
}

/// Live guest screen.
struct VMScreen: NSViewRepresentable {
    @ObservedObject var machine: VirtualMachine
    @AppStorage("MacShortcuts") private var macShortcuts = true

    func makeNSView(context: Context) -> VMDisplayView {
        let view = VMDisplayView()
        view.keyboard.macShortcuts = macShortcuts
        view.onFilesDropped = { [weak machine] urls in machine?.sendFiles(urls) }
        machine.displayView = view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: VMDisplayView, context: Context) {
        view.keyboard.macShortcuts = macShortcuts
        if machine.displayView !== view { machine.displayView = view }
    }

    static func dismantleNSView(_ view: VMDisplayView, coordinator: ()) {
        view.client = nil
        view.framebuffer = nil
    }
}

struct InstallBanner: View {
    @ObservedObject var machine: VirtualMachine

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text("Installing Windows").font(.callout.weight(.semibold))
                Text(machine.config.setup.enabled && machine.config.setup.acceptedLicense
                     ? "Fully automatic. Windows restarts a few times; this takes about 15–30 minutes."
                     : "Follow Windows Setup. The virtual machine restarts a few times.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 6, y: 2)
        .allowsHitTesting(false)
    }
}

/// Screenshot of the VM, or a placeholder for one that never ran.
struct MachineArtwork: View {
    @ObservedObject var machine: VirtualMachine
    var cornerRadius: CGFloat = 12

    var body: some View {
        ZStack {
            if let image = machine.thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(red: 0.0, green: 0.36, blue: 0.75), Color(red: 0.0, green: 0.62, blue: 0.86)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                GeometryReader { geometry in
                    let side = min(geometry.size.width, geometry.size.height) * 0.36
                    WindowGlyph()
                        .frame(width: side, height: side)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}

/// Four panes (a window), drawn rather than using anyone's logo.
struct WindowGlyph: View {
    var body: some View {
        GeometryReader { geometry in
            let gap = geometry.size.width * 0.07
            let pane = (geometry.size.width - gap) / 2
            ZStack(alignment: .topLeading) {
                ForEach(0..<4) { index in
                    RoundedRectangle(cornerRadius: pane * 0.12)
                        .fill(.white.opacity(index == 0 ? 0.95 : 0.8))
                        .frame(width: pane, height: pane)
                        .offset(x: CGFloat(index % 2) * (pane + gap), y: CGFloat(index / 2) * (pane + gap))
                }
            }
        }
    }
}

struct MachineOverview: View {
    @ObservedObject var machine: VirtualMachine
    @EnvironmentObject private var library: VMLibrary
    @Binding var showingSettings: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MachineArtwork(machine: machine, cornerRadius: 16)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .frame(maxWidth: 760)
                    .overlay {
                        if machine.state == .starting {
                            ZStack {
                                Color.black.opacity(0.35)
                                VStack(spacing: 10) {
                                    ProgressView()
                                    Text(machine.statusText).foregroundStyle(.white)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .shadow(color: .black.opacity(0.25), radius: 14, y: 6)

                if let error = machine.errorMessage {
                    Label {
                        Text(error).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .padding(12)
                    .frame(maxWidth: 760, alignment: .leading)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(machine.config.name).font(.largeTitle.weight(.semibold))
                        Text(statusLine).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        showingSettings = true
                    } label: {
                        Text("Settings…")
                    }
                    .controlSize(.large)
                    .disabled(machine.state != .stopped)
                    Button {
                        machine.start()
                    } label: {
                        Label(primaryTitle, systemImage: "play.fill").padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(machine.state != .stopped)
                }
                .frame(maxWidth: 760)

                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                    spec("cpu", "Processor", "\(machine.config.cpuCount) cores · \(machine.config.guest.isHardwareAccelerated ? "Apple hypervisor (native speed)" : "x86 emulation")")
                    spec("memorychip", "Memory", "\(machine.config.memoryMB / 1024) GB")
                    spec("internaldrive", "Disk", "\(machine.diskUsageBytes.formattedBytes) used of \(machine.config.diskSizeGB) GB on \(library.volumeName)")
                    spec("display", "Display", machine.config.resolution.label)
                    spec("network", "Network", machine.config.networkEnabled ? "Shared with the Mac (NAT)" : "Off")
                    spec("speaker.wave.2", "Sound", machine.config.soundEnabled ? "On" : "Off")
                    if machine.attachesInstaller, let iso = machine.config.installerISOPath {
                        spec("opticaldisc", "Installer", URL(fileURLWithPath: iso).lastPathComponent)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)

                Divider().frame(maxWidth: 760)
                SnapshotsSection(machine: machine)
                    .frame(maxWidth: 760, alignment: .leading)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }

    private var primaryTitle: String {
        machine.config.installState == .installed ? "Start Windows" : (machine.config.installState == .installing ? "Continue Installing" : "Install Windows")
    }

    private var statusLine: String {
        switch machine.config.installState {
        case .notInstalled: return "\(machine.config.guest.displayName) · ready to install"
        case .installing: return "\(machine.config.guest.displayName) · installation in progress"
        case .installed:
            if let date = machine.config.lastStartedAt {
                return "\(machine.config.guest.displayName) · last used \(date.formatted(.relative(presentation: .named)))"
            }
            return machine.config.guest.displayName
        }
    }

    private func spec(_ icon: String, _ title: String, _ value: String) -> some View {
        GridRow {
            Label(title, systemImage: icon)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}
