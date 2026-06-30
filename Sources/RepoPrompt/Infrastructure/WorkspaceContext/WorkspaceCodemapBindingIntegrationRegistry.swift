import Foundation

enum WorkspaceCodemapBindingIntegrationRoutingError: Error, Equatable {
    case routeUnavailable(WorkspaceCodemapRootEpoch)
    case routeDetached(WorkspaceCodemapRootEpoch)
}

struct WorkspaceCodemapBindingIntegrationRouteToken: Hashable {
    let registryID: UUID
    let rootEpoch: WorkspaceCodemapRootEpoch
    let generation: UInt64
    let nonce: UUID
}

final class WorkspaceCodemapBindingIntegrationEndpoint: @unchecked Sendable {
    let sourceReader: WorkspaceCodemapValidatedSourceReaderClient
    let catalogClient: WorkspaceCodemapBindingCatalogClient

    init(
        sourceReader: WorkspaceCodemapValidatedSourceReaderClient,
        catalogClient: WorkspaceCodemapBindingCatalogClient
    ) {
        self.sourceReader = sourceReader
        self.catalogClient = catalogClient
    }
}

actor WorkspaceCodemapBindingIntegrationRegistry {
    private final class WeakEndpoint {
        weak var value: WorkspaceCodemapBindingIntegrationEndpoint?

        init(_ value: WorkspaceCodemapBindingIntegrationEndpoint) {
            self.value = value
        }
    }

    private struct Route {
        let token: WorkspaceCodemapBindingIntegrationRouteToken
        let endpoint: WeakEndpoint
    }

    private let registryID = UUID()
    private var nextGeneration: UInt64? = 1
    private var routes: [WorkspaceCodemapRootEpoch: Route] = [:]

    nonisolated func makeValidatedSourceReaderClient() -> WorkspaceCodemapValidatedSourceReaderClient {
        WorkspaceCodemapValidatedSourceReaderClient { [self] identity, fingerprint, maximumBytes, ownerID in
            try await read(
                identity: identity,
                fingerprint: fingerprint,
                maximumBytes: maximumBytes,
                ownerID: ownerID
            )
        }
    }

    nonisolated func makeBindingCatalogClient() -> WorkspaceCodemapBindingCatalogClient {
        WorkspaceCodemapBindingCatalogClient { [self] rootEpoch, relativePath in
            await resolveManifestBinding(rootEpoch: rootEpoch, relativePath: relativePath)
        } readProjectionCatalogPage: { [self] request in
            await readProjectionCatalogPage(request)
        } revalidateProjectionCatalogToken: { [self] rootEpoch, token in
            await revalidateProjectionCatalogToken(rootEpoch: rootEpoch, token: token)
        } publishProjection: { [self] snapshot in
            await publishProjection(snapshot)
        } publishMarkerReadiness: { [self] update in
            await publishMarkerReadiness(update)
        }
    }

    func register(
        rootEpoch: WorkspaceCodemapRootEpoch,
        endpoint: WorkspaceCodemapBindingIntegrationEndpoint
    ) -> WorkspaceCodemapBindingIntegrationRouteToken? {
        if let current = routes[rootEpoch], current.endpoint.value != nil {
            return nil
        }
        routes[rootEpoch] = nil
        guard let generation = nextGeneration else { return nil }
        let token = WorkspaceCodemapBindingIntegrationRouteToken(
            registryID: registryID,
            rootEpoch: rootEpoch,
            generation: generation,
            nonce: UUID()
        )
        nextGeneration = generation == .max ? nil : generation + 1
        routes[rootEpoch] = Route(token: token, endpoint: WeakEndpoint(endpoint))
        return token
    }

    @discardableResult
    func unregister(_ token: WorkspaceCodemapBindingIntegrationRouteToken) -> Bool {
        guard token.registryID == registryID,
              let route = routes[token.rootEpoch],
              route.token == token
        else { return false }
        routes[token.rootEpoch] = nil
        return true
    }

    private func read(
        identity: WorkspaceCodemapArtifactBindingIdentity,
        fingerprint: GitBlobLStatFingerprint,
        maximumBytes: Int64,
        ownerID: UUID
    ) async throws -> ValidatedRawFileContentSnapshot {
        let rootEpoch = WorkspaceCodemapRootEpoch(
            rootID: identity.rootID,
            rootLifetimeID: identity.rootLifetimeID
        )
        guard let (token, sourceReader) = currentSourceRoute(for: rootEpoch) else {
            throw WorkspaceCodemapBindingIntegrationRoutingError.routeUnavailable(rootEpoch)
        }
        let result = try await sourceReader.read(identity, fingerprint, maximumBytes, ownerID)
        guard isCurrent(token: token) else {
            throw WorkspaceCodemapBindingIntegrationRoutingError.routeDetached(rootEpoch)
        }
        return result
    }

    private func resolveManifestBinding(
        rootEpoch: WorkspaceCodemapRootEpoch,
        relativePath: String
    ) async -> WorkspaceCodemapManifestBindingCandidate? {
        guard let (token, catalogClient) = currentCatalogRoute(for: rootEpoch) else { return nil }
        let result = await catalogClient.resolveManifestBinding(rootEpoch, relativePath)
        guard isCurrent(token: token) else { return nil }
        guard let result,
              result.identity.rootID == rootEpoch.rootID,
              result.identity.rootLifetimeID == rootEpoch.rootLifetimeID
        else { return nil }
        return result
    }

    private func readProjectionCatalogPage(
        _ request: WorkspaceCodemapProjectionCatalogPageRequest
    ) async -> WorkspaceCodemapProjectionCatalogPageDisposition {
        guard let (token, catalogClient) = currentCatalogRoute(for: request.rootEpoch) else {
            return .unavailable(.rootNotCurrent)
        }
        let result = await catalogClient.readProjectionCatalogPage(request)
        guard isCurrent(token: token) else { return .stale }
        if case let .page(page) = result {
            guard page.token.rootEpoch == request.rootEpoch else { return .stale }
        }
        return result
    }

    private func revalidateProjectionCatalogToken(
        rootEpoch: WorkspaceCodemapRootEpoch,
        token catalogToken: WorkspaceCodemapProjectionCatalogToken
    ) async -> WorkspaceCodemapProjectionCatalogTokenDisposition {
        guard catalogToken.rootEpoch == rootEpoch else { return .stale }
        guard let (token, catalogClient) = currentCatalogRoute(for: rootEpoch) else {
            return .unavailable(.rootNotCurrent)
        }
        let result = await catalogClient.revalidateProjectionCatalogToken(rootEpoch, catalogToken)
        guard isCurrent(token: token) else { return .stale }
        return result
    }

    private func publishProjection(
        _ snapshot: WorkspaceCodemapProjectionSnapshot
    ) async -> WorkspaceCodemapProjectionSnapshotDisposition {
        let rootEpoch: WorkspaceCodemapRootEpoch = switch snapshot {
        case let .segment(segment):
            segment.generation.rootEpoch
        case let .seal(proof):
            proof.generation.rootEpoch
        }
        guard let (token, catalogClient) = currentCatalogRoute(for: rootEpoch) else {
            return .superseded
        }
        let result = await catalogClient.publishProjection(snapshot)
        guard isCurrent(token: token) else { return .superseded }
        return result
    }

    private func publishMarkerReadiness(
        _ update: WorkspaceCodemapMarkerReadinessUpdate
    ) async -> Bool {
        guard let (token, catalogClient) = currentCatalogRoute(for: update.rootEpoch) else {
            return false
        }
        let accepted = await catalogClient.publishMarkerReadiness(update)
        guard isCurrent(token: token) else { return false }
        return accepted
    }

    private func currentSourceRoute(
        for rootEpoch: WorkspaceCodemapRootEpoch
    ) -> (WorkspaceCodemapBindingIntegrationRouteToken, WorkspaceCodemapValidatedSourceReaderClient)? {
        guard let route = routes[rootEpoch], let endpoint = route.endpoint.value else {
            routes[rootEpoch] = nil
            return nil
        }
        return (route.token, endpoint.sourceReader)
    }

    private func currentCatalogRoute(
        for rootEpoch: WorkspaceCodemapRootEpoch
    ) -> (WorkspaceCodemapBindingIntegrationRouteToken, WorkspaceCodemapBindingCatalogClient)? {
        guard let route = routes[rootEpoch], let endpoint = route.endpoint.value else {
            routes[rootEpoch] = nil
            return nil
        }
        return (route.token, endpoint.catalogClient)
    }

    private func isCurrent(token: WorkspaceCodemapBindingIntegrationRouteToken) -> Bool {
        guard let route = routes[token.rootEpoch],
              route.token == token,
              route.endpoint.value != nil
        else { return false }
        return true
    }
}
