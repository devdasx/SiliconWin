import AppKit
import SwiftUI

@main
struct SiliconWinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = VMLibrary()
    @StateObject private var downloads = DownloadCenter.shared

    var body: some Scene {
        Window("SiliconWin", id: "main") {
            ContentView()
                .environmentObject(library)
                .environmentObject(downloads)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear { appDelegate.library = library }
        }
        .defaultSize(width: 1400, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Machine…") {
                    NotificationCenter.default.post(name: .newMachineRequested, object: nil)
                }
                .keyboardShortcut("n")
            }
            MachineCommands(library: library)
        }

        Settings {
            SettingsView()
                .environmentObject(library)
        }
    }
}

extension Notification.Name {
    static let newMachineRequested = Notification.Name("SiliconWinNewMachineRequested")
}

struct MachineCommands: Commands {
    @ObservedObject var library: VMLibrary

    var body: some Commands {
        CommandMenu("Virtual Machine") {
            let machine = library.selected
            Button(machine?.state == .paused ? "Resume" : "Start") {
                if machine?.state == .paused { machine?.resume() } else { machine?.start() }
            }
            .disabled(machine == nil || !(machine?.state == .stopped || machine?.state == .paused))
            Button("Pause") { machine?.pause() }
                .disabled(machine?.state != .running)
            Button("Restart") { machine?.restart() }
                .disabled(machine?.state != .running)
            Divider()
            Button("Shut Down") { machine?.shutDown() }
                .disabled(!(machine?.state == .running || machine?.state == .paused))
            Button("Force Stop") { machine?.forceStop() }
                .disabled(machine == nil || machine?.state == .stopped)
            Divider()
            Button("Send Ctrl+Alt+Delete") { machine?.sendCtrlAltDelete() }
                .disabled(machine?.state != .running)
            Button("Show in Finder") {
                if let url = machine?.bundle.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .disabled(machine == nil)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var library: VMLibrary?
    private var quitTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = library?.machines.filter(\.isActive) ?? []
        guard !active.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = active.count == 1 ? "\(active[0].config.name) is still running" : "Windows virtual machines are still running"
        alert.informativeText = "Shut Windows down before quitting so nothing is lost. “Turn Off” stops it immediately, like pulling the plug."
        alert.addButton(withTitle: "Shut Down and Quit")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Turn Off and Quit")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            active.forEach { $0.shutDown() }
            waitForStop(of: active, timeout: 180)
            return .terminateLater
        case .alertThirdButtonReturn:
            active.forEach { $0.forceStop() }
            waitForStop(of: active, timeout: 15)
            return .terminateLater
        default:
            return .terminateCancel
        }
    }

    private func waitForStop(of machines: [VirtualMachine], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        quitTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            Task { @MainActor in
                if machines.allSatisfy({ !$0.isActive }) {
                    timer.invalidate()
                    NSApp.reply(toApplicationShouldTerminate: true)
                } else if Date() > deadline {
                    machines.filter(\.isActive).forEach { $0.forceStop() }
                    if Date() > deadline.addingTimeInterval(10) {
                        timer.invalidate()
                        NSApp.reply(toApplicationShouldTerminate: true)
                    }
                }
                _ = self
            }
        }
    }
}
