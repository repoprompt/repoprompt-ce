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

    #if DEBUG
        func testExactRootReusePreservesSaveCommittedBeforeReceiptPublication() async throws {
            let fixture = try ActivationFixture()
            defer { fixture.remove() }
            let authority = fixture.authority()
            let saved = try fixture.document(name: "Saved", repoPaths: [fixture.root.path])
            let created = await authority.execute(.init(
                operationID: UUID(),
                origin: .appPresentation(windowID: 1),
                command: .createWorkspace(saved)
            ))
            XCTAssertEqual(created.disposition, .applied)
            let working = try fixture.document(name: "Working", repoPaths: [fixture.root.path])
            let updated = await authority.execute(.init(
                operationID: UUID(),
                expectedWorkspaceRevision: created.after?.workingRevision,
                origin: .appPresentation(windowID: 1),
                command: .replaceWorkingDocument(working)
            ))
            XCTAssertEqual(updated.disposition, .applied)
            let dirty = try XCTUnwrap(updated.workspace)
            XCTAssertNotNil(dirty.revisions.dirtyRevision)
            let save = DomainWorkspaceCommandEnvelope(
                operationID: UUID(),
                expectedWorkspaceRevision: dirty.revisions.workingRevision,
                origin: .appPresentation(windowID: 1),
                command: .saveWorkspaceDocument(workspaceID: fixture.workspaceID)
            )
            // Save does not take the catalog gate. Complete it after the reuse receipt
            // reaches disk but before the awaiting reuse publishes its in-memory result.
            await authority.testSetAfterUnchangedPersistence { workspaceID in
                XCTAssertEqual(workspaceID, fixture.workspaceID)
                await authority.testSetAfterUnchangedPersistence(nil)
                let result = await authority.execute(save)
                XCTAssertEqual(result.disposition, .applied)
                XCTAssertNil(result.workspace?.revisions.dirtyRevision)
            }
            let reuse = DomainWorkspaceCommandEnvelope(
                operationID: UUID(),
                origin: .appPresentation(windowID: 1),
                command: .resolveOrCreateWorkspaceForExactRoot(
                    document: working,
                    canonicalRootPath: fixture.root.standardizedFileURL.path.lowercased()
                )
            )
            let result = await authority.execute(reuse)
            XCTAssertEqual(result.disposition, .unchanged)
            XCTAssertEqual(result.exactRootResolution, .reused)
            let returned = try XCTUnwrap(result.workspace)
            XCTAssertNil(returned.revisions.dirtyRevision)
            XCTAssertEqual(returned.revisions.savedRevision, dirty.revisions.workingRevision)
            let current = await authority.canonicalWorkspaceSnapshot(fixture.workspaceID)
            XCTAssertEqual(current?.revisions, returned.revisions)
            XCTAssertNil(current?.revisions.dirtyRevision)
            let cold = await fixture.authority().activationSnapshot(
                workspaceID: fixture.workspaceID,
                fileURL: working.fileURL
            )
            XCTAssertEqual(current?.revisions, cold.workspace?.revisions)
            XCTAssertEqual(current?.document.contentDigest, working.contentDigest)
            let replay = await authority.execute(reuse)
            XCTAssertEqual(replay.disposition, .deduplicated)
            XCTAssertEqual(replay.exactRootResolution, .reused)
            XCTAssertEqual(replay.workspace?.revisions, cold.workspace?.revisions)
            let saveReplay = await authority.execute(save)
            XCTAssertEqual(saveReplay.disposition, .deduplicated)
        }
    #endif

    func testMetadataDecodeUsesDeterministicLegacyRecencyAndPreservesDocumentBytes() throws {
        let workspaceID = UUID()
        let fileURL = URL(fileURLWithPath: "/tmp/legacy-workspace.json")
        var object: [String: Any] = [
            "id": workspaceID.uuidString,
            "name": "Legacy",
            "repoPaths": [],
            "dateModified": 0,
            "unknownFutureField": ["preserve": true]
        ]

        func decode() throws -> DomainWorkspaceDocument {
            let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let document = try DomainWorkspaceDocument.decode(documentBytes: bytes, fileURL: fileURL)
            XCTAssertEqual(document.documentBytes, bytes)
            return document
        }

        var document = try decode()
        XCTAssertEqual(document.metadata.lastUsed, Date(timeIntervalSinceReferenceDate: 0))

        object["dateModified"] = 1
        object["lastUsed"] = true
        document = try decode()
        XCTAssertEqual(document.metadata.lastUsed, Date(timeIntervalSinceReferenceDate: 1))

        object["lastUsed"] = 0
        document = try decode()
        XCTAssertEqual(document.metadata.lastUsed, Date(timeIntervalSinceReferenceDate: 0))

        object["dateModified"] = "invalid"
        object["lastUsed"] = "invalid"
        document = try decode()
        XCTAssertEqual(document.metadata.lastUsed, .distantPast)
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

    func document(name: String, retiredInto: UUID? = nil, repoPaths: [String] = []) throws -> DomainWorkspaceDocument {
        var object: [String: Any] = [
            "id": workspaceID.uuidString, "name": name, "schemaVersion": 1,
            "repoPaths": repoPaths, "isSystemWorkspace": false,
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
