import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainWorkspaceActivationTests: XCTestCase {
    func testColdActivationReadsWorkingDocumentWithoutBootstrappingCatalog() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.remove() }
        let writer = fixture.authority()
        let saved = try fixture.document(name: "Saved")
        let created = await writer.execute(.init(operationID: UUID(), origin: .appPresentation(windowID: 1), command: .createWorkspace(saved)))
        XCTAssertEqual(created.disposition, .applied)
        let working = try fixture.document(name: "Working", retiredInto: UUID())
        let updated = await writer.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: created.after?.workingRevision,
            origin: .appPresentation(windowID: 1),
            command: .replaceWorkingDocument(working)
        ))
        XCTAssertEqual(updated.disposition, .applied)

        let cold = fixture.authority()
        let activation = await cold.activationSnapshot(workspaceID: fixture.workspaceID, fileURL: saved.fileURL)
        XCTAssertEqual(activation.workspace?.document.contentDigest, working.contentDigest)
        XCTAssertNotNil(activation.workspace?.revisions.dirtyRevision)
        let catalog = await cold.snapshot()
        XCTAssertFalse(catalog.isBootstrapped, "A target activation must not initialize unrelated workspaces")
        XCTAssertTrue(catalog.workspaces.isEmpty, "The read must not publish a partial mutable catalog")
    }

    func testColdActivationRejectsDeletedWorkspaceEvenWhenSavedFileRemains() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.remove() }
        let writer = fixture.authority()
        let document = try fixture.document(name: "Deleted")
        let created = await writer.execute(.init(operationID: UUID(), origin: .appPresentation(windowID: 1), command: .createWorkspace(document)))
        XCTAssertEqual(created.disposition, .applied)
        let deleted = await writer.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: created.after?.workingRevision,
            origin: .appPresentation(windowID: 1),
            command: .deleteWorkspace(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(deleted.disposition, .applied)
        try FileManager.default.createDirectory(at: document.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.documentBytes.write(to: document.fileURL)
        let result = await fixture.authority().activationSnapshot(workspaceID: fixture.workspaceID, fileURL: document.fileURL)
        XCTAssertNil(result.workspace)
    }

    func testWarmActivationUsesCurrentAuthorityInsteadOfStaleSavedBytes() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.remove() }
        let authority = fixture.authority()
        let saved = try fixture.document(name: "Saved")
        let created = await authority.execute(.init(operationID: UUID(), origin: .appPresentation(windowID: 1), command: .createWorkspace(saved)))
        let working = try fixture.document(name: "Renamed")
        let updated = await authority.execute(.init(
            operationID: UUID(),
            expectedWorkspaceRevision: created.after?.workingRevision,
            origin: .appPresentation(windowID: 1),
            command: .replaceWorkingDocument(working)
        ))
        XCTAssertEqual(updated.disposition, .applied)
        let activation = await authority.activationSnapshot(workspaceID: fixture.workspaceID, fileURL: saved.fileURL)
        XCTAssertEqual(activation.workspace?.document.contentDigest, working.contentDigest)
    }
}

private struct ActivationFixture {
    let root: URL
    let workspaceID = UUID()
    let contextID = UUID()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DomainWorkspaceActivationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func authority() -> DomainWorkspaceContextAuthority {
        let configuration = DomainRuntimeConfiguration(
            mode: .app,
            profileIdentifier: "activation-tests",
            storageDirectory: root,
            workspaceStorageDirectory: root.appendingPathComponent("Workspaces", isDirectory: true),
            eventDirectory: root.appendingPathComponent("Events", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("tmp", isDirectory: true),
            externalReloadInterval: nil
        )
        let identity = DomainRuntimeIdentity(runtimeID: UUID(), lifecycleGeneration: 1, processID: 0, mode: .app, createdAt: Date())
        return DomainWorkspaceContextAuthority(identity: identity, persistence: .init(configuration: configuration, identity: identity), metrics: .disabled)
    }

    func document(name: String, retiredInto: UUID? = nil) throws -> DomainWorkspaceDocument {
        var object: [String: Any] = [
            "id": workspaceID.uuidString, "name": name, "schemaVersion": 1,
            "repoPaths": [], "isSystemWorkspace": false,
            "composeTabs": [["id": contextID.uuidString, "name": "T1"]],
            "activeComposeTabID": contextID.uuidString
        ]
        if let retiredInto { object["consolidatedIntoWorkspaceID"] = retiredInto.uuidString }
        return try DomainWorkspaceDocument.decode(
            documentBytes: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            fileURL: root.appendingPathComponent("Workspaces/\(workspaceID.uuidString)/workspace.json")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
