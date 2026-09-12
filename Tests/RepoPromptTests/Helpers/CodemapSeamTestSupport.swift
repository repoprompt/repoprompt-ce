import Darwin
import Foundation
@testable import RepoPromptApp

final class CodemapRuntimeTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var runtimes: [CodeMapArtifactRuntime] = []

    func record(_ runtime: CodeMapArtifactRuntime) -> CodeMapArtifactRuntime {
        lock.withLock { runtimes.append(runtime) }
        return runtime
    }

    func snapshot() -> [CodeMapArtifactRuntime] {
        lock.withLock { runtimes }
    }
}

final class CodemapLockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}

/// Raised by the fixture's injected spawner when a Code Map collaborator attempts to launch a
/// Git child while the scenario forbids it. Attempts are recorded before throwing, so the failure
/// reaches both the assertion and the production error path.
struct CodemapForbiddenGitProcessError: Error {
    let arguments: [String]
}

final class CodemapStoreFixture: @unchecked Sendable {
    let registry: WorkspaceCodemapBindingIntegrationRegistry
    /// Sources handed to the real builder, recorded when the build is *attempted*. Use this for
    /// "must not rebuild" assertions, which have to notice an unnecessary build even before it
    /// finishes.
    let builtSourceTexts: CodemapLockedValues<String>
    /// Sources whose real build actually *returned*. Use this when a scenario needs a completion,
    /// for example to prove that a stale completion existed to be rejected.
    let completedSourceTexts: CodemapLockedValues<String>
    /// Every Git child the Code Map capability, identity, materialization and preflight
    /// collaborators tried to launch. Unrelated app-wide VCS work uses its own services and is
    /// deliberately not observed here.
    let codeMapGitProcessAttempts: CodemapLockedValues<String>

    private let sandbox: URL
    private let runtimeTracker: CodemapRuntimeTracker
    private let runtimeProvider: CodeMapArtifactRuntimeProvider
    private let codeMapGitService: GitService

    init(
        name: String,
        capabilityHooks: WorkspaceCodemapRootCapabilityServiceHooks = .none,
        forbidCodeMapGitProcesses: Bool = false,
        beforeArtifactBuild: @escaping @Sendable (String) async -> Void = { _ in }
    ) throws {
        let registry = WorkspaceCodemapBindingIntegrationRegistry()
        let builtSourceTexts = CodemapLockedValues<String>()
        let completedSourceTexts = CodemapLockedValues<String>()
        let codeMapGitProcessAttempts = CodemapLockedValues<String>()
        let runtimeTracker = CodemapRuntimeTracker()
        let codeMapGitService = GitService(
            processSpawner: { executablePath, arguments, environment, workingDirectoryPath in
                codeMapGitProcessAttempts.append(arguments.joined(separator: " "))
                if forbidCodeMapGitProcesses {
                    throw CodemapForbiddenGitProcessError(arguments: arguments)
                }
                return try GitService.defaultProcessSpawner(
                    executablePath,
                    arguments,
                    environment,
                    workingDirectoryPath
                )
            }
        )
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodemapStoreFixture-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let artifactRoot = sandbox.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: artifactRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(artifactRoot.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let resolvedArtifactRoot = try artifactRoot.path.withCString { pointer -> URL in
            guard let resolved = realpath(pointer, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { free(resolved) }
            return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        }

        let defaultBuilder = CodeMapArtifactBuilderClient()
        let runtimeProvider = CodeMapArtifactRuntimeProvider {
            try runtimeTracker.record(CodeMapArtifactRuntime(
                rootURL: resolvedArtifactRoot,
                builder: CodeMapArtifactBuilderClient(execute: { input, ownerID, priority in
                    var decodedText: String?
                    if case let .decoded(source) = input.source.decodeResult {
                        await beforeArtifactBuild(source.text)
                        builtSourceTexts.append(source.text)
                        decodedText = source.text
                    }
                    let artifact = try await defaultBuilder.execute(input, ownerID, priority)
                    if let decodedText {
                        completedSourceTexts.append(decodedText)
                    }
                    return artifact
                }),
                bindingIntegrationRegistry: registry,
                bindingEngineFactory: { runtime in
                    WorkspaceCodemapBindingEngine(
                        runtime: runtime,
                        capabilityService: WorkspaceCodemapRootCapabilityService(
                            gitService: codeMapGitService,
                            namespaceSalt: Data(
                                repeating: 0x6C,
                                count: GitBlobRepositoryNamespace.saltByteCount
                            ),
                            hooks: capabilityHooks
                        ),
                        identityService: GitBlobIdentityService(gitService: codeMapGitService),
                        materializationService: GitBlobSourceMaterializationService(
                            gitService: codeMapGitService
                        ),
                        sourceReader: registry.makeValidatedSourceReaderClient(),
                        catalogClient: registry.makeBindingCatalogClient()
                    )
                }
            ))
        }
        self.registry = registry
        self.builtSourceTexts = builtSourceTexts
        self.completedSourceTexts = completedSourceTexts
        self.codeMapGitProcessAttempts = codeMapGitProcessAttempts
        self.sandbox = sandbox
        self.runtimeTracker = runtimeTracker
        self.runtimeProvider = runtimeProvider
        self.codeMapGitService = codeMapGitService
    }

    deinit {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// Store that forces Code Map eligibility. Retained for the existing Git scenarios, whose
    /// contracts are about serving and not about admission.
    func makeStore() -> WorkspaceFileContextStore {
        let runtimeProvider = runtimeProvider
        return WorkspaceFileContextStore(
            codemapRuntimeProvider: { try runtimeProvider.runtime() },
            codemapLocalGitClassificationProbe: .init { _ in .requiresGitPreflight },
            codemapGitEligibilityProbe: .init { _ in .eligible }
        )
    }

    /// Store that admits roots through the production local proof and Git preflight, sharing the
    /// fixture's instrumented Git service with the engine's Code Map collaborators.
    func makeProductionStore() -> WorkspaceFileContextStore {
        let runtimeProvider = runtimeProvider
        return WorkspaceFileContextStore(
            codemapRuntimeProvider: { try runtimeProvider.runtime() },
            codemapLocalGitClassificationProbe: .production,
            codemapGitEligibilityProbe: .production(gitService: codeMapGitService)
        )
    }

    /// Manifest writer bookkeeping for the fixture's isolated store. A fresh store starts with
    /// capacity, so an unchanged sequence plus no active sessions proves no writer registration.
    func manifestWriterSessionState() async throws -> (nextSequence: UInt64?, activeCount: Int) {
        try await runtimeProvider.runtime().manifestStore.debugWriterSessionState()
    }

    func runtime() throws -> CodeMapArtifactRuntime {
        try runtimeProvider.runtime()
    }

    func shutdown() async {
        for runtime in runtimeTracker.snapshot() {
            if let engine = try? runtime.bindingEngine() {
                await engine.shutdown()
            }
        }
    }
}
