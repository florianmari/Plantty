import SwiftUI

struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let icon: String
    var shortcut: String = ""
    let run: () -> Void
}

/// ⌘⇧P: fuzzy-filtered list of actions, projects and tabs. ↑/↓ to move, ↩ to run, esc to close.
struct CommandPalette: View {
    @Environment(Workspace.self) private var ws
    @AppStorage("tabStyle") private var tabStyle = TabStyle.vertical
    @AppStorage(Workspace.restoreSessionKey) private var restoreSession = true
    @AppStorage(sidebarAutoHideKey) private var sidebarAutoHide = false
    @AppStorage(showUsageKey) private var showUsage = true
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = filtered
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { run(results) }
                    .onKeyPress(.downArrow) { move(1, count: results.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
                    .onExitCommand { close() }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Theme.separator.frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { i, cmd in
                            row(cmd, selected: i == selection)
                                .id(cmd.id)
                                .onTapGesture { selection = i; run(results) }
                        }
                        if results.isEmpty {
                            Text("No matching commands")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: selection) {
                    if results.indices.contains(selection) { proxy.scrollTo(results[selection].id) }
                }
            }
        }
        .frame(width: 540)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        .onAppear { focused = true }
        .onChange(of: query) { selection = 0 }
    }

    private func row(_ cmd: PaletteCommand, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: cmd.icon)
                .font(.system(size: 12))
                .foregroundStyle(selected ? .primary : .secondary)
                .frame(width: 18)
            Text(cmd.title).font(.system(size: 13)).lineLimit(1)
            Spacer()
            Text(cmd.shortcut).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(selected ? Theme.selected : .clear, in: .rect(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private var filtered: [PaletteCommand] {
        let tokens = query.lowercased().split(separator: " ")
        guard !tokens.isEmpty else { return commands }
        return commands.filter { cmd in
            let title = cmd.title.lowercased()
            return tokens.allSatisfy { title.contains($0) }
        }
    }

    private var commands: [PaletteCommand] {
        var list: [PaletteCommand] = [
            .init(id: "new-tab", title: "New Tab", icon: "plus", shortcut: "⌘T") { ws.newTab() },
            .init(id: "new-project", title: "New Project…", icon: "folder.badge.plus", shortcut: "⇧⌘N") { ws.newProject() },
            .init(id: "split-right", title: "Split Right", icon: "rectangle.split.2x1", shortcut: "⌘D") { ws.splitFocused(.horizontal) },
            .init(id: "split-down", title: "Split Down", icon: "rectangle.split.1x2", shortcut: "⇧⌘D") { ws.splitFocused(.vertical) },
            .init(id: "close-pane", title: "Close Pane", icon: "xmark.square", shortcut: "⌘W") { ws.closeFocusedPane() },
            .init(id: "close-tab", title: "Close Tab", icon: "xmark", shortcut: "⌥⌘W") { ws.closeSelectedTab() },
            .init(id: "next-tab", title: "Next Tab", icon: "arrow.right", shortcut: "⇧⌘]") { ws.cycleTab(1) },
            .init(id: "prev-tab", title: "Previous Tab", icon: "arrow.left", shortcut: "⇧⌘[") { ws.cycleTab(-1) },
            .init(id: "toggle-style", title: tabStyle == .vertical ? "Use Horizontal Tabs" : "Use Vertical Tabs",
                  icon: "sidebar.left", shortcut: "⇧⌘T") { tabStyle = tabStyle == .vertical ? .horizontal : .vertical },
            .init(id: "sidebar-autohide", title: sidebarAutoHide ? "Keep Sidebar Open" : "Auto-Hide Sidebar",
                  icon: "sidebar.left", shortcut: "⌃⌘S") { sidebarAutoHide.toggle() },
            .init(id: "check-updates", title: "Check for Updates…", icon: "arrow.down.circle") { Updater.checkForUpdates() },
            .init(id: "show-usage", title: showUsage ? "Hide AI Usage" : "Show AI Usage", icon: "gauge.with.dots.needle.50percent") {
                showUsage.toggle()
                if showUsage { UsageService.shared.refresh() }
            },
            .init(id: "refresh-usage", title: "Refresh AI Usage", icon: "arrow.clockwise") { UsageService.shared.refresh() },
            .init(id: "restore-session",
                  title: restoreSession ? "Don't Restore Tabs on Launch" : "Restore Tabs on Launch",
                  icon: "clock.arrow.circlepath") { restoreSession.toggle() },
        ]
        if let tab = ws.selectedTab {
            list.append(.init(id: "rename-tab", title: "Rename Tab…", icon: "pencil") { ws.startRename(tab) })
        }
        if let project = ws.selectedProject {
            list += [
                .init(id: "rename-project", title: "Rename Project…", icon: "pencil.line") { ws.startRename(project) },
                .init(id: "reveal-project", title: "Show Project in Finder", icon: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.directory)])
                },
                .init(id: "close-project", title: "Close Project", icon: "trash") { ws.close(project) },
            ]
        }
        for project in ws.projects {
            list.append(.init(id: "project-\(project.id)", title: "Go to Project: \(project.name)", icon: "folder.fill") {
                ws.select(project)
            })
            for tab in project.tabs {
                list.append(.init(id: "tab-\(tab.id)", title: "Go to Tab: \(ws.title(of: tab)) — \(project.name)", icon: "terminal") {
                    ws.select(tab, in: project)
                })
            }
        }
        return list
    }

    private func move(_ step: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + step + count) % count
    }

    private func run(_ results: [PaletteCommand]) {
        guard results.indices.contains(selection) else { return }
        let cmd = results[selection]
        close()
        // After the palette is gone, so prompts/panels it opens get focus.
        DispatchQueue.main.async { cmd.run() }
    }

    private func close() {
        ws.isPaletteOpen = false
        DispatchQueue.main.async { ws.refocusTerminal() }
    }
}
