import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

enum WarmManifestCandidateState: CaseIterable {
    case stagedOnly
    case stagedAndUnstaged
    case untrackedReplacement
    case conflict
    case checkoutTransform
}

class CodemapBindingEngineTestCase: XCTestCase {
    private var retainedRepositoryFixtures: [ReviewGitRepositoryFixture] = []

    func publishVerifiedManifestRecord(
        fixture: EngineFixture,
        runtime: CodeMapArtifactRuntime,
        ready: WorkspaceCodemapLiveReadySnapshot,
        bindingGeneration: UInt64? = nil
    ) async throws -> CodeMapRootManifestRecord {
        let capabilityState = await fixture.capabilityService.state(for: fixture.rootEpoch)
        let capability = try eligible(capabilityState)
        let classificationBatch = await GitBlobIdentityService().classify(
            workspaceRoot: fixture.root,
            relativePaths: [ready.standardizedRelativePath]
        )
        guard classificationBatch.failure == nil,
              let classification = classificationBatch.classifications.first,
              let repositoryRelativePath = classification.repositoryRelativePath,
              case let .oidEligible(blobOID) = classification.outcome,
              let indexMode = classification.indexEntries.first(where: { $0.stage == 0 })?.mode
        else {
            throw WorkspaceCodemapProvenanceTestSupportError.capabilityUnavailable
        }
        let pipeline = try SyntaxManager.shared.pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let namespace = try CodeMapRootManifestNamespace(
            capability: capability,
            pipelineIdentity: pipeline
        )
        let authority = try CodeMapRootManifestAuthority(
            namespace: namespace,
            token: capability.repositoryAuthority
        )
        let locator = GitBlobCodeMapLocatorIdentity(
            repositoryNamespace: capability.repositoryNamespace,
            blobOID: blobOID,
            pipelineIdentity: pipeline
        )
        let result = try await runtime.coordinator.resolve(CodeMapArtifactBuildRequest(
            ownerID: fixture.rootEpoch.rootLifetimeID,
            priority: .explicit,
            target: .locator(locator)
        ))
        guard case let .ready(resolution) = result,
              resolution.handle.key == ready.artifactKey
        else {
            throw WorkspaceCodemapProvenanceTestSupportError.capabilityUnavailable
        }
        let association = try VerifiedGitBlobCodeMapLocatorAssociation.revalidatePersisted(
            identity: locator,
            artifactKey: ready.artifactKey,
            casHandle: resolution.handle
        )
        let contribution: CodeMapSelectionGraphContribution? = switch association.outcome {
        case let .ready(artifact):
            CodeMapSelectionGraphContribution(
                artifactKey: association.artifactKey,
                artifact: artifact
            )
        case .readyNoSymbols:
            CodeMapSelectionGraphContribution(
                artifactKey: association.artifactKey,
                definitions: [],
                references: []
            )
        case .oversize, .decodeFailed, .parseFailed:
            nil
        }
        let record = try CodeMapRootManifestRecord.verifiedClean(
            namespace: namespace,
            repositoryRelativePath: repositoryRelativePath,
            gitMode: CodeMapRootManifestGitMode(gitValue: indexMode),
            association: association,
            contribution: contribution,
            authority: authority,
            bindingGeneration: bindingGeneration ?? ready.requestGeneration
        )
        _ = try await runtime.manifestStore.replaceCurrentManifest(
            namespace: namespace,
            authority: authority,
            records: [record],
            lastAccessEpochSeconds: 42
        )
        return record
    }

    func replaceCurrentManifestWithEmpty(
        fixture: EngineFixture,
        runtime: CodeMapArtifactRuntime
    ) async throws {
        let capability = try await eligible(fixture.capabilityService.state(for: fixture.rootEpoch))
        let pipeline = try SyntaxManager.shared.pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        let namespace = try CodeMapRootManifestNamespace(
            capability: capability,
            pipelineIdentity: pipeline
        )
        _ = try await runtime.manifestStore.replaceCurrentManifest(
            namespace: namespace,
            authority: CodeMapRootManifestAuthority(
                namespace: namespace,
                token: capability.repositoryAuthority
            ),
            records: [],
            lastAccessEpochSeconds: 42
        )
    }

    func republishManifestForCurrentAuthority(
        record: CodeMapRootManifestRecord,
        root: URL,
        runtime: CodeMapArtifactRuntime
    ) async throws {
        let service = capabilityService()
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        let state = await service.resolve(root: WorkspaceCodemapGitCapabilityRequest(
            rootID: rootEpoch.rootID,
            rootLifetimeID: rootEpoch.rootLifetimeID,
            loadedRootURL: root
        ))
        let capability = try eligible(state)
        let namespace = try CodeMapRootManifestNamespace(
            capability: capability,
            pipelineIdentity: record.locatorIdentity.pipelineIdentity
        )
        let authority = try CodeMapRootManifestAuthority(
            namespace: namespace,
            token: capability.repositoryAuthority
        )
        let result = try await runtime.coordinator.resolve(CodeMapArtifactBuildRequest(
            ownerID: rootEpoch.rootLifetimeID,
            priority: .explicit,
            target: .artifactKey(record.artifactKey)
        ))
        guard case let .ready(resolution) = result else {
            throw WorkspaceCodemapProvenanceTestSupportError.capabilityUnavailable
        }
        let association = try VerifiedGitBlobCodeMapLocatorAssociation.revalidatePersisted(
            identity: record.locatorIdentity,
            artifactKey: record.artifactKey,
            casHandle: resolution.handle
        )
        let contribution: CodeMapSelectionGraphContribution? = switch association.outcome {
        case let .ready(artifact):
            CodeMapSelectionGraphContribution(
                artifactKey: association.artifactKey,
                artifact: artifact
            )
        case .readyNoSymbols:
            CodeMapSelectionGraphContribution(
                artifactKey: association.artifactKey,
                definitions: [],
                references: []
            )
        case .oversize, .decodeFailed, .parseFailed:
            nil
        }
        let refreshed = try CodeMapRootManifestRecord.verifiedClean(
            namespace: namespace,
            repositoryRelativePath: record.repositoryRelativePath,
            gitMode: record.gitMode,
            association: association,
            contribution: contribution,
            authority: authority,
            bindingGeneration: record.bindingGeneration
        )
        _ = try await runtime.manifestStore.replaceCurrentManifest(
            namespace: namespace,
            authority: authority,
            records: [refreshed],
            lastAccessEpochSeconds: 42
        )
        await service.release(rootEpoch: rootEpoch)
    }

    func configureWarmManifestCandidate(
        _ state: WarmManifestCandidateState,
        repository: ReviewGitRepositoryFixture,
        root: URL,
        path: String
    ) throws {
        switch state {
        case .stagedOnly:
            try repository.write("struct Candidate { let staged = true }\n", to: path, at: root)
            try repository.stage(path, at: root)
        case .stagedAndUnstaged:
            try repository.write("struct Candidate { let staged = true }\n", to: path, at: root)
            try repository.stage(path, at: root)
            try repository.write("struct Candidate { let unstaged = true }\n", to: path, at: root)
        case .untrackedReplacement:
            _ = try repository.runGit(["rm", "--cached", "--", path], at: root)
            try repository.write("struct Candidate { let replacement = true }\n", to: path, at: root)
        case .conflict:
            _ = try repository.runGit(["checkout", "-b", "other"], at: root)
            try repository.write("struct Candidate { let side = 1 }\n", to: path, at: root)
            try repository.stage(path, at: root)
            try repository.commit("Other", at: root)
            _ = try repository.runGit(["checkout", "main"], at: root)
            try repository.write("struct Candidate { let side = 2 }\n", to: path, at: root)
            try repository.stage(path, at: root)
            try repository.commit("Main", at: root)
            let merge = try repository.runGitResult(["merge", "other"], at: root)
            XCTAssertNotEqual(merge.terminationStatus, 0)
        case .checkoutTransform:
            try repository.write("\(path) text eol=crlf\n", to: ".gitattributes", at: root)
        }
    }

    func assertWarmManifestClassification(
        _ classification: GitBlobIdentityClassification,
        matches state: WarmManifestCandidateState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch state {
        case .stagedOnly:
            guard case .oidEligible = classification.outcome else {
                return XCTFail("Expected staged-only OID eligibility.", file: file, line: line)
            }
            XCTAssertTrue(classification.porcelainRecord?.hasIndexChange == true, file: file, line: line)
            XCTAssertFalse(classification.porcelainRecord?.hasWorkTreeChange == true, file: file, line: line)
        case .stagedAndUnstaged:
            XCTAssertEqual(
                classification.outcome,
                .requiresValidatedWorktreeBytes(.stagedAndUnstaged),
                file: file,
                line: line
            )
        case .untrackedReplacement:
            XCTAssertEqual(
                classification.outcome,
                .requiresValidatedWorktreeBytes(.untracked),
                file: file,
                line: line
            )
        case .conflict:
            XCTAssertTrue(classification.hasConflictStages, file: file, line: line)
            XCTAssertEqual(
                classification.outcome,
                .requiresValidatedWorktreeBytes(.unmerged),
                file: file,
                line: line
            )
        case .checkoutTransform:
            XCTAssertEqual(
                classification.outcome,
                .requiresValidatedWorktreeBytes(.checkoutTransformation),
                file: file,
                line: line
            )
            XCTAssertNotEqual(
                classification.checkoutMaterialization,
                .bytePreserving,
                file: file,
                line: line
            )
        }
    }

    func makeRepositoryFixture(name: String) throws -> ReviewGitRepositoryFixture {
        let fixture = try ReviewGitRepositoryFixture(name: name)
        retainedRepositoryFixtures.append(fixture)
        addTeardownBlock { [fixture] in
            fixture.cleanup()
        }
        return fixture
    }

    func makeEngineFixture(
        root: URL,
        runtime: CodeMapArtifactRuntime,
        policy: WorkspaceCodemapBindingEnginePolicy = .default,
        hooks: WorkspaceCodemapBindingEngineHooks = .none,
        overlay: WorkspaceCodemapLiveOverlay? = nil,
        initialQueueOrdinal: UInt64 = 1,
        initialAdmissionOrdinal: UInt64 = 1,
        initialCounterValue: UInt64 = 0,
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        sourceReaderOverride: WorkspaceCodemapValidatedSourceReaderClient? = nil,
        materializationServiceOverride: GitBlobSourceMaterializationService? = nil,
        capabilityHooks: WorkspaceCodemapGitCapabilityServiceHooks = .none,
        identityHooks: GitBlobIdentityServiceHooks = .none,
        catalogResolutionHook: @escaping @Sendable (String) async -> Void = { _ in },
        projectionCatalogFactory: ((
            WorkspaceCodemapRootEpoch,
            EngineFileIDs
        ) -> WorkspaceCodemapBindingCatalogClient)? = nil
    ) async throws -> EngineFixture {
        let rootID = UUID()
        let lifetimeID = UUID()
        let rootEpoch = WorkspaceCodemapRootEpoch(rootID: rootID, rootLifetimeID: lifetimeID)
        let service = capabilityService(hooks: capabilityHooks)
        let fileSystem = try await FileSystemService(
            path: root.path,
            respectRepoIgnore: false,
            respectCursorignore: false
        )
        let fileIDs = EngineFileIDs()
        let defaultCatalog = WorkspaceCodemapBindingCatalogClient { epoch, relativePath in
            await catalogResolutionHook(relativePath)
            guard epoch == rootEpoch,
                  let identity = WorkspaceCodemapArtifactBindingIdentity(
                      rootID: rootID,
                      rootLifetimeID: lifetimeID,
                      fileID: fileIDs.id(for: relativePath),
                      standardizedRootPath: root.path,
                      standardizedRelativePath: relativePath,
                      standardizedFullPath: root.appendingPathComponent(relativePath).path
                  )
            else { return nil }
            return WorkspaceCodemapManifestBindingCandidate(
                identity: identity,
                requestGeneration: 1,
                pathGeneration: 1,
                ingressGeneration: 1
            )
        }
        let catalog = projectionCatalogFactory?(rootEpoch, fileIDs) ?? defaultCatalog
        let reader = WorkspaceCodemapValidatedSourceReaderClient { identity, expected, maximumBytes, ownerID in
            try await fileSystem.loadValidatedRawContent(
                ofRelativePath: identity.standardizedRelativePath,
                expectedFingerprint: FileContentFingerprint(
                    deviceID: expected.device,
                    fileNumber: expected.inode,
                    byteSize: expected.size,
                    modificationSeconds: expected.modificationSeconds,
                    modificationNanoseconds: expected.modificationNanoseconds,
                    statusChangeSeconds: expected.changeSeconds,
                    statusChangeNanoseconds: expected.changeNanoseconds
                ),
                maximumBytes: maximumBytes,
                workloadClass: .codemap,
                schedulerOwnerID: ownerID
            )
        }
        let registration = WorkspaceCodemapBindingRootRegistration(
            rootID: rootID,
            rootLifetimeID: lifetimeID,
            loadedRootURL: root,
            catalogGeneration: 1,
            ingressGeneration: 1
        )
        let engine = WorkspaceCodemapBindingEngine(
            runtime: runtime,
            capabilityService: service,
            identityService: GitBlobIdentityService(hooks: identityHooks),
            materializationService: materializationServiceOverride ?? GitBlobSourceMaterializationService(),
            sourceReader: sourceReaderOverride ?? reader,
            catalogClient: catalog,
            overlay: overlay ?? WorkspaceCodemapLiveOverlay(),
            policy: policy,
            hooks: hooks,
            initialQueueOrdinal: initialQueueOrdinal,
            initialAdmissionOrdinal: initialAdmissionOrdinal,
            initialCounterValue: initialCounterValue,
            uptimeNanoseconds: uptimeNanoseconds,
            accessEpochSeconds: { 42 }
        )
        addTeardownBlock { await engine.shutdown() }
        return EngineFixture(
            root: root,
            rootEpoch: rootEpoch,
            registration: registration,
            capabilityService: service,
            fileIDs: fileIDs,
            engine: engine
        )
    }

    func capabilityService(
        hooks: WorkspaceCodemapGitCapabilityServiceHooks = .none
    ) -> WorkspaceCodemapGitCapabilityService {
        WorkspaceCodemapGitCapabilityService(
            namespaceSalt: Data(repeating: 0x44, count: GitBlobRepositoryNamespace.saltByteCount),
            hooks: hooks
        )
    }

    func makeSecureDirectory(in parent: URL, named name: String) throws -> URL {
        let root = parent.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(root.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let resolvedPath = try root.path.withCString { pointer -> String in
            guard let value = realpath(pointer, nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { free(value) }
            return String(cString: value)
        }
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }

    func eligible(_ state: WorkspaceCodemapGitCapabilityState) throws -> GitCodemapRootCapability {
        guard case let .eligible(capability) = state else {
            throw WorkspaceCodemapProvenanceTestSupportError.capabilityUnavailable
        }
        return capability
    }

    func isReady(_ result: WorkspaceCodemapBindingDemandResult) -> Bool {
        switch result {
        case .ready, .alreadyReady:
            true
        default:
            false
        }
    }

    func bindingDemandFailureMessage(
        _ message: String,
        result: WorkspaceCodemapBindingDemandResult,
        accounting: WorkspaceCodemapBindingEngineAccounting,
        events: [WorkspaceCodemapBindingEngineHookEvent]
    ) -> String {
        """
        \(message) result=\(String(describing: result)); \
        accounting={\(bindingAccountingSummary(accounting))}; \
        events=[\(bindingHookSummary(events))]
        """
    }

    func bindingAccountingSummary(
        _ accounting: WorkspaceCodemapBindingEngineAccounting
    ) -> String {
        [
            "dirtyManifestCount=\(accounting.dirtyManifestCount)",
            "activeRequestCount=\(accounting.activeRequestCount)",
            "queuedRequestCount=\(accounting.queuedRequestCount)",
            "manifestWrites=\(accounting.counters.manifestWrites)",
            "manifestFailures=\(accounting.counters.manifestFailures)",
            "overlayReadyPublications=\(accounting.counters.overlayReadyPublications)",
            "overlayExactDuplicateCompletions=\(accounting.counters.overlayExactDuplicateCompletions)"
        ].joined(separator: ", ")
    }

    func bindingHookSummary(
        _ events: [WorkspaceCodemapBindingEngineHookEvent]
    ) -> String {
        events.enumerated().map { index, event in
            let rootDescription = event.rootEpoch.map { String(describing: $0) } ?? "nil"
            return "#\(index):\(event.kind.rawValue)(root=\(rootDescription),value=\(event.numericValue))"
        }.joined(separator: " -> ")
    }

    func demandResult(
        _ task: Task<WorkspaceCodemapBindingDemandResult, Never>,
        before timeout: Duration
    ) async -> WorkspaceCodemapBindingDemandResult? {
        await EngineDemandResultTimeoutRace().wait(for: task, timeout: timeout)
    }

    func waitForEngineCondition(
        timeout: Duration = .seconds(5),
        _ condition: () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}

final class EngineDemandResultTimeoutRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WorkspaceCodemapBindingDemandResult?, Never>?
    private var resolved = false

    func wait(
        for task: Task<WorkspaceCodemapBindingDemandResult, Never>,
        timeout: Duration
    ) async -> WorkspaceCodemapBindingDemandResult? {
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            Task { [self] in
                await finish(task.value)
            }
            Task { [self] in
                try? await Task.sleep(for: timeout)
                finish(nil)
            }
        }
    }

    private func finish(_ result: WorkspaceCodemapBindingDemandResult?) {
        let continuation = lock.withLock { () -> CheckedContinuation<WorkspaceCodemapBindingDemandResult?, Never>? in
            guard !resolved else { return nil }
            resolved = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: result)
    }
}

struct EngineFixture {
    let root: URL
    let rootEpoch: WorkspaceCodemapRootEpoch
    let registration: WorkspaceCodemapBindingRootRegistration
    let capabilityService: WorkspaceCodemapGitCapabilityService
    let fileIDs: EngineFileIDs
    let engine: WorkspaceCodemapBindingEngine

    func demand(
        path: String,
        owner: WorkspaceCodemapLiveDemandOwner = WorkspaceCodemapLiveDemandOwner(),
        priority: CodeMapArtifactBuildPriority = .demand,
        language: LanguageType = .swift,
        requestGeneration: UInt64 = 1,
        pathGeneration: UInt64 = 1,
        ingressGeneration: UInt64 = 1
    ) -> WorkspaceCodemapBindingDemand {
        let identity = WorkspaceCodemapArtifactBindingIdentity(
            rootID: rootEpoch.rootID,
            rootLifetimeID: rootEpoch.rootLifetimeID,
            fileID: fileIDs.id(for: path),
            standardizedRootPath: root.path,
            standardizedRelativePath: path,
            standardizedFullPath: root.appendingPathComponent(path).path
        )!
        return WorkspaceCodemapBindingDemand(
            owner: owner,
            identity: identity,
            requestGeneration: requestGeneration,
            catalogGeneration: 1,
            pathGeneration: pathGeneration,
            ingressGeneration: ingressGeneration,
            priority: priority,
            language: language
        )
    }
}

final class EngineFileIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: UUID] = [:]

    func id(for path: String) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        if let value = values[path] { return value }
        let value = UUID()
        values[path] = value
        return value
    }
}

actor EngineAsyncCounter {
    private(set) var value = 0
    func increment() {
        value += 1
    }
}

actor EngineManifestBindingResolutionRecorder {
    struct Entry: Equatable {
        let relativePath: String
        let requestGeneration: UInt64
        let pathGeneration: UInt64
        let ingressGeneration: UInt64
    }

    private(set) var entries: [Entry] = []

    func record(_ candidate: WorkspaceCodemapManifestBindingCandidate) {
        entries.append(Entry(
            relativePath: candidate.identity.standardizedRelativePath,
            requestGeneration: candidate.requestGeneration,
            pathGeneration: candidate.pathGeneration,
            ingressGeneration: candidate.ingressGeneration
        ))
    }
}

final class EngineUptimeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UInt64

    init(_ value: UInt64) {
        storage = value
    }

    var now: UInt64 {
        lock.withLock { storage }
    }

    func set(_ value: UInt64) {
        lock.withLock { storage = value }
    }
}

final class EngineManifestFaultOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false
    private var triggerCount = 0

    var triggeredCount: Int {
        lock.withLock { triggerCount }
    }

    func action(_ point: CodeMapRootManifestStoreFaultPoint) -> CodeMapRootManifestStoreFaultAction {
        lock.withLock {
            guard point == .afterTemporaryWrite, !failed else { return .proceed }
            failed = true
            triggerCount += 1
            return .simulateProcessTermination
        }
    }
}

final class EngineLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

final class EngineLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set(_ value: Bool) {
        lock.withLock { storage = value }
    }
}

actor EngineBuildGate {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        if released { return }
        await withCheckedContinuation {
            if continuation != nil {
                preconditionFailure("EngineBuildGate supports exactly one waiter")
            }
            continuation = $0
        }
    }

    func waitUntilEntered(timeout: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !entered, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return entered
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

actor EngineOneShotFileMutation {
    private let url: URL
    private let contents: String
    private var didMutate = false
    private(set) var invocationCount = 0

    init(url: URL, contents: String) {
        self.url = url
        self.contents = contents
    }

    func mutateOnce() {
        invocationCount += 1
        guard !didMutate else { return }
        didMutate = true
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

actor EngineSecondCatalogResolutionMutation {
    private let url: URL
    private let contents: String
    private(set) var resolutionCount = 0

    init(url: URL, contents: String) {
        self.url = url
        self.contents = contents
    }

    func resolve() {
        resolutionCount += 1
        guard resolutionCount == 2 else { return }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

final class EngineBlockingGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func enterAndWait() {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilEntered(timeout: TimeInterval = 10) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !entered {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

final class EngineAsyncGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        await withCheckedContinuation { continuation in
            register(continuation)
        }
    }

    private func register(_ continuation: CheckedContinuation<Void, Never>) {
        condition.lock()
        entered = true
        condition.broadcast()
        if released {
            condition.unlock()
            continuation.resume()
        } else {
            if self.continuation != nil {
                preconditionFailure("EngineAsyncGate supports exactly one waiter")
            }
            self.continuation = continuation
            condition.unlock()
        }
    }

    func waitUntilEntered(timeout: TimeInterval = 10) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !entered {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func release() {
        condition.lock()
        released = true
        let continuation = continuation
        self.continuation = nil
        condition.broadcast()
        condition.unlock()
        continuation?.resume()
    }
}

enum EngineBulkCancellationOperation: CaseIterable {
    case pathInvalidation
    case authorityInvalidation
    case unload
    case shutdown
}

enum EngineRegistrationInvalidationKind: CaseIterable {
    case path
    case watcher
    case checkout
    case repository
}

actor EngineMultiEntryGate {
    private var enteredCount = 0
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var count: Int {
        enteredCount
    }

    func enter() async {
        enteredCount += 1
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitUntilEntered(
        _ expectedCount: Int,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while enteredCount < expectedCount, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return enteredCount >= expectedCount
    }

    func releaseAll() {
        released = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

actor EngineFirstResolutionGate {
    private(set) var resolutionCount = 0
    private var firstResolutionEntered = false
    private var firstResolutionReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func enter() async {
        resolutionCount += 1
        guard resolutionCount == 1 else { return }
        firstResolutionEntered = true
        if firstResolutionReleased { return }
        await withCheckedContinuation {
            if continuation != nil {
                preconditionFailure("EngineFirstResolutionGate supports exactly one waiter")
            }
            continuation = $0
        }
    }

    func waitUntilFirstResolution(timeout: Duration = .seconds(10)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !firstResolutionEntered, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return firstResolutionEntered
    }

    func releaseFirstResolution() {
        firstResolutionReleased = true
        continuation?.resume()
        continuation = nil
    }
}

final class EngineHookEvents: @unchecked Sendable {
    private let condition = NSCondition()
    private var events: [WorkspaceCodemapBindingEngineHookEvent] = []

    func record(_ event: WorkspaceCodemapBindingEngineHookEvent) {
        condition.lock()
        events.append(event)
        condition.broadcast()
        condition.unlock()
    }

    func count(kind: WorkspaceCodemapBindingEngineHookKind) -> Int {
        condition.lock()
        defer { condition.unlock() }
        return events.count(where: { $0.kind == kind })
    }

    func numericTotal(kind: WorkspaceCodemapBindingEngineHookKind) -> UInt64 {
        condition.lock()
        defer { condition.unlock() }
        return events.filter { $0.kind == kind }.reduce(0) { $0 + $1.numericValue }
    }

    func values(kind: WorkspaceCodemapBindingEngineHookKind) -> [WorkspaceCodemapBindingEngineHookEvent] {
        condition.lock()
        defer { condition.unlock() }
        return events.filter { $0.kind == kind }
    }

    func snapshot() -> [WorkspaceCodemapBindingEngineHookEvent] {
        condition.lock()
        defer { condition.unlock() }
        return events
    }

    func wait(
        kind: WorkspaceCodemapBindingEngineHookKind,
        numericValue: UInt64,
        timeout: TimeInterval = 10
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !events.contains(where: { $0.kind == kind && $0.numericValue == numericValue }) {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }

    func wait(
        kind: WorkspaceCodemapBindingEngineHookKind,
        rootEpoch: WorkspaceCodemapRootEpoch,
        numericValue: UInt64,
        timeout: TimeInterval = 10
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !events.contains(where: {
            $0.kind == kind && $0.rootEpoch == rootEpoch && $0.numericValue == numericValue
        }) {
            guard condition.wait(until: deadline) else { return false }
        }
        return true
    }
}

actor EngineProjectionRecorder {
    private(set) var snapshots: [WorkspaceCodemapProjectionSnapshot] = []
    private var progress = WorkspaceCodemapProjectionProgress.notStarted

    func publish(
        _ snapshot: WorkspaceCodemapProjectionSnapshot
    ) -> WorkspaceCodemapProjectionSnapshotDisposition {
        snapshots.append(snapshot)
        switch snapshot {
        case let .segment(segment):
            progress = segment.progress
        case let .seal(proof):
            if case let .success(completed) = progress.advancing(
                to: .complete,
                by: .zero,
                catalogCompletion: proof.catalogCompletion
            ) {
                progress = completed
            }
        }
        return .accepted(progress)
    }
}

actor EngineProjectionGenerationRacePublisher {
    private let gate: EngineAsyncGate
    private let recorder: EngineProjectionRecorder
    private var rejectedFirstSnapshot = false
    private(set) var snapshots: [WorkspaceCodemapProjectionSnapshot] = []

    init(gate: EngineAsyncGate, recorder: EngineProjectionRecorder) {
        self.gate = gate
        self.recorder = recorder
    }

    func publish(
        _ snapshot: WorkspaceCodemapProjectionSnapshot
    ) async -> WorkspaceCodemapProjectionSnapshotDisposition {
        snapshots.append(snapshot)
        if !rejectedFirstSnapshot {
            rejectedFirstSnapshot = true
            await gate.enterAndWait()
            return .stale
        }
        return await recorder.publish(snapshot)
    }
}

final class EngineProjectionCatalogStub: @unchecked Sendable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let entries: [WorkspaceCodemapProjectionCatalogCandidate]
    let recorder: EngineProjectionRecorder
    let pageGate: EngineAsyncGate?
    let publishProjectionOverride: (@Sendable (
        WorkspaceCodemapProjectionSnapshot
    ) async -> WorkspaceCodemapProjectionSnapshotDisposition)?

    init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        entries: [WorkspaceCodemapProjectionCatalogCandidate],
        recorder: EngineProjectionRecorder,
        pageGate: EngineAsyncGate? = nil,
        publishProjectionOverride: (@Sendable (
            WorkspaceCodemapProjectionSnapshot
        ) async -> WorkspaceCodemapProjectionSnapshotDisposition)? = nil
    ) {
        self.rootEpoch = rootEpoch
        self.entries = entries.sorted { lhs, rhs in
            if lhs.identity.standardizedRelativePath != rhs.identity.standardizedRelativePath {
                return lhs.identity.standardizedRelativePath.utf8.lexicographicallyPrecedes(
                    rhs.identity.standardizedRelativePath.utf8
                )
            }
            return lhs.identity.fileID.uuidString.utf8.lexicographicallyPrecedes(
                rhs.identity.fileID.uuidString.utf8
            )
        }
        self.recorder = recorder
        self.pageGate = pageGate
        self.publishProjectionOverride = publishProjectionOverride
    }

    var client: WorkspaceCodemapBindingCatalogClient {
        WorkspaceCodemapBindingCatalogClient {
            _, _ in nil
        } readProjectionCatalogPage: { [self] request in
            if let pageGate { await pageGate.enterAndWait() }
            guard request.rootEpoch == rootEpoch, request.cursor == nil else { return .stale }
            let token = projectionToken
            switch WorkspaceCodemapProjectionCatalogPage.validated(
                request: request,
                token: token,
                entries: entries,
                nextCursor: nil,
                isEnd: true,
                supportedCandidateCountThroughPage: UInt64(entries.count)
            ) {
            case let .success(page): return .page(page)
            case .failure: return .unavailable(.catalogUnavailable)
            }
        } revalidateProjectionCatalogToken: { [self] epoch, token in
            epoch == rootEpoch && token == projectionToken ? .current : .stale
        } publishProjection: { [recorder, publishProjectionOverride] snapshot in
            if let publishProjectionOverride {
                return await publishProjectionOverride(snapshot)
            }
            return await recorder.publish(snapshot)
        }
    }

    private var projectionToken: WorkspaceCodemapProjectionCatalogToken {
        WorkspaceCodemapProjectionCatalogToken(
            rootEpoch: rootEpoch,
            topologyGeneration: 1,
            appliedIndexGeneration: 1,
            catalogGeneration: 1,
            ingressGeneration: 1,
            projectionInvalidationGeneration: 1
        )
    }
}

final class EngineCompletionFlag: @unchecked Sendable {
    private let condition = NSCondition()
    private var finished = false

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilFinished(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !finished else { return true }
        return condition.wait(until: Date().addingTimeInterval(timeout)) && finished
    }
}

final class EngineEventDescriptions: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}
