import Darwin
import Foundation
@testable import RepoPrompt

enum WorkspaceCodemapProvenanceTestSupportError: Error {
    case capabilityUnavailable
    case sourceAuthorityUnavailable
    case bindingIdentityUnavailable
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
    ) async throws -> CodeMapSourceSnapshot {
        let capability = try await WorkspaceCodemapCapabilityTestPool.capability(
            objectFormat: objectFormat,
            namespaceScope: namespaceScope
        )
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

    private actor Cache {
        private var contexts: [String: Context] = [:]
        private var inFlight: [String: Task<Context, Error>] = [:]

        func capability(
            objectFormat: GitObjectFormat,
            namespaceScope: String
        ) async throws -> GitCodemapRootCapability {
            let key = objectFormat.rawValue + "|" + namespaceScope
            if let context = contexts[key] {
                return context.capability
            }
            if let task = inFlight[key] {
                return try await task.value.capability
            }

            let task = Task<Context, Error> {
                try await WorkspaceCodemapCapabilityTestPool.makeContext(objectFormat: objectFormat)
            }
            inFlight[key] = task
            do {
                let context = try await task.value
                contexts[key] = context
                inFlight[key] = nil
                return context.capability
            } catch {
                inFlight[key] = nil
                throw error
            }
        }
    }

    private static let cache = Cache()

    static func capability(
        objectFormat: GitObjectFormat,
        namespaceScope: String
    ) async throws -> GitCodemapRootCapability {
        try await cache.capability(
            objectFormat: objectFormat,
            namespaceScope: namespaceScope
        )
    }

    private static func makeContext(objectFormat: GitObjectFormat) async throws -> Context {
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
}
