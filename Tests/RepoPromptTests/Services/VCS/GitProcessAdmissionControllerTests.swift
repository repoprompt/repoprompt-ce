@testable import RepoPrompt
import XCTest

final class GitProcessAdmissionControllerTests: XCTestCase {
    func testBudgetsBoundGlobalAndPerRepositoryConcurrency() async {
        let controller = GitProcessAdmissionController(globalLimit: 2, perRepositoryLimit: 1)
        let probe = GitAdmissionProbe()
        let repositories = ["repo-a", "repo-a", "repo-b", "repo-c"]

        await withTaskGroup(of: Void.self) { group in
            for repository in repositories {
                group.addTask {
                    do {
                        let lease = try await controller.acquire(repositoryKey: repository)
                        await probe.enter(repository: repository)
                        try? await Task.sleep(nanoseconds: 30_000_000)
                        await probe.leave(repository: repository)
                        await controller.release(lease)
                    } catch {
                        XCTFail("unexpected admission failure: \(error)")
                    }
                }
            }
        }

        let snapshot = await probe.snapshot()
        XCTAssertLessThanOrEqual(snapshot.peakGlobal, 2)
        XCTAssertLessThanOrEqual(snapshot.peakByRepository["repo-a"] ?? 0, 1)
        XCTAssertEqual(snapshot.completed, repositories.count)
    }

    func testBoundedOrderedMapPreservesInputOrder() async {
        let values = await BoundedOrderedConcurrentMap.map([0, 1, 2, 3], maxConcurrent: 2) { value in
            try? await Task.sleep(nanoseconds: UInt64((4 - value) * 5_000_000))
            return "value-\(value)"
        }
        XCTAssertEqual(values, ["value-0", "value-1", "value-2", "value-3"])
    }

    func testOptionalLocksClassifierExcludesMutations() {
        XCTAssertTrue(GitService.isVerifiedReadOnlyGitOperation(["status", "--porcelain=v2"]))
        XCTAssertTrue(GitService.isVerifiedReadOnlyGitOperation(["diff", "--numstat", "HEAD"]))
        XCTAssertTrue(GitService.isVerifiedReadOnlyGitOperation(["worktree", "list", "--porcelain"]))
        XCTAssertFalse(GitService.isVerifiedReadOnlyGitOperation(["worktree", "add", "/tmp/wt"]))
        XCTAssertFalse(GitService.isVerifiedReadOnlyGitOperation(["switch", "main"]))
        XCTAssertFalse(GitService.isVerifiedReadOnlyGitOperation(["fetch", "--all"]))
        XCTAssertFalse(GitService.isVerifiedReadOnlyGitOperation(["merge", "--abort"]))
    }
}

private actor GitAdmissionProbe {
    private var activeGlobal = 0
    private var activeByRepository: [String: Int] = [:]
    private var peakGlobal = 0
    private var peakByRepository: [String: Int] = [:]
    private var completed = 0

    func enter(repository: String) {
        activeGlobal += 1
        activeByRepository[repository, default: 0] += 1
        peakGlobal = max(peakGlobal, activeGlobal)
        peakByRepository[repository] = max(
            peakByRepository[repository] ?? 0,
            activeByRepository[repository] ?? 0
        )
    }

    func leave(repository: String) {
        activeGlobal -= 1
        activeByRepository[repository, default: 1] -= 1
        completed += 1
    }

    func snapshot() -> (peakGlobal: Int, peakByRepository: [String: Int], completed: Int) {
        (peakGlobal, peakByRepository, completed)
    }
}
