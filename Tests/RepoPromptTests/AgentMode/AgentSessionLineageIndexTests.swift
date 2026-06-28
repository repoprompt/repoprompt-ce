@testable import RepoPrompt
import XCTest

final class AgentSessionLineageIndexTests: XCTestCase {
    func testValidChainReportsRootAncestorsAndDescendants() {
        let root = id(1)
        let child = id(2)
        let grandchild = id(3)
        let lineage = AgentSessionLineageIndex(nodes: [
            .init(sessionID: root, parentSessionID: nil),
            .init(sessionID: child, parentSessionID: root),
            .init(sessionID: grandchild, parentSessionID: child)
        ])

        XCTAssertEqual(lineage.rootSessionID(for: grandchild), root)
        XCTAssertEqual(lineage.ancestorSessionIDs(of: grandchild), [child, root])
        XCTAssertEqual(lineage.descendantSessionIDs(of: root), [child, grandchild])
    }

    func testMissingParentDegradesToRoot() {
        let child = id(10)
        let missingParent = id(11)
        let lineage = AgentSessionLineageIndex(nodes: [
            .init(sessionID: child, parentSessionID: missingParent)
        ])

        XCTAssertEqual(lineage.rootSessionID(for: child), child)
        XCTAssertEqual(lineage.parentSessionID(of: child), nil)
        XCTAssertEqual(lineage.ancestorSessionIDs(of: child), [])
    }

    func testSelfParentDegradesToRoot() {
        let sessionID = id(20)
        let lineage = AgentSessionLineageIndex(nodes: [
            .init(sessionID: sessionID, parentSessionID: sessionID)
        ])

        XCTAssertEqual(lineage.rootSessionID(for: sessionID), sessionID)
        XCTAssertEqual(lineage.parentSessionID(of: sessionID), nil)
    }

    func testTwoNodeCycleInvalidatesBothEdges() {
        let first = id(30)
        let second = id(31)
        let lineage = AgentSessionLineageIndex(nodes: [
            .init(sessionID: first, parentSessionID: second),
            .init(sessionID: second, parentSessionID: first)
        ])

        XCTAssertEqual(lineage.rootSessionID(for: first), first)
        XCTAssertEqual(lineage.rootSessionID(for: second), second)
        XCTAssertEqual(lineage.parentSessionID(of: first), nil)
        XCTAssertEqual(lineage.parentSessionID(of: second), nil)
        XCTAssertEqual(lineage.childSessionIDs(of: first), [])
        XCTAssertEqual(lineage.childSessionIDs(of: second), [])
    }

    func testCycleInAncestorChainInvalidatesAffectedDescendant() {
        let first = id(40)
        let second = id(41)
        let descendant = id(42)
        let lineage = AgentSessionLineageIndex(nodes: [
            .init(sessionID: first, parentSessionID: second),
            .init(sessionID: second, parentSessionID: first),
            .init(sessionID: descendant, parentSessionID: first)
        ])

        XCTAssertEqual(lineage.rootSessionID(for: descendant), descendant)
        XCTAssertEqual(lineage.parentSessionID(of: descendant), nil)
        XCTAssertEqual(lineage.ancestorSessionIDs(of: descendant), [])
    }

    func testChildOrderPreservesInputOrderForValidEdges() {
        let root = id(50)
        let firstChild = id(51)
        let secondChild = id(52)
        let lineage = AgentSessionLineageIndex(nodes: [
            .init(sessionID: secondChild, parentSessionID: root),
            .init(sessionID: root, parentSessionID: nil),
            .init(sessionID: firstChild, parentSessionID: root)
        ])

        XCTAssertEqual(lineage.childSessionIDs(of: root), [secondChild, firstChild])
    }

    func testChildFirstDescendantOrderReturnsDescendantsBeforeRoot() {
        let root = id(60)
        let child = id(61)
        let grandchild = id(62)
        let lineage = AgentSessionLineageIndex(nodes: [
            .init(sessionID: root, parentSessionID: nil),
            .init(sessionID: child, parentSessionID: root),
            .init(sessionID: grandchild, parentSessionID: child)
        ])

        XCTAssertEqual(
            lineage.descendantSessionIDsChildFirst(of: root, includeSelf: true),
            [grandchild, child, root]
        )
    }

    func testChildFirstDescendantOrderPreservesSiblingInputOrder() {
        let root = id(70)
        let firstChild = id(71)
        let firstGrandchild = id(72)
        let secondChild = id(73)
        let lineage = AgentSessionLineageIndex(nodes: [
            .init(sessionID: secondChild, parentSessionID: root),
            .init(sessionID: root, parentSessionID: nil),
            .init(sessionID: firstChild, parentSessionID: root),
            .init(sessionID: firstGrandchild, parentSessionID: firstChild)
        ])

        XCTAssertEqual(
            lineage.descendantSessionIDsChildFirst(of: root, includeSelf: true),
            [secondChild, firstGrandchild, firstChild, root]
        )
    }

    private func id(_ value: Int) -> UUID {
        let suffix = String(format: "%012d", value)
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }
}
