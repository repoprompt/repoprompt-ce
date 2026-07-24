import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

class WorkspaceFileContextStoreCodemapSeamTestSupport: XCTestCase {
    func smallManifestAdoptionPolicy(recordLimit: Int) -> WorkspaceCodemapBindingEnginePolicy {
        precondition(recordLimit > 0)
        return WorkspaceCodemapBindingEnginePolicy(maximumManifestAdoptionRecordCount: recordLimit)
    }

    func waitForCompletionBeforeExternalDeadline(
        _ completion: CodemapBoundedCompletionState,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) async -> Bool {
        while clock.now < deadline {
            if completion.completedBeforeDeadline {
                return true
            }
            if completion.isFinished {
                return completion.expireDeadline()
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return completion.expireDeadline()
    }

    func waitForBoundedCompletionDrain(
        _ completion: CodemapBoundedCompletionState,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        do {
            try await AsyncTestWait.waitUntil(
                "bounded codemap completion drain",
                timeout: Self.timeInterval(timeout)
            ) {
                completion.isFinished
            }
            return true
        } catch {
            return completion.isFinished
        }
    }

    func pendingTicket(
        _ result: WorkspaceCodemapArtifactDemandResult
    ) throws -> WorkspaceCodemapArtifactDemandTicket {
        guard case let .pending(ticket) = result else {
            throw CodemapStoreTestError.expectedPending
        }
        return ticket
    }

    func graphIndexPage(
        _ disposition: WorkspaceCodemapGraphIndexCatalogPageDisposition
    ) throws -> WorkspaceCodemapGraphIndexCatalogPage {
        guard case let .page(page) = disposition else {
            throw CodemapStoreTestError.expectedGraphIndexPage
        }
        return page
    }

    func readyResult(
        _ result: WorkspaceCodemapArtifactDemandResult
    ) throws -> WorkspaceCodemapArtifactDemandReady {
        guard case let .ready(ready) = result else {
            throw CodemapStoreTestError.expectedReady
        }
        return ready
    }

    /// Requests a codemap artifact demand and retries through transient unavailability
    /// (git transient failures, busy backoff, runtime setup hiccups) until the demand
    /// settles ready or a stable unavailability/timeout is reached. Hosted CI runners
    /// can transiently fail git authority capture under load; re-requesting detaches
    /// the failed session and re-triggers setup so the test reaches the ready state
    /// it needs without masking genuine terminal failures.
    func readyArtifactDemand(
        store: WorkspaceFileContextStore,
        forFileID fileID: UUID,
        timeout: Duration = .seconds(30),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> (ticket: WorkspaceCodemapArtifactDemandTicket, ready: WorkspaceCodemapArtifactDemandReady) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastNonReadyResult: WorkspaceCodemapArtifactDemandResult?
        while clock.now < deadline {
            let initial = await store.requestCodemapArtifact(forFileID: fileID)
            switch initial {
            case let .pending(ticket):
                let result = try await settledResult(store: store, ticket: ticket)
                switch result {
                case let .ready(ready):
                    return (ticket, ready)
                case let .unavailable(reason) where !Self.demandUnavailableIsStable(reason):
                    lastNonReadyResult = result
                    try await Task.sleep(for: .milliseconds(50))
                    continue
                default:
                    lastNonReadyResult = result
                    throw CodemapStoreTestError.expectedReady
                }
            case let .ready(ready):
                return (ready.ticket, ready)
            case let .unavailable(reason) where !Self.demandUnavailableIsStable(reason):
                lastNonReadyResult = initial
                try await Task.sleep(for: .milliseconds(50))
                continue
            default:
                lastNonReadyResult = initial
                throw CodemapStoreTestError.expectedReady
            }
        }
        XCTFail(
            "Timed out waiting for ready codemap artifact demand; last result = \(String(describing: lastNonReadyResult)).",
            file: file,
            line: line
        )
        throw CodemapStoreTestError.timedOut
    }

    private static func demandUnavailableIsStable(
        _ reason: WorkspaceCodemapArtifactDemandUnavailableReason
    ) -> Bool {
        switch reason {
        case .rootNotLoaded, .fileNotCataloged, .unsupportedFileType:
            true
        case let .gitTerminal(reason):
            reason != .releasedRootEpoch
        case let .demandUnavailable(reason):
            reason != .transient
        case .gitTransient, .busy, .rejected, .routeConflict, .registrationFailed,
             .runtimeFailure, .staleCurrentness, .cancelled:
            false
        }
    }

    func frozenPresentationBundle(
        _ disposition: WorkspaceCodemapPresentationFreezeDisposition
    ) throws -> WorkspaceCodemapFrozenPresentationBundle {
        guard case let .ready(bundle) = disposition else {
            throw CodemapStoreTestError.expectedFrozenPresentationBundle
        }
        return bundle
    }

    func renderedPresentationEntries(
        _ disposition: WorkspaceCodemapPresentationRenderDisposition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [WorkspaceCodemapRenderedPresentationEntry] {
        guard case let .ready(entries) = disposition else {
            if case let .unavailable(reason) = disposition {
                XCTFail(
                    "Expected rendered presentation entries, got \(reason).",
                    file: file,
                    line: line
                )
            }
            throw CodemapStoreTestError.expectedRenderedPresentationEntries
        }
        return entries
    }

    func assertPresentationFreezeUnavailable(
        _ disposition: WorkspaceCodemapPresentationFreezeDisposition,
        equals expected: WorkspaceCodemapPresentationFreezeUnavailableReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .unavailable(actual) = disposition else {
            return XCTFail(
                "Expected presentation freeze unavailability.",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func assertPresentationRenderUnavailable(
        _ disposition: WorkspaceCodemapPresentationRenderDisposition,
        equals expected: WorkspaceCodemapPresentationRenderUnavailableReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .unavailable(actual) = disposition else {
            return XCTFail(
                "Expected presentation render unavailability.",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    func settledResult(
        store: WorkspaceFileContextStore,
        ticket: WorkspaceCodemapArtifactDemandTicket,
        timeout: Duration = .seconds(15)
    ) async throws -> WorkspaceCodemapArtifactDemandResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let result = await store.codemapArtifactDemandStatus(ticket)
            if case .pending = result {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            return result
        }
        throw CodemapStoreTestError.timedOut
    }

    func currentCodemapArtifactDemand(
        store: WorkspaceFileContextStore,
        fileID: UUID,
        phase: String,
        timeout: Duration = .seconds(15),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> WorkspaceCodemapArtifactDemandResult {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var latestResult: WorkspaceCodemapArtifactDemandResult?
        while clock.now < deadline {
            let result = await store.requestCodemapArtifact(forFileID: fileID)
            latestResult = result
            switch result {
            case .pending, .ready:
                return result
            case let .unavailable(.busy(retryAfterMilliseconds)):
                let retryMilliseconds = retryAfterMilliseconds.map { UInt64(max(0, $0)) } ?? 25
                try await Task.sleep(for: .milliseconds(
                    min(1000, max(25, Int(exactly: retryMilliseconds) ?? 1000))
                ))
            case .unavailable:
                XCTFail("Expected \(phase) codemap artifact demand, got \(result).", file: file, line: line)
                throw CodemapStoreTestError.timedOut
            }
        }
        XCTFail(
            "Timed out waiting for \(phase) codemap artifact demand; latest=\(String(describing: latestResult)).",
            file: file,
            line: line
        )
        throw CodemapStoreTestError.timedOut
    }

    func routeBecomesUnavailable(
        registry: WorkspaceCodemapBindingIntegrationRegistry,
        ticket: WorkspaceCodemapArtifactDemandTicket,
        relativePath: String
    ) async -> Bool {
        do {
            try await AsyncTestWait.waitUntil("codemap route unavailable", timeout: 5) {
                let candidate = await registry.makeBindingCatalogClient()
                    .resolveManifestBinding(ticket.rootEpoch, relativePath)
                return candidate == nil
            }
            return true
        } catch {
            XCTFail(error.localizedDescription)
            return false
        }
    }

    func assertEngineRootCount(
        _ expected: Int,
        fixture: CodemapStoreFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let engine = try fixture.runtime().bindingEngine()
        let accounting = await engine.accounting()
        XCTAssertEqual(accounting.rootCount, expected, file: file, line: line)
    }

    func engineRootCountBecomesZero(
        fixture: CodemapStoreFixture
    ) async throws -> Bool {
        let engine = try fixture.runtime().bindingEngine()
        do {
            try await AsyncTestWait.waitUntil("codemap engine root count zero", timeout: 5) {
                await engine.accounting().rootCount == 0
            }
            return true
        } catch {
            return await engine.accounting().rootCount == 0
        }
    }

    func waitForCodemapGraphIndexBuildEvent(
        store: WorkspaceFileContextStore,
        rootID: UUID,
        kind: WorkspaceFileContextStore.CodemapGraphIndexBuildStoreEventKind,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        await waitForCodemapGraphIndexBuildEventCount(
            store: store,
            rootID: rootID,
            kind: kind,
            count: 1,
            timeout: timeout
        )
    }

    func waitForCodemapGraphIndexBuildEventCount(
        store: WorkspaceFileContextStore,
        rootID: UUID,
        kind: WorkspaceFileContextStore.CodemapGraphIndexBuildStoreEventKind,
        count: Int,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        do {
            try await AsyncTestWait.waitUntil(
                "codemap graph-index build event count",
                timeout: Self.timeInterval(timeout)
            ) {
                let events = await store.codemapGraphIndexBuildStoreEventsForTesting(rootID: rootID)
                return events.count(where: { $0.kind == kind }) >= count
            }
            return true
        } catch {
            let events = await store.codemapGraphIndexBuildStoreEventsForTesting(rootID: rootID)
            return events.count(where: { $0.kind == kind }) >= count
        }
    }

    func assertNonGitTerminal(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.gitTerminal(.nonGit)) = result else {
            return XCTFail("Expected terminal non-Git unavailability.", file: file, line: line)
        }
    }

    func assertCancelled(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.cancelled) = result else {
            return XCTFail("Expected cancelled unavailability.", file: file, line: line)
        }
    }

    func assertStale(
        _ result: WorkspaceCodemapArtifactDemandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .unavailable(.staleCurrentness) = result else {
            return XCTFail("Expected stale currentness.", file: file, line: line)
        }
    }

    static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) +
            TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

enum CodemapStoreTestError: Error {
    case expectedFrozenPresentationBundle
    case expectedPending
    case expectedGraphIndexPage
    case expectedReady
    case expectedRenderedPresentationEntries
    case timedOut
}

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

final class CodemapStoreFixture: @unchecked Sendable {
    let registry = WorkspaceCodemapBindingIntegrationRegistry()
    let providerAccessCount = CodemapLockedCounter()
    let runtimeFactoryCount = CodemapLockedCounter()
    let engineFactoryCount = CodemapLockedCounter()
    let manifestReadCount = CodemapLockedCounter()
    let buildCount = CodemapLockedCounter()
    let buildPriorities = CodemapLockedValues<CodeMapArtifactBuildPriority>()
    let builtSourceTexts = CodemapLockedValues<String>()
    let demandedTickets = CodemapLockedValues<WorkspaceCodemapArtifactDemandTicket>()

    private let sandbox: URL
    private let artifactRoot: URL
    private let runtimeTracker: CodemapRuntimeTracker
    private let freshRuntimeFactory: @Sendable () throws -> CodeMapArtifactRuntime
    private let runtimeProvider: CodeMapArtifactRuntimeProvider

    init(
        name: String,
        syntheticGraphArtifacts: Bool = false,
        artifactBuilder: CodeMapArtifactBuilderClient? = nil,
        artifactCoordinatorPolicy: CodeMapArtifactBuildCoordinatorPolicy = .default,
        bindingEnginePolicy: WorkspaceCodemapBindingEnginePolicy = .default,
        manifestStoreFaultAction: @escaping @Sendable (
            CodeMapRootManifestStoreFaultPoint
        ) -> CodeMapRootManifestStoreFaultAction = { _ in .proceed }
    ) throws {
        let sandbox = try Self.makeSandbox(name: name)
        let artifactRoot = try Self.makeSecureDirectory(in: sandbox, named: "artifacts")
        let registry = registry
        let runtimeFactoryCount = runtimeFactoryCount
        let engineFactoryCount = engineFactoryCount
        let manifestReadCount = manifestReadCount
        let buildCount = buildCount
        let buildPriorities = buildPriorities
        let builtSourceTexts = builtSourceTexts
        let defaultBuilder = artifactBuilder ?? CodeMapArtifactBuilderClient()
        let runtimeTracker = CodemapRuntimeTracker()
        let freshRuntimeFactory: @Sendable () throws -> CodeMapArtifactRuntime = {
            runtimeFactoryCount.increment()
            return try runtimeTracker.record(CodeMapArtifactRuntime(
                rootURL: artifactRoot,
                manifestStoreHooks: CodeMapRootManifestStoreHooks(
                    afterReadAdmission: {
                        manifestReadCount.increment()
                    },
                    faultAction: manifestStoreFaultAction
                ),
                builder: CodeMapArtifactBuilderClient(execute: { input, ownerID, priority in
                    buildCount.increment()
                    buildPriorities.append(priority)
                    if case let .decoded(source) = input.source.decodeResult {
                        builtSourceTexts.append(source.text)
                    }
                    if syntheticGraphArtifacts,
                       case let .decoded(source) = input.source.decodeResult
                    {
                        return CodeMapArtifactBuilderExecution(
                            outcome: .ready(Self.syntheticGraphArtifact(source.text)),
                            permitWaitNanoseconds: 0,
                            buildNanoseconds: 0
                        )
                    }
                    return try await defaultBuilder.execute(input, ownerID, priority)
                }),
                coordinatorPolicy: artifactCoordinatorPolicy,
                bindingIntegrationRegistry: registry,
                bindingEngineFactory: { runtime in
                    engineFactoryCount.increment()
                    return WorkspaceCodemapBindingEngine(
                        runtime: runtime,
                        capabilityService: WorkspaceCodemapGitCapabilityService(
                            namespaceSalt: Data(
                                repeating: 0x6C,
                                count: GitBlobRepositoryNamespace.saltByteCount
                            )
                        ),
                        sourceReader: registry.makeValidatedSourceReaderClient(),
                        catalogClient: registry.makeBindingCatalogClient(),
                        policy: bindingEnginePolicy
                    )
                }
            ))
        }
        runtimeProvider = CodeMapArtifactRuntimeProvider(factory: freshRuntimeFactory)
        self.sandbox = sandbox
        self.artifactRoot = artifactRoot
        self.runtimeTracker = runtimeTracker
        self.freshRuntimeFactory = freshRuntimeFactory
    }

    deinit {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func makeStore(
        codemapLocalGitClassificationProbe: WorkspaceCodemapLocalGitClassificationProbe = .init { _ in
            .requiresGitPreflight
        },
        codemapGitEligibilityProbe: WorkspaceCodemapGitEligibilityProbe = WorkspaceCodemapGitEligibilityProbe { _ in
            .eligible
        },
        codemapGraphIndexBuildRetryPolicy: WorkspaceFileContextStore.CodemapGraphIndexBuildRetryPolicy = .production,
        codemapGraphIndexBuildLaunchPolicy: WorkspaceFileContextStore.CodemapGraphIndexBuildLaunchPolicyForTesting = .enabled,
        selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory = .production,
        selectionGraphQueryBudgetPolicy: WorkspaceCodemapAutomaticSelectionBudgetPolicy = .initial,
        automaticSelectionAccountingMaximum: Int = .max,
        demandRequestHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket
        ) async -> Void = { _ in },
        cancellationCleanupHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket
        ) async -> Void = { _ in },
        readyPublicationHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket
        ) async -> Void = { _ in },
        demandResultHook: @escaping @Sendable (
            WorkspaceCodemapArtifactDemandTicket,
            WorkspaceCodemapBindingDemandResult
        ) async -> WorkspaceCodemapBindingDemandResult = { _, result in result },
        automaticSelectionQueryHook: @escaping @Sendable (
            WorkspaceCodemapRootEpoch
        ) async -> Void = { _ in }
    ) -> WorkspaceFileContextStore {
        let providerAccessCount = providerAccessCount
        let runtimeProvider = runtimeProvider
        let demandedTickets = demandedTickets
        return WorkspaceFileContextStore(
            codemapRuntimeProvider: {
                providerAccessCount.increment()
                return try runtimeProvider.runtime()
            },
            codemapLocalGitClassificationProbe: codemapLocalGitClassificationProbe,
            codemapGitEligibilityProbe: codemapGitEligibilityProbe,
            codemapGraphIndexBuildRetryPolicy: codemapGraphIndexBuildRetryPolicy,
            codemapGraphIndexBuildLaunchPolicyForTesting: codemapGraphIndexBuildLaunchPolicy,
            selectionGraphFactory: selectionGraphFactory,
            selectionGraphQueryBudgetPolicy: selectionGraphQueryBudgetPolicy,
            automaticSelectionAccountingMaximum: automaticSelectionAccountingMaximum,
            codemapDemandRequestHook: { ticket in
                demandedTickets.append(ticket)
                await demandRequestHook(ticket)
            },
            codemapCancellationCleanupHook: cancellationCleanupHook,
            codemapReadyPublicationHook: readyPublicationHook,
            codemapDemandResultHook: demandResultHook,
            codemapAutomaticSelectionQueryHook: automaticSelectionQueryHook
        )
    }

    func makeFreshStore(
        codemapGraphIndexBuildLaunchPolicy: WorkspaceFileContextStore.CodemapGraphIndexBuildLaunchPolicyForTesting = .enabled,
        selectionGraphFactory: WorkspaceCodemapSelectionGraphFactory = .production
    ) throws -> WorkspaceFileContextStore {
        let runtime = try freshRuntimeFactory()
        let providerAccessCount = providerAccessCount
        return WorkspaceFileContextStore(
            codemapRuntimeProvider: {
                providerAccessCount.increment()
                return runtime
            },
            codemapGraphIndexBuildLaunchPolicyForTesting: codemapGraphIndexBuildLaunchPolicy,
            selectionGraphFactory: selectionGraphFactory
        )
    }

    func artifactURL(for key: CodeMapArtifactKey) -> URL {
        artifactRoot
            .appendingPathComponent("CodeMapArtifacts", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(key.shard, isDirectory: true)
            .appendingPathComponent(key.storageDigestHex)
    }

    func makePlainRoot(files: [String: String]) throws -> URL {
        let root = sandbox.appendingPathComponent(
            "plain-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, contents) in files {
            try Self.write(
                contents,
                to: root.appendingPathComponent(relativePath)
            )
        }
        return root
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

    static func makeSandbox(name: String) throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WorkspaceFileContextStoreCodemapSeamTests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        return sandbox
    }

    private static func makeSecureDirectory(in parent: URL, named name: String) throws -> URL {
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let resolvedPath = try directory.path.withCString { pointer -> String in
            guard let resolved = realpath(pointer, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }

    private static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func syntheticGraphArtifact(_ source: String) -> CodeMapSyntaxArtifact {
        let definitions: [String]
        let references: [String]
        if source.contains("let target: Target") {
            definitions = ["Source"]
            references = ["Target"]
        } else if source.contains("protocol FirstSource") {
            definitions = ["FirstSource"]
            references = ["FirstTarget"]
        } else if source.contains("protocol SecondSource") {
            definitions = ["SecondSource"]
            references = ["SecondTarget"]
        } else if source.contains("protocol SourceProtocol") {
            definitions = ["SourceProtocol"]
            if source.contains("ForeignDefinition") {
                references = ["ForeignDefinition"]
            } else if source.contains("FirstTarget"), source.contains("SecondTarget") {
                references = ["FirstTarget", "SecondTarget"]
            } else {
                references = ["Target"]
            }
        } else if source.contains("ForeignDefinition") {
            definitions = ["ForeignDefinition"]
            references = []
        } else if source.contains("FirstTarget") {
            definitions = ["FirstTarget"]
            references = []
        } else if source.contains("SecondTarget") {
            definitions = ["SecondTarget"]
            references = []
        } else if source.contains("Target") {
            definitions = ["Target"]
            references = []
        } else {
            definitions = []
            references = []
        }
        return CodeMapSyntaxArtifact(
            imports: [],
            classes: definitions.map { ClassInfo(name: $0, methods: [], properties: []) },
            functions: [],
            enums: [],
            globalVars: [],
            macros: [],
            referencedTypes: references
        )
    }
}

final class CodemapBoundedCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var deadlineExpired = false
    private var completed = false
    private var finished = false

    var completedBeforeDeadline: Bool {
        lock.withLock { completed }
    }

    var isFinished: Bool {
        lock.withLock { finished }
    }

    func recordCompletion(beforeDeadline: Bool) {
        lock.withLock {
            finished = true
            if beforeDeadline, !deadlineExpired {
                completed = true
            }
        }
    }

    func expireDeadline() -> Bool {
        lock.withLock {
            deadlineExpired = true
            return completed
        }
    }
}

final class CodemapManifestWriteAttemptLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var continuations: [UUID: AsyncStream<Int>.Continuation] = [:]

    func recordAttempt() -> Int {
        let update = lock.withLock {
            attempts += 1
            return (count: attempts, continuations: Array(continuations.values))
        }
        for continuation in update.continuations {
            continuation.yield(update.count)
        }
        return update.count
    }

    func waitForAttemptCount(_ count: Int, timeout: Duration) async -> Bool {
        if currentAttemptCount >= count { return true }
        let stream = attemptStream()
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await attemptCount in stream where attemptCount >= count {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return self.currentAttemptCount >= count
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result || self.currentAttemptCount >= count
        }
    }

    private var currentAttemptCount: Int {
        lock.withLock { attempts }
    }

    private func attemptStream() -> AsyncStream<Int> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }
            let current = lock.withLock {
                continuations[id] = continuation
                return attempts
            }
            continuation.yield(current)
        }
    }

    private func removeContinuation(id: UUID) {
        _ = lock.withLock { continuations.removeValue(forKey: id) }
    }
}

final class CodemapLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }

    func incrementAndGet() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
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
