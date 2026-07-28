import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class CodexNativeSessionControllerHookApprovalTests: XCTestCase {
    func testListDecodesAllTrustStatusesWarningsFingerprintAndExternalSourcePaths() async throws {
        let cwd = "/tmp/worktree/repo/./"
        let hooks = [
            hook(key: "z", hash: "hash-z", status: "modified", sourcePath: "/tmp/main/repo/.codex/config.toml"),
            hook(key: "a", hash: "hash-a", status: "managed", command: NSNull()),
            hook(key: "b", hash: "hash-b", status: "untrusted", enabled: false, command: "deny.sh"),
            hook(key: "c", hash: "hash-c", status: "trusted", source: "user")
        ]
        let recorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/worktree/repo", hooks: hooks, warnings: ["review warning"]))
        ])
        let controller = makeController(cwd: cwd, recorder: recorder)

        let inventory = try await controller.listHooksForCurrentWorkspace()

        XCTAssertEqual(inventory.executionCWD, "/tmp/worktree/repo")
        XCTAssertEqual(inventory.hooks.map(\.key), ["a", "b", "c", "z"])
        XCTAssertEqual(inventory.hooks.map(\.trustStatus), [.managed, .untrusted, .trusted, .modified])
        XCTAssertEqual(inventory.projectHooks.map(\.key), ["a", "b", "z"])
        XCTAssertEqual(inventory.unresolvedProjectHooks.map(\.key), ["b", "z"])
        XCTAssertEqual(inventory.warnings, ["review warning"])
        XCTAssertEqual(inventory.hooks.first(where: { $0.key == "b" })?.commandOrHandler, "deny.sh")
        XCTAssertEqual(inventory.hooks.first(where: { $0.key == "z" })?.sourcePath, "/tmp/main/repo/.codex/config.toml")
        XCTAssertEqual(recorder.requests().first?.params?["cwds"] as? [String], [cwd])

        let reordered = try CodexHookInventory.decode(
            result: listResult(cwd: "/tmp/worktree/repo/../repo", hooks: hooks.reversed()),
            executionCWD: "/tmp/worktree/repo"
        )
        XCTAssertEqual(inventory.fingerprint, reordered.fingerprint)
    }

    func testListRejectsUnknownMalformedConflictingDuplicatesAndCwdErrors() async {
        let cases: [(String, [String: Any])] = [
            ("unknown status", listResult(cwd: "/tmp/repo", hooks: [hook(key: "a", hash: "h", status: "future")])),
            ("blank key", listResult(cwd: "/tmp/repo", hooks: [hook(key: " ", hash: "h", status: "untrusted")])),
            ("conflicting duplicate", listResult(cwd: "/tmp/repo", hooks: [
                hook(key: "a", hash: "h1", status: "untrusted"),
                hook(key: "a", hash: "h2", status: "untrusted")
            ])),
            ("handler-only duplicate conflict", listResult(cwd: "/tmp/repo", hooks: [
                hook(key: "a", hash: "h", status: "untrusted", handlerType: "command"),
                hook(key: "a", hash: "h", status: "untrusted", handlerType: "prompt")
            ]))
        ]

        for (name, result) in cases {
            let recorder = HookRequestRecorder(steps: [.init(method: "hooks/list", result: result)])
            let controller = makeController(cwd: "/tmp/repo", recorder: recorder)
            do {
                _ = try await controller.listHooksForCurrentWorkspace()
                XCTFail("Expected malformed response for \(name)")
            } catch let error as CodexHookTrustError {
                guard case .malformedListResponse = error else {
                    return XCTFail("Unexpected error for \(name): \(error)")
                }
                XCTAssertFalse(error.localizedDescription.contains("future"))
            } catch {
                XCTFail("Unexpected error type for \(name): \(error)")
            }
        }

        let cwdErrors = ["SENTINEL_CWD_DISCOVERY_FAILURE_665"]
        let recorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: [], errors: cwdErrors))
        ])
        do {
            _ = try await makeController(cwd: "/tmp/repo", recorder: recorder)
                .listHooksForCurrentWorkspace()
            XCTFail("Expected cwd discovery failure")
        } catch let error as CodexHookTrustError {
            guard case let .discoveryFailed(receivedErrors) = error else {
                return XCTFail("Unexpected cwd error: \(error)")
            }
            XCTAssertEqual(receivedErrors, cwdErrors)
            XCTAssertTrue(error.localizedDescription.contains("1"))
            XCTAssertFalse(error.localizedDescription.contains(cwdErrors[0]))
        } catch {
            XCTFail("Unexpected cwd error type: \(error)")
        }
    }

    func testExactDuplicateRecordsAreDeduplicated() async throws {
        let duplicate = hook(key: "a", hash: "h", status: "untrusted")
        let recorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: [duplicate, duplicate]))
        ])
        let inventory = try await makeController(cwd: "/tmp/repo", recorder: recorder)
            .listHooksForCurrentWorkspace()
        XCTAssertEqual(inventory.hooks.count, 1)
    }

    func testCanonicallyEquivalentByteDistinctHookKeysFailClosed() async throws {
        let composedKey = "hook-\u{00E9}"
        let decomposedKey = "hook-e\u{0301}"
        XCTAssertEqual(composedKey, decomposedKey)
        XCTAssertNotEqual(Array(composedKey.utf8), Array(decomposedKey.utf8))
        let composedInventory = try inventory(hooks: [
            hook(key: composedKey, hash: "h", status: "untrusted")
        ])
        let decomposedInventory = try inventory(hooks: [
            hook(key: decomposedKey, hash: "h", status: "untrusted")
        ])
        XCTAssertNotEqual(composedInventory.hooks[0], decomposedInventory.hooks[0])
        XCTAssertNotEqual(composedInventory, decomposedInventory)
        XCTAssertEqual(Set([composedInventory, decomposedInventory]).count, 2)
        let recorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: [
                hook(key: composedKey, hash: "h", status: "untrusted"),
                hook(key: decomposedKey, hash: "h", status: "untrusted")
            ]))
        ])

        await assertMalformed {
            try await self.makeController(cwd: "/tmp/repo", recorder: recorder)
                .listHooksForCurrentWorkspace()
        }
    }

    func testCanonicallyEquivalentNonliteralCandidateKeyOrHashFailsBeforeMutation() async throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        let hooks = [hook(key: "key-\(composed)", hash: "hash-\(composed)", status: "untrusted")]
        let displayed = try inventory(hooks: hooks)
        let candidates = [
            CodexHookTrustCandidate(key: "key-\(decomposed)", currentHash: "hash-\(composed)"),
            CodexHookTrustCandidate(key: "key-\(composed)", currentHash: "hash-\(decomposed)")
        ]
        let literalCandidate = CodexHookTrustCandidate(
            key: "key-\(composed)",
            currentHash: "hash-\(composed)"
        )
        XCTAssertNotEqual(literalCandidate, candidates[0])
        XCTAssertNotEqual(literalCandidate, candidates[1])
        XCTAssertEqual(Set([literalCandidate] + candidates).count, 3)

        for candidate in candidates {
            let recorder = HookRequestRecorder(steps: [
                .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: hooks))
            ])
            do {
                _ = try await makeController(cwd: "/tmp/repo", recorder: recorder)
                    .trustHooksForCurrentWorkspace(
                        expectedCandidates: [candidate],
                        expectedInventoryFingerprint: displayed.fingerprint
                    )
                XCTFail("Expected byte-distinct candidate rejection")
            } catch let error as CodexHookTrustError {
                guard case .inventoryChanged = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            XCTAssertEqual(recorder.requests().map(\.method), ["hooks/list"])
        }
    }

    func testSelectedOnlyTrustUsesOneDeterministicAggregateWriteAndVerifies() async throws {
        let unresolved = [
            hook(key: "z-key", hash: "hash-z", status: "untrusted"),
            hook(key: "a-key", hash: "hash-a", status: "modified"),
            hook(key: "ignored", hash: "hash-ignored", status: "untrusted")
        ]
        let displayed = try inventory(hooks: unresolved)
        let verified = [
            hook(key: "z-key", hash: "hash-z", status: "trusted"),
            hook(key: "a-key", hash: "hash-a", status: "managed"),
            hook(key: "ignored", hash: "hash-ignored", status: "untrusted")
        ]
        let recorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "config/batchWrite", result: ["status": "ok"]),
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: verified))
        ])
        let controller = makeController(cwd: "/tmp/repo", recorder: recorder)

        let inventory = try await controller.trustHooksForCurrentWorkspace(
            expectedCandidates: [
                .init(key: "z-key", currentHash: "hash-z"),
                .init(key: "a-key", currentHash: "hash-a")
            ],
            expectedInventoryFingerprint: displayed.fingerprint
        )

        XCTAssertEqual(inventory.unresolvedProjectHooks.map(\.key), ["ignored"])
        let requests = recorder.requests()
        XCTAssertEqual(requests.map(\.method), ["hooks/list", "config/batchWrite", "hooks/list"])
        let write = try XCTUnwrap(requests[1].params)
        XCTAssertEqual(write["reloadUserConfig"] as? Bool, true)
        let edits = try XCTUnwrap(write["edits"] as? [[String: Any]])
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0]["keyPath"] as? String, "hooks.state")
        XCTAssertEqual(edits[0]["mergeStrategy"] as? String, "upsert")
        let values = try XCTUnwrap(edits[0]["value"] as? [String: Any])
        XCTAssertEqual(Set(values.keys), Set(["a-key", "z-key"]))
        XCTAssertNil(values["ignored"])
        XCTAssertEqual((values["a-key"] as? [String: String])?["trusted_hash"], "hash-a")
        XCTAssertEqual((values["z-key"] as? [String: String])?["trusted_hash"], "hash-z")
    }

    func testTrustAllWritesEveryDisplayedCandidate() async throws {
        let unresolved = [
            hook(key: "one", hash: "h1", status: "untrusted"),
            hook(key: "two", hash: "h2", status: "modified")
        ]
        let displayed = try inventory(hooks: unresolved)
        let recorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "config/batchWrite", result: ["status": "ok"]),
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: [
                hook(key: "one", hash: "h1", status: "trusted"),
                hook(key: "two", hash: "h2", status: "trusted")
            ]))
        ])

        let result = try await makeController(cwd: "/tmp/repo", recorder: recorder)
            .trustHooksForCurrentWorkspace(
                expectedCandidates: candidates(from: displayed),
                expectedInventoryFingerprint: displayed.fingerprint
            )

        XCTAssertTrue(result.unresolvedProjectHooks.isEmpty)
        let values = batchValues(from: recorder.requests())
        XCTAssertEqual(Set(values.keys), Set(["one", "two"]))
    }

    func testPreWriteDriftPreventsMutation() async throws {
        let displayedHooks = [hook(key: "one", hash: "old", status: "untrusted")]
        let displayed = try inventory(hooks: displayedHooks)
        let recorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: [
                hook(key: "one", hash: "new", status: "modified")
            ]))
        ])

        do {
            _ = try await makeController(cwd: "/tmp/repo", recorder: recorder)
                .trustHooksForCurrentWorkspace(
                    expectedCandidates: [.init(key: "one", currentHash: "old")],
                    expectedInventoryFingerprint: displayed.fingerprint
                )
            XCTFail("Expected inventory drift")
        } catch let error as CodexHookTrustError {
            guard case let .inventoryChanged(replacement) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(replacement.hooks.first?.currentHash, "new")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(recorder.requests().map(\.method), ["hooks/list"])
    }

    func testPostWriteUntrustedModifiedAndPartialVerificationStayBlocked() async throws {
        let unresolved = [
            hook(key: "one", hash: "h1", status: "untrusted"),
            hook(key: "two", hash: "h2", status: "modified")
        ]
        let displayed = try inventory(hooks: unresolved)
        let verificationCases: [(String, [[String: Any]])] = [
            ("untrusted", [
                hook(key: "one", hash: "h1", status: "untrusted"),
                hook(key: "two", hash: "h2", status: "untrusted")
            ]),
            ("modified", [
                hook(key: "one", hash: "h1", status: "modified"),
                hook(key: "two", hash: "h2", status: "modified")
            ]),
            ("partial", [
                hook(key: "one", hash: "h1", status: "untrusted"),
                hook(key: "two", hash: "h2", status: "trusted")
            ]),
            ("hash drift", [
                hook(key: "one", hash: "changed-h1", status: "trusted"),
                hook(key: "two", hash: "h2", status: "trusted")
            ])
        ]

        for (name, verificationHooks) in verificationCases {
            let recorder = HookRequestRecorder(steps: [
                .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
                .init(method: "config/batchWrite", result: ["status": "ok"]),
                .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: verificationHooks))
            ])
            await assertTrustFailure(
                controller: makeController(cwd: "/tmp/repo", recorder: recorder),
                candidates: candidates(from: displayed),
                fingerprint: displayed.fingerprint
            ) { error in
                guard case let .postWriteVerificationFailed(latest) = error else {
                    return XCTFail("Unexpected error for \(name): \(error)")
                }
                XCTAssertNotNil(latest)
            }
        }
    }

    func testAppGlobalTrustWriteMutexSerializesControllers() async throws {
        let unresolved = [hook(key: "one", hash: "h1", status: "untrusted")]
        let trusted = [hook(key: "one", hash: "h1", status: "trusted")]
        let displayed = try inventory(hooks: unresolved)
        let firstVerificationStarted = expectation(description: "first verification started")
        let secondCallStarted = expectation(description: "second trust call started")
        let verificationGate = HookApprovalAsyncGate()
        let firstRecorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "config/batchWrite", result: ["status": "ok"]),
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: trusted))
        ])
        let secondRecorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "config/batchWrite", result: ["status": "ok"]),
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: trusted))
        ])
        let firstController = makeController(cwd: "/tmp/repo") { method, params, timeout in
            let result = try firstRecorder.handle(method: method, params: params, timeout: timeout)
            if method == "hooks/list", firstRecorder.requests().count == 3 {
                firstVerificationStarted.fulfill()
                await verificationGate.wait()
            }
            return result
        }
        let secondController = makeController(cwd: "/tmp/repo", recorder: secondRecorder)
        let candidates = [CodexHookTrustCandidate(key: "one", currentHash: "h1")]

        let firstTask = Task {
            try await firstController.trustHooksForCurrentWorkspace(
                expectedCandidates: candidates,
                expectedInventoryFingerprint: displayed.fingerprint
            )
        }
        await fulfillment(of: [firstVerificationStarted], timeout: 2)
        let secondTask = Task {
            secondCallStarted.fulfill()
            return try await secondController.trustHooksForCurrentWorkspace(
                expectedCandidates: candidates,
                expectedInventoryFingerprint: displayed.fingerprint
            )
        }
        await fulfillment(of: [secondCallStarted], timeout: 2)
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertTrue(secondRecorder.requests().isEmpty)

        await verificationGate.release()
        _ = try await firstTask.value
        _ = try await secondTask.value
        XCTAssertEqual(secondRecorder.requests().map(\.method), ["hooks/list", "config/batchWrite", "hooks/list"])
    }

    func testCancelledBatchWriteHoldsGlobalMutexUntilServerOperationSettles() async throws {
        let unresolved = [hook(key: "one", hash: "h1", status: "untrusted")]
        let trusted = [hook(key: "one", hash: "h1", status: "trusted")]
        let displayed = try inventory(hooks: unresolved)
        let firstWriteStarted = expectation(description: "first batch write started")
        let secondCallStarted = expectation(description: "second trust call started")
        let writeGate = HookApprovalAsyncGate()
        let firstRecorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved))
        ])
        let secondRecorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "config/batchWrite", result: ["status": "ok"]),
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: trusted))
        ])
        let firstController = makeController(cwd: "/tmp/repo", requestTimeout: 0.01) { method, params, timeout in
            if method == "config/batchWrite" {
                firstRecorder.record(method: method, params: params, timeout: timeout)
                firstWriteStarted.fulfill()
                if let timeout {
                    Task { await writeGate.wait() }
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw NSError(domain: "simulated-client-timeout", code: 1)
                }
                await writeGate.wait()
                return ["status": "ok"]
            }
            return try firstRecorder.handle(method: method, params: params, timeout: timeout)
        }
        let secondController = makeController(cwd: "/tmp/repo", requestTimeout: 0.01, recorder: secondRecorder)
        let candidates = [CodexHookTrustCandidate(key: "one", currentHash: "h1")]

        let firstTask = Task {
            try await firstController.trustHooksForCurrentWorkspace(
                expectedCandidates: candidates,
                expectedInventoryFingerprint: displayed.fingerprint
            )
        }
        await fulfillment(of: [firstWriteStarted], timeout: 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(firstRecorder.requests().last?.timeout)
        firstTask.cancel()
        let secondTask = Task {
            secondCallStarted.fulfill()
            return try await secondController.trustHooksForCurrentWorkspace(
                expectedCandidates: candidates,
                expectedInventoryFingerprint: displayed.fingerprint
            )
        }
        await fulfillment(of: [secondCallStarted], timeout: 2)
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertTrue(secondRecorder.requests().isEmpty)

        await writeGate.release()
        do {
            _ = try await firstTask.value
            XCTFail("Expected cancellation after write settlement")
        } catch let error as CodexHookTrustError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        _ = try await secondTask.value
        XCTAssertEqual(firstRecorder.requests().map(\.method), ["hooks/list", "config/batchWrite"])
        XCTAssertEqual(secondRecorder.requests().map(\.method), ["hooks/list", "config/batchWrite", "hooks/list"])
    }

    func testHookOperationMutexSerializesOverlappingOperationsOnOneController() async throws {
        let listStarted = expectation(description: "first list started")
        let secondCallStarted = expectation(description: "second list call started")
        let listGate = HookApprovalAsyncGate()
        let recorder = HookRequestRecorder(steps: [])
        let result = listResult(cwd: "/tmp/repo", hooks: [])
        let controller = makeController(cwd: "/tmp/repo") { method, params, timeout in
            recorder.record(method: method, params: params, timeout: timeout)
            if recorder.requests().count == 1 {
                listStarted.fulfill()
                await listGate.wait()
            }
            return result
        }

        let firstTask = Task { try await controller.listHooksForCurrentWorkspace() }
        await fulfillment(of: [listStarted], timeout: 2)
        let secondTask = Task {
            secondCallStarted.fulfill()
            return try await controller.listHooksForCurrentWorkspace()
        }
        await fulfillment(of: [secondCallStarted], timeout: 2)
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertEqual(recorder.requests().count, 1)

        await listGate.release()
        _ = try await firstTask.value
        _ = try await secondTask.value
        XCTAssertEqual(recorder.requests().map(\.method), ["hooks/list", "hooks/list"])
    }

    func testCancellationDuringPostWriteVerificationRemainsCancelled() async throws {
        let unresolved = [hook(key: "one", hash: "h1", status: "untrusted")]
        let displayed = try inventory(hooks: unresolved)
        let verificationStarted = expectation(description: "verification list started")
        let recorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "config/batchWrite", result: ["status": "ok"]),
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: [
                hook(key: "one", hash: "h1", status: "trusted")
            ]))
        ])
        let controller = makeController(cwd: "/tmp/repo") { method, params, timeout in
            let result = try recorder.handle(method: method, params: params, timeout: timeout)
            if method == "hooks/list", recorder.requests().count == 3 {
                verificationStarted.fulfill()
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
            return result
        }
        let task = Task {
            try await controller.trustHooksForCurrentWorkspace(
                expectedCandidates: [.init(key: "one", currentHash: "h1")],
                expectedInventoryFingerprint: displayed.fingerprint
            )
        }
        await fulfillment(of: [verificationStarted], timeout: 2)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected verification cancellation")
        } catch let error as CodexHookTrustError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(recorder.requests().map(\.method), ["hooks/list", "config/batchWrite", "hooks/list"])
    }

    func testNonUnsupportedListFailuresAreSanitizedMalformedResponses() async {
        let sentinel = "SENTINEL_LIST_FAILURE_665"
        let failures: [Error] = [
            CodexAppServerClient.ClientError.requestFailed(.init(
                method: "hooks/list",
                code: -32000,
                message: sentinel,
                data: nil
            )),
            CodexAppServerClient.ClientError.transportWriteFailed(message: sentinel, errno: nil)
        ]

        for failure in failures {
            let recorder = HookRequestRecorder(steps: [.init(method: "hooks/list", error: failure)])
            do {
                _ = try await makeController(cwd: "/tmp/repo", recorder: recorder)
                    .listHooksForCurrentWorkspace()
                XCTFail("Expected malformed discovery failure")
            } catch let error as CodexHookTrustError {
                guard case .malformedListResponse = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertFalse(error.localizedDescription.contains(sentinel))
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testThrownBatchWriteFailureIsSanitized() async throws {
        let sentinel = "SENTINEL_BATCH_FAILURE_665"
        let unresolved = [hook(key: "one", hash: "h1", status: "untrusted")]
        let displayed = try inventory(hooks: unresolved)
        let failure = CodexAppServerClient.ClientError.requestFailed(.init(
            method: "config/batchWrite",
            code: -32000,
            message: sentinel,
            data: nil
        ))
        let recorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "config/batchWrite", error: failure)
        ])

        await assertTrustFailure(
            controller: makeController(cwd: "/tmp/repo", recorder: recorder),
            candidates: candidates(from: displayed),
            fingerprint: displayed.fingerprint
        ) { error in
            guard case .batchWriteFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains(sentinel))
        }
        XCTAssertEqual(recorder.requests().map(\.method), ["hooks/list", "config/batchWrite"])
    }

    func testMalformedAndTransportFailedVerificationResponsesAreSanitized() async throws {
        let sentinel = "SENTINEL_VERIFICATION_FAILURE_665"
        let unresolved = [hook(key: "one", hash: "h1", status: "untrusted")]
        let displayed = try inventory(hooks: unresolved)
        let verificationSteps: [HookRequestRecorder.Step] = [
            .init(method: "hooks/list", result: [:]),
            .init(
                method: "hooks/list",
                error: CodexAppServerClient.ClientError.transportReadSetupFailed(message: sentinel, errno: nil)
            )
        ]

        for verificationStep in verificationSteps {
            let recorder = HookRequestRecorder(steps: [
                .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
                .init(method: "config/batchWrite", result: ["status": "ok"]),
                verificationStep
            ])
            await assertTrustFailure(
                controller: makeController(cwd: "/tmp/repo", recorder: recorder),
                candidates: candidates(from: displayed),
                fingerprint: displayed.fingerprint
            ) { error in
                guard case let .postWriteVerificationFailed(latest) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertNil(latest)
                XCTAssertFalse(error.localizedDescription.contains(sentinel))
            }
        }
    }

    func testSelectedHookMissingAfterWriteFailsVerification() async throws {
        let unresolved = [hook(key: "one", hash: "h1", status: "untrusted")]
        let displayed = try inventory(hooks: unresolved)
        let recorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "config/batchWrite", result: ["status": "ok"]),
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: []))
        ])

        await assertTrustFailure(
            controller: makeController(cwd: "/tmp/repo", recorder: recorder),
            candidates: candidates(from: displayed),
            fingerprint: displayed.fingerprint
        ) { error in
            guard case let .postWriteVerificationFailed(latest) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(latest?.hooks, [])
        }
    }

    func testEmptyAndDuplicateCandidatesFailBeforeBatchWrite() async throws {
        let unresolved = [hook(key: "one", hash: "h1", status: "untrusted")]
        let displayed = try inventory(hooks: unresolved)
        let cases: [[CodexHookTrustCandidate]] = [
            [],
            [
                .init(key: "one", currentHash: "h1"),
                .init(key: "one", currentHash: "h1")
            ]
        ]

        for candidates in cases {
            let recorder = HookRequestRecorder(steps: [
                .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved))
            ])
            do {
                _ = try await makeController(cwd: "/tmp/repo", recorder: recorder)
                    .trustHooksForCurrentWorkspace(
                        expectedCandidates: candidates,
                        expectedInventoryFingerprint: displayed.fingerprint
                    )
                XCTFail("Expected candidate rejection")
            } catch let error as CodexHookTrustError {
                guard case .inventoryChanged = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(recorder.requests().map(\.method), ["hooks/list"])
        }
    }

    func testStructuredMethodNotFoundClassifiesListAndWriteWithoutMessageLeakage() async throws {
        let sentinel = "SENTINEL_SERVER_MESSAGE_665"
        let listFailure = CodexAppServerClient.ClientError.requestFailed(.init(
            method: "hooks/list",
            code: -32601,
            message: sentinel,
            data: nil
        ))
        let listRecorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", error: listFailure)
        ])
        do {
            _ = try await makeController(cwd: "/tmp/repo", recorder: listRecorder)
                .listHooksForCurrentWorkspace()
            XCTFail("Expected unsupported list")
        } catch let error as CodexHookTrustError {
            guard case .unsupportedMethod(method: "hooks/list") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains(sentinel))
        }

        let unresolved = [hook(key: "one", hash: "h1", status: "untrusted")]
        let displayed = try inventory(hooks: unresolved)
        let writeFailure = CodexAppServerClient.ClientError.requestFailed(.init(
            method: "config/batchWrite",
            code: -32601,
            message: sentinel,
            data: nil
        ))
        let writeRecorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "config/batchWrite", error: writeFailure)
        ])
        do {
            _ = try await makeController(cwd: "/tmp/repo", recorder: writeRecorder)
                .trustHooksForCurrentWorkspace(
                    expectedCandidates: [.init(key: "one", currentHash: "h1")],
                    expectedInventoryFingerprint: displayed.fingerprint
                )
            XCTFail("Expected unsupported write")
        } catch let error as CodexHookTrustError {
            guard case .unsupportedMethod(method: "config/batchWrite") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains(sentinel))
        }
    }

    func testNonOKBatchWriteStatusFailsWithoutVerificationList() async throws {
        let unresolved = [hook(key: "one", hash: "h1", status: "untrusted")]
        let displayed = try inventory(hooks: unresolved)
        let recorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "config/batchWrite", result: ["status": "error"])
        ])

        await assertTrustFailure(
            controller: makeController(cwd: "/tmp/repo", recorder: recorder),
            candidates: candidates(from: displayed),
            fingerprint: displayed.fingerprint
        ) { error in
            guard case .batchWriteFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(recorder.requests().map(\.method), ["hooks/list", "config/batchWrite"])
    }

    func testCancellationAfterBatchWriteWasSentDoesNotReportSuccess() async throws {
        let unresolved = [hook(key: "one", hash: "h1", status: "untrusted")]
        let displayed = try inventory(hooks: unresolved)
        let writeStarted = expectation(description: "batch write sent")
        let writeGate = HookApprovalAsyncGate()
        let recorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved))
        ])
        let controller = makeController(cwd: "/tmp/repo") { method, params, timeout in
            if method == "config/batchWrite" {
                recorder.record(method: method, params: params, timeout: timeout)
                writeStarted.fulfill()
                await writeGate.wait()
                return ["status": "ok"]
            }
            return try recorder.handle(method: method, params: params, timeout: timeout)
        }
        let task = Task {
            try await controller.trustHooksForCurrentWorkspace(
                expectedCandidates: [.init(key: "one", currentHash: "h1")],
                expectedInventoryFingerprint: displayed.fingerprint
            )
        }
        await fulfillment(of: [writeStarted], timeout: 2)
        task.cancel()
        await writeGate.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation after possibly persisted write")
        } catch let error as CodexHookTrustError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(recorder.requests().map(\.method), ["hooks/list", "config/batchWrite"])
    }

    func testEveryHookTrustErrorDescriptionExcludesSensitiveInventoryValues() throws {
        let sentinel = "SENTINEL_HOOK_SECRET_665"
        let sensitiveHook = hook(
            key: "key-\(sentinel)",
            hash: "hash-\(sentinel)",
            status: "untrusted",
            sourcePath: "/private/\(sentinel)/config.toml",
            command: "run-\(sentinel)"
        )
        let inventory = try inventory(hooks: [sensitiveHook])
        let errors: [CodexHookTrustError] = [
            .unsupportedMethod(method: "hooks/list"),
            .malformedListResponse,
            .discoveryFailed(cwdErrors: [sentinel]),
            .inventoryChanged(replacement: inventory),
            .batchWriteFailed,
            .postWriteVerificationFailed(latest: inventory),
            .cancelled
        ]

        for error in errors {
            XCTAssertFalse(error.localizedDescription.contains(sentinel), "Leaked from \(error)")
        }
    }

    func testExecutionCWDWhitespaceIsPreservedForRequestAndFingerprint() async throws {
        let executionCWD = "/tmp/repo "
        let recorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: executionCWD, hooks: []))
        ])
        let listedInventory = try await makeController(cwd: executionCWD, recorder: recorder)
            .listHooksForCurrentWorkspace()
        let trimmedInventory = try inventory(hooks: [])

        XCTAssertEqual(recorder.requests().first?.params?["cwds"] as? [String], [executionCWD])
        XCTAssertEqual(listedInventory.executionCWD, executionCWD)
        XCTAssertNotEqual(listedInventory.fingerprint, trimmedInventory.fingerprint)
    }

    func testCancellationStopsBeforeBatchWrite() async {
        let requestStarted = expectation(description: "preflight hooks/list started")
        let recorder = HookRequestRecorder(steps: [])
        let controller = makeController(cwd: "/tmp/repo") { method, params, timeout in
            recorder.record(method: method, params: params, timeout: timeout)
            requestStarted.fulfill()
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return [:]
        }

        let task = Task {
            try await controller.trustHooksForCurrentWorkspace(
                expectedCandidates: [.init(key: "one", currentHash: "h1")],
                expectedInventoryFingerprint: "fingerprint"
            )
        }
        await fulfillment(of: [requestStarted], timeout: 2)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch let error as CodexHookTrustError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(recorder.requests().map(\.method), ["hooks/list"])
    }

    func testMissingExecutionCWDAndAmbiguousCwdResultFailClosed() async {
        let missingController = makeController(cwd: nil, recorder: HookRequestRecorder(steps: []))
        await assertMalformed { try await missingController.listHooksForCurrentWorkspace() }

        let recorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: ["data": [
                listEntry(cwd: "/tmp/repo", hooks: []),
                listEntry(cwd: "/tmp/other", hooks: [])
            ]])
        ])
        await assertMalformed {
            try await self.makeController(cwd: "/tmp/repo", recorder: recorder)
                .listHooksForCurrentWorkspace()
        }
    }

    private func inventory(
        cwd: String = "/tmp/repo",
        hooks: [[String: Any]]
    ) throws -> CodexHookInventory {
        try CodexHookInventory.decode(
            result: listResult(cwd: cwd, hooks: hooks),
            executionCWD: cwd
        )
    }

    private func candidates(from inventory: CodexHookInventory) -> [CodexHookTrustCandidate] {
        inventory.unresolvedProjectHooks.map {
            CodexHookTrustCandidate(key: $0.key, currentHash: $0.currentHash)
        }
    }

    private func assertTrustFailure(
        controller: CodexNativeSessionController,
        candidates: [CodexHookTrustCandidate],
        fingerprint: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        validate: (CodexHookTrustError) -> Void
    ) async {
        do {
            _ = try await controller.trustHooksForCurrentWorkspace(
                expectedCandidates: candidates,
                expectedInventoryFingerprint: fingerprint
            )
            XCTFail("Expected hook-trust failure", file: file, line: line)
        } catch let error as CodexHookTrustError {
            validate(error)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertMalformed(
        _ operation: () async throws -> CodexHookInventory
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected malformed response")
        } catch let error as CodexHookTrustError {
            guard case .malformedListResponse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeController(
        cwd: String?,
        requestTimeout: TimeInterval? = 120,
        recorder: HookRequestRecorder
    ) -> CodexNativeSessionController {
        makeController(cwd: cwd, requestTimeout: requestTimeout) { method, params, timeout in
            try recorder.handle(method: method, params: params, timeout: timeout)
        }
    }

    private func makeController(
        cwd: String?,
        requestTimeout: TimeInterval? = 120,
        executor: @escaping @Sendable (String, [String: Any]?, TimeInterval?) async throws -> [String: Any]
    ) -> CodexNativeSessionController {
        var options = CodexNativeSessionController.Options.agentModeDefault()
        options.requestTimeout = requestTimeout
        return CodexNativeSessionController(
            client: CodexAppServerClient(),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePaths: .uniform(cwd),
            options: options,
            requestExecutor: executor
        )
    }

    private func batchValues(from requests: [HookRequestRecorder.Request]) -> [String: Any] {
        guard let write = requests.first(where: { $0.method == "config/batchWrite" }),
              let edits = write.params?["edits"] as? [[String: Any]],
              let values = edits.first?["value"] as? [String: Any]
        else {
            return [:]
        }
        return values
    }
}

private final class HookRequestRecorder: @unchecked Sendable {
    struct Request {
        let method: String
        let params: [String: Any]?
        let timeout: TimeInterval?
    }

    struct Step {
        let method: String
        let result: [String: Any]
        let error: Error?

        init(method: String, result: [String: Any]) {
            self.method = method
            self.result = result
            error = nil
        }

        init(method: String, error: Error) {
            self.method = method
            result = [:]
            self.error = error
        }
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var recordedRequests: [Request] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func handle(
        method: String,
        params: [String: Any]?,
        timeout: TimeInterval?
    ) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(.init(method: method, params: params, timeout: timeout))
        guard !steps.isEmpty else {
            throw HookApprovalTestError.unexpectedRequest(method)
        }
        let step = steps.removeFirst()
        guard step.method == method else {
            throw HookApprovalTestError.unexpectedRequest(method)
        }
        if let error = step.error {
            throw error
        }
        return step.result
    }

    func record(method: String, params: [String: Any]?, timeout: TimeInterval?) {
        lock.lock()
        recordedRequests.append(.init(method: method, params: params, timeout: timeout))
        lock.unlock()
    }

    func requests() -> [Request] {
        lock.lock()
        let result = recordedRequests
        lock.unlock()
        return result
    }
}

private enum HookApprovalTestError: Error {
    case unexpectedRequest(String)
}

private actor HookApprovalAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private func listResult(
    cwd: String,
    hooks: [[String: Any]],
    errors: [String] = [],
    warnings: [String] = []
) -> [String: Any] {
    ["data": [listEntry(cwd: cwd, hooks: hooks, errors: errors, warnings: warnings)]]
}

private func listEntry(
    cwd: String,
    hooks: [[String: Any]],
    errors: [String] = [],
    warnings: [String] = []
) -> [String: Any] {
    [
        "cwd": cwd,
        "hooks": hooks,
        "errors": errors,
        "warnings": warnings
    ]
}

private func hook(
    key: String,
    hash: String,
    status: String,
    source: String = "project",
    sourcePath: String = "/tmp/repo/.codex/config.toml",
    enabled: Bool = true,
    handlerType: String = "command",
    command: Any? = nil
) -> [String: Any] {
    var value: [String: Any] = [
        "eventName": "preToolUse",
        "source": source,
        "sourcePath": sourcePath,
        "key": key,
        "currentHash": hash,
        "enabled": enabled,
        "trustStatus": status,
        "handlerType": handlerType
    ]
    if let command {
        value["command"] = command
    }
    return value
}
