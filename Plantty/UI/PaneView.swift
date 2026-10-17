import AppKit
import SwiftUI

/// Hosts an existing SurfaceView. The surface outlives this view (hidden tabs keep their terminals).
/// During layout changes SwiftUI briefly keeps the old host alive next to the new one, so only the
/// most recently created host for a pane (`surface.owner`) may hold it.
struct PaneView: NSViewRepresentable {
    let pane: UUID
    let focused: Bool

    func makeNSView(context: Context) -> PaneHost { PaneHost() }

    func updateNSView(_ host: PaneHost, context: Context) {
        guard let surface = Workspace.shared.surfaces[pane] else { return }
        if host.pane != pane {
            host.pane = pane
            surface.owner = host
        }
        if surface.owner === host { host.attach(surface) }
        host.wantsFocus = focused
        host.focusIfNeeded()
    }

    static func dismantleNSView(_ host: PaneHost, coordinator: ()) {
        host.detach()
    }
}

final class PaneHost: NSView {
    var pane: UUID?
    private(set) var surface: SurfaceView?
    var wantsFocus = false

    func attach(_ view: SurfaceView) {
        guard view.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        surface = view
    }

    func detach() {
        guard let surface, surface.owner === self else { return }
        surface.removeFromSuperview()
        surface.owner = nil
        self.surface = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfNeeded()
    }

    func focusIfNeeded() {
        guard wantsFocus else { return }
        // Deferred: SwiftUI may still be mid-update and the window may not be attached yet.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsFocus, let surface = self.surface, surface.owner === self,
                  let window = surface.window, window.firstResponder !== surface else { return }
            window.makeFirstResponder(surface)
        }
    }
}
