import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainRoutingBindingCASTests: XCTestCase {
    func testCompareAndSetBindingRejectsACompetingOtherWorkspaceBinding() async throws {
        let fixture = try RoutingFixture.make()
        let runtime = fixture.runtime()
        try await runtime.start()
        addTeardownBlock {
            _ = await runtime.shutdown()
            fixture.remove()
        }
        try await fixture.install(in: runtime)
        let scopeID = DomainStandaloneScopeID()
        _ = try await runtime.standaloneScopeCoordinator.register(
            scopeID: scopeID,
            connectionID: UUID(),
            workingDirectories: [fixture.primaryRoot]
        )
        let closed = DomainContextIdentity(workspaceID: fixture.primaryWorkspaceID, contextID: fixture.closedContextID)
        let other = DomainContextIdentity(workspaceID: fixture.secondaryWorkspaceID, contextID: fixture.otherContextID)
        let replacement = DomainContextIdentity(workspaceID: fixture.primaryWorkspaceID, contextID: fixture.replacementContextID)
        _ = try await runtime.standaloneScopeCoordinator.bind(scopeID: scopeID, context: closed)
        _ = try await runtime.standaloneScopeCoordinator.bind(scopeID: scopeID, context: other)

        let result = try await runtime.standaloneScopeCoordinator.compareAndSetBinding(
            scopeID: scopeID,
            expectedBinding: .context(closed, explicit: true),
            replacement: .context(replacement, explicit: true)
        )

        XCTAssertEqual(result.disposition.rawValue, "conflict")
        XCTAssertEqual(result.snapshot.binding, .context(other, explicit: true))
        XCTAssertFalse(result.snapshot.binding.ordinaryContextMatches(closed))
    }

    func testCompareAndSetBindingRejectsRunScopedBindingAndOrdinaryMatcherFailsClosed() async throws {
        let fixture = try RoutingFixture.make()
        let runtime = fixture.runtime()
        try await runtime.start()
        addTeardownBlock {
            _ = await runtime.shutdown()
            fixture.remove()
        }
        try await fixture.install(in: runtime)
        let scopeID = DomainStandaloneScopeID()
        let scope = try await runtime.standaloneScopeCoordinator.register(
            scopeID: scopeID,
            connectionID: UUID(),
            workingDirectories: [fixture.primaryRoot]
        )
        let closed = DomainContextIdentity(workspaceID: fixture.primaryWorkspaceID, contextID: fixture.closedContextID)
        let replacement = DomainContextIdentity(workspaceID: fixture.primaryWorkspaceID, contextID: fixture.replacementContextID)
        let runBinding = DomainBinding.runScoped(runID: UUID(), context: closed)
        _ = await runtime.routingCoordinator.bind(
            connection: scope.registration,
            binding: runBinding,
            operationID: UUID()
        )

        let result = try await runtime.standaloneScopeCoordinator.compareAndSetBinding(
            scopeID: scopeID,
            expectedBinding: .context(closed, explicit: true),
            replacement: .context(replacement, explicit: true)
        )

        XCTAssertEqual(result.disposition.rawValue, "conflict")
        XCTAssertEqual(result.snapshot.binding, runBinding)
        XCTAssertFalse(runBinding.ordinaryContextMatches(closed))
        XCTAssertTrue(DomainBinding.context(closed, explicit: true).ordinaryContextMatches(closed))
    }
}

private struct RoutingFixture {
    let root: URL
    let primaryRoot: URL
    let secondaryRoot: URL
    let storageRoot: URL
    let primaryWorkspaceID: UUID
    let secondaryWorkspaceID: UUID
    let closedContextID: UUID
    let replacementContextID: UUID
    let otherContextID: UUID

    static func make() throws -> RoutingFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("domain-routing-cas-\(UUID().uuidString)", isDirectory: true)
        let primaryRoot = root.appendingPathComponent("primary", isDirectory: true)
        let secondaryRoot = root.appendingPathComponent("secondary", isDirectory: true)
        let storageRoot = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: primaryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondaryRoot, withIntermediateDirectories: true)
        return RoutingFixture(
            root: root,
            primaryRoot: primaryRoot,
            secondaryRoot: secondaryRoot,
            storageRoot: storageRoot,
            primaryWorkspaceID: UUID(),
            secondaryWorkspaceID: UUID(),
            closedContextID: UUID(),
            replacementContextID: UUID(),
            otherContextID: UUID()
        )
    }

    func runtime() -> MCPDomainRuntime {
        MCPDomainRuntime(configuration: .init(
            mode: .standalone,
            profileIdentifier: "routing-cas",
            storageDirectory: storageRoot,
            eventDirectory: root.appendingPathComponent("events", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true),
            externalReloadInterval: nil
        ))
    }

    func install(in runtime: MCPDomainRuntime) async throws {
        let primary = try document(
            workspaceID: primaryWorkspaceID,
            roots: [primaryRoot],
            contexts: [closedContextID, replacementContextID],
            activeContextID: replacementContextID,
            fileName: "primary.json"
        )
        let secondary = try document(
            workspaceID: secondaryWorkspaceID,
            roots: [secondaryRoot],
            contexts: [otherContextID],
            activeContextID: otherContextID,
            fileName: "secondary.json"
        )
        _ = await runtime.workspaceStore.registerReadDocument(primary)
        _ = await runtime.workspaceStore.registerReadDocument(secondary)
    }

    private func document(
        workspaceID: UUID,
        roots: [URL],
        contexts: [UUID],
        activeContextID: UUID,
        fileName: String
    ) throws -> DomainWorkspaceDocument {
        let object: [String: Any] = [
            "id": workspaceID.uuidString,
            "schemaVersion": 1,
            "name": fileName,
            "repoPaths": roots.map(\.path),
            "isSystemWorkspace": false,
            "isHiddenInMenus": false,
            "activeComposeTabID": activeContextID.uuidString,
            "composeTabs": contexts.map { contextID in
                [
                    "id": contextID.uuidString,
                    "name": contextID.uuidString,
                    "prompt": "",
                    "selectedPaths": []
                ]
            }
        ]
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try DomainWorkspaceDocument.decode(
            documentBytes: bytes,
            fileURL: storageRoot.appendingPathComponent(fileName)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
