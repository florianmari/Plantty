import Foundation

enum SplitAxis: Equatable {
    /// Children side by side (split right).
    case horizontal
    /// Children stacked (split down).
    case vertical
}

/// Layout tree of one tab. Leaves are pane IDs; the views live in `Workspace.surfaces`.
indirect enum SplitNode: Equatable {
    case leaf(UUID)
    case split(id: UUID, axis: SplitAxis, ratio: Double, first: SplitNode, second: SplitNode)

    /// Pane IDs in reading order (left→right, top→bottom).
    var leaves: [UUID] {
        switch self {
        case .leaf(let id): [id]
        case .split(_, _, _, let a, let b): a.leaves + b.leaves
        }
    }

    /// Replaces leaf `target` with a split holding `target` then `new`.
    func inserting(_ new: UUID, beside target: UUID, axis: SplitAxis) -> SplitNode {
        switch self {
        case .leaf(let id):
            guard id == target else { return self }
            return .split(id: UUID(), axis: axis, ratio: 0.5, first: .leaf(id), second: .leaf(new))
        case .split(let id, let ax, let r, let a, let b):
            return .split(id: id, axis: ax, ratio: r,
                          first: a.inserting(new, beside: target, axis: axis),
                          second: b.inserting(new, beside: target, axis: axis))
        }
    }

    /// Removes a leaf; a split left with one child collapses into that child. Nil when nothing remains.
    func removing(_ target: UUID) -> SplitNode? {
        switch self {
        case .leaf(let id):
            return id == target ? nil : self
        case .split(let id, let ax, let r, let a, let b):
            switch (a.removing(target), b.removing(target)) {
            case (nil, nil): return nil
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (let x?, let y?): return .split(id: id, axis: ax, ratio: r, first: x, second: y)
            }
        }
    }

    func settingRatio(_ ratio: Double, of splitID: UUID) -> SplitNode {
        switch self {
        case .leaf: return self
        case .split(let id, let ax, let r, let a, let b):
            return .split(id: id, axis: ax, ratio: id == splitID ? min(max(ratio, 0.1), 0.9) : r,
                          first: a.settingRatio(ratio, of: splitID),
                          second: b.settingRatio(ratio, of: splitID))
        }
    }

    /// The leaf `offset` steps from `id` in reading order, wrapping around.
    func leaf(_ offset: Int, from id: UUID) -> UUID? {
        let all = leaves
        guard let i = all.firstIndex(of: id) else { return all.first }
        return all[((i + offset) % all.count + all.count) % all.count]
    }
}

/// On-disk form of a tab's layout: each pane is just the folder its shell reopens in.
indirect enum SavedLayout: Codable, Equatable {
    case pane(directory: String)
    case split(horizontal: Bool, ratio: Double, first: SavedLayout, second: SavedLayout)
}

extension SplitNode {
    func saved(directory: (UUID) -> String) -> SavedLayout {
        switch self {
        case .leaf(let id):
            return .pane(directory: directory(id))
        case .split(_, let axis, let ratio, let a, let b):
            return .split(horizontal: axis == .horizontal, ratio: ratio,
                          first: a.saved(directory: directory), second: b.saved(directory: directory))
        }
    }

    /// Rebuilds a layout, creating a pane per saved folder via `makePane`.
    init(saved: SavedLayout, makePane: (String) -> UUID) {
        switch saved {
        case .pane(let dir):
            self = .leaf(makePane(dir))
        case .split(let horizontal, let ratio, let a, let b):
            self = .split(id: UUID(), axis: horizontal ? .horizontal : .vertical, ratio: min(max(ratio, 0.1), 0.9),
                          first: SplitNode(saved: a, makePane: makePane), second: SplitNode(saved: b, makePane: makePane))
        }
    }
}
