import SwiftUI

/// Horizontal mode: project dropdown on the left, the selected project's tabs as pills.
struct TabBarView: View {
    @Environment(Workspace.self) private var ws
    @AppStorage("tabStyle") private var tabStyle = TabStyle.vertical

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 76) // traffic lights

            projectMenu

            Theme.separator.frame(width: 1, height: 16)

            if let project = ws.selectedProject {
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(project.tabs) { tab in
                            TabPill(tab: tab, project: project)
                        }
                    }
                }
                .scrollIndicators(.never)
                .fixedSize(horizontal: false, vertical: true)
            }

            ChromeButton(systemImage: "plus", help: "New Tab") { ws.newTab() }

            Spacer(minLength: 0)

            UsageChips()

            ChromeButton(systemImage: "sidebar.left", help: "Use Vertical Tabs") { tabStyle = .vertical }
        }
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(Theme.chrome.gesture(WindowDragGesture()))
    }

    private var projectMenu: some View {
        Menu {
            ForEach(ws.projects) { project in
                Button {
                    ws.select(project)
                } label: {
                    if ws.selectedProject === project {
                        Label(project.name, systemImage: "checkmark")
                    } else {
                        Text(project.name)
                    }
                }
            }
            Divider()
            Button("New Project…") { ws.newProject() }
            if let project = ws.selectedProject {
                Divider()
                ProjectMenuItems(project: project)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                Text(ws.selectedProject?.name ?? "Projects").fontWeight(.semibold)
            }
            .font(.system(size: 12))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Switch Project")
    }
}

private struct TabPill: View {
    @Environment(Workspace.self) private var ws
    let tab: Tab
    let project: Project
    @State private var hovering = false

    var body: some View {
        let isSelected = project.selectedTab === tab
        HStack(spacing: 4) {
            Text(ws.title(of: tab))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: 180)
            ChromeButton(systemImage: "xmark", help: "Close Tab") { ws.close(tab, in: project) }
                .scaleEffect(0.85)
                .opacity(hovering || isSelected ? 1 : 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 28)
        .background(isSelected ? Theme.selected : hovering ? Theme.hover : .clear, in: .rect(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { ws.select(tab, in: project) }
        .contextMenu { TabMenuItems(tab: tab, project: project) }
    }
}
