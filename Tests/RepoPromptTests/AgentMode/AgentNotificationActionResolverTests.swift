import Foundation
@testable import RepoPromptApp
import XCTest

/// Target double backed by real `AgentTabSession`s. Mutators mirror the view model's id-checked
/// forwards: they only consume the interaction whose id they were given.
@MainActor
private final class FakeNotificationActionTarget: AgentNotificationActionTarget {
    var sessions: [UUID: AgentTabSession] = [:]
    var mcpControlledTabIDs: Set<UUID> = []
    private(set) var approvals: [(UUID, AgentApprovalDecision)] = []
    private(set) var declinedPermissions: [UUID] = []
    private(set) var askUserDrafts: [[String: AgentAskUserDraft]] = []
    private(set) var skippedAskUser: [UUID] = []
    private(set) var userInputAnswers: [[String: [String]]] = []
    private(set) var instructions: [String] = []
    var instructionAccepted = true

    func notificationSession(tabID: UUID) -> AgentTabSession? {
        sessions[tabID]
    }

    func notificationSessionIsMCPControlled(tabID: UUID) -> Bool {
        mcpControlledTabIDs.contains(tabID)
    }

    func notificationSubmitApproval(tabID: UUID, requestID: UUID, decision: AgentApprovalDecision) -> Bool {
        guard let session = sessions[tabID], session.pendingApproval?.id == requestID else { return false }
        approvals.append((requestID, decision))
        session.pendingApproval = nil
        return true
    }

    func notificationDeclinePermissions(tabID: UUID, requestID: UUID) -> Bool {
        guard let session = sessions[tabID], session.pendingPermissionsRequest?.id == requestID else { return false }
        declinedPermissions.append(requestID)
        session.pendingPermissionsRequest = nil
        return true
    }

    func notificationSubmitAskUser(
        tabID: UUID,
        interactionID: UUID,
        draftsByQuestionID: [String: AgentAskUserDraft]
    ) throws -> Bool {
        guard let session = sessions[tabID], let pending = session.pendingAskUser, pending.interaction.id == interactionID else {
            return false
        }
        _ = try pending.interaction.buildSubmittedResponse(drafts: draftsByQuestionID, elapsedSeconds: 0)
        askUserDrafts.append(draftsByQuestionID)
        session.pendingAskUser = nil
        return true
    }

    func notificationSkipAskUser(tabID: UUID, interactionID: UUID) -> Bool {
        guard let session = sessions[tabID], session.pendingAskUser?.interaction.id == interactionID else { return false }
        skippedAskUser.append(interactionID)
        session.pendingAskUser = nil
        return true
    }

    func notificationSubmitUserInput(tabID: UUID, requestID: UUID, answers: [String: [String]]) -> Bool {
        guard let session = sessions[tabID], session.pendingUserInputRequest?.id == requestID else { return false }
        userInputAnswers.append(answers)
        session.pendingUserInputRequest = nil
        return true
    }

    func notificationSubmitInstruction(tabID: UUID, text: String) -> Bool {
        instructions.append(text)
        return instructionAccepted
    }
}

@MainActor
final class AgentNotificationActionResolverTests: XCTestCase {
    private var target: FakeNotificationActionTarget!
    private var session: AgentTabSession!
    private let tabID = UUID()

    override func setUp() async throws {
        target = FakeNotificationActionTarget()
        session = AgentTabSession(tabID: tabID)
        target.sessions[tabID] = session
    }

    private func installApproval(command: String = "swift test", id: UUID = UUID()) -> UUID {
        session.pendingApproval = AgentApprovalRequest(
            id: id,
            requestID: .acp("req"),
            method: "session/request_permission",
            kind: .commandExecution,
            threadID: "t",
            turnID: "t",
            itemID: "i",
            command: command
        )
        return id
    }

    private func installAskUser(options: [String] = ["Yes", "No"], allowsCustom: Bool = true) -> UUID {
        let id = UUID()
        session.pendingAskUser = AgentAskUserPendingState(interaction: AgentAskUserInteraction(
            id: id,
            questions: [AgentAskUserQuestion(
                id: "q1",
                question: "Proceed?",
                options: options.map { AgentAskUserOption(label: $0) },
                allowsCustom: allowsCustom
            )]
        ))
        return id
    }

    /// Captures the reference exactly as the planner would have posted it.
    private func reference() throws -> AppNotificationPayload.InteractionReference {
        let descriptor = try XCTUnwrap(AgentPendingInteractionDescriptor.make(from: session))
        return .init(id: descriptor.id, kind: descriptor.kind, fingerprint: descriptor.fingerprint)
    }

    private func resolve(
        _ action: AgentNotificationActionIdentity,
        reference: AppNotificationPayload.InteractionReference?,
        text: String? = nil,
        kind: AppNotificationKind = .interaction,
        sessionID: UUID? = nil,
        turnMarker: String? = nil,
        preferences: NotificationPreferences = .defaults
    ) -> AgentNotificationActionOutcome {
        AgentNotificationActionResolver.resolve(
            AgentNotificationActionRequest(
                notificationKind: kind,
                tabID: tabID,
                sessionID: sessionID,
                interaction: reference,
                action: action,
                userText: text,
                turnMarker: turnMarker
            ),
            target: target,
            preferences: preferences
        )
    }

    // MARK: Approvals

    func testApproveAppliesExactlyOnce() throws {
        let id = installApproval()
        let reference = try reference()

        XCTAssertEqual(resolve(.approve, reference: reference), .applied)
        XCTAssertEqual(target.approvals.map(\.0), [id])
        XCTAssertEqual(target.approvals.first?.1, .accept)

        XCTAssertEqual(resolve(.approve, reference: reference), .stale, "A second press finds nothing pending")
        XCTAssertEqual(target.approvals.count, 1)
    }

    func testApproveNeverReachesAReplacementInteraction() throws {
        _ = installApproval()
        let reference = try reference()
        _ = installApproval(command: "swift test") // new id, same text

        XCTAssertEqual(resolve(.approve, reference: reference), .stale)
        XCTAssertTrue(target.approvals.isEmpty)
    }

    func testFingerprintMismatchIsStaleEvenWithSameID() throws {
        let id = installApproval(command: "ls")
        let reference = try reference()
        _ = installApproval(command: "ls -la", id: id)

        XCTAssertEqual(resolve(.approve, reference: reference), .stale)
        XCTAssertTrue(target.approvals.isEmpty)
    }

    func testApproveIsReValidatedAgainstCurrentPreferencesAndRisk() throws {
        _ = installApproval()
        let reference = try reference()
        var noApprove = NotificationPreferences.defaults
        noApprove.approveFromNotifications = false

        XCTAssertEqual(resolve(.approve, reference: reference, preferences: noApprove), .ineligible)
        XCTAssertTrue(target.approvals.isEmpty)

        XCTAssertEqual(resolve(.decline, reference: reference, preferences: noApprove), .applied)
        XCTAssertEqual(target.approvals.first?.1, .decline)
    }

    func testForgedApproveOnHighRiskCommandIsIneligible() throws {
        _ = installApproval(command: "rm -rf build")
        XCTAssertEqual(try resolve(.approve, reference: reference()), .ineligible)
        XCTAssertTrue(target.approvals.isEmpty)
    }

    func testMCPControlledSessionRejectsBackgroundActions() throws {
        _ = installApproval()
        target.mcpControlledTabIDs = [tabID]
        XCTAssertEqual(try resolve(.decline, reference: reference()), .ineligible)
        XCTAssertTrue(target.approvals.isEmpty)
    }

    func testSessionIncarnationMismatchIsStale() throws {
        _ = installApproval()
        XCTAssertEqual(try resolve(.approve, reference: reference(), sessionID: UUID()), .stale)
    }

    func testUnknownTabIsStale() {
        target.sessions = [:]
        XCTAssertEqual(
            resolve(.approve, reference: .init(id: UUID(), kind: .approval, fingerprint: "x")),
            .stale
        )
    }

    func testPermissionsOnlyAllowDecline() throws {
        let id = UUID()
        session.pendingPermissionsRequest = AgentPermissionsRequest(
            id: id,
            requestID: .int(1),
            method: "item/permissions/requestApproval",
            threadID: "t",
            turnID: "t",
            itemID: "i",
            cwd: "/tmp",
            permissionsJSON: "{}"
        )
        let reference = try reference()
        XCTAssertEqual(resolve(.approve, reference: reference), .ineligible)
        XCTAssertEqual(resolve(.decline, reference: reference), .applied)
        XCTAssertEqual(target.declinedPermissions, [id])
    }

    // MARK: Questions

    func testChoiceMapsToSelectedOption() throws {
        _ = installAskUser()
        XCTAssertEqual(try resolve(.choice(index: 1), reference: reference()), .applied)
        XCTAssertEqual(target.askUserDrafts.first?["q1"], AgentAskUserDraft(selectedOptionLabels: ["No"]))
    }

    func testOutOfRangeChoiceIsIneligible() throws {
        _ = installAskUser()
        XCTAssertEqual(try resolve(.choice(index: 5), reference: reference()), .ineligible)
        XCTAssertTrue(target.askUserDrafts.isEmpty)
    }

    func testReplyBecomesCustomResponseOrExactOption() throws {
        _ = installAskUser()
        XCTAssertEqual(try resolve(.reply, reference: reference(), text: "  maybe later  "), .applied)
        XCTAssertEqual(target.askUserDrafts.last?["q1"], AgentAskUserDraft(customResponse: "maybe later"))

        _ = installAskUser()
        XCTAssertEqual(try resolve(.reply, reference: reference(), text: "Yes"), .applied)
        XCTAssertEqual(target.askUserDrafts.last?["q1"], AgentAskUserDraft(selectedOptionLabels: ["Yes"]))
    }

    func testEmptyReplyIsInvalidAndLeavesQuestionPending() throws {
        let id = installAskUser()
        XCTAssertEqual(try resolve(.reply, reference: reference(), text: "   "), .invalidInput)
        XCTAssertEqual(session.pendingAskUser?.interaction.id, id)
    }

    func testReplyNotOfferedWhenCustomAnswersAreDisallowed() throws {
        _ = installAskUser(allowsCustom: false)
        XCTAssertEqual(try resolve(.reply, reference: reference(), text: "free text"), .ineligible)
    }

    func testSkip() throws {
        let id = installAskUser()
        XCTAssertEqual(try resolve(.skip, reference: reference()), .applied)
        XCTAssertEqual(target.skippedAskUser, [id])
    }

    func testUserInputChoiceAndOtherNote() throws {
        let id = UUID()
        session.pendingUserInputRequest = AgentRequestUserInputRequest(
            id: id,
            requestID: .int(9),
            method: "item/tool/requestUserInput",
            threadID: "t",
            turnID: "t",
            itemID: "i",
            questions: [AgentRequestUserInputQuestion(
                id: "mode",
                header: "Mode",
                question: "Which mode?",
                isOther: true,
                isSecret: false,
                options: [.init(label: "Fast", description: ""), .init(label: "Safe", description: "")]
            )]
        )
        let reference = try reference()
        XCTAssertEqual(resolve(.reply, reference: reference, text: "custom"), .applied)
        XCTAssertEqual(target.userInputAnswers.last?["mode"], [AgentRequestUserInputQuestion.otherOptionLabel, "user_note: custom"])
    }

    func testInstructionReplyGoesThroughComposerSubmission() async throws {
        let session = try XCTUnwrap(session)
        session.instructionWaitID = UUID()
        session.waitingPrompt = "What next?"
        session.runState = .waitingForUser
        let wait = Task { @MainActor in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UserInstructionResponse, Error>) in
                session.instructionContinuation = continuation
            }
        }
        for _ in 0 ..< 50 where session.instructionContinuation == nil {
            await Task.yield()
        }
        let reference = try reference()
        XCTAssertEqual(reference.kind, .instruction)

        XCTAssertEqual(resolve(.reply, reference: reference, text: "Run the tests"), .applied)
        XCTAssertEqual(target.instructions, ["Run the tests"])

        session.instructionContinuation?.resume(throwing: CancellationError())
        session.instructionContinuation = nil
        _ = try? await wait.value
    }

    // MARK: Turn complete reply

    func testTurnCompleteReplyRequiresOptInAndIdleSession() throws {
        let session = try XCTUnwrap(session)
        let marker = AgentNotificationTurnMarker.make(from: session)
        XCTAssertEqual(resolve(.reply, reference: nil, text: "next", kind: .turnComplete, turnMarker: marker), .ineligible)

        var optIn = NotificationPreferences.defaults
        optIn.replyFromCompletion = true
        XCTAssertEqual(
            resolve(.reply, reference: nil, text: "next", kind: .turnComplete, turnMarker: marker, preferences: optIn),
            .applied
        )
        XCTAssertEqual(target.instructions, ["next"])

        session.runState = .running
        XCTAssertEqual(
            resolve(.reply, reference: nil, text: "again", kind: .turnComplete, turnMarker: marker, preferences: optIn),
            .stale
        )
        XCTAssertEqual(target.instructions, ["next"])
    }

    func testTurnCompleteReplyForAnOlderTurnIsStale() throws {
        let session = try XCTUnwrap(session)
        var optIn = NotificationPreferences.defaults
        optIn.replyFromCompletion = true
        let olderMarker = AgentNotificationTurnMarker.make(from: session)
        session.appendItem(.user("a newer turn", sequenceIndex: session.nextSequenceIndex))

        XCTAssertNotEqual(AgentNotificationTurnMarker.make(from: session), olderMarker)
        XCTAssertEqual(
            resolve(.reply, reference: nil, text: "late", kind: .turnComplete, turnMarker: olderMarker, preferences: optIn),
            .stale
        )
        XCTAssertEqual(
            resolve(.reply, reference: nil, text: "late", kind: .turnComplete, turnMarker: nil, preferences: optIn),
            .stale,
            "A turn-complete notification without a marker can never reply"
        )
        XCTAssertTrue(target.instructions.isEmpty)
    }

    func testFeedbackAndFailureNotificationsCannotAct() {
        XCTAssertEqual(resolve(.approve, reference: nil, kind: .turnFailed), .ineligible)
        XCTAssertEqual(resolve(.approve, reference: nil, kind: .feedback), .ineligible)
    }
}
