import GhosttyKit
import SwiftUI

enum TabStyle: String {
    case vertical, horizontal
}

/// UserDefaults key: vertical sidebar slides away and reappears when the mouse touches the left edge.
let sidebarAutoHideKey = "sidebarAutoHide"

/// Chrome colors derived from the user's ghostty background so the UI blends with the terminal.
enum Theme {
    static let nsBackground = GhosttyApp.shared.backgroundColor
    static let isDark: Bool = {
        guard let c = nsBackground.usingColorSpace(.sRGB) else { return true }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent < 0.5
    }()
    /// Honors `background-opacity`; terminals draw their own translucent background on top of nothing.
    static let opacity = GhosttyApp.shared.backgroundOpacity
    static let isTranslucent = opacity < 1
    static let background = Color(nsColor: nsBackground).opacity(opacity)
    static let chrome = Color(nsColor: nsBackground).mix(with: isDark ? .white : .black, by: 0.04).opacity(opacity)
    static let ink = isDark ? Color.white : Color.black
    static let separator = ink.opacity(0.08)
    static let hover = ink.opacity(0.05)
    static let selected = ink.opacity(0.11)
}

struct ContentView: View {
    @Environment(Workspace.self) private var ws
    @AppStorage("tabStyle") private var tabStyle = TabStyle.vertical
    @AppStorage(sidebarAutoHideKey) private var sidebarAutoHide = false
    @State private var sidebarPeek = false
    @State private var usage = UsageService.shared
    @State private var renameText = ""

    var body: some View {
        @Bindable var ws = ws
        Group {
            switch tabStyle {
            case .vertical where sidebarAutoHide:
                TerminalArea()
                    .overlay(alignment: .leading) { autoHidingSidebar }
            case .vertical:
                HStack(spacing: 0) {
                    SidebarView().frame(width: 232)
                    Theme.background.overlay(Theme.separator).frame(width: 1)
                    TerminalArea()
                }
            case .horizontal:
                VStack(spacing: 0) {
                    TabBarView()
                    Theme.background.overlay(Theme.separator).frame(height: 1)
                    TerminalArea()
                }
            }
        }
        // When translucent, nothing may sit behind the terminals or their opacity would stack.
        .background(Theme.isTranslucent ? Color.clear : Theme.background)
        .background(WindowChrome(hidesTrafficLights: tabStyle == .vertical && sidebarAutoHide && !sidebarPeek))
        .onChange(of: sidebarAutoHide) { sidebarPeek = false }
        .onChange(of: usage.isPanelOpen) { if !usage.isPanelOpen { sidebarPeek = false } }
        .ignoresSafeArea()
        .preferredColorScheme(Theme.isDark ? .dark : .light)
        .overlay(alignment: .top) {
            if ws.isPaletteOpen {
                Color.black.opacity(0.12)
                    .contentShape(Rectangle())
                    .onTapGesture { ws.isPaletteOpen = false; ws.refocusTerminal() }
                CommandPalette()
                    .padding(.top, 56)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.snappy(duration: 0.15), value: ws.isPaletteOpen)
        .alert(ws.renaming?.title ?? "Rename", isPresented: Binding(
            get: { ws.renaming != nil },
            set: { if !$0 { ws.renaming = nil; ws.refocusTerminal() } }
        )) {
            TextField("Name", text: $renameText)
            Button(ws.renaming?.confirm ?? "Rename") { ws.renaming?.apply(renameText.trimmingCharacters(in: .whitespaces)) }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: ws.renaming?.id) { renameText = ws.renaming?.current ?? "" }
    }
}

extension ContentView {
    /// Arc-style: a thin hot edge reveals the sidebar over the terminal; leaving it hides it again.
    private var autoHidingSidebar: some View {
        ZStack(alignment: .leading) {
            Color.clear
                .frame(width: 5)
                .contentShape(Rectangle())
                .onHover { if $0 { sidebarPeek = true } }
            if sidebarPeek {
                SidebarView()
                    .frame(width: 232)
                    .background(Theme.background) // keep terminal text from showing through when translucent
                    .overlay(alignment: .trailing) { Theme.separator.frame(width: 1) }
                    .shadow(color: .black.opacity(0.35), radius: 18, x: 6)
                    // The usage panel is a popover anchored in the sidebar; hiding it would close the panel.
                    .onHover { if !$0, !usage.isPanelOpen { sidebarPeek = false } }
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.snappy(duration: 0.2), value: sidebarPeek)
    }
}

struct TerminalArea: View {
    @Environment(Workspace.self) private var ws

    var body: some View {
        if let tab = ws.selectedTab {
            SplitContainerView(node: tab.root, tab: tab).id(tab.id)
        } else {
            ContentUnavailableView {
                Label("No Tabs", systemImage: "terminal")
            } actions: {
                Button("New Tab") { ws.newTab() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
    }
}

/// Small borderless icon button used across the chrome.
struct ChromeButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 22)
                .background(hovering ? Theme.hover : .clear, in: .rect(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}

/// An empty compact toolbar makes AppKit center the traffic lights in a taller title bar,
/// so the tab bar / sidebar header can be roomier and still line up with them.
struct WindowChrome: NSViewRepresentable {
    /// With an auto-hidden sidebar the traffic lights would sit on top of terminal text.
    var hidesTrafficLights = false

    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ nsView: ChromeView, context: Context) {
        nsView.hidesTrafficLights = hidesTrafficLights
    }

    final class ChromeView: NSView {
        var hidesTrafficLights = false { didSet { applyTrafficLights() } }

        private func applyTrafficLights() {
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window?.standardWindowButton(kind)?.isHidden = hidesTrafficLights
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The first SwiftUI update can arrive before this view has a window.
            applyTrafficLights()
            guard let window, window.toolbar == nil else { return }
            let toolbar = NSToolbar(identifier: "plantty")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unifiedCompact
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            if Theme.isTranslucent {
                window.isOpaque = false
                // Near-clear rather than clear keeps the window shadow and clicks on empty areas.
                window.backgroundColor = .white.withAlphaComponent(0.001)
                // Applies `background-blur` from the config (no-op when it's off).
                ghostty_set_window_background_blur(GhosttyApp.shared.app, Unmanaged.passUnretained(window).toOpaque())
            }
        }
    }
}
