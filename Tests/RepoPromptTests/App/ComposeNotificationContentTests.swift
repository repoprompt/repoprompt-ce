import Foundation
@testable import RepoPromptApp
import XCTest

final class ComposeNotificationContentTests: XCTestCase {
    private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let tabID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let agentSessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let otherSessionID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    // MARK: Placeholder detection

    func testPlaceholderNamesAreDetectedCaseInsensitivelyAndTrimmed() {
        for name in [nil, "", "   ", "Untitled Chat", "untitled chat", "  UNTITLED   CHAT \n", "New Chat", "new chat", "Untitled"] {
            XCTAssertTrue(ChatSession.isPlaceholderName(name), "\(String(describing: name)) should be a placeholder")
            XCTAssertNil(ChatSession.displayableName(name))
        }
    }

    func testRealNamesAreNotPlaceholders() {
        for name in ["Refactor auth flow", "Untitled Chat about auth", "New Chat 2", "T3"] {
            XCTAssertFalse(ChatSession.isPlaceholderName(name), "\(name) should not be a placeholder")
        }
        XCTAssertEqual(ChatSession.displayableName("  Refactor   auth\nflow "), "Refactor auth flow")
    }

    func testValidatedNameFallbackIsAPlaceholder() {
        XCTAssertTrue(ChatSession.isPlaceholderName(ChatSession.validatedName("")))
    }

    // MARK: Chat complete

    func testUserChatShowsRealNameWhenDetailsAreEnabled() {
        let content = ComposeNotificationContent.chatComplete(
            chatName: "Refactor auth flow",
            isAgentLinked: false,
            agentSessionName: nil,
            showDetails: true
        )
        XCTAssertEqual(content, ComposeNotificationContent(
            title: "Chat Complete",
            subtitle: nil,
            body: "Refactor auth flow"
        ))
    }

    func testUserChatWithPlaceholderNameFallsBackToGenericBody() {
        for name in ["Untitled Chat", "New Chat", "", nil] {
            let content = ComposeNotificationContent.chatComplete(
                chatName: name,
                isAgentLinked: false,
                agentSessionName: nil,
                showDetails: true
            )
            XCTAssertEqual(content.title, "Chat Complete")
            XCTAssertEqual(content.body, ComposeNotificationContent.genericChatBody)
        }
    }

    func testChatNameIsHiddenWhenDetailsAreDisabled() {
        let content = ComposeNotificationContent.chatComplete(
            chatName: "Refactor auth flow",
            isAgentLinked: false,
            agentSessionName: nil,
            showDetails: false
        )
        XCTAssertEqual(content.body, ComposeNotificationContent.genericChatBody)
    }

    func testAgentLinkedChatIsLabelledWithAgentSessionName() {
        let content = ComposeNotificationContent.chatComplete(
            chatName: "Untitled Chat",
            isAgentLinked: true,
            agentSessionName: "Fix login bug",
            showDetails: true
        )
        XCTAssertEqual(content, ComposeNotificationContent(
            title: "Oracle reply ready",
            subtitle: "Fix login bug",
            body: ComposeNotificationContent.genericChatBody
        ))
    }

    func testAgentLinkedChatKeepsRealChatNameAsBody() {
        let content = ComposeNotificationContent.chatComplete(
            chatName: "Plan: auth refactor",
            isAgentLinked: true,
            agentSessionName: "Fix login bug",
            showDetails: true
        )
        XCTAssertEqual(content.subtitle, "Fix login bug")
        XCTAssertEqual(content.body, "Plan: auth refactor")
    }

    func testAgentSessionNameIsShownEvenWithoutDetailsLikeOtherAgentNotifications() {
        let content = ComposeNotificationContent.chatComplete(
            chatName: "Plan: auth refactor",
            isAgentLinked: true,
            agentSessionName: "Fix login bug",
            showDetails: false
        )
        XCTAssertEqual(content.subtitle, "Fix login bug")
        XCTAssertEqual(content.body, ComposeNotificationContent.genericChatBody)
    }

    func testAgentLinkedChatWithoutLiveSessionOmitsSubtitle() {
        for sessionName in [nil, "Untitled Chat"] {
            let content = ComposeNotificationContent.chatComplete(
                chatName: "Untitled Chat",
                isAgentLinked: true,
                agentSessionName: sessionName,
                showDetails: true
            )
            XCTAssertEqual(content.title, "Oracle reply ready")
            XCTAssertNil(content.subtitle)
        }
    }

    // MARK: Context Builder complete

    func testContextBuilderUsesTabNameUnlessPlaceholderOrHidden() {
        XCTAssertEqual(
            ComposeNotificationContent.contextBuilderComplete(tabName: "Auth refactor", showDetails: true),
            ComposeNotificationContent(title: "Context Builder Complete", subtitle: nil, body: "Auth refactor")
        )
        XCTAssertEqual(
            ComposeNotificationContent.contextBuilderComplete(tabName: "Untitled Chat", showDetails: true).body,
            ComposeNotificationContent.genericContextBuilderBody
        )
        XCTAssertEqual(
            ComposeNotificationContent.contextBuilderComplete(tabName: "Auth refactor", showDetails: false).body,
            ComposeNotificationContent.genericContextBuilderBody
        )
    }

    // MARK: Agent link

    func testAgentLinkIsOnlyCreatedForAgentOwnedChats() {
        XCTAssertNil(ChatNotificationAgentLink(chatSession: ChatSession(composeTabID: tabID, name: "New Chat")))

        let bySession = ChatNotificationAgentLink(chatSession: ChatSession(
            composeTabID: tabID,
            agentModeSessionID: agentSessionID,
            name: "Untitled Chat"
        ))
        XCTAssertEqual(bySession, ChatNotificationAgentLink(tabID: tabID, sessionID: agentSessionID))

        let byRunOnly = ChatNotificationAgentLink(chatSession: ChatSession(
            composeTabID: tabID,
            agentModeRunID: UUID(),
            name: "Untitled Chat"
        ))
        XCTAssertEqual(byRunOnly, ChatNotificationAgentLink(tabID: tabID, sessionID: nil))
    }

    func testAgentLinkMatchesOnlyTheOwningSessionIncarnation() {
        let link = ChatNotificationAgentLink(tabID: tabID, sessionID: agentSessionID)

        let owning = attentionState(sessionID: agentSessionID)
        XCTAssertEqual(link.matchingState(owning), owning)
        XCTAssertEqual(
            link.matchingState(owning)?.route.withInteractionID(nil),
            AgentSessionDeepLinkRoute(windowID: 7, workspaceID: workspaceID, tabID: tabID, sessionID: agentSessionID)
        )

        XCTAssertNil(link.matchingState(attentionState(sessionID: otherSessionID)))
        XCTAssertNil(link.matchingState(attentionState(sessionID: nil)))
        XCTAssertNil(link.matchingState(attentionState(sessionID: agentSessionID, tabID: UUID())))
        XCTAssertNil(link.matchingState(nil))
    }

    func testRunOnlyAgentLinkAcceptsTheTabsLiveSession() {
        let link = ChatNotificationAgentLink(tabID: tabID, sessionID: nil)
        let state = attentionState(sessionID: otherSessionID)
        XCTAssertEqual(link.matchingState(state), state)
    }

    private func attentionState(sessionID: UUID?, tabID: UUID? = nil) -> AgentAttentionState {
        AgentAttentionState(
            windowID: 7,
            workspaceID: workspaceID,
            tabID: tabID ?? self.tabID,
            sessionID: sessionID,
            sessionName: "Fix login bug",
            isMCPControlled: false,
            interaction: nil,
            turnMarker: nil
        )
    }
}
