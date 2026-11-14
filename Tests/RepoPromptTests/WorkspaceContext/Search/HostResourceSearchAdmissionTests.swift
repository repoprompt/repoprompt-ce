import Foundation
import RepoPromptDomainRuntime
@testable import RepoPromptWorkspaceContext
import XCTest

#if DEBUG
    final class HostResourceSearchAdmissionTests: XCTestCase {
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

    private final class AdmissionSearchFile: WorkspaceSearchFileProjection {
        let id = UUID()
        let name = "File.swift"
        let relativePath = "File.swift"
        let standardizedRelativePath = "File.swift"
        let fullPath = "/host-admission-test/File.swift"
        let standardizedFullPath = "/host-admission-test/File.swift"
        let standardizedRootFolderPath = "/host-admission-test"
        let fileExtension: String? = "swift"
        func searchContentSnapshot(freshnessPolicy _: FileContentFreshnessPolicy) async -> FileSearchContentSnapshot {
            FileSearchContentSnapshot(
                content: "needle\n", contentRevision: 1, modificationDate: Date(timeIntervalSince1970: 0), isFresh: true
            )
        }
    }
#endif
