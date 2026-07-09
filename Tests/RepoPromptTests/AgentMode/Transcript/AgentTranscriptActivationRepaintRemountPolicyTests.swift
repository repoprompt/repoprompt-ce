@testable import RepoPromptApp
import XCTest

final class AgentTranscriptActivationRepaintRemountPolicyTests: XCTestCase {
    func testEnteredHydratedLiveBottomActivationProducesRemountKey() {
        let tabID = UUID()
        let key = AgentTranscriptActivationRepaintRemountPolicy.remountKey(
            oldSignal: AgentTranscriptRestoreSignal(tabID: UUID(), bindingsHydrated: true, presentationRevision: 1),
            newSignal: AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: true, presentationRevision: 7),
            currentTabID: tabID,
            rehydratePhase: .awaitingHydration(tabID: tabID, target: .liveBottom),
            lastRemountKey: nil,
            remountCount: 0,
            layoutPassToken: 42
        )

        XCTAssertEqual(key, AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 7, layoutPassToken: 42))
    }

    func testDuplicateRevisionExceededLimitDetachedOrIdleActivationSuppressesRemount() {
        let tabID = UUID()
        let oldSignal = AgentTranscriptRestoreSignal(tabID: nil, bindingsHydrated: false, presentationRevision: 0)
        let newSignal = AgentTranscriptRestoreSignal(tabID: tabID, bindingsHydrated: true, presentationRevision: 3)
        let previousKey = AgentTranscriptRehydrateRetryKey(tabID: tabID, presentationRevision: 3, layoutPassToken: 1)

        XCTAssertNil(AgentTranscriptActivationRepaintRemountPolicy.remountKey(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .awaitingLayout(tabID: tabID, presentationRevision: 3, target: .liveBottom),
            lastRemountKey: previousKey,
            remountCount: 0,
            layoutPassToken: 2
        ))
        XCTAssertNil(AgentTranscriptActivationRepaintRemountPolicy.remountKey(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .awaitingLayout(tabID: tabID, presentationRevision: 3, target: .liveBottom),
            lastRemountKey: nil,
            remountCount: AgentTranscriptActivationRepaintRemountPolicy.maximumRemountsPerActivation,
            layoutPassToken: 2
        ))
        XCTAssertNil(AgentTranscriptActivationRepaintRemountPolicy.remountKey(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .awaitingHydration(tabID: tabID, target: .detached(nil)),
            lastRemountKey: nil,
            remountCount: 0,
            layoutPassToken: 0
        ))
        XCTAssertNil(AgentTranscriptActivationRepaintRemountPolicy.remountKey(
            oldSignal: oldSignal,
            newSignal: newSignal,
            currentTabID: tabID,
            rehydratePhase: .idle,
            lastRemountKey: nil,
            remountCount: 0,
            layoutPassToken: 0
        ))
    }
}
