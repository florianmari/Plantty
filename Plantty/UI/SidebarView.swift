import SwiftUI

/// Vertical mode: projects as collapsible groups with their tabs nested underneath.
struct SidebarView: View {
    @Environment(Workspace.self) private var ws
    @AppStorage("tabStyle") private var tabStyle = TabStyle.vertical

    var body: some View {
        VStack(spacing: 0) {
            // Room for the traffic lights; doubles as a window drag handle.
            Color.clear
                .contentShape(Rectangle())
                .frame(height: 40)
                .gesture(WindowDragGesture())

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(ws.projects) { project in
                        ProjectRow(project: project)
                        if project.isExpanded {
                            ForEach(project.tabs) { tab in
                                TabRow(tab: tab, project: project)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)

            HStack(spacing: 2) {
                ChromeButton(systemImage: "folder.badge.plus", help: "New Project") { ws.newProject() }
                ChromeButton(systemImage: "plus", help: "New Tab") { ws.newTab() }
                Spacer()
                ChromeButton(systemImage: "rectangle.topthird.inset.filled", help: "Use Horizontal Tabs") {
                    tabStyle = .horizontal
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
        }
        .background(Theme.chrome)
    }
}

private struct ProjectRow: View {
    @Environment(Workspace.self) private var ws
    let project: Project
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button { setExpanded(!project.isExpanded) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(project.isExpanded ? 90 : 0))
                    .frame(width: 16, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -3)
            .accessibilityLabel(project.isExpanded ? "Collapse \(project.name)" : "Expand \(project.name)")
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(ws.selectedProject === project ? Color.accentColor : .secondary)
            Text(project.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if hovering {
                ChromeButton(systemImage: "plus", help: "New Tab in \(project.name)") { ws.newTab(in: project) }
            } else if !project.isExpanded {
                Text("\(project.tabs.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 6)
        .frame(height: 28)
        .background(hovering ? Theme.hover : .clear, in: .rect(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            // Selecting never collapses; only the chevron does.
            ws.select(project)
            if !project.isExpanded { setExpanded(true) }
        }
        .padding(.top, 6)
        .contextMenu { ProjectMenuItems(project: project) }
        .help(project.directory)
    }

    private func setExpanded(_ expanded: Bool) {
        withAnimation(.snappy(duration: 0.18)) { project.isExpanded = expanded }
        ws.save()
    }
}

private struct TabRow: View {
    @Environment(Workspace.self) private var ws
    let tab: Tab
    let project: Project
    @State private var hovering = false

    var body: some View {
        let isSelected = ws.selectedTab === tab
        HStack(spacing: 7) {
            Image(systemName: tab.root.leaves.count > 1 ? "rectangle.split.2x1" : "terminal")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 14)
            Text(ws.title(of: tab))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
            Spacer(minLength: 4)
            if hovering {
                ChromeButton(systemImage: "xmark", help: "Close Tab") { ws.close(tab, in: project) }
            }
        }
        .padding(.leading, 26)
        .padding(.trailing, 2)
        .frame(height: 26)
        .background(isSelected ? Theme.selected : hovering ? Theme.hover : .clear, in: .rect(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { ws.select(tab, in: project) }
        .contextMenu { TabMenuItems(tab: tab, project: project) }
    }
}

struct TabMenuItems: View {
    @Environment(Workspace.self) private var ws
    let tab: Tab
    let project: Project

    var body: some View {
        Button("Rename Tab…") { ws.startRename(tab) }
        if tab.customTitle != nil {
            Button("Reset Name") { tab.customTitle = nil; ws.save() }
        }
        Button("New Tab") { ws.newTab(in: project) }
        Divider()
        Button("Close Tab", role: .destructive) { ws.close(tab, in: project) }
    }
}

struct ProjectMenuItems: View {
    @Environment(Workspace.self) private var ws
    let project: Project

    var body: some View {
        Button("New Tab") { ws.newTab(in: project) }
        Button("Rename…") { ws.startRename(project) }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: project.directory)])
        }
        Divider()
        Button("Close Project", role: .destructive) { ws.close(project) }
    }
}
