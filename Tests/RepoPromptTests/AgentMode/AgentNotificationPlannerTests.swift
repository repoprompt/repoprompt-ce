import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentNotificationPlannerTests: XCTestCase {
    private let workspaceID = UUID()
    private let now = Date(timeIntervalSince1970: 1000)

    private func state(
        tabID: UUID = UUID(),
        interaction: AgentPendingInteractionDescriptor?,
        isMCPControlled: Bool = false
    ) -> AgentAttentionState {
        AgentAttentionState(
            windowID: 1,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: nil,
            sessionName: "Refactor auth",
            isMCPControlled: isMCPControlled,
            interaction: interaction
        )
    }

    private func approval(id: UUID = UUID(), command: String = "ls") -> AgentPendingInteractionDescriptor {
        AgentPendingInteractionDescriptor(
            id: id,
            kind: .approval,
            title: "Command Approval",
            detail: command,
            approvalKind: .commandExecution,
            command: command
        )
    }

    private func input(
        _ states: [AgentAttentionState],
        visible: Set<UUID> = [],
        appIsActive: Bool = false,
        preferences: NotificationPreferences = .defaults,
        firstSeenAt: [UUID: Date]? = nil,
        announced: Set<UUID> = [],
        posted: [String: AgentPostedInteraction] = [:]
    ) -> AgentNotificationPlanInput {
        let seen = firstSeenAt ?? Dictionary(
            uniqueKeysWithValues: states.compactMap { $0.interaction?.id }.map { ($0, now.addingTimeInterval(-5)) }
        )
        return AgentNotificationPlanInput(
            states: states,
            visibleTabIDs: visible,
            appIsActive: appIsActive,
            preferences: preferences,
            firstSeenAt: seen,
            announcedInteractionIDs: announced,
            posted: posted,
            now: now,
            gracePeriod: 1.0
        )
    }

    private func record(for post: AgentInteractionPost) -> [String: AgentPostedInteraction] {
        [post.request.identifier: AgentPostedInteraction(
            requestIdentifier: post.request.identifier,
            interactionID: post.interactionID,
            tabID: post.tabID,
            contentKey: post.contentKey,
            categoryIdentifier: post.category?.identifier
        )]
    }

    func testPendingApprovalPostsActionableNotification() throws {
        let descriptor = approval(command: "swift test")
        let plan = AgentNotificationPlanner.plan(input([state(interaction: descriptor)]))

        let post = try XCTUnwrap(plan.posts.first)
        XCTAssertEqual(post.request.identifier, AppNotificationIdentifier.interaction(descriptor.id))
        XCTAssertEqual(post.request.body, "swift test", "Approve requires the verbatim command in the body")
        XCTAssertEqual(post.request.subtitle, "Command Approval")
        XCTAssertEqual(post.category?.actions.map(\.identifier), [
            AppNotificationActionID.approve, AppNotificationActionID.decline, AppNotificationActionID.review
        ])
        XCTAssertEqual(post.request.payload?.interaction?.fingerprint, descriptor.fingerprint)
        XCTAssertEqual(post.request.payload?.route?.interactionID, descriptor.id)
        XCTAssertTrue(post.request.playsSound)
        XCTAssertEqual(plan.badgeCount, 1)
    }

    func testGracePeriodDefersPostingAndSchedulesWakeup() {
        let descriptor = approval()
        let plan = AgentNotificationPlanner.plan(input(
            [state(interaction: descriptor)],
            firstSeenAt: [descriptor.id: now.addingTimeInterval(-0.2)]
        ))

        XCTAssertTrue(plan.posts.isEmpty)
        XCTAssertEqual(plan.nextGraceDeadline, now.addingTimeInterval(0.8))
        XCTAssertEqual(plan.badgeCount, 1, "The badge counts pending work immediately")
    }

    func testNewlyObservedInteractionStartsItsGraceWindow() {
        let descriptor = approval()
        let plan = AgentNotificationPlanner.plan(input([state(interaction: descriptor)], firstSeenAt: [:]))

        XCTAssertTrue(plan.posts.isEmpty)
        XCTAssertEqual(plan.firstSeenAt[descriptor.id], now)
    }

    func testResolvedInteractionIsRetracted() throws {
        let descriptor = approval()
        let tabID = UUID()
        let firstPlan = AgentNotificationPlanner.plan(input([state(tabID: tabID, interaction: descriptor)]))
        let post = try XCTUnwrap(firstPlan.posts.first)

        let secondPlan = AgentNotificationPlanner.plan(input(
            [state(tabID: tabID, interaction: nil)],
            posted: record(for: post)
        ))

        XCTAssertEqual(secondPlan.removals, [post.request.identifier])
        XCTAssertTrue(secondPlan.posts.isEmpty)
        XCTAssertEqual(secondPlan.badgeCount, 0)
    }

    func testUnchangedContentIsNotRepostedButChangedContentReplacesInPlace() throws {
        let id = UUID()
        let tabID = UUID()
        let first = try XCTUnwrap(AgentNotificationPlanner.plan(input([state(tabID: tabID, interaction: approval(id: id))])).posts.first)

        let unchanged = AgentNotificationPlanner.plan(input(
            [state(tabID: tabID, interaction: approval(id: id))],
            posted: record(for: first)
        ))
        XCTAssertTrue(unchanged.posts.isEmpty)
        XCTAssertTrue(unchanged.removals.isEmpty)

        let changed = AgentNotificationPlanner.plan(input(
            [state(tabID: tabID, interaction: approval(id: id, command: "ls -la"))],
            posted: record(for: first)
        ))
        XCTAssertEqual(changed.posts.map(\.request.identifier), [first.request.identifier])
        XCTAssertTrue(changed.removals.isEmpty)
    }

    func testVisibleSessionIsSuppressedRetractedAndLaterRepostIsSilent() throws {
        let descriptor = approval()
        let tabID = UUID()
        let post = try XCTUnwrap(AgentNotificationPlanner.plan(input([state(tabID: tabID, interaction: descriptor)])).posts.first)

        let visiblePlan = AgentNotificationPlanner.plan(input(
            [state(tabID: tabID, interaction: descriptor)],
            visible: [tabID],
            appIsActive: true,
            posted: record(for: post)
        ))
        XCTAssertEqual(visiblePlan.removals, [post.request.identifier])
        XCTAssertTrue(visiblePlan.retractTurnNotificationsForTabs.contains(tabID))
        XCTAssertTrue(visiblePlan.announcedInteractionIDs.contains(descriptor.id))

        let awayPlan = AgentNotificationPlanner.plan(input(
            [state(tabID: tabID, interaction: descriptor)],
            announced: visiblePlan.announcedInteractionIDs
        ))
        XCTAssertEqual(awayPlan.posts.first?.request.playsSound, false)
    }

    func testForegroundPreferenceAndCategoryToggles() {
        let descriptor = approval()
        var noForeground = NotificationPreferences.defaults
        noForeground.notifyWhileActive = false
        XCTAssertTrue(AgentNotificationPlanner.plan(input(
            [state(interaction: descriptor)],
            appIsActive: true,
            preferences: noForeground
        )).posts.isEmpty)
        XCTAssertEqual(AgentNotificationPlanner.plan(input(
            [state(interaction: descriptor)],
            appIsActive: true
        )).posts.count, 1)

        var noInteractions = NotificationPreferences.defaults
        noInteractions.agentInteractions = false
        XCTAssertTrue(AgentNotificationPlanner.plan(input([state(interaction: descriptor)], preferences: noInteractions)).posts.isEmpty)

        var noInstructionWaits = NotificationPreferences.defaults
        noInstructionWaits.agentInstructionWaits = false
        let instruction = AgentPendingInteractionDescriptor(id: UUID(), kind: .instruction, title: "t", detail: "Next?", allowsCustom: true)
        XCTAssertTrue(AgentNotificationPlanner.plan(input([state(interaction: instruction)], preferences: noInstructionWaits)).posts.isEmpty)
    }

    func testAgentDrivenSessionsAreExcludedByDefault() {
        let mcpState = state(interaction: approval(), isMCPControlled: true)
        let plan = AgentNotificationPlanner.plan(input([mcpState]))
        XCTAssertTrue(plan.posts.isEmpty)
        XCTAssertEqual(plan.badgeCount, 0)

        var include = NotificationPreferences.defaults
        include.includeAgentDrivenSessions = true
        let included = AgentNotificationPlanner.plan(input([mcpState], preferences: include))
        XCTAssertEqual(included.posts.first?.category?.actions.map(\.identifier), [AppNotificationActionID.review])
    }

    func testHiddenDetailsUseGenericBodyWithoutApprove() throws {
        var hidden = NotificationPreferences.defaults
        hidden.showDetails = false
        let post = try XCTUnwrap(AgentNotificationPlanner.plan(input(
            [state(interaction: approval(command: "cat secrets.txt"))],
            preferences: hidden
        )).posts.first)

        XCTAssertEqual(post.request.body, "Needs your approval")
        XCTAssertFalse(post.category?.actions.contains { $0.identifier == AppNotificationActionID.approve } ?? true)
    }

    func testInteractionRetractsTurnCompleteForItsTab() {
        let tabID = UUID()
        let plan = AgentNotificationPlanner.plan(input([state(tabID: tabID, interaction: approval())]))
        XCTAssertTrue(plan.retractTurnNotificationsForTabs.contains(tabID))
    }

    func testDockBadgePreference() {
        var noBadge = NotificationPreferences.defaults
        noBadge.dockBadge = false
        XCTAssertEqual(AgentNotificationPlanner.plan(input([state(interaction: approval())], preferences: noBadge)).badgeCount, 0)
    }

    func testTextPreviewTruncatesLongDetails() {
        let long = String(repeating: "word ", count: 100)
        let preview = NotificationTextPreview.make(from: long)
        XCTAssertEqual(preview?.hasSuffix("…"), true)
        XCTAssertLessThanOrEqual(preview?.count ?? 0, 221)
        XCTAssertEqual(NotificationTextPreview.make(from: "a\n\nb\nc\nd"), "a\nb\nc")
        XCTAssertNil(NotificationTextPreview.make(from: "   "))
    }
}

@MainActor
final class AgentNotificationCoordinatorTests: XCTestCase {
    private var center: FakeUserNotificationCenter!
    private var preferences: FakeNotificationPreferencesProvider!
    private var visibility: FakeAgentSessionVisibility!
    private var clock = Date(timeIntervalSince1970: 1000)
    private var bounces = 0

    override func setUp() async throws {
        center = FakeUserNotificationCenter()
        preferences = FakeNotificationPreferencesProvider()
        visibility = FakeAgentSessionVisibility()
        bounces = 0
    }

    private func makeCoordinator(gracePeriod: TimeInterval = 0) -> AgentNotificationCoordinator {
        AgentNotificationCoordinator(
            client: center,
            registry: NotificationCategoryRegistry(client: center, staticCategories: AgentNotificationAction.staticCategories),
            preferences: preferences,
            visibility: visibility,
            authorization: { [unowned self] in center.status },
            now: { [unowned self] in clock },
            gracePeriod: gracePeriod,
            requestUserAttention: { [unowned self] in bounces += 1 }
        )
    }

    private func state(tabID: UUID, interaction: AgentPendingInteractionDescriptor?) -> AgentAttentionState {
        AgentAttentionState(
            windowID: 7,
            workspaceID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            tabID: tabID,
            sessionID: nil,
            sessionName: "Session",
            isMCPControlled: false,
            interaction: interaction
        )
    }

    private func question(id: UUID) -> AgentPendingInteractionDescriptor {
        AgentPendingInteractionDescriptor(
            id: id,
            kind: .askUser,
            title: "Question",
            detail: "Ship it?",
            questionID: "q1",
            questionCount: 1,
            optionLabels: ["Yes", "No"],
            allowsCustom: false
        )
    }

    func testPostsRegistersDynamicCategoryAndRetractsOnResolve() async throws {
        let coordinator = makeCoordinator()
        let tabID = UUID()
        let interactionID = UUID()

        coordinator.update(windowID: 7, states: [state(tabID: tabID, interaction: question(id: interactionID))])
        await coordinator.waitForIdleForTesting()

        let request = try XCTUnwrap(center.addedRequests.last)
        XCTAssertEqual(request.identifier, AppNotificationIdentifier.interaction(interactionID))
        let category = try XCTUnwrap(center.category(request.categoryIdentifier))
        XCTAssertEqual(category.actions.map(\.title), ["Yes", "No", "Skip", "Review…"])
        XCTAssertEqual(center.badgeCounts.last, 1)

        coordinator.update(windowID: 7, states: [state(tabID: tabID, interaction: nil)])
        await coordinator.waitForIdleForTesting()

        XCTAssertTrue(center.removedDeliveredIdentifiers.contains(request.identifier))
        XCTAssertNil(center.category(request.categoryIdentifier), "Dynamic category is pruned once unused")
        XCTAssertEqual(center.badgeCounts.last, 0)
    }

    func testWindowRemovalRetractsItsNotifications() async {
        let coordinator = makeCoordinator()
        let interactionID = UUID()
        coordinator.update(windowID: 7, states: [state(tabID: UUID(), interaction: question(id: interactionID))])
        await coordinator.waitForIdleForTesting()

        coordinator.removeWindow(7)
        await coordinator.waitForIdleForTesting()

        XCTAssertTrue(center.removedDeliveredIdentifiers.contains(AppNotificationIdentifier.interaction(interactionID)))
    }

    func testUnauthorizedFallsBackToOneDockBouncePerInteraction() async {
        center.status = .denied
        let coordinator = makeCoordinator()
        let tabID = UUID()
        let descriptor = question(id: UUID())

        coordinator.update(windowID: 7, states: [state(tabID: tabID, interaction: descriptor)])
        await coordinator.waitForIdleForTesting()
        await coordinator.forceReconcileForTesting()

        XCTAssertTrue(center.addedRequests.isEmpty)
        XCTAssertEqual(bounces, 1)
    }

    func testTurnCompleteIsSuppressedWhileVisibleAndPostedOtherwise() async throws {
        let coordinator = makeCoordinator()
        let tabID = UUID()
        visibility.isAppActive = true
        visibility.visibleTabIDs = [tabID]
        coordinator.postTurnOutcome(.completed(preview: "Done"), for: state(tabID: tabID, interaction: nil))
        await coordinator.waitForIdleForTesting()
        XCTAssertTrue(center.addedRequests.isEmpty)

        visibility.isAppActive = false
        coordinator.postTurnOutcome(.completed(preview: "Done"), for: state(tabID: tabID, interaction: nil))
        await coordinator.waitForIdleForTesting()
        let request = try XCTUnwrap(center.addedRequests.last)
        XCTAssertEqual(request.identifier, AppNotificationIdentifier.turnComplete(tabID: tabID))
        XCTAssertEqual(request.body, "Done")
        XCTAssertNil(request.categoryIdentifier, "Reply on completion is opt-in")
        XCTAssertEqual(request.payload?.kind, .turnComplete)
    }

    func testTurnFailureRespectsPreference() async {
        let coordinator = makeCoordinator()
        let tabID = UUID()
        preferences.currentNotificationPreferences.agentTurnFailed = false
        coordinator.postTurnOutcome(.failed(message: "boom"), for: state(tabID: tabID, interaction: nil))
        await coordinator.waitForIdleForTesting()
        XCTAssertTrue(center.addedRequests.isEmpty)

        preferences.currentNotificationPreferences.agentTurnFailed = true
        coordinator.postTurnOutcome(.failed(message: "boom"), for: state(tabID: tabID, interaction: nil))
        await coordinator.waitForIdleForTesting()
        XCTAssertEqual(center.addedRequests.last?.identifier, AppNotificationIdentifier.turnFailed(tabID: tabID))
        XCTAssertEqual(center.addedRequests.last?.subtitle, "Run failed")
    }

    func testNewInteractionRetractsTurnCompleteForTab() async {
        let coordinator = makeCoordinator()
        let tabID = UUID()
        coordinator.postTurnOutcome(.completed(preview: "Done"), for: state(tabID: tabID, interaction: nil))
        await coordinator.waitForIdleForTesting()

        coordinator.update(windowID: 7, states: [state(tabID: tabID, interaction: question(id: UUID()))])
        await coordinator.waitForIdleForTesting()

        XCTAssertTrue(center.removedDeliveredIdentifiers.contains(AppNotificationIdentifier.turnComplete(tabID: tabID)))
    }

    func testLaunchSweepRemovesNotificationsFromPreviousLaunches() async {
        let coordinator = makeCoordinator()
        let oldPayload = AppNotificationPayload(kind: .interaction, route: nil, launchID: UUID())
        let currentPayload = AppNotificationPayload(kind: .turnComplete, route: nil)
        center.externallyDelivered = [
            DeliveredNotificationSummary(identifier: "old", threadIdentifier: "", categoryIdentifier: "", payload: oldPayload),
            DeliveredNotificationSummary(identifier: "legacy", threadIdentifier: "", categoryIdentifier: "", payload: nil),
            DeliveredNotificationSummary(identifier: "current", threadIdentifier: "", categoryIdentifier: "", payload: currentPayload)
        ]

        await coordinator.sweepPreviousLaunchNotifications()

        XCTAssertEqual(Set(center.removedDeliveredIdentifiers), ["old", "legacy"])
        XCTAssertEqual(center.badgeCounts.last, 0)
    }

    func testForegroundPresentationDecisions() {
        let coordinator = makeCoordinator()
        let tabID = UUID()
        let route = AgentSessionDeepLinkRoute(windowID: 7, workspaceID: UUID(), tabID: tabID)
        visibility.isAppActive = true

        XCTAssertTrue(coordinator.shouldPresentWhileActive(AppNotificationPayload(kind: .interaction, route: route)))
        XCTAssertFalse(coordinator.shouldPresentWhileActive(AppNotificationPayload(kind: .turnComplete, route: route)))
        XCTAssertTrue(coordinator.shouldPresentWhileActive(AppNotificationPayload(kind: .feedback, route: nil)))

        visibility.visibleTabIDs = [tabID]
        XCTAssertFalse(coordinator.shouldPresentWhileActive(AppNotificationPayload(kind: .interaction, route: route)))
    }

    func testFailedAddIsRetriedOnTheNextPass() async {
        let coordinator = makeCoordinator()
        let interactionID = UUID()
        struct AddFailure: Error {}
        center.addError = AddFailure()

        coordinator.update(windowID: 7, states: [state(tabID: UUID(), interaction: question(id: interactionID))])
        await coordinator.waitForIdleForTesting()
        XCTAssertFalse(coordinator.postedInteractionIDsForTesting.contains(interactionID))

        center.addError = nil
        await coordinator.forceReconcileForTesting()
        XCTAssertTrue(coordinator.postedInteractionIDsForTesting.contains(interactionID))
        XCTAssertEqual(center.addedRequests.last?.identifier, AppNotificationIdentifier.interaction(interactionID))
    }

    func testTurnPostQueuedBeforeVisibilityIsDroppedInTheSamePass() async {
        let coordinator = makeCoordinator()
        let tabID = UUID()
        coordinator.update(windowID: 7, states: [state(tabID: tabID, interaction: nil)])
        coordinator.postTurnOutcome(.completed(preview: "Done"), for: state(tabID: tabID, interaction: nil))
        // The session becomes visible before the queued post is delivered.
        visibility.isAppActive = true
        visibility.visibleTabIDs = [tabID]
        preferences.currentNotificationPreferences.completionsWhileActive = true

        await coordinator.waitForIdleForTesting()

        XCTAssertFalse(center.addedRequests.contains { $0.identifier == AppNotificationIdentifier.turnComplete(tabID: tabID) })
    }

    func testTurnCompletePayloadCarriesTurnMarker() async throws {
        let coordinator = makeCoordinator()
        let tabID = UUID()
        var turnState = state(tabID: tabID, interaction: nil)
        turnState.turnMarker = "3:abc"
        coordinator.postTurnOutcome(.completed(preview: "Done"), for: turnState)
        await coordinator.waitForIdleForTesting()

        let payload = try XCTUnwrap(center.addedRequests.last?.payload)
        XCTAssertEqual(payload.turnMarker, "3:abc")
        XCTAssertEqual(AppNotificationPayload.parse(payload.userInfo)?.turnMarker, "3:abc")
    }

    func testUnavailableClientIsInert() async {
        center.isAvailable = false
        let coordinator = makeCoordinator()
        coordinator.update(windowID: 7, states: [state(tabID: UUID(), interaction: question(id: UUID()))])
        await coordinator.waitForIdleForTesting()
        XCTAssertTrue(center.addedRequests.isEmpty)
        XCTAssertTrue(center.badgeCounts.isEmpty)
    }
}
