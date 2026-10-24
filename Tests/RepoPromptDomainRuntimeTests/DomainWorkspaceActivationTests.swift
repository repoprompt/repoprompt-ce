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

    func testColdReadLocationReportsNotReadyWithoutBootstrappingKnownCatalog() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.remove() }
        let writer = fixture.authority()
        let document = try fixture.document(name: "Registered")
        let created = await writer.execute(.init(
            operationID: UUID(), origin: .appPresentation(windowID: 1), command: .createWorkspace(document)
        ))
        XCTAssertEqual(created.disposition, .applied)

        let cold = fixture.authority()
        let store = DomainWorkspaceStore(authority: cold)
        let byID = await store.readLocation(matching: .id(fixture.workspaceID))
        let byName = await store.readLocation(matching: .exactName("Registered"))
        XCTAssertEqual(byID, .notReady)
        XCTAssertEqual(byName, .notReady)
        let snapshot = await cold.snapshot()
        XCTAssertFalse(snapshot.isBootstrapped)
        XCTAssertTrue(snapshot.workspaces.isEmpty, "A location read must not publish a partial or bootstrapped catalog")
    }

    func testReadLocationUsesCurrentCanonicalNameAndCustomDirectoryInsteadOfSavedBytesOrReadOverlay() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.remove() }
        let authority = fixture.authority()
        let store = DomainWorkspaceStore(authority: authority)
        let fileURL = fixture.root.appendingPathComponent("CustomStorage/workspace.json")
        let saved = try fixture.document(name: "Saved", fileURL: fileURL)
        let created = await store.execute(.init(
            operationID: UUID(), origin: .appPresentation(windowID: 1), command: .createWorkspace(saved)
        ))
        XCTAssertEqual(created.disposition, .applied)
        let originalSelection = await store.readLocation(matching: .id(fixture.workspaceID))
        guard case let .matched(original) = originalSelection else { return XCTFail("Expected canonical location") }

        let working = try fixture.document(name: "Renamed", fileURL: fileURL)
        let updated = await store.execute(.init(
            operationID: UUID(), expectedWorkspaceRevision: created.after?.workingRevision,
            origin: .appPresentation(windowID: 1), command: .replaceWorkingDocument(working)
        ))
        XCTAssertEqual(updated.disposition, .applied)
        let overlay = try fixture.document(
            name: "Read Overlay", fileURL: fixture.root.appendingPathComponent("WrongLocation/workspace.json")
        )
        _ = await store.registerReadDocument(overlay)

        let selection = await store.readLocation(matching: .exactName(" \nrenamed\t"))
        guard case let .matched(current) = selection else { return XCTFail("Expected current canonical name") }
        XCTAssertEqual(current.workspaceID, fixture.workspaceID)
        XCTAssertEqual(current.runtimeID, original.runtimeID)
        XCTAssertEqual(current.name, "Renamed")
        XCTAssertEqual(current.directory, fileURL.deletingLastPathComponent().standardizedFileURL)
        XCTAssertGreaterThan(current.locationGeneration, original.locationGeneration)
        let byID = await store.readLocation(matching: .id(fixture.workspaceID))
        let savedName = await store.readLocation(matching: .exactName("Saved"))
        let overlayName = await store.readLocation(matching: .exactName("Read Overlay"))
        let partialName = await store.readLocation(matching: .exactName("Rename"))
        XCTAssertEqual(byID, selection)
        XCTAssertEqual(savedName, .notRegistered)
        XCTAssertEqual(overlayName, .notRegistered)
        XCTAssertEqual(partialName, .notRegistered, "Exact-name discovery must not silently use substring matching")
        let diskDocument = try DomainWorkspaceDocument.decode(documentBytes: Data(contentsOf: fileURL), fileURL: fileURL)
        XCTAssertEqual(diskDocument.metadata.name, "Saved", "The test must retain stale saved bytes")

        let unrelated = try fixture.document(name: "Unrelated", workspaceID: UUID())
        let unrelatedCreated = await store.execute(.init(
            operationID: UUID(), origin: .appPresentation(windowID: 1), command: .createWorkspace(unrelated)
        ))
        XCTAssertEqual(unrelatedCreated.disposition, .applied)
        let afterUnrelatedCreate = await store.readLocation(matching: .id(fixture.workspaceID))
        XCTAssertEqual(afterUnrelatedCreate, selection, "Unrelated publication must not invalidate selected location evidence")
    }

    func testReadLocationCannotReviveDeletedOrUnregisteredWorkspaceThroughReadOverlay() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.remove() }
        let authority = fixture.authority()
        let store = DomainWorkspaceStore(authority: authority)
        let document = try fixture.document(name: "Deleted")
        let created = await store.execute(.init(
            operationID: UUID(), origin: .appPresentation(windowID: 1), command: .createWorkspace(document)
        ))
        XCTAssertEqual(created.disposition, .applied)
        let deleted = await store.execute(.init(
            operationID: UUID(), expectedWorkspaceRevision: created.after?.workingRevision,
            origin: .appPresentation(windowID: 1), command: .deleteWorkspace(workspaceID: fixture.workspaceID)
        ))
        XCTAssertEqual(deleted.disposition, .applied)
        try FileManager.default.createDirectory(at: document.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.documentBytes.write(to: document.fileURL)
        _ = await store.registerReadDocument(document)
        let deletedByID = await store.readLocation(matching: .id(fixture.workspaceID))
        let deletedByName = await store.readLocation(matching: .exactName("Deleted"))
        XCTAssertEqual(deletedByID, .notRegistered)
        XCTAssertEqual(deletedByName, .notRegistered)

        let transient = try fixture.document(name: "Transient", workspaceID: UUID())
        _ = await store.registerReadDocument(transient)
        let transientByID = await store.readLocation(matching: .id(transient.workspaceID))
        let transientByName = await store.readLocation(matching: .exactName("Transient"))
        XCTAssertEqual(transientByID, .notRegistered)
        XCTAssertEqual(transientByName, .notRegistered)
    }

    func testReadLocationRejectsAmbiguousExactNamesAndUpdatesIndexAfterCanonicalRename() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.remove() }
        let store = DomainWorkspaceStore(authority: fixture.authority())
        let first = try fixture.document(name: "Shared")
        let second = try fixture.document(name: "SHARED", workspaceID: UUID())
        let firstCreated = await store.execute(.init(
            operationID: UUID(), origin: .appPresentation(windowID: 1), command: .createWorkspace(first)
        ))
        let secondCreated = await store.execute(.init(
            operationID: UUID(), origin: .appPresentation(windowID: 1), command: .createWorkspace(second)
        ))
        XCTAssertEqual(firstCreated.disposition, .applied)
        XCTAssertEqual(secondCreated.disposition, .applied)
        let ambiguous = await store.readLocation(matching: .exactName("shared"))
        XCTAssertEqual(ambiguous, .ambiguous)
        let firstByID = await store.readLocation(matching: .id(first.workspaceID))
        guard case let .matched(location) = firstByID else { return XCTFail("An ambiguous name must not block an exact UUID") }
        XCTAssertEqual(location.workspaceID, first.workspaceID)

        let renamed = try fixture.document(name: "Distinct", workspaceID: second.workspaceID)
        let updated = await store.execute(.init(
            operationID: UUID(), expectedWorkspaceRevision: secondCreated.after?.workingRevision,
            origin: .appPresentation(windowID: 1), command: .replaceWorkingDocument(renamed)
        ))
        XCTAssertEqual(updated.disposition, .applied)
        let unique = await store.readLocation(matching: .exactName("shared"))
        XCTAssertEqual(unique, firstByID)
    }

    func testReadLocationMarksNameCoverageUnavailableWithoutBlockingHealthyExactUUID() async throws {
        let fixture = try ActivationFixture()
        defer { fixture.remove() }
        let writer = fixture.authority()
        let healthy = try fixture.document(name: "Healthy")
        let missing = try fixture.document(name: "Missing", workspaceID: UUID())
        for document in [healthy, missing] {
            let created = await writer.execute(.init(
                operationID: UUID(), origin: .appPresentation(windowID: 1), command: .createWorkspace(document)
            ))
            XCTAssertEqual(created.disposition, .applied)
        }
        try FileManager.default.removeItem(at: missing.fileURL)

        let store = DomainWorkspaceStore(authority: fixture.authority())
        _ = await store.snapshot()
        let healthyByID = await store.readLocation(matching: .id(healthy.workspaceID))
        guard case let .matched(location) = healthyByID else { return XCTFail("Healthy exact location should remain available") }
        XCTAssertEqual(location.workspaceID, healthy.workspaceID)
        let missingByID = await store.readLocation(matching: .id(missing.workspaceID))
        let healthyByName = await store.readLocation(matching: .exactName("Healthy"))
        let absentByName = await store.readLocation(matching: .exactName("Absent"))
        XCTAssertEqual(missingByID, .unavailable)
        XCTAssertEqual(healthyByName, .unavailable, "An unreadable member may share this name")
        XCTAssertEqual(absentByName, .unavailable, "An unreadable member prevents a definitive no-match answer")
        _ = await store.registerReadDocument(missing)
        let afterOverlay = await store.readLocation(matching: .id(missing.workspaceID))
        XCTAssertEqual(afterOverlay, .unavailable, "A routing overlay cannot authorize unavailable canonical storage")
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

    func document(
        name: String,
        retiredInto: UUID? = nil,
        repoPaths: [String] = [],
        workspaceID: UUID? = nil,
        fileURL: URL? = nil
    ) throws -> DomainWorkspaceDocument {
        let workspaceID = workspaceID ?? self.workspaceID
        var object: [String: Any] = [
            "id": workspaceID.uuidString, "name": name, "schemaVersion": 1,
            "repoPaths": repoPaths, "isSystemWorkspace": false,
            "composeTabs": [["id": contextID.uuidString, "name": "T1"]],
            "activeComposeTabID": contextID.uuidString
        ]
        if let retiredInto { object["consolidatedIntoWorkspaceID"] = retiredInto.uuidString }
        return try DomainWorkspaceDocument.decode(
            documentBytes: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            fileURL: fileURL ?? root.appendingPathComponent("Workspaces/\(workspaceID.uuidString)/workspace.json")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
