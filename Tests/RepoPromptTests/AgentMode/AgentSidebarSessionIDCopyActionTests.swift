@testable import RepoPromptApp
import XCTest

@MainActor
final class AgentSidebarSessionIDCopyActionTests: XCTestCase {
    func testIsEnabledWhenSessionIDIsPresent() throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "12345678-1234-1234-1234-123456789ABC"))
        let action = AgentSidebarSessionIDCopyAction(
            sessionID: sessionID,
            clipboardWriter: { _ in }
        )

        XCTAssertTrue(action.isEnabled)
    }

    func testPerformWritesExactRawUUIDOnceWithoutPrefixOrWhitespace() throws {
        let sessionID = try XCTUnwrap(UUID(uuidString: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"))
        var writtenValues: [String] = []
        let action = AgentSidebarSessionIDCopyAction(
            sessionID: sessionID,
            clipboardWriter: { writtenValues.append($0) }
        )

        action.perform()

        XCTAssertEqual(writtenValues, [sessionID.uuidString])
    }

    func testNilSessionIDIsDisabledAndPerformsNoWrite() {
        var writtenValues = ["sentinel"]
        let action = AgentSidebarSessionIDCopyAction(
            sessionID: nil,
            clipboardWriter: { writtenValues.append($0) }
        )

        XCTAssertFalse(action.isEnabled)

        action.perform()

        XCTAssertEqual(writtenValues, ["sentinel"])
    }

    func testRowsExposeInjectedSessionIDCopyAction() throws {
        let rootSessionID = try XCTUnwrap(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let subagentSessionID = try XCTUnwrap(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        let archivedSessionID = try XCTUnwrap(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        var rootWrites: [String] = []
        var subagentWrites: [String] = []
        var archivedWrites: [String] = []

        let rootRow = makeActiveRow(
            threadDepth: 0,
            sessionIDCopyAction: AgentSidebarSessionIDCopyAction(
                sessionID: rootSessionID,
                clipboardWriter: { rootWrites.append($0) }
            )
        )
        let subagentRow = makeActiveRow(
            threadDepth: 1,
            sessionIDCopyAction: AgentSidebarSessionIDCopyAction(
                sessionID: subagentSessionID,
                clipboardWriter: { subagentWrites.append($0) }
            )
        )
        let archivedRow = makeArchivedRow(
            sessionID: archivedSessionID,
            sessionIDCopyAction: AgentSidebarSessionIDCopyAction(
                sessionID: archivedSessionID,
                clipboardWriter: { archivedWrites.append($0) }
            )
        )

        rootRow.sessionIDCopyAction.perform()
        subagentRow.sessionIDCopyAction.perform()
        archivedRow.sessionIDCopyAction.perform()

        XCTAssertEqual(rootWrites, ["11111111-1111-1111-1111-111111111111"])
        XCTAssertEqual(subagentWrites, ["22222222-2222-2222-2222-222222222222"])
        XCTAssertEqual(archivedWrites, ["33333333-3333-3333-3333-333333333333"])
    }

    private func makeActiveRow(
        threadDepth: Int,
        sessionIDCopyAction: AgentSidebarSessionIDCopyAction
    ) -> AgentSessionRow {
        AgentSessionRow(
            title: "Session",
            isActive: false,
            isPinned: false,
            isMCPControlled: false,
            runState: .idle,
            threadDepth: threadDepth,
            onSelectionGesture: { _ in .ignored },
            onSelect: {},
            onTogglePin: {},
            onDelete: {},
            onRename: { _ in },
            sessionIDCopyAction: sessionIDCopyAction
        )
    }

    private func makeArchivedRow(
        sessionID: UUID,
        sessionIDCopyAction: AgentSidebarSessionIDCopyAction
    ) -> AgentStashedSessionRow {
        AgentStashedSessionRow(
            stashed: StashedTab(
                tab: ComposeTabState(activeAgentSessionID: sessionID)
            ),
            onSelectionGesture: { _ in .ignored },
            onRestore: {},
            onDelete: {},
            sessionIDCopyAction: sessionIDCopyAction
        )
    }
}
