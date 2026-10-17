import AppKit
import GhosttyKit

/// Mods helpers, ported from ghostty's Ghostty.Input.swift (MIT, Mitchell Hashimoto, Ghostty contributors).
enum Ghostty {
    static func eventModifierFlags(mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags(rawValue: 0)
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }
}

/// Owns the single libghostty app instance and routes its runtime callbacks into `Workspace`.
final class GhosttyApp {
    static let shared = GhosttyApp()

    let app: ghostty_app_t
    let config: ghostty_config_t

    private init() {
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == 0 else {
            fatalError("ghostty_init failed")
        }

        // Same files Ghostty.app reads: ~/.config/ghostty/config and friends.
        config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: false,
            wakeup_cb: { _ in DispatchQueue.main.async { ghostty_app_tick(GhosttyApp.shared.app) } },
            action_cb: { _, target, action in GhosttyApp.handle(target, action) },
            read_clipboard_cb: { ud, loc, state, mimes, count, _ in
                GhosttyApp.readClipboard(ud, loc, state, mimes, count)
            },
            confirm_read_clipboard_cb: { ud, confirm, state, request in
                GhosttyApp.confirmPaste(ud, confirm, state, request)
            },
            write_clipboard_cb: { _, loc, content, len, confirm in
                // shortcut: writes needing confirmation (OSC 52) are dropped, add a prompt if wanted.
                guard loc == GHOSTTY_CLIPBOARD_STANDARD, !confirm, let content else { return }
                for i in 0..<len where String(cString: content[i].mime) == "text/plain" {
                    let data = Data(bytes: content[i].data, count: content[i].len)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
                }
            },
            close_surface_cb: { ud, processAlive in
                guard let view = SurfaceView.from(userdata: ud) else { return }
                onMain { Workspace.shared.closePane(view.paneID, confirm: processAlive) }
            }
        )
        guard let app = ghostty_app_new(&runtime, config) else { fatalError("ghostty_app_new failed") }
        self.app = app

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            ghostty_app_set_focus(app, true)
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            ghostty_app_set_focus(app, false)
        }
        nc.addObserver(forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main) { _ in
            ghostty_app_keyboard_changed(app)
        }
    }

    /// Terminal background from the user's config, used to theme the chrome.
    var backgroundColor: NSColor {
        var c = ghostty_config_color_s()
        let key = "background"
        guard ghostty_config_get(config, &c, key, UInt(key.utf8.count)) else { return .black }
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    /// `background-opacity` from the user's config (1 = opaque).
    var backgroundOpacity: Double {
        var v = 1.0
        let key = "background-opacity"
        _ = ghostty_config_get(config, &v, key, UInt(key.utf8.count))
        return min(max(v, 0), 1)
    }

    // MARK: Callbacks

    private static func handle(_ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
        let view = target.tag == GHOSTTY_TARGET_SURFACE ? SurfaceView.from(surface: target.target.surface) : nil
        let id = view?.paneID

        switch action.tag {
        case GHOSTTY_ACTION_NEW_TAB, GHOSTTY_ACTION_NEW_WINDOW:
            onMain { Workspace.shared.newTab() }
        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let id else { return false }
            let axis: SplitAxis = switch action.action.new_split {
            case GHOSTTY_SPLIT_DIRECTION_DOWN, GHOSTTY_SPLIT_DIRECTION_UP: .vertical
            default: .horizontal
            }
            onMain { Workspace.shared.split(id, axis: axis) }
        case GHOSTTY_ACTION_CLOSE_TAB:
            // close_tab:other / :right aren't supported; never close the current tab for them.
            guard let id, action.action.close_tab_mode == GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS else { return false }
            onMain { Workspace.shared.closeTab(containing: id) }
        case GHOSTTY_ACTION_GOTO_TAB:
            let raw = Int(action.action.goto_tab.rawValue)
            onMain {
                let ws = Workspace.shared
                switch raw {
                case Int(GHOSTTY_GOTO_TAB_PREVIOUS.rawValue): ws.cycleTab(-1)
                case Int(GHOSTTY_GOTO_TAB_NEXT.rawValue): ws.cycleTab(1)
                case Int(GHOSTTY_GOTO_TAB_LAST.rawValue): ws.selectTab(at: Int.max)
                default: ws.selectTab(at: raw - 1)
                }
            }
        case GHOSTTY_ACTION_GOTO_SPLIT:
            // shortcut: directional moves map to reading order, add geometry-based lookup if it feels wrong.
            let step = switch action.action.goto_split {
            case GHOSTTY_GOTO_SPLIT_PREVIOUS, GHOSTTY_GOTO_SPLIT_LEFT, GHOSTTY_GOTO_SPLIT_UP: -1
            default: 1
            }
            onMain { Workspace.shared.cycleFocus(step) }
        case GHOSTTY_ACTION_SET_TITLE:
            guard let id, let p = action.action.set_title.title else { return false }
            let title = String(cString: p)
            onMain { Workspace.shared.titles[id] = title }
        case GHOSTTY_ACTION_PWD:
            guard let id, let p = action.action.pwd.pwd else { return false }
            let pwd = String(cString: p)
            onMain { Workspace.shared.pwds[id] = pwd }
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = action.action.mouse_shape
            onMain { view?.setCursor(shape) }
        case GHOSTTY_ACTION_CELL_SIZE:
            let size = action.action.cell_size
            onMain { view?.setCellSize(pixels: CGSize(width: Double(size.width), height: Double(size.height))) }
        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let p = u.url else { return false }
            let str = String(decoding: Data(bytes: p, count: Int(u.len)), as: UTF8.self)
            guard let url = URL(string: str) else { return false }
            onMain { NSWorkspace.shared.open(url) }
        case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
            // ghostty binds ⌘⇧P to this by default, so it arrives here when a terminal has focus.
            onMain { Workspace.shared.isPaletteOpen.toggle() }
        case GHOSTTY_ACTION_RING_BELL:
            onMain { NSSound.beep() }
        case GHOSTTY_ACTION_QUIT:
            onMain { NSApp.terminate(nil) }
        default:
            return false
        }
        return true
    }

    private static func readClipboard(
        _ ud: UnsafeMutableRawPointer?,
        _ loc: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?,
        _ mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        _ count: Int
    ) -> ghostty_clipboard_read_result_e {
        guard loc == GHOSTTY_CLIPBOARD_STANDARD, let surface = SurfaceView.from(userdata: ud)?.surface else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }
        let wantsText = (0..<count).contains { i in mimes?[i].map { String(cString: $0) } == "text/plain" }
        guard wantsText, let text = pasteText(NSPasteboard.general) else {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }
        // shortcut: only text/plain is served; images become a temp-file path (see pasteText).
        complete(surface, text: text, state: state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Ghostty's paste protection asks before pasting text that could run commands on its own
    /// (e.g. line breaks without bracketed paste).
    private static func confirmPaste(
        _ ud: UnsafeMutableRawPointer?,
        _ confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        _ state: UnsafeMutableRawPointer?,
        _ request: ghostty_clipboard_request_e
    ) {
        guard let view = SurfaceView.from(userdata: ud), let surface = view.surface else { return }
        let c = confirm?.pointee
        let text = (0..<(c?.contents_len ?? 0)).lazy.compactMap { i -> String? in
            guard let item = c?.contents?[i], String(cString: item.mime) == "text/plain" else { return nil }
            return String(decoding: Data(bytes: item.data, count: item.len), as: UTF8.self)
        }.first
        // shortcut: OSC 52 / kitty clipboard reads that need confirmation are still denied.
        guard request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let text else {
            return ghostty_surface_deny_clipboard_request(surface, state)
        }

        onMain {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            var preview = lines.prefix(8).joined(separator: "\n")
            if preview.count > 600 { preview = String(preview.prefix(600)) + "…" }
            if lines.count > 8 { preview += "\n… (\(lines.count) lines)" }

            let alert = NSAlert()
            alert.messageText = "Paste text that may run commands?"
            alert.informativeText = "The text has line breaks, so the shell may run it as soon as it's pasted.\n\n" + preview
            alert.addButton(withTitle: "Paste")
            alert.addButton(withTitle: "Cancel")
            let ok = alert.runModal() == .alertFirstButtonReturn
            // The surface may have closed while the prompt was up.
            guard let surface = view.surface else { return }
            if ok {
                complete(surface, text: text, state: state, confirmed: true)
            } else {
                ghostty_surface_deny_clipboard_request(surface, state)
            }
            view.window?.makeFirstResponder(view)
        }
    }

    private static func complete(_ surface: ghostty_surface_t, text: String, state: UnsafeMutableRawPointer?, confirmed: Bool) {
        let mime = strdup("text/plain")!
        defer { free(mime) }
        text.withCString { ptr in
            var content = ghostty_clipboard_content_s(mime: mime, data: ptr, len: strlen(ptr))
            withUnsafePointer(to: &content) { c in
                var complete = ghostty_clipboard_complete_s(
                    contents: c, contents_len: 1, available: nil, available_len: 0,
                    confirmed: confirmed, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &complete, state)
            }
        }
    }

    /// Text to paste: copied files paste as shell-escaped paths, and a bare image
    /// (e.g. a screenshot copied with ⌃⇧⌘4) is saved as a temp PNG whose path is pasted,
    /// so CLIs like Claude Code can pick it up.
    static func pasteText(_ pb: NSPasteboard) -> String? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { shellEscape($0.path) }.joined(separator: " ")
        }
        if let text = pb.string(forType: .string) { return text }
        guard let image = NSImage(pasteboard: pb),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plantty-paste-\(stamp).png")
        do { try png.write(to: url) } catch { return nil }
        return shellEscape(url.path)
    }

    static func shellEscape(_ path: String) -> String {
        let special = Set(" \\'\"`$&*()[]{}<>|;?!#~")
        return String(path.flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }
}

/// libghostty may call back off the main thread, or re-entrantly while a surface is
/// being created inside Workspace.init, so model changes are always deferred to the next main-loop turn.
func onMain(_ work: @escaping () -> Void) {
    DispatchQueue.main.async(execute: work)
}
