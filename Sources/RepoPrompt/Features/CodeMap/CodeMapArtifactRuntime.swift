import Darwin
import Foundation
import RepoPromptShared

/// Process-lifetime ownership for content-addressed codemap artifact infrastructure.
///
/// Production access is intentionally lazy and inert until an explicit codemap caller requests it.
/// Tests and benchmarks should construct isolated runtimes with explicit temporary roots instead.
final class CodeMapArtifactRuntime: @unchecked Sendable {
    let artifactStore: CodeMapArtifactStore
    let locatorStore: GitBlobCodeMapLocatorStore
    let manifestStore: CodeMapRootManifestStore
    let coordinator: CodeMapArtifactBuildCoordinator
    let bindingIntegrationRegistry: WorkspaceCodemapBindingIntegrationRegistry
    private let bindingEngineProvider: WorkspaceCodemapBindingEngineProvider

    init(
        rootURL: URL,
        artifactStorePolicy: CodeMapArtifactStorePolicy = .default,
        artifactStoreClock: CodeMapArtifactStoreClock = .system,
        artifactStoreRemovalHooks: CodeMapSecureFileRemovalHooks? = nil,
        artifactStoreLeaseAdmission: CodeMapArtifactLeaseAdmission = CodeMapArtifactLeaseAdmission(
            maximumCount: CodeMapArtifactStorePolicy.default.maximumActiveLeaseCount,
            maximumBytes: CodeMapArtifactStorePolicy.default.maximumActiveLeaseBytes
        ),
        locatorStorePolicy: GitBlobCodeMapLocatorStorePolicy = .default,
        locatorStoreHooks: GitBlobCodeMapLocatorStoreHooks = .none,
        manifestStorePolicy: CodeMapRootManifestStorePolicy = .default,
        manifestStoreHooks: CodeMapRootManifestStoreHooks = .none,
        builder: CodeMapArtifactBuilderClient = CodeMapArtifactBuilderClient(),
        coordinatorPolicy: CodeMapArtifactBuildCoordinatorPolicy = .default,
        coordinatorClock: CodeMapArtifactBuildCoordinatorClock = .continuous,
        coordinatorHooks: CodeMapArtifactBuildCoordinatorHooks = .none,
        bindingIntegrationRegistry: WorkspaceCodemapBindingIntegrationRegistry =
            WorkspaceCodemapBindingIntegrationRegistry(),
        bindingEngineFactory: @escaping WorkspaceCodemapBindingEngineProvider.Factory =
            WorkspaceCodemapBindingEngineProvider.unconfiguredFactory
    ) throws {
        let artifactStore = try CodeMapArtifactStore(
            rootURL: rootURL,
            policy: artifactStorePolicy,
            clock: artifactStoreClock,
            removalHooks: artifactStoreRemovalHooks,
            leaseAdmission: artifactStoreLeaseAdmission
        )
        let locatorStore = try GitBlobCodeMapLocatorStore(
            rootURL: rootURL,
            policy: locatorStorePolicy,
            hooks: locatorStoreHooks
        )
        let manifestStore = try CodeMapRootManifestStore(
            rootURL: rootURL,
            policy: manifestStorePolicy,
            hooks: manifestStoreHooks
        )
        let coordinator = CodeMapArtifactBuildCoordinator(
            artifactStore: CodeMapArtifactStoreClient(store: artifactStore),
            locatorStore: GitBlobCodeMapLocatorStoreClient(store: locatorStore),
            builder: builder,
            policy: coordinatorPolicy,
            clock: coordinatorClock,
            hooks: coordinatorHooks
        )

        self.artifactStore = artifactStore
        self.locatorStore = locatorStore
        self.manifestStore = manifestStore
        self.coordinator = coordinator
        self.bindingIntegrationRegistry = bindingIntegrationRegistry
        bindingEngineProvider = WorkspaceCodemapBindingEngineProvider(factory: bindingEngineFactory)
    }

    func bindingEngine() throws -> WorkspaceCodemapBindingEngine {
        try bindingEngineProvider.engine(for: self)
    }

    static func processWide() throws -> CodeMapArtifactRuntime {
        try processWideProvider.runtime()
    }

    static func processWideRootURL(
        applicationSupportRootURL: URL,
        buildFlavor: MCPFilesystemIdentity.BuildFlavor
    ) -> URL {
        applicationSupportRootURL.appendingPathComponent(
            "CodeMapArtifactRuntime-\(buildFlavor.rawValue)",
            isDirectory: true
        )
    }

    static func makeProcessWideProvider(
        identity: MCPFilesystemIdentity,
        applicationSupportRootURL: URL,
        namespaceSaltProvider: @escaping @Sendable (URL, MCPFilesystemIdentity) throws -> Data = { rootURL, identity in
            try CodeMapRepositoryNamespaceSaltStore.loadOrCreate(
                rootURL: rootURL,
                identity: identity
            )
        },
        bindingIntegrationRegistryFactory: @escaping @Sendable ()
            -> WorkspaceCodemapBindingIntegrationRegistry = {
                WorkspaceCodemapBindingIntegrationRegistry()
            },
        postSuccessfulInitialization: @escaping @Sendable () -> Void = {}
    ) -> CodeMapArtifactRuntimeProvider {
        CodeMapArtifactRuntimeProvider {
            let rootURL = processWideRootURL(
                applicationSupportRootURL: applicationSupportRootURL,
                buildFlavor: identity.buildFlavor
            )
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let registry = bindingIntegrationRegistryFactory()
            let runtime = try CodeMapArtifactRuntime(
                rootURL: rootURL,
                artifactStoreLeaseAdmission: .processWide,
                bindingIntegrationRegistry: registry,
                bindingEngineFactory: { runtime in
                    let namespaceSalt = try namespaceSaltProvider(rootURL, identity)
                    return WorkspaceCodemapBindingEngine(
                        runtime: runtime,
                        capabilityService: WorkspaceCodemapGitCapabilityService(
                            namespaceSalt: namespaceSalt
                        ),
                        sourceReader: registry.makeValidatedSourceReaderClient(),
                        catalogClient: registry.makeBindingCatalogClient()
                    )
                }
            )
            postSuccessfulInitialization()
            return runtime
        }
    }

    private static let processWideProvider: CodeMapArtifactRuntimeProvider = {
        let identity = MCPFilesystemConstants.identity
        #if DEBUG
            return makeProcessWideProvider(
                identity: identity,
                applicationSupportRootURL: identity.applicationSupportRootURL()
            )
        #else
            return makeProcessWideProvider(
                identity: identity,
                applicationSupportRootURL: identity.applicationSupportRootURL(),
                postSuccessfulInitialization: {
                    CodeMapV6CacheDeletionScheduler.schedule()
                }
            )
        #endif
    }()
}

enum CodeMapRepositoryNamespaceSaltStoreError: Error {
    case insecureStorage
    case ioFailure(operation: String, code: Int32)
}

enum CodeMapRepositoryNamespaceSaltSynchronizationOperation: Equatable {
    case temporaryFile
    case rootDirectory
}

struct CodeMapRepositoryNamespaceSaltStoreHooks {
    var beforePublish: @Sendable () -> Void
    var synchronize: @Sendable (Int32, CodeMapRepositoryNamespaceSaltSynchronizationOperation) -> Int32

    init(
        beforePublish: @escaping @Sendable () -> Void = {},
        synchronize: @escaping @Sendable (
            Int32,
            CodeMapRepositoryNamespaceSaltSynchronizationOperation
        ) -> Int32 = { descriptor, _ in fsync(descriptor) }
    ) {
        self.beforePublish = beforePublish
        self.synchronize = synchronize
    }

    static let none = CodeMapRepositoryNamespaceSaltStoreHooks()
}

/// Persists the private installation salt used to derive path-free Git repository namespaces.
/// Product/build identity separates debug and release storage without incorporating repository paths.
enum CodeMapRepositoryNamespaceSaltStore {
    private static let fileMode = mode_t(S_IRUSR | S_IWUSR)

    static func loadOrCreate(
        rootURL: URL,
        identity: MCPFilesystemIdentity,
        hooks: CodeMapRepositoryNamespaceSaltStoreHooks = .none
    ) throws -> Data {
        let rootDescriptor = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else { throw ioError("root-open") }
        defer { Darwin.close(rootDescriptor) }
        var rootStatus = stat()
        guard fstat(rootDescriptor, &rootStatus) == 0 else { throw ioError("root-stat") }
        guard rootStatus.st_mode & S_IFMT == S_IFDIR,
              rootStatus.st_uid == getuid(),
              rootStatus.st_mode & (S_IRWXG | S_IRWXO) == 0
        else { throw CodeMapRepositoryNamespaceSaltStoreError.insecureStorage }

        let fileName = "repository-namespace-salt-\(identity.product.rawValue)-\(identity.buildFlavor.rawValue)-v1"
        if let existing = try read(parentDescriptor: rootDescriptor, name: fileName) {
            return existing
        }

        let temporaryName = ".\(fileName).tmp.\(UUID().uuidString)"
        let temporaryDescriptor = openat(
            rootDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            fileMode
        )
        guard temporaryDescriptor >= 0 else { throw ioError("temporary-create") }
        defer {
            Darwin.close(temporaryDescriptor)
            unlinkat(rootDescriptor, temporaryName, 0)
        }

        var generator = SystemRandomNumberGenerator()
        let generated = Data((0 ..< GitBlobRepositoryNamespace.saltByteCount).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
        try writeAll(generated, descriptor: temporaryDescriptor)
        try synchronize(
            temporaryDescriptor,
            operation: .temporaryFile,
            name: "temporary-fsync",
            hooks: hooks
        )

        hooks.beforePublish()
        let renameResult = renameatx_np(
            rootDescriptor,
            temporaryName,
            rootDescriptor,
            fileName,
            UInt32(RENAME_EXCL)
        )
        if renameResult != 0 {
            let publishError = errno
            guard publishError == EEXIST else { throw ioError("publish", code: publishError) }
            guard let winner = try read(parentDescriptor: rootDescriptor, name: fileName) else {
                throw ioError("publish", code: publishError)
            }
            try synchronize(
                rootDescriptor,
                operation: .rootDirectory,
                name: "root-fsync",
                hooks: hooks
            )
            return winner
        }
        try synchronize(
            rootDescriptor,
            operation: .rootDirectory,
            name: "root-fsync",
            hooks: hooks
        )
        return generated
    }

    private static func read(parentDescriptor: Int32, name: String) throws -> Data? {
        let descriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw ioError("salt-open") }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw ioError("salt-stat") }
        guard status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1,
              status.st_size == off_t(GitBlobRepositoryNamespace.saltByteCount),
              status.st_mode & (S_IRWXG | S_IRWXO) == 0
        else { throw CodeMapRepositoryNamespaceSaltStoreError.insecureStorage }

        var result = Data(count: GitBlobRepositoryNamespace.saltByteCount)
        var offset = 0
        while offset < result.count {
            let count = result.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
            }
            guard count > 0 else {
                if count < 0, errno == EINTR { continue }
                throw count == 0
                    ? CodeMapRepositoryNamespaceSaltStoreError.insecureStorage
                    : ioError("salt-read")
            }
            offset += count
        }
        return result
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
            }
            guard count > 0 else {
                if count < 0, errno == EINTR { continue }
                throw ioError("salt-write")
            }
            offset += count
        }
    }

    private static func synchronize(
        _ descriptor: Int32,
        operation: CodeMapRepositoryNamespaceSaltSynchronizationOperation,
        name: String,
        hooks: CodeMapRepositoryNamespaceSaltStoreHooks
    ) throws {
        while hooks.synchronize(descriptor, operation) != 0 {
            if errno == EINTR { continue }
            throw ioError(name)
        }
    }

    private static func ioError(
        _ operation: String,
        code: Int32 = errno
    ) -> CodeMapRepositoryNamespaceSaltStoreError {
        .ioFailure(operation: operation, code: code)
    }
}

final class CodeMapArtifactRuntimeProvider: @unchecked Sendable {
    typealias Factory = @Sendable () throws -> CodeMapArtifactRuntime

    private let lock = NSLock()
    private let factory: Factory
    private var cachedResult: Result<CodeMapArtifactRuntime, Error>?

    init(factory: @escaping Factory) {
        self.factory = factory
    }

    func runtime() throws -> CodeMapArtifactRuntime {
        lock.lock()
        defer { lock.unlock() }

        if let cachedResult {
            return try cachedResult.get()
        }

        let result: Result<CodeMapArtifactRuntime, Error>
        do {
            result = try .success(factory())
        } catch {
            result = .failure(error)
        }
        cachedResult = result
        return try result.get()
    }
}
