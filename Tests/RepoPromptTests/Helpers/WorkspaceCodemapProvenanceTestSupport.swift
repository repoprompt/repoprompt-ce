import Darwin
import Foundation
@testable import RepoPrompt

enum WorkspaceCodemapProvenanceTestSupportError: Error {
    case capabilityUnavailable
    case sourceAuthorityUnavailable
    case bindingIdentityUnavailable
    case missingResult
}

final class WorkspaceCodemapAuthorityTestFixture: @unchecked Sendable {
    let repositoryFixture: ReviewGitRepositoryFixture
    let repositoryRoot: URL
    let loadedRoot: URL
    let capabilityService: WorkspaceCodemapGitCapabilityService
    let capability: GitCodemapRootCapability

    private init(
        repositoryFixture: ReviewGitRepositoryFixture,
        repositoryRoot: URL,
        loadedRoot: URL,
        capabilityService: WorkspaceCodemapGitCapabilityService,
        capability: GitCodemapRootCapability
    ) {
        self.repositoryFixture = repositoryFixture
        self.repositoryRoot = repositoryRoot
        self.loadedRoot = loadedRoot
        self.capabilityService = capabilityService
        self.capability = capability
    }

    static func make(
        name: String,
        files: [String: String],
        objectFormat: GitObjectFormat = .sha1,
        loadedRootRelativePath: String = "",
        rootID: UUID = UUID(),
        rootLifetimeID: UUID = UUID()
    ) async throws -> WorkspaceCodemapAuthorityTestFixture {
        let repositoryFixture = try ReviewGitRepositoryFixture(name: name)
        let repositoryRoot = try repositoryFixture.makeRepository(
            named: "repository",
            files: files,
            objectFormat: objectFormat
        )
        let loadedRoot = loadedRootRelativePath.isEmpty
            ? repositoryRoot
            : repositoryRoot.appendingPathComponent(loadedRootRelativePath, isDirectory: true)
        let gitService = GitService()
        let capabilityService = WorkspaceCodemapGitCapabilityService(
            gitService: gitService,
            namespaceSalt: Data(repeating: 0xA7, count: GitBlobRepositoryNamespace.saltByteCount)
        )
        let state = await capabilityService.resolve(
            root: WorkspaceCodemapGitCapabilityRequest(
                rootID: rootID,
                rootLifetimeID: rootLifetimeID,
                loadedRootURL: loadedRoot
            )
        )
        guard case let .eligible(capability) = state else {
            throw WorkspaceCodemapProvenanceTestSupportError.capabilityUnavailable
        }
        return WorkspaceCodemapAuthorityTestFixture(
            repositoryFixture: repositoryFixture,
            repositoryRoot: repositoryRoot,
            loadedRoot: loadedRoot,
            capabilityService: capabilityService,
            capability: capability
        )
    }

    func sourceAuthority(
        repositoryRelativePath: String,
        pathGeneration: UInt64 = 1,
        ingressGeneration: UInt64 = 1
    ) async throws -> WorkspaceCodemapSourceAuthorityToken {
        guard let authority = await capabilityService.makeSourceAuthority(
            capability: capability,
            observedRootEpoch: capability.rootEpoch,
            observedRepositoryAuthority: capability.repositoryAuthority,
            candidateRepositoryRelativePath: repositoryRelativePath,
            observedPathGeneration: pathGeneration,
            currentPathGeneration: pathGeneration,
            observedIngressGeneration: ingressGeneration,
            currentIngressGeneration: ingressGeneration
        ) else {
            throw WorkspaceCodemapProvenanceTestSupportError.sourceAuthorityUnavailable
        }
        return authority
    }

    func bindingIdentity(
        fileID: UUID = UUID(),
        loadedRootRelativePath: String
    ) throws -> WorkspaceCodemapArtifactBindingIdentity {
        guard let identity = WorkspaceCodemapArtifactBindingIdentity(
            rootID: capability.rootEpoch.rootID,
            rootLifetimeID: capability.rootEpoch.rootLifetimeID,
            fileID: fileID,
            standardizedRootPath: loadedRoot.path,
            standardizedRelativePath: loadedRootRelativePath,
            standardizedFullPath: loadedRoot.appendingPathComponent(loadedRootRelativePath).path
        ) else {
            throw WorkspaceCodemapProvenanceTestSupportError.bindingIdentityUnavailable
        }
        return identity
    }

    func validatedWorktreeSource(
        loadedRootRelativePath: String
    ) async throws -> CodeMapSourceSnapshot {
        let fileSystem = try await FileSystemService(
            path: loadedRoot.path,
            respectRepoIgnore: false,
            respectCursorignore: false
        )
        let validated = try await fileSystem.loadValidatedRawContent(
            ofRelativePath: loadedRootRelativePath
        )
        return CodeMapSourceSnapshot(validatedContent: validated)
    }

    func cleanSource(bytes: Data) async throws -> CodeMapSourceSnapshot {
        let blobOID = GitBlobOID.blob(
            bytes: bytes,
            objectFormat: capability.objectFormat
        )
        let materializer = GitBlobSourceMaterializationService(
            client: GitBlobSourceMaterializationClient(
                size: { _, _ in UInt64(bytes.count) },
                bytes: { _, _, _ in bytes }
            )
        )
        let validated = try await materializer.materialize(
            capability: capability,
            blobOID: blobOID
        )
        return CodeMapSourceSnapshot(validatedGitBlob: validated)
    }

    func secureArtifactRoot(named name: String = "artifacts") throws -> URL {
        let root = repositoryFixture.sandbox.appendingPathComponent(
            "\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolvedPath = try root.path.withCString { pointer -> String in
            guard let resolved = realpath(pointer, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let resolved = URL(fileURLWithPath: resolvedPath, isDirectory: true)
        guard chmod(resolved.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return resolved
    }
}

enum WorkspaceCodemapValidatedSnapshotTestSupport {
    static func cleanSource(
        bytes: Data,
        objectFormat: GitObjectFormat,
        namespaceScope: String = "shared"
    ) throws -> CodeMapSourceSnapshot {
        let capability = try WorkspaceCodemapCapabilityTestPool.capability(
            objectFormat: objectFormat,
            namespaceScope: namespaceScope
        )
        return try WorkspaceCodemapBlockingAwait.run {
            let blobOID = GitBlobOID.blob(bytes: bytes, objectFormat: objectFormat)
            let materializer = GitBlobSourceMaterializationService(
                client: GitBlobSourceMaterializationClient(
                    size: { _, _ in UInt64(bytes.count) },
                    bytes: { _, _, _ in bytes }
                )
            )
            let validated = try await materializer.materialize(
                capability: capability,
                blobOID: blobOID
            )
            return CodeMapSourceSnapshot(validatedGitBlob: validated)
        }
    }
}

private enum WorkspaceCodemapCapabilityTestPool {
    private final class Context: @unchecked Sendable {
        let repositoryFixture: ReviewGitRepositoryFixture
        let capability: GitCodemapRootCapability

        init(
            repositoryFixture: ReviewGitRepositoryFixture,
            capability: GitCodemapRootCapability
        ) {
            self.repositoryFixture = repositoryFixture
            self.capability = capability
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var contexts: [String: Context] = [:]

    static func capability(
        objectFormat: GitObjectFormat,
        namespaceScope: String
    ) throws -> GitCodemapRootCapability {
        let key = objectFormat.rawValue + "|" + namespaceScope
        lock.lock()
        defer { lock.unlock() }
        if let context = contexts[key] {
            return context.capability
        }

        let context: Context = try WorkspaceCodemapBlockingAwait.run {
            let fixture = try ReviewGitRepositoryFixture(
                name: "WorkspaceCodemapCapabilityTestPool-\(objectFormat.rawValue)-\(UUID().uuidString)"
            )
            let root = try fixture.makeRepository(
                named: "repository",
                files: ["Sources/Fixture.swift": "struct Fixture {}\n"],
                objectFormat: objectFormat
            )
            let service = WorkspaceCodemapGitCapabilityService(
                namespaceSalt: Data(
                    repeating: 0x6B,
                    count: GitBlobRepositoryNamespace.saltByteCount
                )
            )
            let state = await service.resolve(
                root: WorkspaceCodemapGitCapabilityRequest(
                    rootID: UUID(),
                    rootLifetimeID: UUID(),
                    loadedRootURL: root
                )
            )
            guard case let .eligible(capability) = state else {
                throw WorkspaceCodemapProvenanceTestSupportError.capabilityUnavailable
            }
            return Context(
                repositoryFixture: fixture,
                capability: capability
            )
        }
        contexts[key] = context
        return context.capability
    }
}

private enum WorkspaceCodemapBlockingAwait {
    private final class ResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Result<Value, Error>?

        func store(_ result: Result<Value, Error>) {
            lock.lock()
            storage = result
            lock.unlock()
        }

        func take() throws -> Value {
            lock.lock()
            defer { lock.unlock() }
            guard let storage else {
                throw WorkspaceCodemapProvenanceTestSupportError.missingResult
            }
            return try storage.get()
        }
    }

    static func run<Value>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Value>()
        Task.detached {
            do {
                try await box.store(.success(operation()))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.take()
    }
}
