import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainProtectedMutationJournalTests: XCTestCase {
    func testPersistedPathIdentityEncodingKeepsPreExtractionDeviceInodeSchema() throws {
        let identity = DomainMutationPathIdentity(
            originalPath: "/repo",
            resolvedPath: "/repo",
            device: 17,
            inode: 42
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(identity)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"device":17,"inode":42,"originalPath":"\/repo","resolvedPath":"\/repo"}"#
        )
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("birthTimeBits"))
        XCTAssertEqual(try JSONDecoder().decode(DomainMutationPathIdentity.self, from: data), identity)

        let legacy = Data(#"{"device":17,"inode":42,"originalPath":"/repo","resolvedPath":"/repo"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(DomainMutationPathIdentity.self, from: legacy).birthTimeBits)
    }

    func testPersistedPathIdentityAdditivelySnapshotsBirthTimeWhenAvailable() throws {
        let identity = DomainMutationPathIdentity(
            originalPath: "/repo",
            resolvedPath: "/repo",
            device: 17,
            inode: 42,
            birthTimeBits: 1_725_000_000_123_456_789
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(
            String(decoding: try encoder.encode(identity), as: UTF8.self),
            #"{"birthTimeBits":1725000000123456789,"device":17,"inode":42,"originalPath":"/repo","resolvedPath":"/repo"}"#
        )
    }

    func testFailedBeforeWriteStatusDecodesAndReencodesCanonically() throws {
        let decoder = JSONDecoder()
        let status = try decoder.decode(
            DomainMutationJournalStatus.self,
            from: Data(#""failed_before_write""#.utf8)
        )

        XCTAssertEqual(status, .failedBeforeCommit)
        XCTAssertEqual(
            String(data: try JSONEncoder().encode(status), encoding: .utf8),
            #""failed_before_commit""#
        )
        XCTAssertThrowsError(
            try decoder.decode(
                DomainMutationJournalStatus.self,
                from: Data(#""unknown_status""#.utf8)
            )
        )
    }

    func testLegacyFailedBeforeWriteJournalRetriesAndRewritesCanonicalStatus() async throws {
        let fixture = try M4BFixture()
        let arguments = fixture.arguments(operationID: "legacy-failed-before-write")
        let failingBinding = fixture.binding { _ in
            throw DomainMutationPathFenceError.scopeUnavailable
        }

        await XCTAssertThrowsErrorAsync({
            try await fixture.invoke(
                failingBinding,
                arguments: arguments,
                requestIdentitySeed: "legacy-failed-before-write-request"
            )
        })

        let persistence = fixture.runtime.persistenceCoordinator
        let persistedCanonicalData = try await persistence.loadProtectedMutationJournalData()
        let canonicalData = try XCTUnwrap(persistedCanonicalData)
        let canonicalJSON = try XCTUnwrap(String(data: canonicalData, encoding: .utf8))
        let legacyJSON = canonicalJSON.replacingOccurrences(
            of: #""failed_before_commit""#,
            with: #""failed_before_write""#
        )
        XCTAssertNotEqual(legacyJSON, canonicalJSON)
        try await persistence.compareAndSwapProtectedMutationJournalData(
            expectedDigest: DomainContentDigest.sha256(canonicalData),
            data: Data(legacyJSON.utf8)
        )

        let restarted = try M4BFixture(storage: fixture.storage, root: fixture.root)
        let retriedBinding = restarted.binding { _ in
            try await MCPDomainMutationCommitContext.willCommit()
            return .string("retried")
        }
        let result = try await restarted.invoke(
            retriedBinding,
            arguments: arguments,
            requestIdentitySeed: "legacy-failed-before-write-request"
        )

        XCTAssertEqual(result.stringValue, "retried")
        let persistedRewrittenData = try await restarted.runtime.persistenceCoordinator.loadProtectedMutationJournalData()
        let rewrittenData = try XCTUnwrap(persistedRewrittenData)
        let rewrittenJSON = try XCTUnwrap(String(data: rewrittenData, encoding: .utf8))
        XCTAssertFalse(rewrittenJSON.contains("failed_before_write"))
    }

    func testInternalMutationKeyReplaysWhilePublicCorrelationIDCanBeReused() async throws {
        let fixture = try M4BFixture()
        let calls = MutationCounter()
        let binding = fixture.binding { _ in
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            return .string("applied")
        }
        let arguments = fixture.arguments(operationID: "correlation-1")

        let first = try await fixture.invoke(binding, arguments: arguments, requestIdentitySeed: "request-1")
        let replay = try await fixture.invoke(
            binding,
            arguments: arguments,
            workspaceRevision: 8,
            requestIdentitySeed: "request-1"
        )
        XCTAssertEqual(first.stringValue, "applied")
        XCTAssertEqual(replay.stringValue, "applied")
        let callsAfterReplay = await calls.value
        XCTAssertEqual(callsAfterReplay, 1)

        var reusedCorrelation = arguments
        reusedCorrelation["content"] = .string("different")
        let distinctRequest = try await fixture.invoke(
            binding,
            arguments: reusedCorrelation,
            requestIdentitySeed: "request-2"
        )
        XCTAssertEqual(distinctRequest.stringValue, "applied")
        let callsAfterDistinctRequest = await calls.value
        XCTAssertEqual(callsAfterDistinctRequest, 2)

        await XCTAssertThrowsErrorAsync({
            try await fixture.invoke(
                binding,
                arguments: reusedCorrelation,
                requestIdentitySeed: "request-1"
            )
        }) { error in
            XCTAssertEqual(error as? DomainMutationJournalError, .operationIDCollision("correlation-1"))
        }
        let callsAfterCollision = await calls.value
        XCTAssertEqual(callsAfterCollision, 2)
    }

    func testRootAndSymlinkFencesApplyAtAdmissionAndPrecommit() async throws {
        let fixture = try M4BFixture()
        let outside = fixture.storage.appendingPathComponent("outside", isDirectory: true)
        let safe = fixture.root.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        let link = fixture.root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let calls = MutationCounter()
        let neverCalled = fixture.binding { _ in
            await calls.increment()
            return .string("unexpected")
        }

        await XCTAssertThrowsErrorAsync({
            try await fixture.invoke(
                neverCalled,
                arguments: fixture.arguments(operationID: "outside", path: link.appendingPathComponent("file.txt").path)
            )
        }) { error in
            XCTAssertTrue(error is DomainMutationPathFenceError)
        }
        let callsAfterAdmission = await calls.value
        XCTAssertEqual(callsAfterAdmission, 0)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: safe)
        let swapped = fixture.binding { _ in
            try FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            return .string("unexpected")
        }
        await XCTAssertThrowsErrorAsync({
            try await fixture.invoke(
                swapped,
                arguments: fixture.arguments(operationID: "swap", path: link.appendingPathComponent("file.txt").path)
            )
        }) { error in
            XCTAssertEqual(error as? DomainMutationPathFenceError, .pathResolutionChanged(link.appendingPathComponent("file.txt").path))
        }
        let callsAfterPrecommit = await calls.value
        XCTAssertEqual(callsAfterPrecommit, 0)
    }

    func testLogicalRootMappingFencesTranslatedPhysicalWorktreeTarget() async throws {
        let fixture = try M4BFixture()
        let worktreeRoot = fixture.storage.appendingPathComponent("bound-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let physicalTarget = worktreeRoot.appendingPathComponent("Sources/Translated.swift").path
        let binding = fixture.binding(rootMappings: [
            DomainMutationPhysicalRootMapping(
                canonicalRoot: fixture.root.path,
                physicalRoot: worktreeRoot.path
            )
        ]) { _ in
            try await MCPDomainMutationCommitContext.willCommit()
            return .string("translated")
        }

        let result = try await fixture.invoke(
            binding,
            arguments: fixture.arguments(
                operationID: "translated-correlation",
                path: physicalTarget
            ),
            requestIdentitySeed: "translated-request"
        )
        XCTAssertEqual(result.stringValue, "translated")
        let snapshot = try await fixture.runtime.mutationJournal.snapshot()
        let record = snapshot.records["file_actions.create:request:translated-request"]
        XCTAssertEqual(record?.pathFence?.entries.first?.requestedPath, physicalTarget)
        XCTAssertEqual(record?.pathFence?.coveredRoots, [worktreeRoot.standardizedFileURL.path])
    }

    func testDurableLogicalMutationRejectsRepoRootOutsideAuthoritativeScopeBeforeBackend() async throws {
        let fixture = try M4BFixture()
        let calls = MutationCounter()
        let binding = fixture.logicalBinding { _ in
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            return .string("unexpected")
        }
        let outsideRoot = fixture.storage.appendingPathComponent("outside-repo", isDirectory: true)
        let arguments: [String: Value] = [
            "op": .string("bind"),
            "repo_root": .string(outsideRoot.path),
            "operation_id": .string("logical-outside")
        ]

        await XCTAssertThrowsErrorAsync({
            try await fixture.invokeLogical(binding, arguments: arguments)
        }) { error in
            XCTAssertEqual(error as? DomainMutationPolicyError, .grantMissing)
        }
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
    }

    func testDurableLogicalMutationUsesOnlyRequestedRootForMultiRootGrant() async throws {
        let fixture = try M4BFixture()
        let rootB = fixture.storage.appendingPathComponent("root-b", isDirectory: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let grant = DomainHeadlessMutationGrant(
            principalKey: "test-app-fingerprint",
            allowedOperations: ["manage_worktree.bind"],
            canonicalRoots: [fixture.root.path],
            provider: "test",
            expiresAt: Date().addingTimeInterval(3600)
        )
        _ = try await fixture.runtime.mutationPolicyStore.addGrant(
            grant,
            expectedRevision: 0,
            administrator: m4bTTYAdministrator()
        )
        let calls = MutationCounter()
        let binding = fixture.logicalBinding { _ in
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            return .string("applied")
        }
        let authorizedRoots: Set<String> = [fixture.root.path, rootB.path]
        let rootAResult = try await fixture.invokeLogical(
            binding,
            arguments: [
                "op": .string("bind"),
                "repo_root": .string(fixture.root.path),
                "operation_id": .string("logical-root-a")
            ],
            requestIdentitySeed: "logical-root-a-request",
            authorizedCanonicalRoots: authorizedRoots,
            ephemeralGrantedToolNames: []
        )
        XCTAssertEqual(rootAResult.stringValue, "applied")

        await XCTAssertThrowsErrorAsync({
            try await fixture.invokeLogical(
                binding,
                arguments: [
                    "op": .string("bind"),
                    "repo_root": .string(rootB.path),
                    "operation_id": .string("logical-root-b")
                ],
                requestIdentitySeed: "logical-root-b-request",
                authorizedCanonicalRoots: authorizedRoots,
                ephemeralGrantedToolNames: []
            )
        }) { error in
            XCTAssertEqual(error as? DomainMutationPolicyError, .grantMissing)
        }
        let callCount = await calls.value
        XCTAssertEqual(callCount, 1)
    }

    func testDurableLogicalMutationRequiresPostResolutionForDefaultAndAlternateSelectors() async throws {
        let fixture = try M4BFixture()
        let rootB = fixture.storage.appendingPathComponent("root-b", isDirectory: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let grant = DomainHeadlessMutationGrant(
            principalKey: "test-app-fingerprint",
            allowedOperations: ["manage_worktree.bind"],
            canonicalRoots: [fixture.root.path],
            provider: "test",
            expiresAt: Date().addingTimeInterval(3600)
        )
        _ = try await fixture.runtime.mutationPolicyStore.addGrant(
            grant,
            expectedRevision: 0,
            administrator: m4bTTYAdministrator()
        )
        let calls = MutationCounter()
        let binding = fixture.logicalBinding { _ in
            try await MCPDomainMutationCommitContext.admitPhysicalTargets(
                [rootB.path],
                rootMappings: [
                    DomainMutationPhysicalRootMapping(canonicalRoot: rootB.path, physicalRoot: rootB.path)
                ]
            )
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            return .string("unexpected")
        }
        let selectors: [(label: String, values: [String: Value])] = [
            ("default", [:]),
            ("repo-key", ["repo_key": .string("repo-b")]),
            ("root-name", ["repo_root": .string("root-b")]),
            ("main-alias", ["repo_root": .string("@main")])
        ]
        for selector in selectors {
            var arguments: [String: Value] = [
                "op": .string("bind"),
                "operation_id": .string("post-resolution-\(selector.label)")
            ]
            arguments.merge(selector.values) { _, new in new }
            await XCTAssertThrowsErrorAsync({
                try await fixture.invokeLogical(
                    binding,
                    arguments: arguments,
                    requestIdentitySeed: "post-resolution-\(selector.label)",
                    authorizedCanonicalRoots: [fixture.root.path, rootB.path],
                    ephemeralGrantedToolNames: []
                )
            }) { error in
                XCTAssertEqual(error as? DomainMutationPolicyError, .grantMissing, selector.label)
            }
        }
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
    }

    func testDurableLogicalMutationRejectsMultiRootUnbindAllBeforeBackend() async throws {
        let fixture = try M4BFixture()
        let rootB = fixture.storage.appendingPathComponent("root-b", isDirectory: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let grant = DomainHeadlessMutationGrant(
            principalKey: "test-app-fingerprint",
            allowedOperations: ["manage_worktree.unbind"],
            canonicalRoots: [fixture.root.path],
            provider: "test",
            expiresAt: Date().addingTimeInterval(3600)
        )
        _ = try await fixture.runtime.mutationPolicyStore.addGrant(
            grant,
            expectedRevision: 0,
            administrator: m4bTTYAdministrator()
        )
        let calls = MutationCounter()
        let binding = fixture.logicalBinding { _ in
            try await MCPDomainMutationCommitContext.admitPhysicalTargets(
                [fixture.root.path, rootB.path],
                rootMappings: [
                    DomainMutationPhysicalRootMapping(canonicalRoot: fixture.root.path, physicalRoot: fixture.root.path),
                    DomainMutationPhysicalRootMapping(canonicalRoot: rootB.path, physicalRoot: rootB.path)
                ]
            )
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            return .string("unexpected")
        }

        await XCTAssertThrowsErrorAsync({
            try await fixture.invokeLogical(
                binding,
                arguments: [
                    "op": .string("unbind"),
                    "all": .bool(true),
                    "operation_id": .string("unbind-all-multi-root")
                ],
                requestIdentitySeed: "unbind-all-multi-root-request",
                authorizedCanonicalRoots: [fixture.root.path, rootB.path],
                ephemeralGrantedToolNames: []
            )
        }) { error in
            XCTAssertEqual(error as? DomainMutationPolicyError, .grantMissing)
        }
        let callCount = await calls.value
        XCTAssertEqual(callCount, 0)
    }

    func testNonexistentParentIdentitySwapFailsImmediatelyBeforeCommit() async throws {
        let fixture = try M4BFixture()
        let parent = fixture.root.appendingPathComponent("existing-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("missing/created.txt").path
        let calls = MutationCounter()
        let binding = fixture.binding { _ in
            try FileManager.default.removeItem(at: parent)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            return .string("unexpected")
        }

        await XCTAssertThrowsErrorAsync({
            try await fixture.invoke(
                binding,
                arguments: fixture.arguments(operationID: "parent-swap", path: target),
                requestIdentitySeed: "parent-swap-request"
            )
        }) { error in
            XCTAssertTrue(error is DomainMutationPathFenceError)
        }
        let callsAfterParentSwap = await calls.value
        XCTAssertEqual(callsAfterParentSwap, 0)
    }

    func testCancellationBeforeCommitIsSafeToRetry() async throws {
        let fixture = try M4BFixture()
        let gate = MutationGate()
        let behavior = MutationAttemptBehavior()
        let calls = MutationCounter()
        let binding = fixture.binding { _ in
            if await behavior.next() == 1 {
                try await gate.wait()
            }
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            return .string("retried")
        }
        let arguments = fixture.arguments(operationID: "cancel-before")
        let task = Task {
            try await fixture.invoke(binding, arguments: arguments, requestIdentitySeed: "cancel-before-request")
        }
        await gate.waitUntilEntered()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}

        let snapshot = try await fixture.runtime.mutationJournal.snapshot()
        XCTAssertEqual(
            snapshot.records["file_actions.create:request:cancel-before-request"]?.status,
            .cancelledBeforeCommit
        )
        let retry = try await fixture.invoke(
            binding,
            arguments: arguments,
            requestIdentitySeed: "cancel-before-request"
        )
        XCTAssertEqual(retry.stringValue, "retried")
        let callsAfterRetry = await calls.value
        XCTAssertEqual(callsAfterRetry, 1)
    }

    func testCancellationAfterCommitIsIndeterminateAcrossRestart() async throws {
        let fixture = try M4BFixture()
        let gate = MutationGate()
        let calls = MutationCounter()
        let binding = fixture.binding { _ in
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            try await gate.wait()
            return .string("late")
        }
        let arguments = fixture.arguments(operationID: "cancel-after")
        let task = Task {
            try await fixture.invoke(binding, arguments: arguments, requestIdentitySeed: "cancel-after-request")
        }
        await gate.waitUntilEntered()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected partial-success error")
        } catch let error as DomainProtectedMutationError {
            XCTAssertEqual(error, .partialSuccessAfterCommit(operationID: "cancel-after"))
        }
        let callsAfterCommit = await calls.value
        XCTAssertEqual(callsAfterCommit, 1)

        let restarted = try M4BFixture(storage: fixture.storage, root: fixture.root)
        let restartedCalls = MutationCounter()
        let restartedBinding = restarted.binding { _ in
            await restartedCalls.increment()
            return .string("duplicate")
        }
        await XCTAssertThrowsErrorAsync({
            try await restarted.invoke(
                restartedBinding,
                arguments: arguments,
                requestIdentitySeed: "cancel-after-request"
            )
        }) { error in
            XCTAssertEqual(error as? DomainMutationJournalError, .interruptedCommit("cancel-after"))
        }
        let callsAfterRestart = await restartedCalls.value
        XCTAssertEqual(callsAfterRestart, 0)
    }

    func testNWriterContentionUsesOneOwnerThenReplays() async throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4b-n-writer-\(UUID().uuidString)", isDirectory: true)
        let root = storage.appendingPathComponent("root", isDirectory: true)
        let first = try M4BFixture(storage: storage, root: root)
        let second = try M4BFixture(storage: storage, root: root)
        let gate = MutationGate()
        let calls = MutationCounter()
        let firstBinding = first.binding { _ in
            try await gate.wait()
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            return .string("winner")
        }
        let secondBinding = second.binding { _ in
            try await MCPDomainMutationCommitContext.willCommit()
            await calls.increment()
            return .string("duplicate")
        }
        let arguments = first.arguments(operationID: "n-writer")
        let owner = Task {
            try await first.invoke(firstBinding, arguments: arguments, requestIdentitySeed: "n-writer-request")
        }
        await gate.waitUntilEntered()

        await XCTAssertThrowsErrorAsync({
            try await second.invoke(
                secondBinding,
                arguments: arguments,
                requestIdentitySeed: "n-writer-request"
            )
        }) { error in
            XCTAssertEqual(error as? DomainMutationJournalError, .operationInProgress("n-writer"))
        }
        await gate.release()
        let ownerResult = try await owner.value
        XCTAssertEqual(ownerResult.stringValue, "winner")
        let replay = try await second.invoke(
            secondBinding,
            arguments: arguments,
            requestIdentitySeed: "n-writer-request"
        )
        XCTAssertEqual(replay.stringValue, "winner")
        let callsAfterContention = await calls.value
        XCTAssertEqual(callsAfterContention, 1)
    }
}

private final class M4BFixture: @unchecked Sendable {
    let runtime: MCPDomainRuntime
    let storage: URL
    let root: URL

    init(storage: URL? = nil, root: URL? = nil) throws {
        let storage = storage ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("m4b-runtime-\(UUID().uuidString)", isDirectory: true)
        let root = root ?? storage.appendingPathComponent("root", isDirectory: true)
        self.storage = storage
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        runtime = MCPDomainRuntime(
            configuration: .init(
                mode: .app,
                profileIdentifier: "m4b-test",
                storageDirectory: storage,
                eventDirectory: storage.appendingPathComponent("events", isDirectory: true),
                temporaryDirectory: storage.appendingPathComponent("tmp", isDirectory: true),
                externalReloadInterval: nil,
            ),
            runtimeID: UUID(),
            lifecycleGeneration: 1,
            processID: 42
        )
    }

    func arguments(operationID: String, path: String? = nil) -> [String: Value] {
        [
            "action": .string("create"),
            "operation_id": .string(operationID),
            "path": .string(path ?? root.appendingPathComponent("file.txt").path),
            "content": .string("content")
        ]
    }

    func binding(
        rootMappings: [DomainMutationPhysicalRootMapping]? = nil,
        operation: @Sendable @escaping ([String: Value]) async throws -> Value
    ) -> MCPDomainToolBinding {
        let mappings = rootMappings ?? [
            DomainMutationPhysicalRootMapping(canonicalRoot: root.path, physicalRoot: root.path)
        ]
        return runtime.protectedMutationProvider.protectedBinding(MCPDomainToolBinding(
            definition: MCPDomainToolDefinition(
                name: "file_actions",
                description: "fixture",
                inputSchema: .object(["type": .string("object")]),
                annotations: .init(readOnlyHint: false, destructiveHint: true)
            ),
            operation: { arguments in
                guard let path = arguments["path"]?.stringValue else {
                    throw DomainMutationPathFenceError.relativePath("missing fixture path")
                }
                try await MCPDomainMutationCommitContext.admitPhysicalTargets(
                    [path],
                    rootMappings: mappings
                )
                return try await operation(arguments)
            }
        ))
    }

    func logicalBinding(
        operation: @Sendable @escaping ([String: Value]) async throws -> Value
    ) -> MCPDomainToolBinding {
        runtime.protectedMutationProvider.protectedBinding(MCPDomainToolBinding(
            definition: MCPDomainToolDefinition(
                name: "manage_worktree",
                description: "fixture",
                inputSchema: .object(["type": .string("object")]),
                annotations: .init(readOnlyHint: false, destructiveHint: true)
            ),
            operation: operation
        ))
    }

    func invoke(
        _ binding: MCPDomainToolBinding,
        arguments: [String: Value],
        workspaceRevision: UInt64 = 7,
        requestIdentitySeed: String = UUID().uuidString
    ) async throws -> Value {
        var context = DomainToolInvocationSecurityContext(
            principal: DomainClientPrincipal(
                principalID: UUID(),
                stableKey: "app:test",
                displayName: "test app proxy",
                kind: .runScoped,
                assurance: .hostLaunchToken,
                processID: 42,
                runID: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"),
                provider: "test",
                verifiedIdentityFingerprint: "test-app-fingerprint"
            ),
            connectionID: UUID(),
            connectionGeneration: 1,
            invocationID: UUID(),
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: runtime.identity.lifecycleGeneration,
            workspaceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            workspaceRevision: workspaceRevision,
            authorizedCanonicalRoots: [root.path],
            ephemeralGrantedToolNames: ["file_actions"]
        )
        context.overrideMutationRequestKeyForTesting(requestIdentitySeed)
        return try await MCPDomainInvocationSecurityContext.$current.withValue(context) {
            try await binding(arguments)
        }
    }

    func invokeLogical(
        _ binding: MCPDomainToolBinding,
        arguments: [String: Value],
        workspaceRevision: UInt64 = 7,
        requestIdentitySeed: String = UUID().uuidString,
        authorizedCanonicalRoots: Set<String>? = nil,
        ephemeralGrantedToolNames: Set<String> = ["manage_worktree"]
    ) async throws -> Value {
        var context = DomainToolInvocationSecurityContext(
            principal: DomainClientPrincipal(
                principalID: UUID(),
                stableKey: "app:test",
                displayName: "test app proxy",
                kind: .runScoped,
                assurance: .hostLaunchToken,
                processID: 42,
                runID: UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF"),
                provider: "test",
                verifiedIdentityFingerprint: "test-app-fingerprint"
            ),
            connectionID: UUID(),
            connectionGeneration: 1,
            invocationID: UUID(),
            runtimeID: runtime.identity.runtimeID,
            runtimeGeneration: runtime.identity.lifecycleGeneration,
            workspaceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            workspaceRevision: workspaceRevision,
            authorizedCanonicalRoots: authorizedCanonicalRoots ?? [root.path],
            ephemeralGrantedToolNames: ephemeralGrantedToolNames
        )
        context.overrideMutationRequestKeyForTesting(requestIdentitySeed)
        return try await MCPDomainInvocationSecurityContext.$current.withValue(context) {
            try await binding(arguments)
        }
    }
}

private actor MutationCounter {
    private(set) var value = 0
    func increment() {
        value += 1
    }
}

private actor MutationAttemptBehavior {
    private var attempt = 0
    func next() -> Int {
        attempt += 1
        return attempt
    }
}

private actor MutationGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var entered = false

    func wait() async throws {
        entered = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilEntered() async {
        while !entered {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}

private func m4bTTYAdministrator() -> DomainClientPrincipal {
    DomainClientPrincipal(
        principalID: UUID(),
        stableKey: nil,
        displayName: "local tty",
        kind: .ttyAdministrator,
        assurance: .localTTY,
        processID: 42,
        runID: nil,
        provider: nil
    )
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> some Any,
    _ verify: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        verify(error)
    }
}
