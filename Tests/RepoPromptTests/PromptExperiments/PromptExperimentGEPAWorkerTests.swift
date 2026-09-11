import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    final class PromptExperimentGEPAWorkerTests: XCTestCase {
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
                "exception_type=NameError source_frame=gepa.optimize_anything.run_candidate:417 error_payload=excluded"
            )
            XCTAssertEqual(
                importDetail,
                "exception_type=ImportError source_frame=gepa.adapters.mcp_adapter.load_transport:83 error_payload=excluded"
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
    }
#endif
