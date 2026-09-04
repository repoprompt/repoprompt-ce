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

final class CodemapStoreFixture: @unchecked Sendable {
    let registry: WorkspaceCodemapBindingIntegrationRegistry
    let builtSourceTexts: CodemapLockedValues<String>

    private let sandbox: URL
    private let runtimeTracker: CodemapRuntimeTracker
    private let runtimeProvider: CodeMapArtifactRuntimeProvider

    init(name: String) throws {
        let registry = WorkspaceCodemapBindingIntegrationRegistry()
        let builtSourceTexts = CodemapLockedValues<String>()
        let runtimeTracker = CodemapRuntimeTracker()
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
                    if case let .decoded(source) = input.source.decodeResult {
                        builtSourceTexts.append(source.text)
                    }
                    return try await defaultBuilder.execute(input, ownerID, priority)
                }),
                bindingIntegrationRegistry: registry,
                bindingEngineFactory: { runtime in
                    WorkspaceCodemapBindingEngine(
                        runtime: runtime,
                        capabilityService: WorkspaceCodemapGitCapabilityService(
                            namespaceSalt: Data(
                                repeating: 0x6C,
                                count: GitBlobRepositoryNamespace.saltByteCount
                            )
                        ),
                        sourceReader: registry.makeValidatedSourceReaderClient(),
                        catalogClient: registry.makeBindingCatalogClient()
                    )
                }
            ))
        }
        self.registry = registry
        self.builtSourceTexts = builtSourceTexts
        self.sandbox = sandbox
        self.runtimeTracker = runtimeTracker
        self.runtimeProvider = runtimeProvider
    }

    deinit {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func makeStore() -> WorkspaceFileContextStore {
        let runtimeProvider = runtimeProvider
        return WorkspaceFileContextStore(
            codemapRuntimeProvider: { try runtimeProvider.runtime() },
            codemapLocalGitClassificationProbe: .init { _ in .requiresGitPreflight },
            codemapGitEligibilityProbe: .init { _ in .eligible }
        )
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
