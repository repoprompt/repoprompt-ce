import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceCodemapBindingIntegrationRegistryTests: XCTestCase {
    func testRoutesByExactRootEpoch() async throws {
        let registry = WorkspaceCodemapBindingIntegrationRegistry()
        let sharedRootID = UUID()
        let firstEpoch = WorkspaceCodemapRootEpoch(rootID: sharedRootID, rootLifetimeID: UUID())
        let secondEpoch = WorkspaceCodemapRootEpoch(rootID: sharedRootID, rootLifetimeID: UUID())
        let missingEpoch = WorkspaceCodemapRootEpoch(rootID: sharedRootID, rootLifetimeID: UUID())
        let firstFileID = UUID()
        let secondFileID = UUID()
        let firstEndpoint = endpoint(rootEpoch: firstEpoch, fileID: firstFileID, marker: "first")
        let secondEndpoint = endpoint(rootEpoch: secondEpoch, fileID: secondFileID, marker: "second")
        let firstToken = await registry.register(rootEpoch: firstEpoch, endpoint: firstEndpoint)
        let secondToken = await registry.register(rootEpoch: secondEpoch, endpoint: secondEndpoint)
        XCTAssertNotNil(firstToken)
        XCTAssertNotNil(secondToken)

        let catalog = registry.makeBindingCatalogClient()
        let firstCandidate = await catalog.resolveManifestBinding(firstEpoch, "Sources/Value.swift")
        let secondCandidate = await catalog.resolveManifestBinding(secondEpoch, "Sources/Value.swift")
        XCTAssertEqual(firstCandidate?.identity.fileID, firstFileID)
        XCTAssertEqual(secondCandidate?.identity.fileID, secondFileID)
        let missingCandidate = await catalog.resolveManifestBinding(missingEpoch, "Sources/Value.swift")
        XCTAssertNil(missingCandidate)

        let firstPage = try await projectionPage(catalog.readProjectionCatalogPage(
            WorkspaceCodemapProjectionCatalogPageRequest(
                rootEpoch: firstEpoch,
                token: nil,
                cursor: nil,
                maximumEntryCount: 1,
                maximumPathByteCount: 64
            )
        ))
        let secondPage = try await projectionPage(catalog.readProjectionCatalogPage(
            WorkspaceCodemapProjectionCatalogPageRequest(
                rootEpoch: secondEpoch,
                token: nil,
                cursor: nil,
                maximumEntryCount: 1,
                maximumPathByteCount: 64
            )
        ))
        XCTAssertEqual(firstPage.token.rootEpoch, firstEpoch)
        XCTAssertEqual(secondPage.token.rootEpoch, secondEpoch)
        let currentToken = await catalog.revalidateProjectionCatalogToken(firstEpoch, firstPage.token)
        XCTAssertEqual(currentToken, .current)
        let foreignToken = await catalog.revalidateProjectionCatalogToken(firstEpoch, secondPage.token)
        XCTAssertEqual(foreignToken, .stale)
        let missingPage = await catalog.readProjectionCatalogPage(
            WorkspaceCodemapProjectionCatalogPageRequest(
                rootEpoch: missingEpoch,
                token: nil,
                cursor: nil,
                maximumEntryCount: 1,
                maximumPathByteCount: 64
            )
        )
        XCTAssertEqual(missingPage, .unavailable(.rootNotCurrent))

        let sourceReader = registry.makeValidatedSourceReaderClient()
        let firstIdentity = try XCTUnwrap(identity(rootEpoch: firstEpoch, fileID: firstFileID))
        let secondIdentity = try XCTUnwrap(identity(rootEpoch: secondEpoch, fileID: secondFileID))
        let firstRead = try await sourceReader.read(firstIdentity, fingerprint, 1024, UUID())
        let secondRead = try await sourceReader.read(secondIdentity, fingerprint, 1024, UUID())
        XCTAssertEqual(String(data: firstRead.data, encoding: .utf8), "first")
        XCTAssertEqual(String(data: secondRead.data, encoding: .utf8), "second")

        let missingIdentity = try XCTUnwrap(identity(rootEpoch: missingEpoch, fileID: UUID()))
        do {
            _ = try await sourceReader.read(missingIdentity, fingerprint, 1024, UUID())
            XCTFail("Expected a typed missing-route error.")
        } catch let error as WorkspaceCodemapBindingIntegrationRoutingError {
            XCTAssertEqual(error, .routeUnavailable(missingEpoch))
        }
    }

    func testDetachedRouteCannotReadOrResolveCatalog() async throws {
        let registry = WorkspaceCodemapBindingIntegrationRegistry()
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let fileID = UUID()
        let sourceGate = RegistryRouteGate()
        let catalogGate = RegistryRouteGate()
        let routeEndpoint = WorkspaceCodemapBindingIntegrationEndpoint(
            sourceReader: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                await sourceGate.enterAndWait()
                return Self.snapshot(marker: "detached")
            },
            catalogClient: WorkspaceCodemapBindingCatalogClient { epoch, relativePath in
                await catalogGate.enterAndWait()
                return Self.candidate(rootEpoch: epoch, fileID: fileID, relativePath: relativePath)
            }
        )
        let tokenValue = await registry.register(rootEpoch: rootEpoch, endpoint: routeEndpoint)
        let token = try XCTUnwrap(tokenValue)
        let bindingIdentity = try XCTUnwrap(identity(rootEpoch: rootEpoch, fileID: fileID))
        let sourceReader = registry.makeValidatedSourceReaderClient()
        let catalog = registry.makeBindingCatalogClient()

        let readTask = Task {
            try await sourceReader.read(bindingIdentity, fingerprint, 1024, UUID())
        }
        let catalogTask = Task {
            await catalog.resolveManifestBinding(rootEpoch, bindingIdentity.standardizedRelativePath)
        }
        await sourceGate.waitUntilEntered()
        await catalogGate.waitUntilEntered()
        let didUnregister = await registry.unregister(token)
        XCTAssertTrue(didUnregister)
        await sourceGate.release()
        await catalogGate.release()

        do {
            _ = try await readTask.value
            XCTFail("A read completed after its route detached.")
        } catch let error as WorkspaceCodemapBindingIntegrationRoutingError {
            XCTAssertEqual(error, .routeDetached(rootEpoch))
        }
        let detachedCatalogResult = await catalogTask.value
        XCTAssertNil(detachedCatalogResult)
        let missingCatalogResult = await catalog.resolveManifestBinding(
            rootEpoch,
            bindingIdentity.standardizedRelativePath
        )
        XCTAssertNil(missingCatalogResult)

        do {
            _ = try await sourceReader.read(bindingIdentity, fingerprint, 1024, UUID())
            XCTFail("Expected a typed missing-route error after detach.")
        } catch let error as WorkspaceCodemapBindingIntegrationRoutingError {
            XCTAssertEqual(error, .routeUnavailable(rootEpoch))
        }

        let deallocatedEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let weakEndpoint = await Self.registerEphemeralEndpoint(registry: registry, rootEpoch: deallocatedEpoch)
        XCTAssertNil(weakEndpoint.value)
        let deallocatedResult = await catalog.resolveManifestBinding(deallocatedEpoch, "Sources/Value.swift")
        XCTAssertNil(deallocatedResult)
        let deallocatedIdentity = try XCTUnwrap(identity(rootEpoch: deallocatedEpoch, fileID: UUID()))
        do {
            _ = try await sourceReader.read(deallocatedIdentity, fingerprint, 1024, UUID())
            XCTFail("A deallocated route remained readable.")
        } catch let error as WorkspaceCodemapBindingIntegrationRoutingError {
            XCTAssertEqual(error, .routeUnavailable(deallocatedEpoch))
        }
    }

    func testInFlightOwnerReleaseDetachesWithoutRegistryRetention() async throws {
        let registry = WorkspaceCodemapBindingIntegrationRegistry()
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let fileID = UUID()
        let sourceGate = RegistryRouteGate()
        let catalogGate = RegistryRouteGate()
        var routeEndpoint: WorkspaceCodemapBindingIntegrationEndpoint? =
            WorkspaceCodemapBindingIntegrationEndpoint(
                sourceReader: WorkspaceCodemapValidatedSourceReaderClient { _, _, _, _ in
                    await sourceGate.enterAndWait()
                    return Self.snapshot(marker: "released")
                },
                catalogClient: WorkspaceCodemapBindingCatalogClient { epoch, relativePath in
                    await catalogGate.enterAndWait()
                    return Self.candidate(rootEpoch: epoch, fileID: fileID, relativePath: relativePath)
                }
            )
        let weakEndpoint = try RegistryWeakEndpointBox(XCTUnwrap(routeEndpoint))
        _ = try await registry.register(rootEpoch: rootEpoch, endpoint: XCTUnwrap(routeEndpoint))
        let identity = try XCTUnwrap(identity(rootEpoch: rootEpoch, fileID: fileID))
        let sourceReader = registry.makeValidatedSourceReaderClient()
        let catalog = registry.makeBindingCatalogClient()

        let readTask = Task {
            try await sourceReader.read(identity, fingerprint, 1024, UUID())
        }
        let catalogTask = Task {
            await catalog.resolveManifestBinding(rootEpoch, identity.standardizedRelativePath)
        }
        await sourceGate.waitUntilEntered()
        await catalogGate.waitUntilEntered()

        routeEndpoint = nil
        XCTAssertNil(weakEndpoint.value)
        await sourceGate.release()
        await catalogGate.release()

        do {
            _ = try await readTask.value
            XCTFail("An in-flight read completed after its endpoint owner deallocated.")
        } catch let error as WorkspaceCodemapBindingIntegrationRoutingError {
            XCTAssertEqual(error, .routeDetached(rootEpoch))
        }
        let catalogResult = await catalogTask.value
        XCTAssertNil(catalogResult)
    }

    func testStaleTokenCannotUnregisterSuccessor() async {
        let registry = WorkspaceCodemapBindingIntegrationRegistry()
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let firstEndpoint = endpoint(rootEpoch: rootEpoch, fileID: UUID(), marker: "first")
        let successorFileID = UUID()
        let successorEndpoint = endpoint(rootEpoch: rootEpoch, fileID: successorFileID, marker: "successor")
        guard let staleToken = await registry.register(rootEpoch: rootEpoch, endpoint: firstEndpoint)
        else { return XCTFail("Expected initial route registration.") }
        let initialUnregistered = await registry.unregister(staleToken)
        XCTAssertTrue(initialUnregistered)
        guard let successorToken = await registry.register(rootEpoch: rootEpoch, endpoint: successorEndpoint)
        else { return XCTFail("Expected successor route registration.") }

        let staleTokenUnregistered = await registry.unregister(staleToken)
        XCTAssertFalse(staleTokenUnregistered)
        let candidate = await registry.makeBindingCatalogClient().resolveManifestBinding(
            rootEpoch,
            "Sources/Value.swift"
        )
        XCTAssertEqual(candidate?.identity.fileID, successorFileID)
        let successorUnregistered = await registry.unregister(successorToken)
        XCTAssertTrue(successorUnregistered)
    }

    private static let fingerprint = GitBlobLStatFingerprint(
        device: 1,
        inode: 2,
        mode: 0,
        size: 0,
        modificationSeconds: 0,
        modificationNanoseconds: 0,
        changeSeconds: 0,
        changeNanoseconds: 0
    )

    private var fingerprint: GitBlobLStatFingerprint {
        Self.fingerprint
    }

    private func endpoint(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        marker: String
    ) -> WorkspaceCodemapBindingIntegrationEndpoint {
        Self.endpoint(rootEpoch: rootEpoch, fileID: fileID, marker: marker)
    }

    private static func endpoint(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        marker: String
    ) -> WorkspaceCodemapBindingIntegrationEndpoint {
        WorkspaceCodemapBindingIntegrationEndpoint(
            sourceReader: WorkspaceCodemapValidatedSourceReaderClient { identity, _, _, _ in
                guard identity.rootID == rootEpoch.rootID,
                      identity.rootLifetimeID == rootEpoch.rootLifetimeID
                else { throw WorkspaceCodemapBindingIntegrationRoutingError.routeUnavailable(rootEpoch) }
                return snapshot(marker: marker)
            },
            catalogClient: WorkspaceCodemapBindingCatalogClient { epoch, relativePath in
                guard epoch == rootEpoch else { return nil }
                return candidate(rootEpoch: epoch, fileID: fileID, relativePath: relativePath)
            } readProjectionCatalogPage: { request in
                guard request.rootEpoch == rootEpoch else { return .stale }
                let token = projectionToken(rootEpoch: rootEpoch)
                guard request.token == nil || request.token == token else { return .stale }
                switch WorkspaceCodemapProjectionCatalogPage.validated(
                    request: request,
                    token: token,
                    entries: [],
                    nextCursor: nil,
                    isEnd: true,
                    supportedCandidateCountThroughPage: 0
                ) {
                case let .success(page):
                    return .page(page)
                case .failure:
                    return .unavailable(.catalogUnavailable)
                }
            } revalidateProjectionCatalogToken: { epoch, token in
                guard epoch == rootEpoch, token.rootEpoch == rootEpoch else { return .stale }
                return token == projectionToken(rootEpoch: rootEpoch) ? .current : .stale
            }
        )
    }

    private func projectionPage(
        _ disposition: WorkspaceCodemapProjectionCatalogPageDisposition
    ) throws -> WorkspaceCodemapProjectionCatalogPage {
        guard case let .page(page) = disposition else {
            throw RegistryTestError.expectedProjectionPage
        }
        return page
    }

    private static func projectionToken(
        rootEpoch: WorkspaceCodemapRootEpoch
    ) -> WorkspaceCodemapProjectionCatalogToken {
        WorkspaceCodemapProjectionCatalogToken(
            rootEpoch: rootEpoch,
            topologyGeneration: 1,
            appliedIndexGeneration: 1,
            catalogGeneration: 1,
            ingressGeneration: 1,
            projectionInvalidationGeneration: 1
        )
    }

    private func identity(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        relativePath: String = "Sources/Value.swift"
    ) -> WorkspaceCodemapArtifactBindingIdentity? {
        Self.identity(rootEpoch: rootEpoch, fileID: fileID, relativePath: relativePath)
    }

    private static func identity(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        relativePath: String = "Sources/Value.swift"
    ) -> WorkspaceCodemapArtifactBindingIdentity? {
        let rootPath = "/tmp/registry-\(rootEpoch.rootLifetimeID.uuidString)"
        return WorkspaceCodemapArtifactBindingIdentity(
            rootID: rootEpoch.rootID,
            rootLifetimeID: rootEpoch.rootLifetimeID,
            fileID: fileID,
            standardizedRootPath: rootPath,
            standardizedRelativePath: relativePath,
            standardizedFullPath: rootPath + "/" + relativePath
        )
    }

    private static func candidate(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        relativePath: String
    ) -> WorkspaceCodemapManifestBindingCandidate? {
        guard let identity = identity(
            rootEpoch: rootEpoch,
            fileID: fileID,
            relativePath: relativePath
        ) else { return nil }
        return WorkspaceCodemapManifestBindingCandidate(
            identity: identity,
            requestGeneration: 1,
            pathGeneration: 1,
            ingressGeneration: 1
        )
    }

    private static func snapshot(marker: String) -> ValidatedRawFileContentSnapshot {
        ValidatedRawFileContentSnapshot(
            data: Data(marker.utf8),
            modificationDate: .distantPast,
            fingerprint: FileContentFingerprint(
                deviceID: 1,
                fileNumber: 2,
                byteSize: Int64(marker.utf8.count),
                modificationSeconds: 0,
                modificationNanoseconds: 0,
                statusChangeSeconds: 0,
                statusChangeNanoseconds: 0
            )
        )
    }

    private static func registerEphemeralEndpoint(
        registry: WorkspaceCodemapBindingIntegrationRegistry,
        rootEpoch: WorkspaceCodemapRootEpoch
    ) async -> RegistryWeakEndpointBox {
        let endpoint = endpoint(rootEpoch: rootEpoch, fileID: UUID(), marker: "unused")
        let weakEndpoint = RegistryWeakEndpointBox(endpoint)
        _ = await registry.register(rootEpoch: rootEpoch, endpoint: endpoint)
        return weakEndpoint
    }
}

private final class RegistryWeakEndpointBox {
    weak var value: WorkspaceCodemapBindingIntegrationEndpoint?

    init(_ value: WorkspaceCodemapBindingIntegrationEndpoint) {
        self.value = value
    }
}

private enum RegistryTestError: Error {
    case expectedProjectionPage
}

private actor RegistryRouteGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
