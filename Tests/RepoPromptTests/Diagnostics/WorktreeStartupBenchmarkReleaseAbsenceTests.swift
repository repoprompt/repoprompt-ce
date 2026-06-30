import Foundation
import XCTest

final class WorktreeStartupBenchmarkReleaseAbsenceTests: XCTestCase {
    func testReleaseProjectionOmitsBenchmarkPhasesSchemaAndDiagnosticSurface() throws {
        let root = try RepoRoot.url()
        let files = [
            "Sources/RepoPrompt/Features/Diagnostics/App/WorktreeStartupInstrumentation.swift",
            "Sources/RepoPrompt/Features/Diagnostics/App/WorktreeStartupBenchmarkDiagnostics.swift",
            "Sources/RepoPrompt/Infrastructure/VCS/GitWorkspacePolicyCanonicalizationDiagnostics.swift",
            "Sources/RepoPrompt/Infrastructure/VCS/GitWorktreeInitializationModels.swift",
            "Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnostics.swift",
            "Sources/RepoPrompt/Features/Diagnostics/MCP/MCPConnectionManager+DebugDiagnosticsWorktreeStartup.swift",
            "Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPAgentControlToolProvider.swift",
            "Sources/RepoPrompt/Infrastructure/MCP/AppSettingsMCPService.swift"
        ]
        let projection = try files.map { path in
            try releaseProjection(String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
        }.joined(separator: "\n")
        for forbidden in [
            "firstBenchmarkSearchStarted",
            "firstBenchmarkReadCompleted",
            "firstBenchmarkCodemapStarted",
            "worktree_startup_benchmark",
            "_worktree_startup_benchmark_token",
            "BenchmarkMetricTag",
            "ReceiptDecision",
            "GitWorkspacePolicyCanonicalizationDiagnostics",
            "BenchmarkPlannerPhase",
            "marker_publications",
            "receipt_decisions",
            "receiptDecisionDigest",
            "worktree_startup_benchmark_diagnostics_enabled"
        ] {
            XCTAssertFalse(projection.contains(forbidden), "Release source projection leaked \(forbidden)")
        }
    }

    private func releaseProjection(_ source: String) -> String {
        struct Frame { let parentIncluded: Bool
            let debugCondition: Bool
            var inElse: Bool
        }
        var frames: [Frame] = []
        var included = true
        var output: [String] = []
        for line in source.components(separatedBy: .newlines) {
            let directive = line.trimmingCharacters(in: .whitespaces)
            if directive.hasPrefix("#if ") {
                let isDebug = directive == "#if DEBUG"
                frames.append(Frame(parentIncluded: included, debugCondition: isDebug, inElse: false))
                included = included && !isDebug
            } else if directive == "#else", var frame = frames.popLast() {
                frame.inElse.toggle()
                frames.append(frame)
                included = frame.parentIncluded && (frame.debugCondition || !frame.debugCondition)
            } else if directive == "#endif", let frame = frames.popLast() {
                included = frame.parentIncluded
            } else if included {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }
}
