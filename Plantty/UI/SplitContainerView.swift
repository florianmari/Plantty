import SwiftUI

struct SplitContainerView: View {
    let node: SplitNode
    let tab: Tab

    var body: some View {
        switch node {
        case .leaf(let id):
            PaneView(pane: id, focused: tab.focusedPane == id)
                .overlay {
                    // Dim unfocused panes so the active one is obvious.
                    if tab.focusedPane != id {
                        Color.black.opacity(0.18).allowsHitTesting(false)
                    }
                }
        case .split(let id, let axis, let ratio, let first, let second):
            GeometryReader { geo in
                let horizontal = axis == .horizontal
                let total = horizontal ? geo.size.width : geo.size.height
                let firstLength = max(0, (total - SplitDivider.thickness) * ratio)
                let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    SplitContainerView(node: first, tab: tab)
                        .frame(width: horizontal ? firstLength : nil, height: horizontal ? nil : firstLength)
                    SplitDivider(axis: axis, space: id) { location in
                        let pos = horizontal ? location.x : location.y
                        tab.root = tab.root.settingRatio(pos / max(total - SplitDivider.thickness, 1), of: id)
                    }
                    SplitContainerView(node: second, tab: tab)
                }
                .coordinateSpace(.named(id))
            }
        }
    }
}

private struct SplitDivider: View {
    static let thickness: CGFloat = 5
    let axis: SplitAxis
    let space: UUID
    let onDrag: (CGPoint) -> Void

    var body: some View {
        let horizontal = axis == .horizontal
        ZStack {
            Theme.background
            Rectangle()
                .fill(Theme.separator)
                .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
        }
        .frame(width: horizontal ? Self.thickness : nil, height: horizontal ? nil : Self.thickness)
        .contentShape(Rectangle())
        .pointerStyle(horizontal ? .columnResize : .rowResize)
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(space)).onChanged { onDrag($0.location) })
    }
}
