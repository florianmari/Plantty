import XCTest

final class SplitNodeTests: XCTestCase {
    let a = UUID(), b = UUID(), c = UUID()

    func testInsertAndOrder() {
        let tree = SplitNode.leaf(a)
            .inserting(b, beside: a, axis: .horizontal)
            .inserting(c, beside: a, axis: .vertical)
        XCTAssertEqual(tree.leaves, [a, c, b])
    }

    func testRemoveCollapsesSplit() {
        let tree = SplitNode.leaf(a).inserting(b, beside: a, axis: .horizontal)
        XCTAssertEqual(tree.removing(b), .leaf(a))
        XCTAssertNil(SplitNode.leaf(a).removing(a))
    }

    func testRemoveNestedKeepsOthers() {
        let tree = SplitNode.leaf(a)
            .inserting(b, beside: a, axis: .horizontal)
            .inserting(c, beside: b, axis: .vertical)
        XCTAssertEqual(tree.removing(a)?.leaves, [b, c])
    }

    func testRatioClampedAndTargeted() {
        let tree = SplitNode.leaf(a).inserting(b, beside: a, axis: .horizontal)
        guard case .split(let id, _, _, _, _) = tree else { return XCTFail() }
        guard case .split(_, _, let r, _, _) = tree.settingRatio(2, of: id) else { return XCTFail() }
        XCTAssertEqual(r, 0.9)
    }

    func testLeafNavigationWraps() {
        let tree = SplitNode.leaf(a).inserting(b, beside: a, axis: .horizontal)
        XCTAssertEqual(tree.leaf(1, from: b), a)
        XCTAssertEqual(tree.leaf(-1, from: a), b)
    }

    func testSavedLayoutRoundTripsThroughJSON() throws {
        let tree = SplitNode.leaf(a)
            .inserting(b, beside: a, axis: .horizontal)
            .inserting(c, beside: b, axis: .vertical)
        guard case .split(let id, _, _, _, _) = tree else { return XCTFail() }
        let dirs = [a: "/a", b: "/b", c: "/c"]
        let saved = tree.settingRatio(0.7, of: id).saved { dirs[$0]! }

        let decoded = try JSONDecoder().decode(SavedLayout.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded, saved)

        var made: [String] = []
        let rebuilt = SplitNode(saved: decoded) { made.append($0); return UUID() }
        XCTAssertEqual(made, ["/a", "/b", "/c"])
        guard case .split(_, .horizontal, 0.7, .leaf, .split(_, .vertical, _, _, _)) = rebuilt else {
            return XCTFail("shape lost: \(rebuilt)")
        }
    }

    func testSavedLayoutClampsBadRatio() {
        let rebuilt = SplitNode(saved: .split(horizontal: true, ratio: 5, first: .pane(directory: "/"),
                                              second: .pane(directory: "/"))) { _ in UUID() }
        guard case .split(_, _, let r, _, _) = rebuilt else { return XCTFail() }
        XCTAssertEqual(r, 0.9)
    }
}
