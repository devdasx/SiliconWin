import AppKit
import Foundation
import Metal

enum VMError: LocalizedError {
    case missingRuntime([String])
    case installerMissing(String?)
    case unexpectedExit(Int32, String)

    var errorDescription: String? {
        switch self {
        case .missingRuntime(let files):
            return "SiliconWin is missing parts of its virtualization engine: \(files.joined(separator: ", ")). Rebuild the app with Scripts/build-app.sh."
        case .installerMissing(let path):
            return "The Windows installer disc image can't be found\(path.map { " at \($0)" } ?? ""). Choose it again in the VM settings."
        case .unexpectedExit(let code, let log):
            return "The virtual machine stopped unexpectedly (exit code \(code)).\n\n\(log)"
        }
    }
}

/// One Windows virtual machine: its settings, the QEMU process running it and
/// the live connections to that process (QMP control, screen, guest agent).
@MainActor
final class VirtualMachine: ObservableObject, Identifiable {
    enum State: Equatable {
        case stopped, starting, running, paused, stopping

        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting"
            case .running: return "Running"
            case .paused: return "Paused"
            case .stopping: return "Shutting down"
            }
        }
    }

    @Published var config: VMConfiguration
    @Published private(set) var state: State = .stopped
    @Published private(set) var statusText = ""
    @Published var errorMessage: String?
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var framebuffer: Framebuffer?
    @Published private(set) var agentConnected = false
    @Published private(set) var snapshots: [VMSnapshot] = []
    /// Progress of files being copied into Windows (nil when idle).
    @Published private(set) var transferStatus: String?

    let bundle: VMBundle
    /// Never changes, so it can be read from any thread (Identifiable).
    nonisolated let id: UUID
    var isActive: Bool { state != .stopped }

    /// The view currently showing this VM (set by `VMScreen`).
    weak var displayView: VMDisplayView? {
        didSet {
            displayView?.framebuffer = framebuffer
            displayView?.client = display
        }
    }

    var clipboardSharing = UserDefaults.standard.object(forKey: "ClipboardSharing") as? Bool ?? true

    private var process: Process?
    private var tpmProcess: Process?
    private var qmp: QMPClient?
    private var display: RFBClient?
    private var agent: AgentChannel?
    private var sockets: VMSockets?
    private var stopRequested = false
    private var timers: [Timer] = []
    private var lastPasteboardChange = NSPasteboard.general.changeCount
    private var lastClipboardFromGuest: String?
    private var logHandle: FileHandle?

    init(config: VMConfiguration, bundle: VMBundle) {
        self.config = config
        self.bundle = bundle
        id = config.id
        if let image = NSImage(contentsOf: bundle.screenshotURL) { thumbnail = image }
        snapshots = bundle.loadSnapshots()
    }

    // MARK: Snapshots

    func takeSnapshot(named name: String) async throws {
        guard state == .stopped else { throw SnapshotError.running }
        let (bundle, config) = (self.bundle, self.config)
        let title = name.trimmingCharacters(in: .whitespaces).isEmpty
            ? Date().formatted(date: .abbreviated, time: .shortened) : name
        _ = try await Task.detached { try bundle.takeSnapshot(named: title, config: config) }.value
        snapshots = bundle.loadSnapshots()
    }

    func restoreSnapshot(_ snapshot: VMSnapshot) async throws {
        guard state == .stopped else { throw SnapshotError.running }
        let bundle = self.bundle
        try await Task.detached { try bundle.restore(snapshot) }.value
        config.installState = snapshot.installState
        config.installReboots = snapshot.installReboots
        try saveConfig()
    }

    func deleteSnapshot(_ snapshot: VMSnapshot) async throws {
        let bundle = self.bundle
        try await Task.detached { try bundle.delete(snapshot) }.value
        snapshots = bundle.loadSnapshots()
    }

    // MARK: Configuration

    func saveConfig() throws {
        let data = try JSONEncoder.siliconWin.encode(config)
        try data.write(to: bundle.configURL, options: .atomic)
    }

    /// The installer stays attached until Windows reports that Setup finished.
    var attachesInstaller: Bool {
        config.installState != .installed && config.installerISOPath != nil
    }

    var diskUsageBytes: Int64 {
        let values = try? bundle.diskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    // MARK: Lifecycle

    func start() {
        guard state == .stopped else { return }
        errorMessage = nil
        stopRequested = false
        state = .starting
        statusText = "Starting…"
        Task { await launch() }
    }

    private func launch() async {
        let runtime = BundledRuntime.shared
        let config = self.config
        let bundle = self.bundle
        do {
            let missing = runtime.missingComponents(for: config.guest.architecture)
            guard missing.isEmpty else { throw VMError.missingRuntime(missing) }

            let installer = attachesInstaller
            if installer {
                guard let iso = config.installerISOPath, FileManager.default.fileExists(atPath: iso) else {
                    throw VMError.installerMissing(config.installerISOPath)
                }
            }
            statusText = installer ? "Preparing Windows Setup…" : "Starting…"
            try await Task.detached {
                // The tools disc carries the answer file and drivers; rebuild it
                // while installing so it always matches the current settings.
                if installer || GuestToolsMedia.isOutdated(bundle: bundle, runtime: runtime) {
                    try GuestToolsMedia.build(config: config, bundle: bundle, runtime: runtime)
                }
                if config.guest.usesUEFI, !FileManager.default.fileExists(atPath: bundle.efiVarsURL.path) {
                    try FileManager.default.copyItem(at: runtime.armFirmwareVarsTemplate, to: bundle.efiVarsURL)
                }
            }.value

            let sockets = try VMSockets.make(for: config.id)
            self.sockets = sockets
            let withTPM = config.tpmEnabled && config.guest.usesUEFI && runtime.hasTPM
            _ = try openLog()
            if withTPM {
                statusText = "Starting the TPM…"
                try startTPM(runtime: runtime, sockets: sockets)
                try await Task.detached { try Self.waitForSocket(sockets.tpm, timeout: 10) }.value
            }
            let plan = QEMULaunchPlan.make(config: config, bundle: bundle, runtime: runtime, sockets: sockets,
                                           attachInstaller: installer, attachTools: true, withTPM: withTPM)
            try startProcess(plan)

            statusText = "Connecting…"
            let qmp = try await Task.detached { try QMPClient.connect(path: sockets.qmp.path, timeout: 30) }.value
            self.qmp = qmp
            qmp.onEvent = { [weak self] name, data in
                Task { @MainActor in self?.handleEvent(name, data) }
            }

            guard let device = MTLCreateSystemDefaultDevice() else { throw RFBError.protocolViolation("no Metal device") }
            let display = try await Task.detached { try RFBClient(socketPath: sockets.vnc.path, device: device) }.value
            self.display = display
            display.onResize = { [weak self] framebuffer in self?.setFramebuffer(framebuffer) }
            display.onUpdate = { [weak self] in self?.displayView?.needsDisplay = true }
            display.onClose = { [weak self] _ in self?.displayClosed() }
            setFramebuffer(display.framebuffer)
            displayView?.client = display
            display.start()

            connectAgent(path: sockets.agent.path)

            state = .running
            statusText = ""
            self.config.lastStartedAt = Date()
            if self.config.installState == .notInstalled, installer {
                self.config.installState = .installing
            }
            try? saveConfig()

            if installer && self.config.installReboots == 0 {
                pressKeyForInstallerPrompt()
            }
            startTimers()
        } catch {
            errorMessage = error.localizedDescription
            statusText = ""
            stopRequested = true
            teardown()
            process?.terminate()
            if process == nil {
                tpmProcess?.terminate()
                tpmProcess = nil
                try? logHandle?.close()
                logHandle = nil
                state = .stopped
            }
        }
    }

    /// Starts a fresh qemu.log (the previous one is kept as qemu-previous.log).
    private func openLog() throws -> FileHandle {
        if let logHandle { return logHandle }
        let fm = FileManager.default
        try fm.createDirectory(at: bundle.logsURL, withIntermediateDirectories: true)
        let previous = bundle.logsURL.appendingPathComponent("qemu-previous.log")
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: bundle.logURL, to: previous)
        fm.createFile(atPath: bundle.logURL.path, contents: Data("SiliconWin \(Date())\n".utf8))
        let log = try FileHandle(forWritingTo: bundle.logURL)
        log.seekToEndOfFile()
        logHandle = log
        return log
    }

    private func startProcess(_ plan: QEMULaunchPlan) throws {
        let log = try openLog()
        log.write(Data("\(plan.commandLine)\n\n".utf8))

        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.currentDirectoryURL = bundle.url
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.processExited(status: status) }
        }
        try process.run()
        self.process = process
    }

    /// swtpm keeps the TPM's state in the VM bundle and exits on its own when
    /// QEMU disconnects (--terminate).
    private func startTPM(runtime: BundledRuntime, sockets: VMSockets) throws {
        try FileManager.default.createDirectory(at: bundle.tpmStateURL, withIntermediateDirectories: true)
        let tpm = Process()
        tpm.executableURL = runtime.swtpm
        tpm.arguments = ["socket", "--tpm2",
                         "--tpmstate", "dir=\(bundle.tpmStateURL.path.replacingOccurrences(of: ",", with: ",,"))",
                         "--ctrl", "type=unixio,path=\(sockets.tpm.path)",
                         "--log", "file=\(bundle.logsURL.appendingPathComponent("swtpm.log").path.replacingOccurrences(of: ",", with: ",,")),level=1",
                         "--terminate"]
        tpm.currentDirectoryURL = bundle.url
        tpm.standardInput = FileHandle.nullDevice
        tpm.standardOutput = logHandle ?? FileHandle.nullDevice
        tpm.standardError = logHandle ?? FileHandle.nullDevice
        try tpm.run()
        tpmProcess = tpm
    }

    nonisolated private static func waitForSocket(_ url: URL, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path) {
            if Date() > deadline { throw SocketError.connectFailed(url.path, ETIMEDOUT) }
            usleep(50_000)
        }
    }

    private func processExited(status: Int32) {
        if tpmProcess?.isRunning == true { tpmProcess?.terminate() }
        tpmProcess = nil
        teardown()
        process = nil
        try? logHandle?.close()
        logHandle = nil
        if let sockets { try? FileManager.default.removeItem(at: sockets.directory) }
        sockets = nil
        if !stopRequested && status != 0 && errorMessage == nil {
            errorMessage = VMError.unexpectedExit(status, lastLogLines()).localizedDescription
        }
        state = .stopped
        statusText = ""
        framebuffer = nil
        displayView?.framebuffer = nil
    }

    private func teardown() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        display?.onClose = nil
        display?.close()
        display = nil
        displayView?.client = nil
        qmp?.onEvent = nil
        qmp?.close()
        qmp = nil
        agent?.onLine = nil
        agent?.onClose = nil
        agent?.close()
        agent = nil
        agentConnected = false
    }

    private func lastLogLines(_ count: Int = 12) -> String {
        guard let text = try? String(contentsOf: bundle.logURL, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(count).joined(separator: "\n")
    }

    // MARK: Controls

    /// Asks Windows to shut down (like pressing the power button).
    func shutDown() {
        guard state == .running || state == .paused else { return }
        if state == .paused { qmp?.send("cont") }
        captureThumbnail()  // the screen goes black once Windows shuts down
        state = .stopping
        statusText = "Waiting for Windows to shut down…"
        qmp?.send("system_powerdown")
    }

    /// Turns the VM off immediately (unsaved work in Windows is lost).
    func forceStop() {
        guard let process else { return }
        stopRequested = true
        state = .stopping
        qmp?.send("quit")
        let pid = process.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.process?.processIdentifier == pid, self.process?.isRunning == true else { return }
            self.process?.terminate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.process?.processIdentifier == pid, self?.process?.isRunning == true { kill(pid, SIGKILL) }
            }
        }
    }

    func restart() {
        guard state == .running else { return }
        qmp?.send("system_reset")
    }

    func pause() {
        guard state == .running else { return }
        qmp?.send("stop")
    }

    func resume() {
        guard state == .paused else { return }
        qmp?.send("cont")
    }

    func sendCtrlAltDelete() {
        qmp?.sendKeys(["ctrl", "alt", "delete"])
    }

    /// Detaches the Windows installer disc (after Setup finished).
    func markInstalled() {
        config.installState = .installed
        try? saveConfig()
    }

    // MARK: Events

    private func handleEvent(_ name: String, _ data: [String: Any]) {
        switch name {
        case "STOP":
            if state == .running { state = .paused }
        case "RESUME":
            if state == .paused || state == .starting { state = .running }
        case "RESET":
            // Windows Setup reboots several times; from then on the installer
            // disc must not be booted again.
            if config.installState == .installing {
                config.installReboots += 1
                try? saveConfig()
            }
        case "SHUTDOWN":
            stopRequested = true
            state = .stopping
        case "POWERDOWN":
            statusText = "Waiting for Windows to shut down…"
        default:
            break
        }
    }

    private func setFramebuffer(_ framebuffer: Framebuffer) {
        self.framebuffer = framebuffer
        displayView?.framebuffer = framebuffer
    }

    private func displayClosed() {
        // QEMU closes the display when it exits; the process handler cleans up.
    }

    /// UEFI shows "Press any key to boot from CD or DVD…" for a few seconds on
    /// the first boot of an installation; answer it so Setup starts by itself.
    /// Key presses stop as soon as Windows Boot Manager starts loading boot.wim
    /// from the disc, so none of them reach Windows Setup itself.
    private func pressKeyForInstallerPrompt() {
        Task { [weak self] in
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, self.state == .running, self.config.installReboots == 0, let qmp = self.qmp else { return }
                if await self.installerBytesRead(qmp) > 48 << 20 { return }
                qmp.sendKeys(["ret"], holdMilliseconds: 50)
            }
        }
    }

    private func installerBytesRead(_ qmp: QMPClient) async -> Int {
        guard let devices = try? await qmp.execute("query-blockstats") as? [[String: Any]],
              let installer = devices.first(where: { ($0["device"] as? String) == "installer" }),
              let stats = installer["stats"] as? [String: Any] else { return 0 }
        return (stats["rd_bytes"] as? NSNumber)?.intValue ?? 0
    }

    // MARK: Guest agent

    private func connectAgent(path: String) {
        guard let channel = try? AgentChannel.connect(path: path, timeout: 5) else { return }
        agent = channel
        channel.onLine = { [weak self] line in
            Task { @MainActor in self?.handleAgentLine(line) }
        }
        channel.onClose = { [weak self] in
            Task { @MainActor in self?.agentConnected = false }
        }
        channel.start()
    }

    private func handleAgentLine(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let command = parts.first else { return }
        switch command {
        case "hello":
            agentConnected = true
            lastPasteboardChange = -1  // push the Mac clipboard to Windows
            // The agent only exists in an installed Windows.
            if config.installState != .installed {
                config.installState = .installed
                try? saveConfig()
            }
        case "install-complete":
            if config.installState != .installed {
                config.installState = .installed
                try? saveConfig()
            }
        case "file-done":
            let name = parts.count > 1 ? String(decoding: Data(base64Encoded: parts[1]) ?? Data(), as: UTF8.self) : "File"
            transferStatus = "\(name) is on the Windows desktop in “From Mac”"
            let shown = transferStatus
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if self?.transferStatus == shown { self?.transferStatus = nil }
            }
        case "file-error":
            let message = parts.count > 1 ? String(decoding: Data(base64Encoded: parts[1]) ?? Data(), as: UTF8.self) : ""
            transferStatus = nil
            errorMessage = "Windows could not save the file: \(message)"
        case "clipboard":
            guard clipboardSharing, parts.count > 1, let data = Data(base64Encoded: parts[1]) else { return }
            let text = String(decoding: data, as: UTF8.self)
            lastClipboardFromGuest = text
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            lastPasteboardChange = pasteboard.changeCount
        default:
            break
        }
    }

    /// Markers that password managers put on secrets they copy (see
    /// nspasteboard.org). Such clipboard contents never leave the Mac.
    private static let concealedPasteboardTypes: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType"),
    ]

    private func syncClipboardToGuest() {
        guard clipboardSharing, agentConnected, let agent else { return }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = pasteboard.changeCount
        guard !(pasteboard.types ?? []).contains(where: Self.concealedPasteboardTypes.contains) else { return }
        guard let text = pasteboard.string(forType: .string), text != lastClipboardFromGuest,
              text.utf8.count <= 4_000_000 else { return }
        agent.send("clipboard " + Data(text.utf8).base64EncodedString())
    }

    // MARK: Files to Windows

    /// Copies files (folders are zipped first) into Windows, where the agent
    /// saves them to Desktop\\From Mac.
    func sendFiles(_ urls: [URL]) {
        guard agentConnected, let agent else {
            errorMessage = "Windows isn't ready to receive files yet. Wait until the Windows desktop is up (the SiliconWin guest tools must be running)."
            return
        }
        let staging = bundle.url.appendingPathComponent(".outgoing", isDirectory: true)
        transferStatus = "Preparing…"
        Task.detached { [weak self] in
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            for url in urls {
                var file = url
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    await self?.setTransferStatus("Compressing \(url.lastPathComponent)…")
                    let zip = staging.appendingPathComponent(url.lastPathComponent + ".zip")
                    let ditto = Process()
                    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    ditto.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", url.path, zip.path]
                    try? ditto.run()
                    ditto.waitUntilExit()
                    guard ditto.terminationStatus == 0 else { continue }
                    file = zip
                }
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                defer { try? handle.close() }
                let name = file.lastPathComponent
                let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                agent.send("file-begin \(Data(name.utf8).base64EncodedString()) \(size)")
                var sent: Int64 = 0
                var lastReport = Date.distantPast
                while let chunk = try? handle.read(upToCount: 48 * 1024), !chunk.isEmpty {
                    agent.send("file-data " + chunk.base64EncodedString())
                    sent += Int64(chunk.count)
                    if Date().timeIntervalSince(lastReport) > 0.25 {
                        lastReport = Date()
                        let percent = size > 0 ? Int(Double(sent) / Double(size) * 100) : 0
                        await self?.setTransferStatus("Copying \(name) to Windows… \(percent) %")
                    }
                }
                agent.send("file-end")
            }
        }
    }

    private func setTransferStatus(_ text: String?) {
        transferStatus = text
    }

    // MARK: Periodic work

    private func startTimers() {
        timers.forEach { $0.invalidate() }
        timers = [
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.syncClipboardToGuest() }
            },
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.captureThumbnail() }
            },
        ]
    }

    /// Saves a small picture of the screen for the library.
    func captureThumbnail() {
        guard let framebuffer, let image = framebuffer.makeImage() else { return }
        let width = 640
        let height = max(1, Int(Double(width) * Double(image.height) / Double(image.width)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Keep the previous picture rather than a black screen (boot, shutdown).
        if let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
            var total = 0
            let count = context.bytesPerRow * height
            for index in stride(from: 0, to: count, by: 4 * 97) { total += Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2]) }
            if total / max(1, count / (4 * 97)) < 24 { return }
        }
        guard let scaled = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: bundle.screenshotURL, options: .atomic)
        thumbnail = NSImage(data: png)
    }
}
