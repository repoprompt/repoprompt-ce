import Foundation
@testable import RepoPromptApp
import XCTest

enum GitWorktreeTestSupport {
    static func waitForStableDescriptor(
        repo: URL,
        path: URL,
        expectedBranch: String? = nil,
        expectedHead: String? = nil,
        timeout: Duration = .seconds(5),
        listDescriptors: () async throws -> [GitWorktreeDescriptor],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> GitWorktreeDescriptor {
        let standardizedPath = path.standardizedFileURL.path
        let deadline = ContinuousClock.now + timeout
        var lastDescriptors: [GitWorktreeDescriptor] = []
        var lastError: Error?

        while true {
            do {
                let descriptors = try await listDescriptors()
                lastDescriptors = descriptors
                if let descriptor = descriptors.first(where: { samePath($0.path, standardizedPath) }),
                   isStableDescriptor(descriptor, expectedBranch: expectedBranch, expectedHead: expectedHead)
                {
                    return descriptor
                }
            } catch {
                lastError = error
            }

            if ContinuousClock.now >= deadline {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let message = worktreeDescriptorDump(
            repo: repo,
            expectedPath: standardizedPath,
            expectedBranch: expectedBranch,
            expectedHead: expectedHead,
            descriptors: lastDescriptors,
            lastError: lastError
        )
        XCTFail(message, file: file, line: line)
        throw NSError(
            domain: "GitWorktreeTestSupport.waitForStableDescriptor",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    static func descriptorDump(
        repo: URL,
        expectedPath: URL? = nil,
        requestedID: String? = nil,
        descriptors: [GitWorktreeDescriptor]
    ) -> String {
        worktreeDescriptorDump(
            repo: repo,
            expectedPath: expectedPath?.standardizedFileURL.path,
            expectedBranch: nil,
            expectedHead: nil,
            requestedID: requestedID,
            descriptors: descriptors,
            lastError: nil
        )
    }

    static func mergeApplyDiagnostics(
        preview: GitWorktreeMergePreview,
        result: GitWorktreeMergeApplyResult
    ) async -> String {
        let inspection = preview.inspection
        async let sourceLive = fingerprint(at: inspection.source.url)
        async let targetLive = fingerprint(at: inspection.target.url)
        async let sourceStatus = gitOutput(["status", "--porcelain=v1", "--branch"], cwd: inspection.source.url)
        async let targetStatus = gitOutput(["status", "--porcelain=v1", "--branch"], cwd: inspection.target.url)
        async let sourceHead = gitOutput(["rev-parse", "HEAD"], cwd: inspection.source.url)
        async let targetHead = gitOutput(["rev-parse", "HEAD"], cwd: inspection.target.url)
        async let sourceTree = gitOutput(["rev-parse", "HEAD^{tree}"], cwd: inspection.source.url)
        async let targetTree = gitOutput(["rev-parse", "HEAD^{tree}"], cwd: inspection.target.url)

        let liveSourceFingerprint = await sourceLive
        let liveTargetFingerprint = await targetLive
        let sourceChanged = liveSourceFingerprint.map { $0 != inspection.sourceFingerprint } ?? true
        let targetChanged = liveTargetFingerprint.map { $0 != inspection.targetFingerprint } ?? true

        return await """
        merge apply diagnostics:
        operation_id: \(preview.operationID)
        result_status: \(result.status.rawValue)
        stale_reason: \(result.staleReason ?? "nil")
        error_message: \(result.errorMessage ?? "nil")
        source_endpoint: \(endpointSummary(inspection.source))
        target_endpoint: \(endpointSummary(inspection.target))
        source_changed_since_preview: \(sourceChanged)
        target_changed_since_preview: \(targetChanged)
        preview_source_fingerprint: \(fingerprintSummary(inspection.sourceFingerprint))
        live_source_fingerprint: \(fingerprintSummary(liveSourceFingerprint))
        preview_target_fingerprint: \(fingerprintSummary(inspection.targetFingerprint))
        live_target_fingerprint: \(fingerprintSummary(liveTargetFingerprint))
        source_head_now: \(oneLine(sourceHead))
        target_head_now: \(oneLine(targetHead))
        source_tree_now: \(oneLine(sourceTree))
        target_tree_now: \(oneLine(targetTree))
        source_status_now:
        \(sourceStatus)
        target_status_now:
        \(targetStatus)
        """
    }

    static func assertApplyStatus(
        _ result: GitWorktreeMergeApplyResult,
        equals expected: GitWorktreeMergeApplyStatus,
        preview: GitWorktreeMergePreview,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard result.status != expected else { return }
        let diagnostics = await mergeApplyDiagnostics(preview: preview, result: result)
        XCTFail("Expected merge apply status \(expected.rawValue), got \(result.status.rawValue).\n\(diagnostics)", file: file, line: line)
    }

    static func gitOutput(_ arguments: [String], cwd: URL) async -> String {
        do {
            return try runGit(arguments, cwd: cwd)
        } catch {
            return "<git \(arguments.joined(separator: " ")) failed: \(error.localizedDescription)>"
        }
    }

    static func runGit(_ arguments: [String], cwd: URL) throws -> String {
        try TestGitCommandRunner.run(
            arguments,
            cwd: cwd,
            failureDomain: "GitWorktreeTestSupport.git"
        )
    }

    private static func isStableDescriptor(
        _ descriptor: GitWorktreeDescriptor,
        expectedBranch: String?,
        expectedHead: String?
    ) -> Bool {
        guard descriptor.gitDir != nil || descriptor.isMain else { return false }
        guard let head = descriptor.head, !head.isEmpty else { return false }
        if let expectedHead, head != expectedHead {
            return false
        }
        if let expectedBranch, descriptor.branch != expectedBranch {
            return false
        }
        return true
    }

    private static func worktreeDescriptorDump(
        repo: URL,
        expectedPath: String?,
        expectedBranch: String?,
        expectedHead: String?,
        requestedID: String? = nil,
        descriptors: [GitWorktreeDescriptor],
        lastError: Error?
    ) -> String {
        let rawList = (try? runGit(["worktree", "list", "--porcelain"], cwd: repo)) ?? "<git worktree list failed>"
        let rawListZ = (try? runGit(["worktree", "list", "--porcelain", "-z"], cwd: repo))?
            .replacingOccurrences(of: "\0", with: "\\0\n") ?? "<git worktree list -z failed>"
        let lines = descriptors.map(descriptorSummary).joined(separator: "\n")
        return """
        timed out waiting for stable Git worktree descriptor
        repo: \(repo.standardizedFileURL.path)
        expected_path: \(expectedPath ?? "nil")
        expected_branch: \(expectedBranch ?? "nil")
        expected_head: \(expectedHead ?? "nil")
        requested_id: \(requestedID ?? "nil")
        last_error: \(lastError.map(\.localizedDescription) ?? "nil")
        resolver_visible_descriptors:
        \(lines.isEmpty ? "<none>" : lines)
        raw_git_worktree_list_porcelain:
        \(rawList)
        raw_git_worktree_list_porcelain_z:
        \(rawListZ)
        """
    }

    private static func descriptorSummary(_ descriptor: GitWorktreeDescriptor) -> String {
        "- id=\(descriptor.worktreeID) path=\(descriptor.path) gitDir=\(descriptor.gitDir ?? "nil") branch=\(descriptor.branch ?? "nil") head=\(descriptor.head ?? "nil") isMain=\(descriptor.isMain) isCurrent=\(descriptor.isCurrent) locked=\(descriptor.isLocked) prunable=\(descriptor.isPrunable)"
    }

    private static func endpointSummary(_ endpoint: GitWorktreeMergeEndpoint) -> String {
        "id=\(endpoint.worktreeID) path=\(endpoint.path) branch=\(endpoint.branch ?? "nil") head=\(endpoint.head) repo=\(endpoint.repositoryID)"
    }

    private static func fingerprint(at url: URL) async -> GitDiffFingerprint? {
        try? await VCSService().getStatusFingerprint(at: url, baseRef: "HEAD")
    }

    private static func fingerprintSummary(_ fingerprint: GitDiffFingerprint?) -> String {
        guard let fingerprint else { return "nil" }
        return fingerprintSummary(fingerprint)
    }

    private static func fingerprintSummary(_ fingerprint: GitDiffFingerprint) -> String {
        "headSHA=\(fingerprint.headSHA) baseRef=\(fingerprint.baseRef) statusHash=\(fingerprint.statusHash) generatedAt=\(fingerprint.generatedAt)"
    }

    private static func oneLine(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " | ")
    }

    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }
}
