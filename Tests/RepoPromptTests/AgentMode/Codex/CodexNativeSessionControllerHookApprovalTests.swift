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
            ])),
            ("partially decoded data", ["data": [listEntry(cwd: "/tmp/repo", hooks: []), "malformed"]]),
            ("oversized hook collection", listResult(
                cwd: "/tmp/repo",
                hooks: Array(repeating: hook(key: "a", hash: "h", status: "untrusted"), count: 4097)
            )),
            ("oversized hook field", listResult(cwd: "/tmp/repo", hooks: [
                hook(key: String(repeating: "x", count: 256 * 1024 + 1), hash: "h", status: "untrusted")
            ])),
            ("oversized empty inventory warnings", listResult(
                cwd: "/tmp/repo",
                hooks: [],
                warnings: Array(repeating: String(repeating: "w", count: 4097), count: 1024)
            )),
            ("oversized raw cwd", listResult(
                cwd: String(repeating: "c", count: 256 * 1024 + 1),
                hooks: []
            ))
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
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: trusted))
        ])
        let secondRecorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "config/batchWrite", result: ["status": "ok"]),
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: trusted))
        ])
        let firstController = makeController(
            cwd: "/tmp/repo",
            requestTimeout: 0.01,
            faultInjection: .init(
                settlementRecoveryExecutor: { await writeGate.wait() },
                mutationExecutor: { method, params, deadline in
                    firstRecorder.record(method: method, params: params, timeout: deadline)
                    firstWriteStarted.fulfill()
                    try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                    return .unsettled
                }
            )
        ) { method, params, timeout in
            try firstRecorder.handle(method: method, params: params, timeout: timeout)
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
        XCTAssertEqual(firstRecorder.requests().last?.timeout, 0.01)
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
        XCTAssertEqual(firstRecorder.requests().map(\.method), ["hooks/list", "config/batchWrite", "hooks/list"])
        XCTAssertEqual(secondRecorder.requests().map(\.method), ["hooks/list", "config/batchWrite", "hooks/list"])
    }

    func testInjectedSettlementRecoveryBalancesRetiredGenerationAndScopesSuppression() async throws {
        let unresolved = [hook(key: "one", hash: "h1", status: "untrusted")]
        let trusted = [hook(key: "one", hash: "h1", status: "trusted")]
        let displayed = try inventory(hooks: unresolved)
        let recorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: trusted))
        ])
        let controller = makeController(
            cwd: "/tmp/repo",
            requestTimeout: 0.01,
            faultInjection: .init(
                settlementRecoveryExecutor: {},
                mutationExecutor: { _, _, _ in .unsettled }
            )
        ) { method, params, timeout in
            try recorder.handle(method: method, params: params, timeout: timeout)
        }
        controller.test_markHookTrustTransportRetiring(generation: 41)
        XCTAssertTrue(controller.test_shouldSuppressHookTrustStreamEnd(transportGeneration: 41))
        XCTAssertFalse(controller.test_shouldSuppressHookTrustStreamEnd(transportGeneration: 42))

        _ = try await controller.trustHooksForCurrentWorkspace(
            expectedCandidates: candidates(from: displayed),
            expectedInventoryFingerprint: displayed.fingerprint
        )

        XCTAssertTrue(controller.test_shouldSuppressHookTrustStreamEnd(transportGeneration: 41))
    }

    func testRecoveryRelistUsesHardDeadlineAndReleasesGlobalTrustMutexOnExpiry() async throws {
        let unresolved = [hook(key: "one", hash: "h1", status: "untrusted")]
        let trusted = [hook(key: "one", hash: "h1", status: "trusted")]
        let displayed = try inventory(hooks: unresolved)
        let firstRecorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "hooks/list", error: HookApprovalTestError.injectedFailure)
        ])
        let firstController = makeController(
            cwd: "/tmp/repo",
            requestTimeout: nil,
            faultInjection: .init(
                settlementRecoveryExecutor: {},
                mutationExecutor: { method, params, deadline in
                    firstRecorder.record(method: method, params: params, timeout: deadline)
                    return .unsettled
                }
            )
        ) { method, params, timeout in
            try firstRecorder.handle(method: method, params: params, timeout: timeout)
        }

        await assertTrustFailure(
            controller: firstController,
            candidates: candidates(from: displayed),
            fingerprint: displayed.fingerprint
        ) { error in
            guard case .postWriteVerificationFailed(latest: nil) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(firstRecorder.requests().map(\.timeout), [30, 30, 30])

        let secondRecorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "config/batchWrite", result: ["status": "ok"]),
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: trusted))
        ])
        _ = try await makeController(cwd: "/tmp/repo", requestTimeout: nil, recorder: secondRecorder)
            .trustHooksForCurrentWorkspace(
                expectedCandidates: candidates(from: displayed),
                expectedInventoryFingerprint: displayed.fingerprint
            )
        XCTAssertEqual(secondRecorder.requests().map(\.timeout), [30, 30, 30])
    }

    func testAmbiguousTransportFailureHoldsGlobalMutexUntilProcessCleanupSettles() async throws {
        let unresolved = [hook(key: "one", hash: "h1", status: "untrusted")]
        let trusted = [hook(key: "one", hash: "h1", status: "trusted")]
        let displayed = try inventory(hooks: unresolved)
        let cleanupStarted = expectation(description: "transport cleanup started")
        let cleanupGate = HookApprovalAsyncGate()
        let client = CodexAppServerClient(
            writeFrameHandler: { _, _ in },
            livenessProbe: { _ in true },
            faultInjection: .init(
                transportTerminationCleanup: {
                    cleanupStarted.fulfill()
                    await cleanupGate.wait()
                }
            )
        )
        await client.debugInstallTestTransport()
        let firstRecorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: trusted)),
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: trusted))
        ])
        let recoveryRan = expectation(description: "ambiguous mutation recovery ran")
        let firstController = makeController(
            client: client,
            cwd: "/tmp/repo",
            faultInjection: .init(
                settlementRecoveryExecutor: { recoveryRan.fulfill() },
                mutationExecutor: { method, params, deadline in
                    do {
                        return try await .response(
                            client.requestWithSettlementDeadline(
                                method: method,
                                params: params,
                                deadline: deadline
                            )
                        )
                    } catch {
                        guard CodexAppServerClient.isTimeoutError(error)
                            || CodexAppServerClient.isAmbiguousMutationError(error)
                        else {
                            throw error
                        }
                        return .unsettled
                    }
                }
            )
        ) { method, params, timeout in
            try firstRecorder.handle(method: method, params: params, timeout: timeout)
        }
        let secondRecorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "config/batchWrite", result: ["status": "ok"]),
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: trusted))
        ])
        let secondController = makeController(cwd: "/tmp/repo", recorder: secondRecorder)
        let candidates = candidates(from: displayed)

        let firstTask = Task {
            try await firstController.trustHooksForCurrentWorkspace(
                expectedCandidates: candidates,
                expectedInventoryFingerprint: displayed.fingerprint
            )
        }
        try await waitUntil("mutation request dispatch") {
            await client.debugPendingRequestCount() == 1
        }
        await client.debugBeginTransportFailure()
        await fulfillment(of: [cleanupStarted], timeout: 2)
        let secondTask = Task {
            try await secondController.trustHooksForCurrentWorkspace(
                expectedCandidates: candidates,
                expectedInventoryFingerprint: displayed.fingerprint
            )
        }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertTrue(secondRecorder.requests().isEmpty)

        await cleanupGate.release()
        _ = try await firstTask.value
        await fulfillment(of: [recoveryRan], timeout: 2)
        _ = try await firstController.listHooksForCurrentWorkspace()
        _ = try await secondTask.value
        XCTAssertEqual(firstRecorder.requests().map(\.method), ["hooks/list", "hooks/list", "hooks/list"])
        XCTAssertEqual(secondRecorder.requests().map(\.method), ["hooks/list", "config/batchWrite", "hooks/list"])
    }

    func testAmbiguousBatchWriteRebuildsTransportBeforeOrdinaryControllerRequest() async throws {
        let unresolved = [hook(key: "one", hash: "h1", status: "untrusted")]
        let trusted = [hook(key: "one", hash: "h1", status: "trusted")]
        let displayed = try inventory(hooks: unresolved)
        let router = HookApprovalClientFrameRouter(hookListResults: [
            listResult(cwd: "/tmp/repo", hooks: unresolved),
            listResult(cwd: "/tmp/repo", hooks: trusted),
            listResult(cwd: "/tmp/repo", hooks: trusted)
        ])
        let client = CodexAppServerClient(
            writeFrameHandler: { _, frame in try router.handle(frame) },
            livenessProbe: { _ in true }
        )
        router.attach(client)
        await client.debugInstallTestTransport()
        let retiredGeneration = await client.debugTransportGeneration()
        var options = CodexNativeSessionController.Options.agentModeDefault()
        options.requestTimeout = 120
        let controller = CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePaths: .uniform("/tmp/repo"),
            options: options,
            hookTrustFaultInjection: .init(
                settlementRecoveryExecutor: { await client.debugInstallTestTransport() }
            )
        )
        try await controller.test_beginBindingSession()

        _ = try await controller.trustHooksForCurrentWorkspace(
            expectedCandidates: candidates(from: displayed),
            expectedInventoryFingerprint: displayed.fingerprint
        )
        let replacementGeneration = await client.debugTransportGeneration()
        XCTAssertGreaterThan(replacementGeneration, retiredGeneration)

        _ = try await controller.listHooksForCurrentWorkspace()
        let installedGenerations = controller.test_inboundStreamTransportGenerations()
        XCTAssertEqual(installedGenerations.notifications, replacementGeneration)
        XCTAssertEqual(installedGenerations.serverRequests, replacementGeneration)
        XCTAssertTrue(controller.test_shouldSuppressHookTrustStreamEnd(transportGeneration: retiredGeneration))
        XCTAssertFalse(controller.test_shouldSuppressHookTrustStreamEnd(transportGeneration: replacementGeneration))
        XCTAssertEqual(router.seenMethods, ["hooks/list", "config/batchWrite", "hooks/list", "hooks/list"])
        await controller.shutdown()
        await client.stop()
    }

    func testUnsettledMutationRecoveryRebindsThreadBeforeFirstTurn() async throws {
        let fixture = try await makeHookTrustRebindFixture()

        let verified = try await fixture.controller.trustHooksForCurrentWorkspace(
            expectedCandidates: candidates(from: fixture.inventory),
            expectedInventoryFingerprint: fixture.inventory.fingerprint
        )
        XCTAssertTrue(verified.verifies(candidates(from: fixture.inventory)))
        XCTAssertEqual(fixture.controller.currentSessionReference?.conversationID, "replacement-thread")

        let receipt = try await fixture.controller.startUserTurn(
            text: "first turn after approval",
            images: [],
            model: "gpt-test",
            reasoningEffort: "medium",
            serviceTier: nil
        )
        XCTAssertEqual(receipt.provisionalSubmissionID, "replacement-turn")

        let requestLog = try String(contentsOf: fixture.requestLogURL, encoding: .utf8)
        let records = try requestLog.split(separator: "\n").map { line in
            try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
        }
        let replacementMethods = records.compactMap { record -> String? in
            guard record["process"] as? Int == 2 else { return nil }
            return record["method"] as? String
        }
        let resumeIndex = try XCTUnwrap(replacementMethods.firstIndex(of: "thread/resume"))
        let startIndex = try XCTUnwrap(replacementMethods.firstIndex(of: "thread/start"))
        XCTAssertLessThan(resumeIndex, startIndex)
        let turnStart = try XCTUnwrap(records.first { record in
            record["process"] as? Int == 2 && record["method"] as? String == "turn/start"
        })
        let turnParams = try XCTUnwrap(turnStart["params"] as? [String: Any])
        XCTAssertEqual(turnParams["threadId"] as? String, "replacement-thread")
    }

    func testWrongRecoveryResumeIdentityDoesNotCommitAndRetryCanRecover() async throws {
        let fixture = try await makeHookTrustRebindFixture(wrongResumeProcessNumber: 2)

        do {
            _ = try await fixture.controller.trustHooksForCurrentWorkspace(
                expectedCandidates: candidates(from: fixture.inventory),
                expectedInventoryFingerprint: fixture.inventory.fingerprint
            )
            XCTFail("Expected the mismatched recovery identity to fail closed")
        } catch {}
        XCTAssertEqual(fixture.controller.currentSessionReference, fixture.initialReference)

        try FileManager.default.removeItem(at: fixture.trustedMarkerURL)
        let verified = try await fixture.controller.trustHooksForCurrentWorkspace(
            expectedCandidates: candidates(from: fixture.inventory),
            expectedInventoryFingerprint: fixture.inventory.fingerprint
        )
        XCTAssertTrue(verified.verifies(candidates(from: fixture.inventory)))
        XCTAssertEqual(fixture.controller.currentSessionReference?.conversationID, "replacement-thread")
        let receipt = try await fixture.controller.startUserTurn(
            text: "first turn after retry",
            images: [],
            model: "gpt-test",
            reasoningEffort: "medium",
            serviceTier: nil
        )
        XCTAssertEqual(receipt.provisionalSubmissionID, "replacement-turn")
    }

    func testRecoveryDeadlineBeforeThreadCommitPreservesIdentityAndRetryCanRecover() async throws {
        let commitGate = HookApprovalAsyncGate()
        let firstCommitClaim = HookApprovalFirstCallClaim()
        let rebindPrepared = expectation(description: "replacement thread response prepared")
        let rebindReleased = expectation(description: "losing rebind continued after deadline")
        let fixture = try await makeHookTrustRebindFixture(
            requestTimeout: 0.15,
            faultInjection: .init(
                threadRebindCommitPreparation: {
                    guard await firstCommitClaim.claim() else { return }
                    rebindPrepared.fulfill()
                    await commitGate.wait()
                    rebindReleased.fulfill()
                }
            )
        )
        addTeardownBlock { await commitGate.release() }

        let firstAttempt = Task {
            try await fixture.controller.trustHooksForCurrentWorkspace(
                expectedCandidates: candidates(from: fixture.inventory),
                expectedInventoryFingerprint: fixture.inventory.fingerprint
            )
        }
        await fulfillment(of: [rebindPrepared], timeout: 2)
        do {
            _ = try await firstAttempt.value
            XCTFail("Expected the recovery deadline to fail closed")
        } catch {}
        XCTAssertEqual(fixture.controller.currentSessionReference, fixture.initialReference)

        await commitGate.release()
        await fulfillment(of: [rebindReleased], timeout: 2)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(fixture.controller.currentSessionReference, fixture.initialReference)

        try FileManager.default.removeItem(at: fixture.trustedMarkerURL)
        let verified = try await fixture.controller.trustHooksForCurrentWorkspace(
            expectedCandidates: candidates(from: fixture.inventory),
            expectedInventoryFingerprint: fixture.inventory.fingerprint
        )
        XCTAssertTrue(verified.verifies(candidates(from: fixture.inventory)))
        XCTAssertEqual(fixture.controller.currentSessionReference?.conversationID, "replacement-thread")
        let receipt = try await fixture.controller.startUserTurn(
            text: "first turn after deadline retry",
            images: [],
            model: "gpt-test",
            reasoningEffort: "medium",
            serviceTier: nil
        )
        XCTAssertEqual(receipt.provisionalSubmissionID, "replacement-turn")
    }

    func testConcurrentInboundStreamStartupInstallsOneOwnedSubscriptionPerKind() async throws {
        let client = CodexAppServerClient(livenessProbe: { _ in true })
        await client.debugInstallTestTransport()
        let controller = makeController(client: client, cwd: "/tmp/repo") { _, _, _ in [:] }
        try await controller.test_beginBindingSession()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 16 {
                group.addTask { await controller.test_ensureInboundStreamsStarted() }
            }
        }

        let notificationSubscriberCount = await client.debugNotificationSubscriberCount()
        let serverRequestSubscriberCount = await client.debugServerRequestSubscriberCount()
        XCTAssertEqual(notificationSubscriberCount, 1)
        XCTAssertEqual(serverRequestSubscriberCount, 1)
        await controller.shutdown()
        await client.stop()
    }

    func testInboundStreamStartupReplacesSlotsFromStaleTransportGeneration() async throws {
        let client = CodexAppServerClient(livenessProbe: { _ in true })
        await client.debugInstallTestTransport()
        let controller = makeController(client: client, cwd: "/tmp/repo") { _, _, _ in [:] }
        try await controller.test_beginBindingSession()
        await controller.test_ensureInboundStreamsStarted()
        let retiredGeneration = await client.debugTransportGeneration()

        await client.debugInstallTestTransport()
        let replacementGeneration = await client.debugTransportGeneration()
        XCTAssertGreaterThan(replacementGeneration, retiredGeneration)
        await controller.test_ensureInboundStreamsStarted()

        let installedGenerations = controller.test_inboundStreamTransportGenerations()
        XCTAssertEqual(installedGenerations.notifications, replacementGeneration)
        XCTAssertEqual(installedGenerations.serverRequests, replacementGeneration)
        try await waitUntil("stale inbound subscriptions to retire") {
            let notificationCount = await client.debugNotificationSubscriberCount()
            let serverRequestCount = await client.debugServerRequestSubscriberCount()
            return notificationCount == 1 && serverRequestCount == 1
        }
        await controller.shutdown()
        await client.stop()
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

    func testTrustedNonProjectHookCannotSubstituteForMissingProjectHook() async throws {
        let unresolved = [hook(key: "one", hash: "h1", status: "untrusted")]
        let displayed = try inventory(hooks: unresolved)
        let recorder = HookRequestRecorder(steps: [
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: unresolved)),
            .init(method: "config/batchWrite", result: ["status": "ok"]),
            .init(method: "hooks/list", result: listResult(cwd: "/tmp/repo", hooks: [
                hook(key: "one", hash: "h1", status: "trusted", source: "user")
            ]))
        ])

        await assertTrustFailure(
            controller: makeController(cwd: "/tmp/repo", recorder: recorder),
            candidates: candidates(from: displayed),
            fingerprint: displayed.fingerprint
        ) { error in
            guard case let .postWriteVerificationFailed(latest) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(latest?.projectHooks, [])
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

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func makeController(
        client: CodexAppServerClient = CodexAppServerClient(),
        cwd: String?,
        requestTimeout: TimeInterval? = 120,
        recorder: HookRequestRecorder
    ) -> CodexNativeSessionController {
        makeController(client: client, cwd: cwd, requestTimeout: requestTimeout) { method, params, timeout in
            try recorder.handle(method: method, params: params, timeout: timeout)
        }
    }

    private func makeController(
        client: CodexAppServerClient = CodexAppServerClient(),
        cwd: String?,
        requestTimeout: TimeInterval? = 120,
        faultInjection: CodexNativeSessionController.HookTrustFaultInjection = .init(),
        executor: @escaping @Sendable (String, [String: Any]?, TimeInterval?) async throws -> [String: Any]
    ) -> CodexNativeSessionController {
        var options = CodexNativeSessionController.Options.agentModeDefault()
        options.requestTimeout = requestTimeout
        return CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePaths: .uniform(cwd),
            options: options,
            requestExecutor: executor,
            hookTrustFaultInjection: faultInjection
        )
    }

    private struct HookTrustRebindFixture {
        let controller: CodexNativeSessionController
        let trustedMarkerURL: URL
        let requestLogURL: URL
        let initialReference: CodexNativeSessionController.SessionRef
        let inventory: CodexHookInventory
    }

    private func makeHookTrustRebindFixture(
        requestTimeout: TimeInterval = 2,
        wrongResumeProcessNumber: Int? = nil,
        faultInjection: CodexNativeSessionController.HookTrustFaultInjection = .init()
    ) async throws -> HookTrustRebindFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHookTrustRebindTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let processCountURL = directory.appendingPathComponent("process-count")
        let trustedMarkerURL = directory.appendingPathComponent("trusted")
        let requestLogURL = directory.appendingPathComponent("requests.jsonl")
        let executableURL = try makeHookTrustRebindServer(
            in: directory,
            processCountURL: processCountURL,
            trustedMarkerURL: trustedMarkerURL,
            requestLogURL: requestLogURL,
            wrongResumeProcessNumber: wrongResumeProcessNumber
        )
        let client = CodexAppServerClient()
        await client.updateConfig(.init(
            commandName: executableURL.path,
            additionalPathHints: [],
            requestTimeout: 2,
            processLaunchDirectory: directory.path
        ))
        var options = CodexNativeSessionController.Options.agentModeDefault(
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            approvalReviewerProvider: { .user }
        )
        options.requestTimeout = requestTimeout
        options.skillExtraRootsProvider = { [] }
        let controller = CodexNativeSessionController(
            client: client,
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePaths: .uniform(directory.path),
            options: options,
            clientShutdownBehavior: .stopOnShutdown,
            hookTrustFaultInjection: faultInjection
        )
        addTeardownBlock {
            await controller.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }

        let initialReference = try await controller.startOrResume(
            existing: nil,
            baseInstructions: "Agent",
            model: "gpt-test",
            reasoningEffort: "medium",
            serviceTier: nil
        )
        XCTAssertEqual(initialReference.conversationID, "initial-thread")
        let inventory = try await controller.listHooksForCurrentWorkspace()
        return HookTrustRebindFixture(
            controller: controller,
            trustedMarkerURL: trustedMarkerURL,
            requestLogURL: requestLogURL,
            initialReference: initialReference,
            inventory: inventory
        )
    }

    private func makeHookTrustRebindServer(
        in directory: URL,
        processCountURL: URL,
        trustedMarkerURL: URL,
        requestLogURL: URL,
        wrongResumeProcessNumber: Int? = nil
    ) throws -> URL {
        let executableURL = directory.appendingPathComponent("fake-codex")
        let script = """
        #!/usr/bin/env python3
        import json
        import os
        import sys

        if sys.argv[1:] == ["--version"]:
            print("codex 0.147.0")
            raise SystemExit(0)

        process_count_path = \(String(reflecting: processCountURL.path))
        trusted_marker_path = \(String(reflecting: trustedMarkerURL.path))
        request_log_path = \(String(reflecting: requestLogURL.path))
        wrong_resume_process_number = \(wrongResumeProcessNumber.map(String.init) ?? "None")
        try:
            with open(process_count_path, "r", encoding="utf-8") as handle:
                process_number = int(handle.read()) + 1
        except Exception:
            process_number = 1
        with open(process_count_path, "w", encoding="utf-8") as handle:
            handle.write(str(process_number))

        loaded_threads = set()

        def respond(request_id, result):
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)

        def reject(request_id, message):
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32600, "message": message}}), flush=True)

        def hook_list():
            status = "trusted" if os.path.exists(trusted_marker_path) else "untrusted"
            return {"data": [{"cwd": \(String(reflecting: directory.path)), "errors": [], "warnings": [], "hooks": [{
                "eventName": "preToolUse",
                "source": "project",
                "sourcePath": \(String(reflecting: directory.appendingPathComponent(".codex/config.toml").path)),
                "key": "one",
                "currentHash": "h1",
                "enabled": True,
                "trustStatus": status,
                "handlerType": "command"
            }]}]}

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            method = request.get("method")
            params = request.get("params") or {}
            with open(request_log_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"process": process_number, "method": method, "params": params}, sort_keys=True) + "\\n")
            if "id" not in request:
                continue
            request_id = request["id"]
            if method == "initialize":
                respond(request_id, {})
            elif method == "thread/start":
                thread_id = "initial-thread" if process_number == 1 else "replacement-thread"
                loaded_threads.add(thread_id)
                respond(request_id, {"thread": {"id": thread_id, "path": None, "status": {"type": "idle"}, "turns": []}, "model": "gpt-test", "reasoningEffort": "medium"})
            elif method == "thread/resume":
                if process_number == wrong_resume_process_number:
                    respond(request_id, {"thread": {"id": "wrong-thread", "path": "/tmp/wrong-rollout.jsonl", "status": {"type": "idle"}, "turns": []}, "model": "gpt-test", "reasoningEffort": "medium"})
                else:
                    reject(request_id, "no rollout found for thread id " + str(params.get("threadId")))
            elif method == "hooks/list":
                respond(request_id, hook_list())
            elif method == "config/batchWrite":
                with open(trusted_marker_path, "w", encoding="utf-8") as handle:
                    handle.write("trusted")
                os._exit(0)
            elif method == "turn/start":
                thread_id = params.get("threadId")
                if thread_id not in loaded_threads:
                    reject(request_id, "thread not found: " + str(thread_id))
                else:
                    respond(request_id, {"turn": {"id": "replacement-turn"}})
            else:
                respond(request_id, {})
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        return executableURL
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

private final class HookApprovalClientFrameRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var client: CodexAppServerClient?
    private var hookListResults: [[String: Any]]
    private var methods: [String] = []

    init(hookListResults: [[String: Any]]) {
        self.hookListResults = hookListResults
    }

    func attach(_ client: CodexAppServerClient) {
        lock.withLock { self.client = client }
    }

    var seenMethods: [String] {
        lock.withLock { methods }
    }

    func handle(_ frame: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let method = object["method"] as? String,
              let requestID = object["id"]
        else {
            throw HookApprovalTestError.unexpectedRequest("invalid JSON-RPC frame")
        }

        let action = try lock.withLock { () -> (CodexAppServerClient, [String: Any]?) in
            guard let client else {
                throw HookApprovalTestError.unexpectedRequest("unattached client")
            }
            methods.append(method)
            switch method {
            case "hooks/list":
                guard !hookListResults.isEmpty else {
                    throw HookApprovalTestError.unexpectedRequest(method)
                }
                return (client, hookListResults.removeFirst())
            case "config/batchWrite":
                return (client, nil)
            default:
                throw HookApprovalTestError.unexpectedRequest(method)
            }
        }

        if let result = action.1 {
            let response = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": requestID,
                "result": result
            ])
            Task { await action.0.debugIngestRawStdoutLine(response) }
        } else {
            Task { await action.0.debugBeginTransportFailure() }
        }
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
    case injectedFailure
    case unexpectedRequest(String)
}

private actor HookApprovalFirstCallClaim {
    private var isClaimed = false

    func claim() -> Bool {
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
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
