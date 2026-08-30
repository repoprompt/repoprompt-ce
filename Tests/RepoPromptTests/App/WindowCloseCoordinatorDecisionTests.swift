@testable import RepoPromptApp
import XCTest

@MainActor
final class WindowCloseCoordinatorPolicyTests: XCTestCase {
    func testTerminationAndAuthorizationAllowDespiteOtherwiseBlockingImpact() {
        let otherwiseBlockingSnapshot = makeSnapshot(
            isLastAppWindow: true,
            isLastMCPEnabledWindow: true,
            activeItems: [activity(id: "workspace-session", count: 1, singular: "active workspace session", plural: "active workspace sessions")],
            mcp: mcp(toolsEnabled: true, liveConnectionCount: 2, activeExecutionCount: 1, hasIdleLiveConnections: true)
        )
        let cases: [(name: String, snapshot: WindowCloseImpactSnapshot, authorization: WindowCloseAuthorization?)] = [
            (
                "termination",
                makeSnapshot(
                    isTerminating: true,
                    isLastAppWindow: true,
                    isLastMCPEnabledWindow: true,
                    activeItems: otherwiseBlockingSnapshot.activeItems,
                    mcp: otherwiseBlockingSnapshot.mcp
                ),
                nil
            ),
            ("user confirmation", otherwiseBlockingSnapshot, authorization(source: .userConfirmed)),
            ("workspace deletion", otherwiseBlockingSnapshot, authorization(source: .workspaceDelete)),
            ("system", otherwiseBlockingSnapshot, authorization(source: .system))
        ]

        for testCase in cases {
            XCTAssertEqual(
                WindowCloseCoordinator.decide(snapshot: testCase.snapshot, authorization: testCase.authorization),
                .allow,
                testCase.name
            )
        }
    }

    func testActiveWorkConfirmationPrecedesMCPContinuityAndFormatsDeterministically() {
        let cases: [(name: String, snapshot: WindowCloseImpactSnapshot, expected: WindowCloseDecision)] = [
            (
                "workspace activity",
                makeSnapshot(activeItems: [activity(id: "workspace-session", count: 1, singular: "active workspace session", plural: "active workspace sessions")]),
                .confirm(activeWorkConfirmation("1 active workspace session"))
            ),
            (
                "zero count is ignored",
                makeSnapshot(activeItems: [activity(id: "workspace-session", count: 0, singular: "active workspace session", plural: "active workspace sessions")]),
                .allow
            ),
            (
                "MCP execution precedes MCP continuity",
                makeSnapshot(
                    isLastAppWindow: true,
                    isLastMCPEnabledWindow: true,
                    mcp: mcp(toolsEnabled: true, liveConnectionCount: 2, activeExecutionCount: 1, hasIdleLiveConnections: true)
                ),
                .confirm(activeWorkConfirmation("1 active MCP tool execution"))
            ),
            (
                "mixed activity is sorted and pluralized",
                makeSnapshot(
                    activeItems: [
                        activity(id: "z-search", count: 2, singular: "active search", plural: "active searches"),
                        activity(id: "a-session", count: 1, singular: "active agent session", plural: "active agent sessions")
                    ],
                    mcp: mcp(activeExecutionCount: 3)
                ),
                .confirm(activeWorkConfirmation("1 active agent session and 3 active MCP tool executions and 2 active searches"))
            )
        ]

        for testCase in cases {
            XCTAssertEqual(
                WindowCloseCoordinator.decide(snapshot: testCase.snapshot, authorization: nil),
                testCase.expected,
                testCase.name
            )
        }
    }

    func testMCPContinuityConfirmationAndOrdinaryAllowCases() {
        let cases: [(name: String, snapshot: WindowCloseImpactSnapshot, expected: WindowCloseDecision)] = [
            (
                "last tools-enabled window without connections",
                makeSnapshot(isLastAppWindow: true, isLastMCPEnabledWindow: true, mcp: mcp(toolsEnabled: true)),
                .confirm(lastWindowMCPConfirmation(connectionCount: 0))
            ),
            (
                "last tools-enabled window with connections",
                makeSnapshot(
                    isLastAppWindow: true,
                    isLastMCPEnabledWindow: true,
                    mcp: mcp(toolsEnabled: true, liveConnectionCount: 2, hasIdleLiveConnections: true)
                ),
                .confirm(lastWindowMCPConfirmation(connectionCount: 2))
            ),
            (
                "last MCP-enabled window with idle connection",
                makeSnapshot(isLastMCPEnabledWindow: true, mcp: mcp(liveConnectionCount: 1, hasIdleLiveConnections: true)),
                .confirm(disconnectMCPConfirmation(connectionCount: 1))
            ),
            ("non-last MCP-enabled window with idle connection", makeSnapshot(mcp: mcp(liveConnectionCount: 1, hasIdleLiveConnections: true)), .allow),
            ("ordinary close", makeSnapshot(), .allow)
        ]

        for testCase in cases {
            XCTAssertEqual(
                WindowCloseCoordinator.decide(snapshot: testCase.snapshot, authorization: nil),
                testCase.expected,
                testCase.name
            )
        }
    }

    private func authorization(source: WindowCloseAuthorization.Source) -> WindowCloseAuthorization {
        WindowCloseAuthorization(
            source: source,
            bypassConfirmation: true,
            bypassBackgroundPreservation: true
        )
    }

    private func activity(id: String, count: Int, singular: String, plural: String) -> WindowCloseActivityItem {
        WindowCloseActivityItem(id: id, count: count, singularLabel: singular, pluralLabel: plural)
    }

    private func makeSnapshot(
        isTerminating: Bool = false,
        isLastAppWindow: Bool = false,
        isLastMCPEnabledWindow: Bool = false,
        activeItems: [WindowCloseActivityItem] = [],
        mcp: WindowMCPCloseSafetyState = .inactive
    ) -> WindowCloseImpactSnapshot {
        WindowCloseImpactSnapshot(
            isTerminating: isTerminating,
            isLastAppWindow: isLastAppWindow,
            isLastMCPEnabledWindow: isLastMCPEnabledWindow,
            activeItems: activeItems,
            mcp: mcp
        )
    }

    private func mcp(
        toolsEnabled: Bool = false,
        liveConnectionCount: Int = 0,
        activeExecutionCount: Int = 0,
        hasIdleLiveConnections: Bool = false
    ) -> WindowMCPCloseSafetyState {
        WindowMCPCloseSafetyState(
            toolsEnabled: toolsEnabled,
            liveConnectionCount: liveConnectionCount,
            activeExecutionCount: activeExecutionCount,
            hasIdleLiveConnections: hasIdleLiveConnections,
            activeToolName: nil
        )
    }

    private func activeWorkConfirmation(_ summary: String) -> WindowCloseConfirmation {
        WindowCloseConfirmation(
            title: "Close Window?",
            message: "Closing this window will terminate \(summary). Do you want to continue?",
            confirmButtonTitle: "Close and End Sessions",
            secondaryButtonTitle: nil,
            secondaryAction: nil
        )
    }

    private func disconnectMCPConfirmation(connectionCount: Int) -> WindowCloseConfirmation {
        let label = connectionCount == 1 ? "client" : "clients"
        return WindowCloseConfirmation(
            title: "Disconnect MCP?",
            message: "Closing this window will disconnect \(connectionCount) MCP \(label).",
            confirmButtonTitle: "Close and Disconnect",
            secondaryButtonTitle: nil,
            secondaryAction: nil
        )
    }

    private func lastWindowMCPConfirmation(connectionCount: Int) -> WindowCloseConfirmation {
        let message: String
        if connectionCount > 0 {
            let label = connectionCount == 1 ? "client" : "clients"
            message = "This is the last MCP-enabled window. Close to disconnect \(connectionCount) \(label) and stop MCP, or hide it to keep MCP running from the menu bar."
        } else {
            message = "This is the last MCP-enabled window. Close to stop MCP, or hide it to keep MCP running from the menu bar."
        }
        return WindowCloseConfirmation(
            title: "Keep MCP running?",
            message: message,
            confirmButtonTitle: "Close and Stop MCP",
            secondaryButtonTitle: "Hide and Keep Running",
            secondaryAction: .backgroundWindow
        )
    }
}
