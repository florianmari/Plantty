// Input handling ported from ghostty-org/ghostty (macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift).
// MIT License, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors.

import AppKit
import Carbon
import GhosttyKit

/// One terminal: an NSView that libghostty renders into (it installs its own IOSurface layer).
final class SurfaceView: NSView, NSTextInputClient {
    let paneID: UUID
    private(set) var surface: ghostty_surface_t?
    private(set) var cellSize: CGSize = .zero
    /// The PaneHost currently allowed to display this surface (see PaneView).
    weak var owner: PaneHost?

    private var markedText = NSMutableAttributedString()
    /// Non-nil while inside keyDown: collects text committed by interpretKeyEvents.
    private var keyTextAccumulator: [String]?
    /// See ghostty's SurfaceView_AppKit.performKeyEquivalent for why this exists.
    private var lastPerformKeyEvent: TimeInterval?
    private var cursor: NSCursor = .iBeam

    init(paneID: UUID, workingDirectory: String?) {
        self.paneID = paneID
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        cfg.context = GHOSTTY_SURFACE_CONTEXT_TAB
        surface = (workingDirectory ?? NSHomeDirectory()).withCString { dir in
            cfg.working_directory = dir
            return ghostty_surface_new(GhosttyApp.shared.app, &cfg)
        }
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    static func from(userdata: UnsafeMutableRawPointer?) -> SurfaceView? {
        userdata.map { Unmanaged<SurfaceView>.fromOpaque($0).takeUnretainedValue() }
    }

    static func from(surface: ghostty_surface_t?) -> SurfaceView? {
        surface.flatMap { from(userdata: ghostty_surface_userdata($0)) }
    }

    var needsConfirmQuit: Bool { surface.map { ghostty_surface_needs_confirm_quit($0) } ?? false }

    func setCellSize(pixels: CGSize) {
        cellSize = convertFromBacking(pixels)
    }

    func setCursor(_ shape: ghostty_action_mouse_shape_e) {
        cursor = switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: .arrow
        case GHOSTTY_MOUSE_SHAPE_POINTER: .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: .resizeUpDown
        default: .iBeam
        }
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - View lifecycle

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let surface {
            ghostty_surface_set_focus(surface, true)
            Workspace.shared.paneDidFocus(paneID)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Hidden tabs are detached from the window; stop rendering them.
        if let surface { ghostty_surface_set_occlusion(surface, window != nil) }
        if window != nil { viewDidChangeBackingProperties() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let fb = convertToBacking(frame)
        ghostty_surface_set_content_scale(surface, fb.width / frame.width, fb.height / frame.height)
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let px = convertToBacking(bounds.size)
        ghostty_surface_set_size(surface, UInt32(max(px.width, 1)), UInt32(max(px.height, 1)))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: frame,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }

    override func mouseUp(with event: NSEvent) {
        sendButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
        if let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
    }

    override func rightMouseDown(with event: NSEvent) {
        if !sendButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !sendButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        sendButton(GHOSTTY_MOUSE_PRESS, otherButton(event), event)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendButton(GHOSTTY_MOUSE_RELEASE, otherButton(event), event)
    }

    @discardableResult
    private func sendButton(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, Ghostty.ghosttyMods(event.modifierFlags))
    }

    private func otherButton(_ event: NSEvent) -> ghostty_input_mouse_button_e {
        switch event.buttonNumber {
        case 2: GHOSTTY_MOUSE_MIDDLE
        case 3: GHOSTTY_MOUSE_FOUR
        case 4: GHOSTTY_MOUSE_FIVE
        default: GHOSTTY_MOUSE_UNKNOWN
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y, Ghostty.ghosttyMods(event.modifierFlags))
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        // Negative position tells ghostty the cursor left the viewport.
        ghostty_surface_mouse_pos(surface, -1, -1, Ghostty.ghosttyMods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX, y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise { x *= 2; y *= 2 }
        // Packed scroll mods: bit 0 = precision, bits 1-3 = momentum phase.
        var mods: Int32 = precise ? 1 : 0
        let momentum: ghostty_input_mouse_momentum_e = switch event.momentumPhase {
        case .began: GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .stationary: GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        case .changed: GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        default: GHOSTTY_MOUSE_MOMENTUM_NONE
        }
        mods |= Int32(momentum.rawValue) << 1
        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else { interpretKeyEvents([event]); return }

        // Apply option-as-alt etc. from config to the event used for text translation.
        let translationGhostty = Ghostty.eventModifierFlags(
            mods: ghostty_surface_key_translation_mods(surface, Ghostty.ghosttyMods(event.modifierFlags)))
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationGhostty.contains(flag) { translationMods.insert(flag) } else { translationMods.remove(flag) }
        }
        // Must reuse the original event when unchanged, or Korean input breaks.
        let translationEvent: NSEvent = translationMods == event.modifierFlags ? event : NSEvent.keyEvent(
            with: event.type, location: event.locationInWindow, modifierFlags: translationMods,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: event.characters(byApplyingModifiers: translationMods) ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let markedTextBefore = markedText.length > 0
        let keyboardBefore = markedTextBefore ? nil : Self.keyboardLayoutID
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // An input-source switch shortcut was consumed by the system.
        if !markedTextBefore && keyboardBefore != Self.keyboardLayoutID { return }

        syncPreedit(clearIfNeeded: markedTextBefore)
        let composing = markedText.length > 0 || markedTextBefore

        if let list = keyTextAccumulator, !list.isEmpty {
            for text in list where !Self.isComposingControl(text, composing: composing) {
                if markedTextBefore {
                    committedText(action, text)
                } else {
                    keyAction(action, event: event, translationEvent: translationEvent, text: text)
                }
            }
        } else {
            if Self.isComposingControl(event.characters, composing: composing) { return }
            keyAction(action, event: event, translationEvent: translationEvent,
                      text: translationEvent.ghosttyCharacters, composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, let surface else { return false }

        // Ghostty keybinds (⌘T, ⌘D, ⌘V…) win over the menu; they come back via action_cb.
        var flags = ghostty_binding_flags_e(0)
        var keyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
        let isBinding = (event.characters ?? "").withCString { ptr in
            keyEvent.text = ptr
            return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            // C-/ beeps in AppKit; send C-_ like ghostty does.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let final = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) else { return false }
        keyDown(with: final)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch event.keyCode {
        case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
        case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
        case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
        case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
        case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }

        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        var action = GHOSTTY_ACTION_RELEASE
        if mods.rawValue & mod != 0 {
            let raw = event.modifierFlags.rawValue
            let sidePressed = switch event.keyCode {
            case 0x3C: raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case 0x3E: raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case 0x3D: raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case 0x36: raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        keyAction(action, event: event)
    }

    @discardableResult
    private func keyAction(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var ev = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
        ev.composing = composing
        // Control characters are encoded by ghostty itself from the physical key.
        if let text, !text.isEmpty, let first = text.unicodeScalars.first, first.value >= 0x20, first.value != 0x7F {
            return text.withCString { ptr in
                ev.text = ptr
                return ghostty_surface_key(surface, ev)
            }
        }
        return ghostty_surface_key(surface, ev)
    }

    /// Text committed by an IME, sent as typed input (never as a paste).
    private func committedText(_ action: ghostty_input_action_e, _ text: String) {
        guard let surface else { return }
        var ev = ghostty_input_key_s()
        ev.action = action
        ev.mods = GHOSTTY_MODS_NONE
        ev.consumed_mods = GHOSTTY_MODS_NONE
        text.withCString { ptr in
            ev.text = ptr
            _ = ghostty_surface_key(surface, ev)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let str = markedText.string
            str.withCString { ghostty_surface_preedit(surface, $0, UInt(str.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    /// A lone C0 control char arriving mid-composition belongs to the IME, not the terminal.
    private static func isComposingControl(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1, let s = text.unicodeScalars.first else { return false }
        return s.value < 0x20
    }

    private static var keyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return unsafeBitCast(ptr, to: CFString.self) as String
    }

    // MARK: - Edit menu (when no ghostty keybind claims the shortcut)

    @objc func copy(_ sender: Any?) { runAction("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { runAction("paste_from_clipboard") }
    override func selectAll(_ sender: Any?) { runAction("select_all") }

    /// Runs a ghostty keybind action by name, e.g. "copy_to_clipboard".
    func runAction(_ action: String) {
        guard let surface else { return }
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }

    // MARK: - NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = NSMutableAttributedString(attributedString: v)
        case let v as String: markedText = NSMutableAttributedString(string: v)
        default: return
        }
        // Outside keyDown (e.g. layout switch mid dead-key) update preedit right away.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, w = Double(cellSize.width), h = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        if range.length == 0 { w = 0 }
        // Ghostty is top-left origin; AppKit is bottom-left.
        let viewRect = NSRect(x: x, y: frame.height - y, width: w, height: max(h, cellSize.height))
        let winRect = convert(viewRect, to: nil)
        return window?.convertToScreen(winRect) ?? winRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars: String = switch string {
        case let v as NSAttributedString: v.string
        case let v as String: v
        default: ""
        }
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }
        if !chars.isEmpty { committedText(GHOSTTY_ACTION_PRESS, chars) }
    }

    override func doCommand(by selector: Selector) {
        // Re-dispatch command keys that performKeyEquivalent deferred so they get encoded.
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }
}
