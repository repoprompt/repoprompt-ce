import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainWorkspaceProtectedTabRecoveryTests: XCTestCase {
    func testStaleWorkingCommitCannotReplayOverNewAgentTab() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stale = fixture.authority()
        let created = await stale.execute(fixture.command(.createWorkspace(try fixture.document(name: "Initial"))))
        XCTAssertEqual(created.disposition, .applied)

        let current = fixture.authority()
        _ = await current.readySnapshot()
        let newer = try fixture.document(name: "Newer", protectedTab: .agent)
        let added = await current.execute(fixture.command(.replaceWorkingDocument(newer)))
        XCTAssertEqual(added.disposition, .applied)
        let saved = await current.execute(fixture.command(.saveWorkspaceDocument(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(saved.disposition, .applied)

        let staleEdit = try fixture.document(name: "Stale edit")
        let replay = await stale.execute(fixture.command(.replaceWorkingDocument(staleEdit)))
        XCTAssertEqual(replay.disposition, .conflict)
        XCTAssertEqual(replay.diagnostic, "durable_replay_protected_agent_identity_missing")
        XCTAssertEqual(replay.workspace?.document.contentDigest, newer.contentDigest)
        XCTAssertEqual(try Data(contentsOf: newer.fileURL), newer.documentBytes)
    }

    func testStaleSaveCannotReplayOverNewPinnedTab() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stale = fixture.authority()
        let created = await stale.execute(fixture.command(.createWorkspace(try fixture.document(name: "Initial"))))
        XCTAssertEqual(created.disposition, .applied)
        let local = try fixture.document(name: "Unsaved local edit")
        let edited = await stale.execute(fixture.command(.replaceWorkingDocument(local)))
        XCTAssertEqual(edited.disposition, .applied)

        let current = fixture.authority()
        _ = await current.readySnapshot()
        let newer = try fixture.document(name: "Newer", protectedTab: .pinned)
        let added = await current.execute(fixture.command(.replaceWorkingDocument(newer)))
        XCTAssertEqual(added.disposition, .applied)

        let replay = await stale.execute(fixture.command(.saveWorkspaceDocument(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(replay.disposition, .conflict)
        XCTAssertEqual(replay.diagnostic, "durable_save_revision_replay_pending")
        XCTAssertEqual(replay.workspace?.document.contentDigest, newer.contentDigest)
        let saved = await current.execute(fixture.command(.saveWorkspaceDocument(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(saved.disposition, .applied)
        XCTAssertEqual(try Data(contentsOf: newer.fileURL), newer.documentBytes)
    }

    func testDirtyExternalRebaseCannotOverwriteNewAgentTab() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authority = fixture.authority()
        let created = await authority.execute(fixture.command(.createWorkspace(try fixture.document(name: "Initial"))))
        XCTAssertEqual(created.disposition, .applied)
        let edited = await authority.execute(fixture.command(.replaceWorkingDocument(try fixture.document(name: "Unsaved local edit"))))
        XCTAssertEqual(edited.disposition, .applied)

        let external = try fixture.document(name: "External", protectedTab: .agent)
        try external.documentBytes.write(to: external.fileURL, options: .atomic)
        _ = await authority.reloadExternalChanges()
        XCTAssertEqual(try Data(contentsOf: external.fileURL), external.documentBytes)

        let save = await authority.execute(fixture.command(.saveWorkspaceDocument(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(save.disposition, .conflict)
        XCTAssertEqual(try Data(contentsOf: external.fileURL), external.documentBytes)
    }

    func testCleanExternalReloadCannotDropExistingAgentTab() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authority = fixture.authority()
        let protected = try fixture.document(name: "Protected", protectedTab: .agent)
        let created = await authority.execute(fixture.command(.createWorkspace(protected)))
        XCTAssertEqual(created.disposition, .applied)

        let external = try fixture.document(name: "External without Agent tab")
        try external.documentBytes.write(to: external.fileURL, options: .atomic)
        _ = await authority.reloadExternalChanges()

        let local = await authority.agentAdmissionSnapshot(fixture.workspaceID)
        XCTAssertEqual(local.snapshot?.document.contentDigest, protected.contentDigest)
        XCTAssertEqual(try Data(contentsOf: external.fileURL), external.documentBytes)
    }

    func testIntentionalSameAuthorityRemovalOfAgentTabStillApplies() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let authority = fixture.authority()
        let protected = try fixture.document(name: "Protected", protectedTab: .agent)
        let created = await authority.execute(fixture.command(.createWorkspace(protected)))
        XCTAssertEqual(created.disposition, .applied)

        let removed = try fixture.document(name: "Intentionally removed")
        let replaced = await authority.execute(fixture.command(.replaceWorkingDocument(removed)))
        XCTAssertEqual(replaced.disposition, .applied)
        let saved = await authority.execute(fixture.command(.saveWorkspaceDocument(workspaceID: fixture.workspaceID)))
        XCTAssertEqual(saved.disposition, .applied)
        XCTAssertEqual(try Data(contentsOf: removed.fileURL), removed.documentBytes)
    }
}

private enum ProtectedTab {
    case agent
    case pinned
}

private struct Fixture {
    let root: URL
    let workspaceID = UUID()
    let contextID = UUID()
    let protectedContextID = UUID()
    let agentSessionID = UUID()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ProtectedTabRecovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func authority() -> DomainWorkspaceContextAuthority {
        let configuration = DomainRuntimeConfiguration(
            mode: .app,
            profileIdentifier: "protected-tab-recovery",
            storageDirectory: root,
            workspaceStorageDirectory: root.appendingPathComponent("Workspaces"),
            eventDirectory: root.appendingPathComponent("Events"),
            temporaryDirectory: root.appendingPathComponent("tmp"),
            externalReloadInterval: nil
        )
        let identity = DomainRuntimeIdentity(runtimeID: UUID(), lifecycleGeneration: 1, processID: 0, mode: .app, createdAt: Date())
        return .init(identity: identity, persistence: .init(configuration: configuration, identity: identity), metrics: .disabled)
    }

    func command(_ command: DomainWorkspaceCommand) -> DomainWorkspaceCommandEnvelope {
        .init(operationID: UUID(), origin: .appPresentation(windowID: 1), command: command)
    }

    func document(name: String, protectedTab: ProtectedTab? = nil) throws -> DomainWorkspaceDocument {
        var tabs: [[String: Any]] = [["id": contextID.uuidString, "name": "Ordinary tab"]]
        if let protectedTab {
            var tab: [String: Any] = ["id": protectedContextID.uuidString, "name": "Protected tab"]
            switch protectedTab {
            case .agent:
                tab["activeAgentSessionID"] = agentSessionID.uuidString
            case .pinned:
                tab["isPinned"] = true
            }
            tabs.append(tab)
        }
        let object: [String: Any] = [
            "id": workspaceID.uuidString,
            "name": name,
            "schemaVersion": 1,
            "repoPaths": ["/private-repository"],
            "isSystemWorkspace": false,
            "composeTabs": tabs,
            "activeComposeTabID": contextID.uuidString
        ]
        return try .decode(
            documentBytes: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            fileURL: root.appendingPathComponent("Workspaces/\(workspaceID.uuidString)/workspace.json")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
