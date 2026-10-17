import AppKit
import Observation

@Observable final class Tab: Identifiable {
    let id = UUID()
    var root: SplitNode
    var focusedPane: UUID
    /// User-chosen name; overrides the title the shell sets.
    var customTitle: String?

    init(pane: UUID) {
        root = .leaf(pane)
        focusedPane = pane
    }
}

@Observable final class Project: Identifiable {
    let id = UUID()
    var name: String
    var directory: String
    var tabs: [Tab] = []
    var selectedTabID: UUID?
    var isExpanded = true

    init(name: String, directory: String) {
        self.name = name
        self.directory = directory
    }

    var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } ?? tabs.first }
}

/// All projects, tabs and live terminals. Main-thread only.
@Observable final class Workspace {
    static let shared = Workspace()

    var projects: [Project] = []
    var selectedProjectID: UUID?
    var titles: [UUID: String] = [:]
    var pwds: [UUID: String] = [:]
    /// Rename prompt currently showing, if any.
    var renaming: RenameRequest?
    var isPaletteOpen = false
    /// Live terminals by pane ID. Hidden tabs keep theirs so switching is instant.
    @ObservationIgnored private(set) var surfaces: [UUID: SurfaceView] = [:]

    var selectedProject: Project? { projects.first { $0.id == selectedProjectID } ?? projects.first }
    var selectedTab: Tab? { selectedProject?.selectedTab }

    private init() {
        load()
        if projects.isEmpty {
            projects = [Project(name: "Home", directory: NSHomeDirectory())]
        }
        let restored = selectedProjectID
        for p in projects where p.tabs.isEmpty { newTab(in: p) }
        selectedProjectID = restored ?? projects.first?.id
    }

    func title(of tab: Tab) -> String {
        tab.customTitle ?? titles[tab.focusedPane] ?? "Terminal"
    }

    // MARK: Renaming

    func startRename(_ project: Project) {
        renaming = RenameRequest(title: "Rename Project", current: project.name) { [weak self] name in
            guard !name.isEmpty else { return }
            project.name = name
            self?.save()
        }
    }

    /// An empty name resets the tab to follow the shell's title.
    func startRename(_ tab: Tab) {
        renaming = RenameRequest(title: "Rename Tab", current: title(of: tab)) { [weak self] name in
            tab.customTitle = name.isEmpty ? nil : name
            self?.save()
        }
    }

    /// Returns keyboard focus to the active terminal (after the palette or a prompt closes).
    func refocusTerminal() {
        guard let t = selectedTab, let view = surfaces[t.focusedPane], let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    // MARK: Projects

    func newProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Create Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let project = Project(name: url.lastPathComponent, directory: url.path)
        projects.append(project)
        newTab(in: project)
    }

    func select(_ project: Project) {
        selectedProjectID = project.id
    }

    func cycleProject(_ step: Int) {
        guard let current = selectedProject, let i = projects.firstIndex(where: { $0 === current }) else { return }
        select(projects[((i + step) % projects.count + projects.count) % projects.count])
    }

    func close(_ project: Project) {
        let panes = project.tabs.flatMap(\.root.leaves)
        guard confirmIfRunning(panes) else { return }
        projects.removeAll { $0 === project }
        panes.forEach(dropPane)
        if projects.isEmpty {
            let home = Project(name: "Home", directory: NSHomeDirectory())
            projects = [home]
            newTab(in: home)
        }
        if selectedProjectID == project.id { selectedProjectID = projects.first?.id }
        save()
    }

    // MARK: Tabs

    func newTab(in project: Project? = nil) {
        guard let project = project ?? selectedProject else { return }
        let tab = Tab(pane: makePane(directory: project.directory))
        if let i = project.tabs.firstIndex(where: { $0.id == project.selectedTabID }) {
            project.tabs.insert(tab, at: i + 1)
        } else {
            project.tabs.append(tab)
        }
        select(tab, in: project)
        save()
    }

    func select(_ tab: Tab, in project: Project) {
        project.selectedTabID = tab.id
        selectedProjectID = project.id
    }

    func selectTab(at index: Int) {
        guard let p = selectedProject, !p.tabs.isEmpty else { return }
        select(p.tabs[min(index, p.tabs.count - 1)], in: p)
    }

    func cycleTab(_ step: Int) {
        guard let p = selectedProject, let t = p.selectedTab, let i = p.tabs.firstIndex(where: { $0 === t }) else { return }
        select(p.tabs[((i + step) % p.tabs.count + p.tabs.count) % p.tabs.count], in: p)
    }

    func close(_ tab: Tab, in project: Project) {
        guard confirmIfRunning(tab.root.leaves) else { return }
        removeTab(tab, from: project)
    }

    func closeTab(containing pane: UUID) {
        guard let (p, t) = locate(pane) else { return }
        close(t, in: p)
    }

    func closeSelectedTab() {
        guard let p = selectedProject, let t = p.selectedTab else { return }
        close(t, in: p)
    }

    private func removeTab(_ tab: Tab, from project: Project) {
        guard let i = project.tabs.firstIndex(where: { $0 === tab }) else { return }
        project.tabs.remove(at: i)
        tab.root.leaves.forEach(dropPane)
        if project.selectedTabID == tab.id {
            project.selectedTabID = project.tabs.isEmpty ? nil : project.tabs[max(i - 1, 0)].id
        }
        save()
    }

    // MARK: Panes

    func split(_ pane: UUID, axis: SplitAxis) {
        guard let (p, t) = locate(pane) else { return }
        let new = makePane(directory: pwds[pane] ?? p.directory)
        t.root = t.root.inserting(new, beside: pane, axis: axis)
        t.focusedPane = new
        save()
    }

    func splitFocused(_ axis: SplitAxis) {
        guard let t = selectedTab else { return }
        split(t.focusedPane, axis: axis)
    }

    func cycleFocus(_ step: Int) {
        guard let t = selectedTab, let next = t.root.leaf(step, from: t.focusedPane) else { return }
        t.focusedPane = next
    }

    func paneDidFocus(_ pane: UUID) {
        guard let (_, t) = locate(pane), t.focusedPane != pane else { return }
        t.focusedPane = pane
    }

    /// ghostty asks to close a surface (⌘W or the shell exited).
    func closePane(_ pane: UUID, confirm: Bool) {
        guard let (p, t) = locate(pane) else { return }
        if confirm && !confirmIfRunning([pane]) { return }
        guard let root = t.root.removing(pane) else { return removeTab(t, from: p) }
        if t.focusedPane == pane { t.focusedPane = t.root.leaf(-1, from: pane) ?? root.leaves[0] }
        t.root = root
        dropPane(pane)
        save()
    }

    func closeFocusedPane() {
        guard let t = selectedTab else { return }
        closePane(t.focusedPane, confirm: surfaces[t.focusedPane]?.needsConfirmQuit ?? false)
    }

    private func makePane(directory: String) -> UUID {
        let id = UUID()
        surfaces[id] = SurfaceView(paneID: id, workingDirectory: directory)
        return id
    }

    /// Releases the view; ghostty_surface_free runs in its deinit once SwiftUI lets go of it.
    private func dropPane(_ pane: UUID) {
        surfaces[pane] = nil
        titles[pane] = nil
        pwds[pane] = nil
    }

    private func locate(_ pane: UUID) -> (Project, Tab)? {
        for p in projects {
            if let t = p.tabs.first(where: { $0.root.leaves.contains(pane) }) { return (p, t) }
        }
        return nil
    }

    private func confirmIfRunning(_ panes: [UUID]) -> Bool {
        guard panes.contains(where: { surfaces[$0]?.needsConfirmQuit ?? false }) else { return true }
        let alert = NSAlert()
        alert.messageText = "Close terminal?"
        alert.informativeText = "A process is still running. Closing will terminate it."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: Persistence

    /// User setting: reopen tabs, splits and pane folders on launch. Projects are always kept.
    static let restoreSessionKey = "restoreSession"
    private var restoreSession: Bool { UserDefaults.standard.object(forKey: Self.restoreSessionKey) as? Bool ?? true }

    // Running processes and scrollback can't survive a quit; each pane restarts a shell in its last folder.
    private struct Saved: Codable {
        var name: String
        var directory: String
        var expanded: Bool
        var selected: Bool?
        var selectedTab: Int?
        var tabs: [SavedTab]?
        // Pre-layout format, still read so older files keep their tabs.
        var tabCount: Int?
        var tabTitles: [String?]?
    }

    private struct SavedTab: Codable {
        var title: String?
        var layout: SavedLayout
    }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plantty", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("projects.json")
    }

    func save() {
        let saved = projects.map { p in
            Saved(name: p.name, directory: p.directory, expanded: p.isExpanded,
                  selected: p === selectedProject,
                  selectedTab: p.tabs.firstIndex { $0 === p.selectedTab },
                  tabs: p.tabs.map { SavedTab(title: $0.customTitle, layout: $0.root.saved { self.pwds[$0] ?? p.directory }) })
        }
        try? JSONEncoder().encode(saved).write(to: Self.fileURL, options: .atomic)
    }

    private static func existing(_ path: String) -> String? {
        FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        guard let saved = try? JSONDecoder().decode([Saved].self, from: data) else {
            // Keep an unreadable file (older build, hand edit) instead of overwriting it with a fresh "Home".
            let bad = Self.fileURL.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: Self.fileURL, to: bad)
            return
        }
        for s in saved {
            // A project folder deleted since last launch falls back to home rather than failing to spawn.
            let dir = Self.existing(s.directory) ?? NSHomeDirectory()
            let p = Project(name: s.name, directory: dir)
            p.isExpanded = s.expanded
            projects.append(p)
            if s.selected == true { selectedProjectID = p.id }
            guard restoreSession else { continue }

            let tabs = s.tabs ?? (0..<(s.tabCount ?? 1)).map { i in
                SavedTab(title: s.tabTitles?[safe: i] ?? nil, layout: .pane(directory: dir))
            }
            for saved in tabs {
                let root = SplitNode(saved: saved.layout) { self.makePane(directory: Self.existing($0) ?? dir) }
                let tab = Tab(pane: root.leaves[0])
                tab.root = root
                tab.customTitle = saved.title
                p.tabs.append(tab)
            }
            p.selectedTabID = p.tabs[safe: s.selectedTab ?? 0]?.id ?? p.tabs.first?.id
        }
    }
}

struct RenameRequest: Identifiable {
    let id = UUID()
    let title: String
    let current: String
    let apply: (String) -> Void
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
