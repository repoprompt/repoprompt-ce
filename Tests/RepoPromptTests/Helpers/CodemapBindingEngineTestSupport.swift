import Darwin
import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
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

    static func timeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

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
        manifestWriterRetryWaiter: WorkspaceCodemapManifestWriterRetryWaiter = .init { _ in },
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
            manifestWriterRetryWaiter: manifestWriterRetryWaiter,
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
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        do {
            try await AsyncTestWait.waitUntil(
                "codemap binding engine condition",
                timeout: Self.timeInterval(timeout)
            ) {
                await condition()
            }
            return true
        } catch {
            return await condition()
        }
    }
}

final class EngineDemandResultTimeoutRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WorkspaceCodemapBindingDemandResult?, Never>?
    private var observerTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var observerCompleted = false
    private var resolved = false

    func wait(
        for task: Task<WorkspaceCodemapBindingDemandResult, Never>,
        timeout: Duration
    ) async -> WorkspaceCodemapBindingDemandResult? {
        let result = await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }

            let observer = Task { [weak self] in
                let result = await task.value
                self?.finish(result, observerCompleted: true)
            }
            let timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                task.cancel()
                self?.finish(nil)
            }

            lock.withLock {
                observerTask = observer
                timeoutTask = timer
            }
        }

        let tasks = lock.withLock { () -> (observer: Task<Void, Never>?, timer: Task<Void, Never>?) in
            let tasks = (observerTask, timeoutTask)
            observerTask = nil
            timeoutTask = nil
            return tasks
        }
        if let timer = tasks.timer {
            timer.cancel()
            await timer.value
        }
        if result == nil {
            await assertObservedTaskDrainedAfterTimeout()
        }
        tasks.observer?.cancel()
        return result
    }

    private var hasObserverCompleted: Bool {
        lock.withLock { observerCompleted }
    }

    private func finish(
        _ result: WorkspaceCodemapBindingDemandResult?,
        observerCompleted: Bool = false
    ) {
        let continuation = lock.withLock { () -> CheckedContinuation<WorkspaceCodemapBindingDemandResult?, Never>? in
            if observerCompleted {
                self.observerCompleted = true
            }
            guard !resolved else { return nil }
            resolved = true
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: result)
    }

    private func assertObservedTaskDrainedAfterTimeout() async {
        do {
            try await AsyncTestWait.waitUntil(
                "codemap binding demand task cancellation drain",
                timeout: 1
            ) {
                self.hasObserverCompleted
            }
        } catch {
            XCTFail("Timed out waiting for cancelled codemap binding demand task to drain: \(error.localizedDescription)")
        }
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
        if let value = values[path] {
            return value
        }
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

final class EngineManifestFaultOnPublication: @unchecked Sendable {
    private let lock = NSLock()
    private let target: Int
    private var publicationCount = 0
    private var didFail = false

    init(_ target: Int) {
        precondition(target > 0)
        self.target = target
    }

    var triggeredCount: Int {
        lock.withLock { didFail ? 1 : 0 }
    }

    var observedPublicationCount: Int {
        lock.withLock { publicationCount }
    }

    func action(_ point: CodeMapRootManifestStoreFaultPoint) -> CodeMapRootManifestStoreFaultAction {
        lock.withLock {
            guard point == .afterTemporaryWrite else { return .proceed }
            publicationCount += 1
            guard publicationCount == target, !didFail else { return .proceed }
            didFail = true
            return .simulateProcessTermination
        }
    }
}

final class EngineManifestFaultOnPublications: @unchecked Sendable {
    private let lock = NSLock()
    private let targets: Set<Int>
    private var publicationCount = 0

    init(_ targets: [Int]) {
        self.targets = Set(targets)
    }

    var triggeredCount: Int {
        lock.withLock { publicationCount }
    }

    func action(_ point: CodeMapRootManifestStoreFaultPoint) -> CodeMapRootManifestStoreFaultAction {
        lock.withLock {
            guard point == .afterTemporaryWrite else { return .proceed }
            publicationCount += 1
            guard targets.contains(publicationCount) else { return .proceed }
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

/// Engine build-hook fence — named thin wrapper over `TestReleaseFence`.
final class EngineBuildGate: @unchecked Sendable {
    private let fence = TestReleaseFence(name: "engine build gate")

    func enter() async {
        await fence.enter()
    }

    func enterAndWait() async {
        await fence.enterAndWait()
    }

    func enterIgnoringCancellationUntilRelease() async {
        await fence.enterAndWaitIgnoringCancellationUntilRelease()
    }

    @discardableResult
    func waitUntilEntered(
        timeout: Duration = TestFenceDefaults.enterWaitDuration,
        failOnTimeout: Bool = true
    ) async -> Bool {
        await fence.waitUntilEntered(timeout: timeout, failOnTimeout: failOnTimeout)
    }

    @discardableResult
    func waitUntilEnteredBlocking(
        timeout: TimeInterval = TestFenceDefaults.enterWait,
        failOnTimeout: Bool = true
    ) -> Bool {
        fence.waitUntilEnteredBlocking(timeout: timeout, failOnTimeout: failOnTimeout)
    }

    func release() {
        fence.release()
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

/// Sync writer-hook fence — named thin wrapper over `TestBlockingFence`.
final class EngineBlockingGate: @unchecked Sendable {
    static let defaultEnterWaitTimeout = TestFenceDefaults.releaseWait

    private let fence = TestBlockingFence(name: "engine blocking gate")

    func enterAndWait(timeout: TimeInterval = defaultEnterWaitTimeout) {
        fence.enterAndWait(timeout: timeout)
    }

    @discardableResult
    func waitUntilEntered(
        timeout: TimeInterval = TestFenceDefaults.enterWait,
        failOnTimeout: Bool = true
    ) -> Bool {
        fence.waitUntilEntered(timeout: timeout, failOnTimeout: failOnTimeout)
    }

    func release() {
        fence.release()
    }
}

/// Async engine fence — named thin wrapper over `TestReleaseFence`.
final class EngineAsyncGate: @unchecked Sendable {
    private let fence = TestReleaseFence(name: "engine async gate")

    func enterAndWait() async {
        await fence.enterAndWait()
    }

    @discardableResult
    func waitUntilEnteredBlocking(
        timeout: TimeInterval = TestFenceDefaults.enterWait,
        failOnTimeout: Bool = true
    ) -> Bool {
        fence.waitUntilEnteredBlocking(timeout: timeout, failOnTimeout: failOnTimeout)
    }

    @discardableResult
    func waitUntilEntered(
        timeout: Duration = TestFenceDefaults.enterWaitDuration,
        failOnTimeout: Bool = true
    ) async -> Bool {
        await fence.waitUntilEntered(timeout: timeout, failOnTimeout: failOnTimeout)
    }

    func release() {
        fence.release()
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
    private let state = EngineMultiEntryGateState()

    var count: Int {
        state.count
    }

    func enter() async {
        await state.enter()
    }

    func waitUntilEntered(
        _ expectedCount: Int,
        timeout: Duration = .seconds(10)
    ) async -> Bool {
        do {
            return try await state.waitUntilEntered(
                expectedCount,
                timeout: CodemapBindingEngineTestCase.timeInterval(timeout)
            )
        } catch {
            // Timeout sibling can win the task group even after the condition is met.
            if state.count >= expectedCount {
                return true
            }
            XCTFail(error.localizedDescription)
            return false
        }
    }

    func releaseAll() {
        state.releaseAll()
    }
}

private final class EngineMultiEntryGateState: @unchecked Sendable {
    private struct EnteredWaiter {
        let id: UUID
        let expectedCount: Int
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var enteredCount = 0
    private var released = false
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelledWaiters = Set<UUID>()
    private var cancelledEnteredWaiters: [UUID: Error] = [:]
    private var enteredWaiters: [EnteredWaiter] = []

    var count: Int {
        lock.withLock { enteredCount }
    }

    func enter() async {
        let waiterID = UUID()
        let readyWaiters = lock.withLock { () -> [EnteredWaiter] in
            enteredCount += 1
            return removeSatisfiedEnteredWaiters()
        }
        for waiter in readyWaiters {
            waiter.continuation.resume()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var shouldResume = false
                lock.lock()
                if released || Task.isCancelled || cancelledWaiters.remove(waiterID) != nil {
                    shouldResume = true
                } else {
                    continuations[waiterID] = continuation
                }
                lock.unlock()
                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            cancelEntryWaiter(id: waiterID)
        }
    }

    func waitUntilEntered(_ expectedCount: Int, timeout: TimeInterval) async throws -> Bool {
        if count >= expectedCount {
            return true
        }
        let waiterID = UUID()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.waitForEnteredSignal(id: waiterID, expectedCount: expectedCount)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64((timeout * 1_000_000_000).rounded()))
                    self.cancelEnteredWaiter(
                        id: waiterID,
                        error: AsyncTestConditionTimeout(description: "engine multi-entry gate count \(expectedCount)", timeout: timeout)
                    )
                    throw AsyncTestConditionTimeout(description: "engine multi-entry gate count \(expectedCount)", timeout: timeout)
                }
                defer {
                    group.cancelAll()
                    cancelEnteredWaiter(id: waiterID, error: CancellationError())
                }
                _ = try await group.next()
            }
        } catch {
            if count >= expectedCount {
                return true
            }
            throw error
        }
        return count >= expectedCount
    }

    func releaseAll() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            let pending = Array(continuations.values)
            continuations.removeAll()
            cancelledWaiters.removeAll()
            cancelledEnteredWaiters.removeAll()
            return pending
        }
        for continuation in pending {
            continuation.resume()
        }
    }

    private func waitForEnteredSignal(id: UUID, expectedCount: Int) async throws {
        try await withCheckedThrowingContinuation { continuation in
            var result: Result<Void, Error>?
            lock.lock()
            if enteredCount >= expectedCount {
                result = .success(())
            } else if let error = cancelledEnteredWaiters.removeValue(forKey: id) {
                result = .failure(error)
            } else if Task.isCancelled {
                result = .failure(CancellationError())
            } else {
                enteredWaiters.append(EnteredWaiter(id: id, expectedCount: expectedCount, continuation: continuation))
            }
            lock.unlock()

            switch result {
            case .success:
                continuation.resume()
            case let .failure(error):
                continuation.resume(throwing: error)
            case nil:
                break
            }
        }
    }

    private func removeSatisfiedEnteredWaiters() -> [EnteredWaiter] {
        var ready: [EnteredWaiter] = []
        enteredWaiters.removeAll { waiter in
            guard enteredCount >= waiter.expectedCount else { return false }
            ready.append(waiter)
            return true
        }
        return ready
    }

    private func cancelEntryWaiter(id: UUID) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if let continuation = continuations.removeValue(forKey: id) {
                return continuation
            }
            cancelledWaiters.insert(id)
            return nil
        }
        continuation?.resume()
    }

    private func cancelEnteredWaiter(id: UUID, error: Error) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            if let index = enteredWaiters.firstIndex(where: { $0.id == id }) {
                return enteredWaiters.remove(at: index).continuation
            }
            // Sticky: timeout/cancel may race ahead of registration; late register must not park.
            if cancelledEnteredWaiters[id] == nil {
                cancelledEnteredWaiters[id] = error
            }
            return nil
        }
        continuation?.resume(throwing: error)
    }
}

actor EngineFirstResolutionGate {
    private let state = EngineFirstResolutionGateState()

    var resolutionCount: Int {
        state.resolutionCount
    }

    func enter() async {
        await state.enter()
    }

    func waitUntilFirstResolution(timeout: Duration = .seconds(10)) async -> Bool {
        do {
            return try await state.waitUntilFirstResolution(
                timeout: CodemapBindingEngineTestCase.timeInterval(timeout)
            )
        } catch {
            if state.firstResolutionEntered {
                return true
            }
            XCTFail(error.localizedDescription)
            return false
        }
    }

    func releaseFirstResolution() {
        state.releaseFirstResolution()
    }
}

private final class EngineFirstResolutionGateState: @unchecked Sendable {
    private struct ResolutionWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var storedResolutionCount = 0
    private var storedFirstResolutionEntered = false
    private var firstResolutionReleased = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var cancelledWaiters = Set<UUID>()
    private var cancelledFirstResolutionWaiters: [UUID: Error] = [:]
    private var firstResolutionWaiters: [ResolutionWaiter] = []

    var resolutionCount: Int {
        lock.withLock { storedResolutionCount }
    }

    var firstResolutionEntered: Bool {
        lock.withLock { storedFirstResolutionEntered }
    }

    func enter() async {
        let entry = lock.withLock { () -> (readyWaiters: [ResolutionWaiter], shouldBlock: Bool) in
            storedResolutionCount += 1
            guard storedResolutionCount == 1 else { return ([], false) }
            storedFirstResolutionEntered = true
            let waiters = firstResolutionWaiters
            firstResolutionWaiters.removeAll()
            return (waiters, true)
        }
        for waiter in entry.readyWaiters {
            waiter.continuation.resume()
        }
        guard entry.shouldBlock else { return }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var shouldResume = false
                lock.lock()
                if firstResolutionReleased || Task.isCancelled || cancelledWaiters.remove(waiterID) != nil {
                    shouldResume = true
                } else if self.continuation != nil {
                    lock.unlock()
                    preconditionFailure("EngineFirstResolutionGate supports exactly one waiter")
                } else {
                    self.continuation = continuation
                }
                lock.unlock()

                if shouldResume {
                    continuation.resume()
                }
            }
        } onCancel: {
            cancelFirstResolutionBlocker(waiterID: waiterID)
        }
    }

    func waitUntilFirstResolution(timeout: TimeInterval) async throws -> Bool {
        if firstResolutionEntered {
            return true
        }
        let waiterID = UUID()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await self.waitForFirstResolutionSignal(id: waiterID)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64((timeout * 1_000_000_000).rounded()))
                    self.cancelFirstResolutionWaiter(
                        id: waiterID,
                        error: AsyncTestConditionTimeout(description: "engine first resolution gate", timeout: timeout)
                    )
                    throw AsyncTestConditionTimeout(description: "engine first resolution gate", timeout: timeout)
                }
                defer {
                    group.cancelAll()
                    cancelFirstResolutionWaiter(id: waiterID, error: CancellationError())
                }
                _ = try await group.next()
            }
        } catch {
            if firstResolutionEntered {
                return true
            }
            throw error
        }
        return firstResolutionEntered
    }

    func releaseFirstResolution() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            firstResolutionReleased = true
            let pending = self.continuation
            self.continuation = nil
            cancelledWaiters.removeAll()
            cancelledFirstResolutionWaiters.removeAll()
            return pending
        }
        pending?.resume()
    }

    private func waitForFirstResolutionSignal(id: UUID) async throws {
        try await withCheckedThrowingContinuation { continuation in
            var result: Result<Void, Error>?
            lock.lock()
            if storedFirstResolutionEntered {
                result = .success(())
            } else if let error = cancelledFirstResolutionWaiters.removeValue(forKey: id) {
                result = .failure(error)
            } else if Task.isCancelled {
                result = .failure(CancellationError())
            } else {
                firstResolutionWaiters.append(ResolutionWaiter(id: id, continuation: continuation))
            }
            lock.unlock()

            switch result {
            case .success:
                continuation.resume()
            case let .failure(error):
                continuation.resume(throwing: error)
            case nil:
                break
            }
        }
    }

    private func cancelFirstResolutionBlocker(waiterID: UUID) {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if let pending = self.continuation {
                self.continuation = nil
                return pending
            }
            cancelledWaiters.insert(waiterID)
            return nil
        }
        pending?.resume()
    }

    private func cancelFirstResolutionWaiter(id: UUID, error: Error) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            if let index = firstResolutionWaiters.firstIndex(where: { $0.id == id }) {
                return firstResolutionWaiters.remove(at: index).continuation
            }
            if cancelledFirstResolutionWaiters[id] == nil {
                cancelledFirstResolutionWaiters[id] = error
            }
            return nil
        }
        continuation?.resume(throwing: error)
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

    func wait(
        kind: WorkspaceCodemapBindingEngineHookKind,
        rootEpoch: WorkspaceCodemapRootEpoch,
        minimumCount: Int,
        timeout: TimeInterval = 10
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while events.count(where: { $0.kind == kind && $0.rootEpoch == rootEpoch }) < minimumCount {
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
            if let pageGate {
                await pageGate.enterAndWait()
            }
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
