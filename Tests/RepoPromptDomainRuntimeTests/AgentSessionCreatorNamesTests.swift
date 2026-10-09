import Foundation
import RepoPromptDomainRuntime
import XCTest

final class AgentSessionCreatorNamesTests: XCTestCase {
    private func candidate(sessionID: UUID = UUID(), windowID: Int = 1, name: String) -> AgentSessionLinkEndpointCandidate {
        AgentSessionLinkEndpointCandidate(
            windowID: windowID, workspaceID: UUID(), tabID: UUID(), sessionID: sessionID,
            persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1,
            isTopLevel: true, hasLoadedPersistedState: true, bindingTransitionInProgress: false,
            isClosing: false, isMCPControlled: false, isMCPOriginated: false,
            roleAllowsOutboundMonitoring: true, displayName: name, providerDisplayName: nil, locationLabel: nil
        )
    }

    func testDuplicateUUIDNamesKeepFirstLiveMatchAcrossRenameAndClose() {
        let id = UUID()
        let first = candidate(sessionID: id, name: "First")
        let second = candidate(sessionID: id, windowID: 2, name: "Second")
        var names = AgentSessionCreatorNames()
        names.replaceLive([first, second])
        XCTAssertEqual(names.snapshot[id], "First")
        names.update(windowID: second.windowID, sources: [second.tabID: .init(
            workspaceID: second.workspaceID, sessionID: id, name: "Renamed second"
        )])
        XCTAssertEqual(names.snapshot[id], "First", "A duplicate's name cannot override the first live match")
        names.replaceLive([second])
        XCTAssertEqual(names.snapshot[id], "Second", "Live resolvedDisplayName beats last-known names")
        names.update(windowID: second.windowID, sources: [second.tabID: .init(
            workspaceID: second.workspaceID, sessionID: id, name: "Latest"
        )])
        names.update(windowID: second.windowID, sources: [:])
        XCTAssertEqual(names.snapshot[id], "Latest", "Synchronous rename capture survives source removal")
        names.remove(id)
        XCTAssertNil(names.snapshot[id], "Committed deletion prunes retained names")
    }

    func testSettledSourceRenameAfterLiveRemovalRefreshesOnlyKnownRetainedNames() {
        let creator = candidate(windowID: 2, name: "Remote before close")
        let unknownID = UUID()
        var names = AgentSessionCreatorNames()
        names.replaceLive([creator])
        names.replaceLive([])
        let sources: [UUID: AgentSessionCreatorNames.Source] = [
            creator.tabID: .init(workspaceID: creator.workspaceID, sessionID: creator.sessionID, name: "Reloaded after close"),
            UUID(): .init(workspaceID: creator.workspaceID, sessionID: unknownID, name: "Never live")
        ]
        names.update(windowID: 1, sources: sources)
        XCTAssertEqual(names.snapshot[creator.sessionID], "Reloaded after close")
        XCTAssertNil(names.snapshot[unknownID], "A non-live source cannot create retained membership")
        names.remove(creator.sessionID)
        names.update(windowID: 1, sources: sources)
        XCTAssertNil(names.snapshot[creator.sessionID], "A source rename cannot resurrect pruned deletion")
    }

    func testRetiredNameRetentionIsBoundedAndDoesNotEvictLiveNames() throws {
        let candidates = (0 ... AgentSessionCreatorNames.retentionLimit).map {
            candidate(name: "Creator \($0)")
        }
        var names = AgentSessionCreatorNames()
        names.replaceLive(candidates)
        XCTAssertEqual(names.snapshot.count, candidates.count)
        let first = try XCTUnwrap(candidates.first)
        let last = try XCTUnwrap(candidates.last)
        XCTAssertEqual(names.snapshot[first.sessionID], "Creator 0")
        names.replaceLive([])
        XCTAssertEqual(names.snapshot.count, AgentSessionCreatorNames.retentionLimit)
        XCTAssertNil(names.snapshot[first.sessionID])
        XCTAssertEqual(names.snapshot[last.sessionID], "Creator \(AgentSessionCreatorNames.retentionLimit)")
    }
}
