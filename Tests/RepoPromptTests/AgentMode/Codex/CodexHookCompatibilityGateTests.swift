import Foundation
@testable import RepoPromptApp
import XCTest

final class CodexHookCompatibilityGateTests: XCTestCase {
    private let cwd = "/tmp/codex-hook-project"
    private let configURL = URL(fileURLWithPath: "/tmp/rpce-codex-home/config.toml")
    private let hashA = "sha256:" + String(repeating: "a", count: 64)
    private let hashB = "sha256:" + String(repeating: "b", count: 64)

    func testZeroInventoryIsValidAndEmitsTypedDiagnostic() async throws {
        let diagnostics = LockedValues<CodexHookInventoryDiagnostic>()
        let dependencies = dependencies(
            read: { method, _, _ in
                XCTAssertEqual(method, "hooks/list")
                return self.inventory(hooks: [])
            },
            review: { _ in XCTFail("zero inventory must not review")
                return .cancel
            },
            emit: { diagnostics.append($0) }
        )

        try await CodexHookCompatibilityGate.run(
            cwd: cwd,
            managedConfigURL: configURL,
            timeout: 1,
            dependencies: dependencies
        )

        XCTAssertEqual(diagnostics.values.count, 1)
        XCTAssertEqual(diagnostics.values.first?.isZeroInventory, true)
        XCTAssertEqual(diagnostics.values.first?.warningCount, 0)
        XCTAssertEqual(diagnostics.values.first?.sourceCounts, [:])
        XCTAssertEqual(
            diagnostics.values.first?.statusSummary,
            "No Codex hook definitions were discovered for this execution directory."
        )
    }

    func testZeroInventoryWarningsRemainVisibleWithoutLeakingRawDetails() async throws {
        let diagnostics = LockedValues<CodexHookInventoryDiagnostic>()
        let dependencies = dependencies(
            read: { _, _, _ in self.inventory(hooks: [], warnings: ["private warning contents"]) },
            review: { _ in .cancel },
            emit: { diagnostics.append($0) }
        )

        try await CodexHookCompatibilityGate.run(
            cwd: cwd,
            managedConfigURL: configURL,
            timeout: 1,
            dependencies: dependencies
        )

        let diagnostic = try XCTUnwrap(diagnostics.values.first)
        XCTAssertEqual(diagnostic.warningCount, 1)
        XCTAssertTrue(diagnostic.statusSummary.contains("1 inventory warning"))
        XCTAssertFalse(diagnostic.statusSummary.contains("private warning contents"))
    }

    func testPinnedSchemaRejectsUnknownTrustAndPerCwdErrors() throws {
        var unknown = projectHook(hash: hashA, trust: "futureStatus")
        XCTAssertThrowsError(try CodexHookInventory.decode(
            inventory(hooks: [unknown]),
            expectedCWDs: [cwd]
        ))
        unknown["trustStatus"] = "untrusted"
        unknown["currentHash"] = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try CodexHookInventory.decode(
            inventory(hooks: [unknown]),
            expectedCWDs: [cwd]
        ))
        unknown["currentHash"] = hashA
        XCTAssertThrowsError(try CodexHookInventory.decode(
            inventory(hooks: [unknown], errors: [["path": "/tmp/.codex/hooks.json", "message": "invalid"]]),
            expectedCWDs: [cwd]
        )) { error in
            guard case CodexHookGateError.inventoryError = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPinnedSchemaRequiresExactlyOneRecordPerCwd() throws {
        let duplicated: [String: Any] = [
            "data": [
                inventoryRecord(hooks: []),
                inventoryRecord(hooks: [])
            ]
        ]
        XCTAssertThrowsError(try CodexHookInventory.decode(duplicated, expectedCWDs: [cwd]))
        XCTAssertThrowsError(try CodexHookInventory.decode(["data": []], expectedCWDs: [cwd]))
    }

    func testTrustAllUsesVersionFencedManagedWriteAndReinventories() async throws {
        let calls = LockedValues<String>()
        let hookReads = LockedCounter()
        let writes = LockedValues<[String: Any]>()
        let dependencies = dependencies(
            read: { method, _, _ in
                calls.append(method)
                switch method {
                case "hooks/list":
                    let count = hookReads.increment()
                    return self.inventory(hooks: [
                        self.projectHook(hash: self.hashA, trust: count == 3 ? "trusted" : "untrusted")
                    ])
                case "config/read":
                    return self.configRead()
                default:
                    XCTFail("Unexpected read \(method)")
                    return [:]
                }
            },
            write: { method, params, _ in
                calls.append(method)
                writes.append(params)
                return ["status": "ok", "version": "v2", "filePath": self.configURL.path]
            },
            review: { _ in .trustAll }
        )

        try await CodexHookCompatibilityGate.run(
            cwd: cwd,
            managedConfigURL: configURL,
            timeout: 1,
            dependencies: dependencies
        )

        XCTAssertEqual(calls.values, ["hooks/list", "hooks/list", "config/read", "config/batchWrite", "hooks/list"])
        let write = try XCTUnwrap(writes.values.first)
        XCTAssertEqual(write["filePath"] as? String, configURL.path)
        XCTAssertEqual(write["expectedVersion"] as? String, "v1")
        let edits = try XCTUnwrap(write["edits"] as? [[String: Any]])
        XCTAssertEqual(edits.first?["keyPath"] as? String, "hooks.state")
        XCTAssertEqual(edits.first?["mergeStrategy"] as? String, "upsert")
    }

    func testDeclineAndCancelDoNotWrite() async throws {
        for (decision, expected) in [
            (CodexHookReviewDecision.decline, CodexHookGateError.reviewDeclined),
            (.cancel, .reviewCancelled)
        ] {
            let writes = LockedCounter()
            let dependencies = dependencies(
                read: { _, _, _ in self.inventory(hooks: [self.projectHook(hash: self.hashA, trust: "untrusted")]) },
                write: { _, _, _ in _ = writes.increment()
                    return [:]
                },
                review: { _ in decision }
            )
            do {
                try await CodexHookCompatibilityGate.run(
                    cwd: cwd,
                    managedConfigURL: configURL,
                    timeout: 1,
                    dependencies: dependencies
                )
                XCTFail("Expected review rejection")
            } catch let error as CodexHookGateError {
                XCTAssertEqual(error, expected)
            }
            XCTAssertEqual(writes.value, 0)
        }
    }

    func testInventoryDriftRequiresFreshDecisionBeforeWrite() async throws {
        let reads = LockedCounter()
        let writes = LockedCounter()
        let dependencies = dependencies(
            read: { _, _, _ in
                let hash = reads.increment() == 1 ? self.hashA : self.hashB
                return self.inventory(hooks: [self.projectHook(hash: hash, trust: "untrusted")])
            },
            write: { _, _, _ in _ = writes.increment()
                return [:]
            },
            review: { _ in .trustAll }
        )
        do {
            try await CodexHookCompatibilityGate.run(
                cwd: cwd,
                managedConfigURL: configURL,
                timeout: 1,
                dependencies: dependencies
            )
            XCTFail("Expected drift")
        } catch let error as CodexHookGateError {
            XCTAssertEqual(error, .inventoryDrift)
        }
        XCTAssertEqual(writes.value, 0)
    }

    func testAmbiguousWriteIsNotRetriedAndReturnsActionableError() async throws {
        struct SimulatedTransportLoss: LocalizedError { var errorDescription: String? {
            "transport lost"
        } }
        let reads = LockedCounter()
        let writes = LockedCounter()
        let terminations = LockedCounter()
        let dependencies = dependencies(
            read: { method, _, _ in
                if method == "config/read" { return self.configRead() }
                _ = reads.increment()
                return self.inventory(hooks: [self.projectHook(hash: self.hashA, trust: "untrusted")])
            },
            write: { _, _, _ in _ = writes.increment()
                throw SimulatedTransportLoss()
            },
            review: { _ in .trustAll },
            terminateUncertainWrite: { _ = terminations.increment() }
        )
        do {
            try await CodexHookCompatibilityGate.run(
                cwd: cwd,
                managedConfigURL: configURL,
                timeout: 1,
                dependencies: dependencies
            )
            XCTFail("Expected uncertain write")
        } catch let error as CodexHookGateError {
            guard case let .uncertainWrite(message) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertTrue(message.contains("did not retry"))
        }
        XCTAssertEqual(writes.value, 1)
        XCTAssertEqual(terminations.value, 1)
    }

    func testMalformedWriteSuccessIsQuarantinedAsUncertain() async {
        let terminations = LockedCounter()
        let dependencies = dependencies(
            read: { method, _, _ in
                method == "config/read"
                    ? self.configRead()
                    : self.inventory(hooks: [self.projectHook(hash: self.hashA, trust: "untrusted")])
            },
            write: { _, _, _ in ["status": "futureStatus"] },
            review: { _ in .trustAll },
            terminateUncertainWrite: { _ = terminations.increment() }
        )

        do {
            try await CodexHookCompatibilityGate.run(
                cwd: cwd,
                managedConfigURL: configURL,
                timeout: 1,
                dependencies: dependencies
            )
            XCTFail("Expected uncertain write")
        } catch let error as CodexHookGateError {
            guard case .uncertainWrite = error else { return XCTFail("Unexpected \(error)") }
        } catch {
            XCTFail("Unexpected \(error)")
        }
        XCTAssertEqual(terminations.value, 1)
    }

    func testStaleAuthorityStopsAfterAwait() async {
        let authorityChecks = LockedCounter()
        let dependencies = dependencies(
            read: { _, _, _ in self.inventory(hooks: []) },
            assertAuthority: {
                if authorityChecks.increment() >= 1 {
                    throw CodexSessionControllerError.invalidLifecycleState("stale test controller")
                }
            }
        )
        await XCTAssertThrowsErrorAsync {
            try await CodexHookCompatibilityGate.run(
                cwd: self.cwd,
                managedConfigURL: self.configURL,
                timeout: 1,
                dependencies: dependencies
            )
        }
    }

    func testTypedLifecycleStartedAndExplicitFailure() throws {
        let started = try CodexHookLifecycleDiagnostic.decode(
            method: "hook/started",
            params: lifecyclePayload(status: "running")
        )
        XCTAssertFalse(started.reportedRuntimeFailure)

        let failed = try CodexHookLifecycleDiagnostic.decode(
            method: "hook/completed",
            params: lifecyclePayload(status: "failed")
        )
        XCTAssertTrue(failed.reportedRuntimeFailure)
        XCTAssertEqual(failed.statusMessage, "exit 1")

        var defaultSourcePayload = lifecyclePayload(status: "running")
        var defaultSourceRun = try XCTUnwrap(defaultSourcePayload["run"] as? [String: Any])
        defaultSourceRun.removeValue(forKey: "source")
        defaultSourcePayload["run"] = defaultSourceRun
        let defaultSource = try CodexHookLifecycleDiagnostic.decode(
            method: "hook/started",
            params: defaultSourcePayload
        )
        XCTAssertEqual(defaultSource.run.source, .unknown)

        XCTAssertThrowsError(try CodexHookLifecycleDiagnostic.decode(
            method: "hook/completed",
            params: lifecyclePayload(status: "running")
        ))
    }

    func testHookReviewApprovalHasNoAlwaysAllow() {
        let request = AgentApprovalRequest(
            requestID: .codexHookReview(UUID()),
            method: "hooks/review",
            kind: .codexHookReview,
            threadID: "",
            turnID: "",
            itemID: "fingerprint"
        )
        XCTAssertFalse(request.supportsAlwaysAllow)
    }

    private func dependencies(
        read: @escaping @Sendable (String, [String: Any], TimeInterval?) async throws -> [String: Any],
        write: @escaping @Sendable (String, [String: Any], TimeInterval?) async throws -> [String: Any] = { _, _, _ in XCTFail("Unexpected write")
            return [:]
        },
        review: @escaping @Sendable (CodexHookReview) async -> CodexHookReviewDecision = { _ in XCTFail("Unexpected review")
            return .cancel
        },
        emit: @escaping @Sendable (CodexHookInventoryDiagnostic) async -> Void = { _ in },
        terminateUncertainWrite: @escaping @Sendable () async throws -> Void = {},
        assertAuthority: @escaping @Sendable () throws -> Void = {}
    ) -> CodexHookGateDependencies {
        .init(
            read: read,
            write: write,
            review: review,
            emitInventory: emit,
            terminateUncertainWrite: terminateUncertainWrite,
            assertAuthority: assertAuthority
        )
    }

    private func inventory(
        hooks: [[String: Any]],
        warnings: [String] = [],
        errors: [[String: Any]] = []
    ) -> [String: Any] {
        ["data": [inventoryRecord(hooks: hooks, warnings: warnings, errors: errors)]]
    }

    private func inventoryRecord(
        hooks: [[String: Any]],
        warnings: [String] = [],
        errors: [[String: Any]] = []
    ) -> [String: Any] {
        ["cwd": cwd, "hooks": hooks, "warnings": warnings, "errors": errors]
    }

    private func projectHook(hash: String, trust: String) -> [String: Any] {
        [
            "key": "project-hook-key",
            "eventName": "sessionStart",
            "handlerType": "command",
            "matcher": NSNull(),
            "command": "./hooks/session-start.sh",
            "timeoutSec": 10,
            "statusMessage": NSNull(),
            "additionalContextLimit": NSNull(),
            "sourcePath": "\(cwd)/.codex/hooks.json",
            "source": "project",
            "pluginId": NSNull(),
            "displayOrder": 0,
            "enabled": true,
            "isManaged": false,
            "currentHash": hash,
            "trustStatus": trust
        ]
    }

    private func configRead() -> [String: Any] {
        [
            "config": [:],
            "origins": [:],
            "layers": [[
                "name": ["type": "user", "file": configURL.path, "profile": NSNull()],
                "version": "v1",
                "config": [:]
            ]]
        ]
    }

    private func lifecyclePayload(status: String) -> [String: Any] {
        [
            "threadId": "thread-1",
            "turnId": NSNull(),
            "run": [
                "id": "run-1",
                "eventName": "sessionStart",
                "handlerType": "command",
                "executionMode": "sync",
                "scope": "thread",
                "sourcePath": "\(cwd)/.codex/hooks.json",
                "source": "project",
                "displayOrder": 0,
                "status": status,
                "statusMessage": status == "failed" ? "exit 1" : NSNull(),
                "startedAt": 1,
                "completedAt": status == "running" ? NSNull() : 2,
                "durationMs": status == "running" ? NSNull() : 1,
                "entries": status == "failed" ? [["kind": "error", "text": "exit 1"]] : []
            ]
        ]
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int {
        lock.withLock { storage }
    }

    @discardableResult func increment() -> Int {
        lock.withLock { storage += 1
            return storage
        }
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
