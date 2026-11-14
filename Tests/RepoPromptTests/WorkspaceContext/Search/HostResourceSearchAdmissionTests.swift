import Foundation
import RepoPromptDomainRuntime
@testable import RepoPromptWorkspaceContext
import XCTest

#if DEBUG
    final class HostResourceSearchAdmissionTests: XCTestCase {
        func testBroadSearchAdmitsAHostSizedBatchWithoutWaitingForAnotherSearchToFinish() async throws {
            let lane = StoreBackedWorkspaceSearchLane()
            let width = HostResourceCapacity.baseline.cpu
            let entered = expectation(description: "host-sized search batch admitted")
            entered.expectedFulfillmentCount = width
            let gate = AdmissionSearchBatchGate()
            let tasks = (0 ..< width).map { _ in
                Task {
                    try await lane.withSearchAccess(searchMode: .content, admissionClass: .unscopedContent) { _ in
                        entered.fulfill()
                        await gate.wait()
                        return "complete"
                    }
                }
            }
            await fulfillment(of: [entered], timeout: 5)
            await gate.release()
            for task in tasks {
                let result = try await task.value
                XCTAssertEqual(result, "complete")
            }
            let snapshot = await lane.snapshotForTesting()
            XCTAssertEqual(snapshot.maximumActivePermitCount, width)
            XCTAssertTrue(snapshot.isIdle)
            XCTAssertEqual(snapshot.waitExpiryCount, 0)
        }

        func testLiteralLineCountsPreserveFoundationSemanticsAtByteBoundaries() async throws {
            var cases: [(String, String, Bool)] = [
                ("", "needle", false),
                ("needle needle\nother\nneedle", "needle", false),
                ("\r\nneedle\rneedle\r\nNeedle\n", "needle", false),
                ("prefixneedle_suffix\nneedle", "needle", false),
                ("before\0needle\rneedle", "needle", false),
                ("a.b\naXb\na.b", "a.b", false),
                ("Needle\nneedle", "needle", true),
                ("I\ni\nI i", "i", true),
                ("İ\nI\ni\nı\nK\nK", "i", true),
                ("ſ\nS\ns", "s", true),
                ("cafe\u{301}\ncafé\n", "café", false),
                ("needle\u{2028}needle\n", "needle", false)
            ]
            for offset in [0, 63, 64, 65, 127, 128, 129] {
                cases.append((String(repeating: "x", count: offset) + "needle\r\nneedle\n", "needle", false))
                // Kelvin-sign canonical equivalence must retain NSString behavior,
                // even when the first non-ASCII byte straddles a vector/tail boundary.
                cases.append((String(repeating: "x", count: offset) + "K\rK", "K", false))
            }
            let budget = HostResourceBudget(capacity: .baseline)
            let search = FileSearchActor(contentBudgetForTesting: budget)
            for (text, needle, insensitive) in cases {
                let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
                let expected = lines.count(where: {
                    ($0 as NSString).range(of: needle, options: insensitive ? [.caseInsensitive] : []).location != NSNotFound
                })
                var corrected: Bool?
                let result = try await search.searchUnified(
                    pattern: needle, wasAutoCorrected: &corrected,
                    options: SearchOptions(
                        mode: .content,
                        caseInsensitive: insensitive,
                        countOnly: true,
                        fuzzySpaceMatching: false,
                        allowLiteralUnescapeFallback: false
                    ),
                    in: [AdmissionSearchFile(text: text)]
                )
                XCTAssertEqual(result.totalCount ?? 0, expected, "\(needle) in \(text.debugDescription)")
            }
            XCTAssertEqual(budget.snapshot().active, 0)
            XCTAssertEqual(budget.snapshot().activeContentUnits, 0)
        }

        func testOverloadedContentSearchThrowsInsteadOfSilentlyOmittingTheFile() async throws {
            let capacity = HostResourceCapacity.resolve(HostResourceSample(
                logicalCores: 8, performanceCores: 4, memoryBytes: 24 * 1024 * 1024 * 1024,
                memoryPressure: .critical, descriptorLimit: 4096, openDescriptors: 32
            ))
            let budget = HostResourceBudget(capacity: capacity, maximumWaiters: 0)
            let owner = try await budget.acquire(.cpu)
            defer { owner.release() }
            let search = FileSearchActor(contentBudgetForTesting: budget)
            var corrected: Bool?
            do {
                _ = try await search.search(
                    pattern: "needle", wasAutoCorrected: &corrected,
                    options: SearchOptions(mode: .content), in: [AdmissionSearchFile()]
                )
                XCTFail("A busy admission queue must not become an empty successful search")
            } catch HostResourceBudget.AdmissionError.queueFull {
                // Explicit backpressure is the contract, not missing matches.
            }
            XCTAssertEqual(budget.snapshot().active, 1)
            XCTAssertNil(budget.snapshot().activeByKind[.retainedContent])
            XCTAssertEqual(budget.snapshot().waiting, 0)
        }
    }

    private actor AdmissionSearchBatchGate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var released = false
        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func release() {
            released = true
            continuations.forEach { $0.resume() }
            continuations.removeAll()
        }
    }

    private final class AdmissionSearchFile: WorkspaceSearchFileProjection {
        let id = UUID()
        let name = "File.swift"
        let relativePath = "File.swift"
        let standardizedRelativePath = "File.swift"
        let fullPath = "/host-admission-test/File.swift"
        let standardizedFullPath = "/host-admission-test/File.swift"
        let standardizedRootFolderPath = "/host-admission-test"
        let fileExtension: String? = "swift"
        private let text: String
        init(text: String = "needle\n") {
            self.text = text
        }

        func searchContentSnapshot(freshnessPolicy _: FileContentFreshnessPolicy) async -> FileSearchContentSnapshot {
            FileSearchContentSnapshot(
                content: text, contentRevision: 1, modificationDate: Date(timeIntervalSince1970: 0), isFresh: true
            )
        }
    }
#endif
