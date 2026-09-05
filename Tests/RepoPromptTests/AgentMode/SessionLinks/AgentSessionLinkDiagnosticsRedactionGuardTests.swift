import Foundation
import XCTest

/// Cross-window oversight carries another session's transcript text, display names, and delivered
/// message bodies through this surface. A single `debugLog("send \(message)")` added later would
/// republish that content, unredacted, into a log file that the sanitizer never sees and that no
/// response-shape test inspects.
///
/// The shipped surface emits none of these facilities, so this guard pins that property rather than
/// trying to prove that some future log line happens to be redacted. If a diagnostic is genuinely
/// needed here, add it deliberately and extend this test with the exact allowed call and the reason
/// its arguments cannot carry overseen content.
///
/// One facility is deliberately allowed: the debug-only, opt-in `WorkspaceRestorePerfLog` shared with
/// window/workspace restore. Its oversight call sites are compiled behind `#if DEBUG` and pass only
/// enum-like outcome labels, counts, window IDs, and `shortID` identifier prefixes — never a
/// transcript item, a session or workspace name, a delivered message, a worktree/backup path, or a
/// full session UUID. It is not listed above because a redacted structural counter is exactly the
/// diagnostic this surface needs; a new call site must keep those argument rules.
final class AgentSessionLinkDiagnosticsRedactionGuardTests: XCTestCase {
    /// Every logging facility used anywhere in this repository.
    ///
    /// Matched with a leading non-identifier boundary so `footprint`, `blueprint`, and
    /// `fingerprintLog` do not register as hits.
    private static let forbiddenCalls = [
        "print",
        "debugPrint",
        "dump",
        "NSLog",
        "os_log",
        "Logger",
        "debugLog",
        "steeringDebugLog",
        "logCodex",
        "logCodexDebug",
        "logHandoffDebug",
        "mcpServerViewModelDebugLog",
        "mcpRoutingInternalDebugLog"
    ]

    /// Directory whose entire contents are session-link owned, so files added later are guarded
    /// automatically instead of silently escaping this test.
    private static let guardedDirectory = "Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks"

    /// Session-link files that live outside the guarded directory.
    private static let guardedFiles = [
        "Sources/RepoPromptDomainRuntime/DomainAgentSessionLinkAuthority.swift",
        "Sources/RepoPromptDomainRuntime/DomainAgentSessionLinkModels.swift",
        "Sources/RepoPromptDomainRuntime/DomainAgentSessionOperationAuthorizer.swift",
        "Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentSessionLinkMCPToolService.swift",
        "Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentSessionTargetOperationGuard.swift",
        "Sources/RepoPrompt/Infrastructure/AI/Prompts/AgentSessionLinkPrompts.swift",
        "Sources/RepoPrompt/App/WindowStatesManager+AgentSessionLinks.swift",
        "Sources/RepoPrompt/Features/AgentMode/ViewModels/UI/AgentMonitorPillModels.swift",
        "Sources/RepoPrompt/Features/AgentMode/Views/Components/AgentMonitorPill.swift"
    ]

    func testMonitoringSurfaceEmitsNoLoggingThatCouldCarryMonitoredContent() throws {
        let root = try RepoRoot.url()
        let sources = try guardedSourceURLs(root: root)
        XCTAssertGreaterThan(sources.count, 12, "guard list resolved to too few files; paths likely moved")

        var violations: [String] = []
        for url in sources {
            let code = try Self.strippingComments(String(contentsOf: url, encoding: .utf8))
            for call in Self.forbiddenCalls where Self.containsCall(call, in: code) {
                violations.append("\(RepoRoot.relativePath(for: url, relativeTo: root)) calls \(call)(")
            }
        }
        XCTAssertEqual(
            violations,
            [],
            """
            Cross-window oversight source emitted logging. Overseen transcript text, display names, \
            and delivered message bodies pass through here, so any log argument must be proven \
            content-free before this guard is relaxed.
            """
        )
    }

    /// The guarded directory must actually be the session-link implementation, so a rename that
    /// empties it fails loudly instead of turning the whole guard into a no-op.
    func testGuardedPathsAllExist() throws {
        let root = try RepoRoot.url()
        var isDirectory: ObjCBool = false
        let directory = root.appendingPathComponent(Self.guardedDirectory, isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue,
            "missing guarded directory \(Self.guardedDirectory)"
        )
        for path in Self.guardedFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path),
                "missing guarded file \(path)"
            )
        }
    }

    // MARK: - Helpers

    private func guardedSourceURLs(root: URL) throws -> [URL] {
        let directory = root.appendingPathComponent(Self.guardedDirectory, isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let inDirectory = contents.filter { $0.pathExtension == "swift" }
        return inDirectory + Self.guardedFiles.map { root.appendingPathComponent($0) }
    }

    /// Removes whole-line `//` comments so prose such as "never print the message body" cannot trip
    /// the scan. Trailing comments are deliberately left in place: keeping the scan conservative is
    /// preferable to mis-parsing a `//` inside a string literal.
    private static func strippingComments(_ source: String) -> String {
        source
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func containsCall(_ name: String, in code: String) -> Bool {
        let pattern = "(?<![A-Za-z0-9_.])\(NSRegularExpression.escapedPattern(for: name))\\s*\\("
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(code.startIndex..., in: code)
        return regex.firstMatch(in: code, range: range) != nil
    }
}
