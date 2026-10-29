import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    final class PromptExperimentGEPAWorkerTests: XCTestCase {
        func testInvalidCandidateStatusSurvivesTheWorkerWireContract() {
            let reply = GEPAWorkerProtocol.HostReply.evaluated(.init(
                evaluationID: "evaluation", score: 0, feedback: "Malformed DSPy instructions",
                outputExcerpt: "", replayed: true, candidateValid: false
            )).jsonObject(id: "request")
            XCTAssertEqual(reply["score"] as? Double, 0, "Evidence keeps the raw task score.")
            XCTAssertEqual(reply["candidate_valid"] as? Bool, false, "Selection must distinguish malformed prompts from valid zero-scoring prompts.")
            XCTAssertEqual(reply["replayed"] as? Bool, true, "Durable replay preserves candidate validity.")
        }

        func testUnbundledWorkerLookupUsesCompiledSourceRootInsteadOfWorkingDirectory() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let worker = root.appendingPathComponent("AppResources/PromptExperiments/gepa_worker.py")
            try FileManager.default.createDirectory(at: worker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# worker".utf8).write(to: worker)
            let source = root.appendingPathComponent("Sources/RepoPrompt/Features/PromptExperiments/PromptExperimentGEPAWorker.swift")

            XCTAssertEqual(
                try PromptExperimentGEPAWorker.resolveWorkerURL(
                    resourcesDirectory: nil, sourceFileURL: source, isPackagedApp: false
                ),
                worker
            )
            XCTAssertThrowsError(try PromptExperimentGEPAWorker.resolveWorkerURL(
                resourcesDirectory: nil, sourceFileURL: source, isPackagedApp: true
            ), "A broken app package must not silently run a source-checkout worker")
        }

        func testPackagedWorkerTakesPrecedenceAndInvalidOverrideDoesNotFallBack() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let resources = root.appendingPathComponent("Contents/Resources")
            let worker = resources.appendingPathComponent("PromptExperiments/gepa_worker.py")
            try FileManager.default.createDirectory(at: worker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# packaged worker".utf8).write(to: worker)

            XCTAssertEqual(
                try PromptExperimentGEPAWorker.resolveWorkerURL(
                    resourcesDirectory: resources, sourceFileURL: root, isPackagedApp: true
                ),
                worker
            )
            XCTAssertThrowsError(try PromptExperimentGEPAWorker.resolveWorkerURL(
                resourcesDirectory: resources, sourceFileURL: root, isPackagedApp: true,
                override: root.appendingPathComponent("missing.py").path
            ))
            XCTAssertThrowsError(try PromptExperimentGEPAWorker.resolveWorkerURL(
                resourcesDirectory: resources, sourceFileURL: root, isPackagedApp: true,
                override: resources.path
            ), "A directory is not a readable worker file")
        }

        func testReadinessRequiresMatchingWorkerProtocolPythonAndGEPAPin() throws {
            let ready: [String: Any] = [
                "type": "ready",
                "protocol_version": GEPAWorkerProtocol.version,
                "python_version": PromptExperimentGEPAWorker.pythonVersion.split(separator: ".").compactMap { Int($0) },
                "gepa_version": PromptExperimentGEPAConfiguration.packageVersion,
                "upstream_revision": PromptExperimentGEPAConfiguration.pinnedRevision
            ]
            let data = try JSONSerialization.data(withJSONObject: ready)
            XCTAssertNoThrow(try PromptExperimentGEPAWorker.validatePreflightResponse(data, terminationStatus: 0))
            XCTAssertThrowsError(try PromptExperimentGEPAWorker.validatePreflightResponse(data, terminationStatus: 2))
            for key in ready.keys {
                var stale = ready
                stale.removeValue(forKey: key)
                XCTAssertThrowsError(try PromptExperimentGEPAWorker.validatePreflightResponse(
                    JSONSerialization.data(withJSONObject: stale), terminationStatus: 0
                ), "Missing readiness field: \(key)")
            }
            var stale = ready
            stale["protocol_version"] = GEPAWorkerProtocol.version - 1
            XCTAssertThrowsError(try PromptExperimentGEPAWorker.validatePreflightResponse(
                JSONSerialization.data(withJSONObject: stale), terminationStatus: 0
            ))
        }

        private final class ResultBox: @unchecked Sendable {
            private let lock = NSLock()
            private var storedResult: Result<Data?, Error>?

            func store(_ result: Result<Data?, Error>) {
                lock.lock()
                storedResult = result
                lock.unlock()
            }

            func load() -> Result<Data?, Error>? {
                lock.lock()
                defer { lock.unlock() }
                return storedResult
            }
        }

        func testFailedProtocolDetailExposesOnlyValidatedExceptionIdentityAndFrame() {
            let nameError: [String: Any] = [
                "error": "SECRET_NAME_ERROR_CANARY",
                "diagnostic": [
                    "schema_version": 1,
                    "exception_type": "NameError",
                    "source_frame": [
                        "module": "gepa.optimize_anything",
                        "function": "run_candidate",
                        "line": 417
                    ]
                ]
            ]
            let importError: [String: Any] = [
                "diagnostic": [
                    "schema_version": 1,
                    "exception_type": "ImportError",
                    "source_frame": [
                        "module": "gepa.adapters.mcp_adapter",
                        "function": "load_transport",
                        "line": 83
                    ]
                ]
            ]

            let nameDetail = PromptExperimentGEPAWorker.safeProtocolDetail(type: "failed", object: nameError)
            let importDetail = PromptExperimentGEPAWorker.safeProtocolDetail(type: "failed", object: importError)
            XCTAssertEqual(
                nameDetail,
                "exception_type=NameError source_frame=gepa.optimize_anything.run_candidate:417 failure_code=unavailable error_payload=excluded"
            )
            XCTAssertEqual(
                importDetail,
                "exception_type=ImportError source_frame=gepa.adapters.mcp_adapter.load_transport:83 failure_code=unavailable error_payload=excluded"
            )
            XCTAssertNotEqual(nameDetail, importDetail)
            XCTAssertFalse(nameDetail?.contains("SECRET_NAME_ERROR_CANARY") == true)
        }

        func testFailedProtocolDetailLabelsLegacyAndRejectsUntrustedFields() {
            XCTAssertEqual(
                PromptExperimentGEPAWorker.safeProtocolDetail(
                    type: "failed",
                    object: ["error": "SECRET_LEGACY_CANARY"]
                ),
                "exception_type=unavailable source_frame=unavailable envelope=legacy error_payload=excluded"
            )
            XCTAssertEqual(
                PromptExperimentGEPAWorker.safeProtocolDetail(type: "failed", object: [
                    "diagnostic": [
                        "schema_version": 1,
                        "exception_type": "NameError SECRET_CANARY",
                        "source_frame": [
                            "module": "gepa.worker",
                            "function": "run",
                            "line": 12
                        ]
                    ]
                ]),
                "exception_type=unavailable source_frame=unavailable envelope=invalid error_payload=excluded"
            )
        }

        func testStderrAllowlistRejectsUntrustedSuffixes() {
            XCTAssertEqual(
                PromptExperimentGEPAWorker.safeStderrDetail(
                    Data("Generating initial seed candidate via LLM...\n".utf8)
                ),
                "Generating initial seed candidate via LLM..."
            )
            let suffixed = Data("Generating initial seed candidate via LLM... SECRET_CANARY\n".utf8)
            XCTAssertEqual(
                PromptExperimentGEPAWorker.safeStderrDetail(suffixed),
                "[redacted \(suffixed.count) bytes]"
            )
        }

        func testProtocolLineSizeIsBoundedBeforeWriterEOF() throws {
            let pipe = Pipe()
            defer { try? pipe.fileHandleForWriting.close() }
            try pipe.fileHandleForWriting.write(contentsOf: Data("12345".utf8))
            var reader = PromptExperimentNDJSONLineReader(
                handle: pipe.fileHandleForReading,
                maximumLineBytes: 4
            )

            XCTAssertThrowsError(try reader.nextLine()) { error in
                guard case PromptExperimentPipeReadError.lineTooLong(maximumBytes: 4) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }

        func testCancellationPipeWakesBlockedProtocolReader() async throws {
            let protocolPipe = Pipe()
            let cancellationPipe = Pipe()
            let completed = expectation(description: "cancellation wakes blocked protocol read")
            let resultBox = ResultBox()
            DispatchQueue.global(qos: .userInitiated).async {
                var reader = PromptExperimentNDJSONLineReader(
                    handle: protocolPipe.fileHandleForReading,
                    cancellationHandle: cancellationPipe.fileHandleForReading
                )
                do {
                    try resultBox.store(.success(reader.nextLine()))
                } catch {
                    resultBox.store(.failure(error))
                }
                completed.fulfill()
            }

            try cancellationPipe.fileHandleForWriting.write(contentsOf: Data([1]))
            await fulfillment(of: [completed], timeout: 2)
            guard case let .failure(error) = try XCTUnwrap(resultBox.load()) else {
                return XCTFail("Expected cancellation failure")
            }
            XCTAssertTrue(error is CancellationError)
        }

        func testNativePipeReaderReturnsSmallLineBeforeWriterEOF() async throws {
            let child = Process()
            let input = Pipe()
            let output = Pipe()
            child.executableURL = URL(fileURLWithPath: "/bin/cat")
            child.standardInput = input
            child.standardOutput = output
            child.standardError = FileHandle.nullDevice
            try child.run()

            let completed = expectation(description: "small NDJSON line returned while child remains alive")
            let resultBox = ResultBox()
            DispatchQueue.global(qos: .userInitiated).async {
                var reader = PromptExperimentNDJSONLineReader(handle: output.fileHandleForReading)
                do {
                    try resultBox.store(.success(reader.nextLine()))
                } catch {
                    resultBox.store(.failure(error))
                }
                completed.fulfill()
            }

            try input.fileHandleForWriting.write(contentsOf: Data("{\"type\":\"host_request\"}\n".utf8))
            await fulfillment(of: [completed], timeout: 2)

            try? input.fileHandleForWriting.close()
            child.waitUntilExit()
            let result = try XCTUnwrap(resultBox.load()).get()
            XCTAssertEqual(result, Data("{\"type\":\"host_request\"}".utf8))
            XCTAssertEqual(child.terminationStatus, 0)
        }

        // MARK: Protocol v2

        func testCompletedSummaryDecodesWithoutRewritingExampleIDKeys() throws {
            let line = Data("""
            {"protocol_version":2,"type":"completed","event_id":"completed","result":{"engine":"gepa",\
            "upstream_revision":"\(PromptExperimentGEPAConfiguration.pinnedRevision)","stop_reason":"budget_exhausted",\
            "has_incumbent":true,"candidates":[{"index":0,"sha256":"\(String(repeating: "a", count: 64))","parent_indices":[],"aggregate_score":0.5}],\
            "best_candidate_index":0,"best_score":0.5,"baseline_score":0.5,"total_metric_calls":7,"wall_time_seconds":1.5,\
            "held_out":{"baseline":{"scores":{"held_out_case_1":1},"average":1},"best":null},"proposer_usage":"reflection_calls=1"}}
            """.utf8)
            let terminal = try GEPAWorkerProtocol.decodeTerminal(line)
            XCTAssertEqual(terminal.stopReason, "budget_exhausted")
            XCTAssertTrue(terminal.hasIncumbent)
            XCTAssertEqual(terminal.candidates.first?.aggregateScore, 0.5)
            XCTAssertEqual(terminal.heldOut?.baseline?.scores, ["held_out_case_1": 1])
            XCTAssertNil(terminal.heldOut?.best, "an unadmitted held-out pass stays unavailable")
        }

        func testHostRequestsAndRepliesUseTheTypedWireShape() throws {
            let request = Data("""
            {"protocol_version":2,"type":"host_request","id":"r1","operation":"evaluate",\
            "payload":{"candidate":"c","candidate_sha256":"sha","example_id":"t_1","split":"training"}}
            """.utf8)
            let decoded = try GEPAWorkerProtocol.decodeHostRequest(request)
            XCTAssertEqual(decoded.id, "r1")
            XCTAssertEqual(decoded.request, .evaluate(.init(candidate: "c", candidateSHA256: "sha", exampleID: "t_1", split: "training")))
            XCTAssertThrowsError(try GEPAWorkerProtocol.decodeHostRequest(Data(#"{"id":"x","operation":"mcp_model","payload":{}}"#.utf8)))

            XCTAssertEqual(GEPAWorkerProtocol.HostReply.budgetExhausted.jsonObject(id: "r1")["status"] as? String, "budget_exhausted")
            let failed = GEPAWorkerProtocol.HostReply.failed(code: "provider_rejected", message: "m").jsonObject(id: "r1")
            XCTAssertEqual(failed["status"] as? String, "failed")
            XCTAssertEqual(failed["failure_code"] as? String, "provider_rejected")
            let evaluated = GEPAWorkerProtocol.HostReply.evaluated(.init(
                evaluationID: "e", score: 1, feedback: "f", outputExcerpt: nil, replayed: true
            )).jsonObject(id: "r1")
            XCTAssertEqual(evaluated["status"] as? String, "ok")
            XCTAssertEqual(evaluated["replayed"] as? Bool, true)
            XCTAssertEqual(evaluated["protocol_version"] as? Int, 2)
            XCTAssertNil(evaluated["output_characters"], "absent usage is omitted, never zero")
            let measured = GEPAWorkerProtocol.HostReply.evaluated(.init(
                evaluationID: "e", score: 1, feedback: "f", outputExcerpt: nil, replayed: false,
                promptTokens: 5, completionTokens: 7, searchRemaining: 3, outputCharacters: 42
            )).jsonObject(id: "r1")
            XCTAssertEqual(measured["search_remaining"] as? Int, 3)
            XCTAssertEqual(measured["output_characters"] as? Int, 42)
            XCTAssertEqual(measured["completion_tokens"] as? Int, 7)
        }

        func testGEPAWorkerEnvironmentDoesNotInheritProviderCredentials() {
            let environment = PromptExperimentGEPAWorker.workerEnvironment(
                home: URL(fileURLWithPath: "/tmp/gepa-home"),
                temporaryDirectory: URL(fileURLWithPath: "/tmp/gepa-tmp")
            )
            // Locale keys are forwarded only when the host sets them, so the exact key set
            // depends on the test environment; everything else is fixed.
            let localeKeys: Set = ["LANG", "LC_ALL", "LC_CTYPE"]
            XCTAssertEqual(Set(environment.keys).subtracting(localeKeys), ["HOME", "PATH", "TMPDIR"])
            let host = ProcessInfo.processInfo.environment
            for key in localeKeys {
                XCTAssertEqual(environment[key], host[key].flatMap { $0.isEmpty ? nil : $0 }, key)
            }
            XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
            XCTAssertEqual(environment["HOME"], "/tmp/gepa-home")
            XCTAssertEqual(environment["TMPDIR"], "/tmp/gepa-tmp")
            for secret in ["PYTHONHOME", "PYTHONPATH", "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "CODEX_HOME"] {
                XCTAssertNil(environment[secret], secret)
            }
        }

        func testCandidateEventDetailExcludesCandidateText() {
            let detail = PromptExperimentGEPAWorker.safeProtocolDetail(type: "candidate", object: [
                "candidate_index": 3,
                "candidate_sha256": String(repeating: "b", count: 64),
                "candidate": "SECRET_CANDIDATE_TEXT"
            ])
            XCTAssertEqual(detail, "candidate_index=3 candidate_sha256=\(String(repeating: "b", count: 64)) text=excluded")
        }
    }
#endif
