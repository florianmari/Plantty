import GhosttyKit
import SwiftUI

@main
struct PlanttyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var ws = Workspace.shared

    var body: some Scene {
        Window("Plantty", id: "main") {
            ContentView()
                .environment(ws)
                .frame(minWidth: 480, minHeight: 280)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 720)
        .commands { PlanttyCommands(ws: ws) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Updater.controller // starts Sparkle's scheduled background checks
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Workspace.shared.save()
        guard ghostty_app_needs_confirm_quit(GhosttyApp.shared.app) else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Plantty?"
        alert.informativeText = "Processes are still running in some terminals."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

/// Menu shortcuts. When a terminal is focused, matching ghostty keybinds fire first and
/// arrive through GhosttyApp's action callback into the same Workspace methods.
struct PlanttyCommands: Commands {
    let ws: Workspace
    @AppStorage("tabStyle") private var tabStyle = TabStyle.vertical
    @AppStorage(Workspace.restoreSessionKey) private var restoreSession = true
    @AppStorage(sidebarAutoHideKey) private var sidebarAutoHide = false

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updater.checkForUpdates() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { ws.newTab() }.keyboardShortcut("t")
            Button("New Project…") { ws.newProject() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Split Right") { ws.splitFocused(.horizontal) }.keyboardShortcut("d")
            Button("Split Down") { ws.splitFocused(.vertical) }.keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Close Pane") { ws.closeFocusedPane() }.keyboardShortcut("w")
            Button("Close Tab") { ws.closeSelectedTab() }.keyboardShortcut("w", modifiers: [.command, .option])
        }
        CommandMenu("Tabs") {
            Button("Command Palette…") { ws.isPaletteOpen.toggle() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Next Tab") { ws.cycleTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { ws.cycleTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Next Split") { ws.cycleFocus(1) }.keyboardShortcut("]")
            Button("Previous Split") { ws.cycleFocus(-1) }.keyboardShortcut("[")
            Divider()
            Button("Next Project") { ws.cycleProject(1) }.keyboardShortcut("]", modifiers: [.command, .control])
            Button("Previous Project") { ws.cycleProject(-1) }.keyboardShortcut("[", modifiers: [.command, .control])
            Divider()
            ForEach(1..<10) { n in
                Button("Tab \(n)") { ws.selectTab(at: n == 9 ? Int.max : n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
            Divider()
            Button(tabStyle == .vertical ? "Use Horizontal Tabs" : "Use Vertical Tabs") {
                tabStyle = tabStyle == .vertical ? .horizontal : .vertical
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            Toggle("Auto-Hide Sidebar", isOn: $sidebarAutoHide)
                .keyboardShortcut("s", modifiers: [.command, .control])
            Toggle("Restore Tabs on Launch", isOn: $restoreSession)
        }
    }
}
