import Foundation
@testable import RepoPrompt
import XCTest

/// Regression coverage for the GLM/z.ai identity-preamble fix (issue #295).
///
/// z.ai selectively rejects requests whose system prompt carries the Claude Agent SDK identity
/// preamble ("You are a Claude agent, built on Anthropic's Claude Agent SDK.") under peak load,
/// returning a misleading 529. Passing a non-empty `--append-system-prompt` makes the CLI emit the
/// never-shed "You are Claude Code…" preamble instead. These tests lock that behavior and its scope.
///
/// Layer note: a unit test over the process-exec trust boundary (the CLI args RPCE spawns `claude`
/// with). The deeper guarantee — that the value actually flips block 1 to the CLI preamble — depends
/// on the real `claude` binary and is verified as a local capture-proxy diagnostic, not a committed
/// test, since it requires the binary and live credentials.
final class ClaudeNativeIdentityPreambleTests: XCTestCase {
    private func makeController(variant: ClaudeCodeRuntimeVariant) -> ClaudeNativeProcessSessionController {
        // buildArguments' append logic keys only on `runtimeVariant`; the other fields .agentMode
        // derives from UserDefaults do not affect the assertions below.
        ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .agentMode(modelString: nil, runtimeVariant: variant)
        )
    }

    func testGLMVariantAppendsIdentityPreambleFlagWithValidValue() async throws {
        // Defect guarded: dropping the gate, mis-scoping it, or using an empty/trigger-word value
        // re-exposes GLM runs to z.ai's 529 shedding under peak load (issue #295).
        let controller = makeController(variant: .glm)
        let args = await controller.test_buildArguments(existingSessionID: nil, model: nil)

        let flagIndex = try XCTUnwrap(
            args.firstIndex(of: "--append-system-prompt"),
            "expected --append-system-prompt for GLM variant, got: \(args)"
        )
        let value = args[args.index(after: flagIndex)]

        // Empty/whitespace is ignored by the CLI and would NOT flip the preamble.
        XCTAssertFalse(
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "--append-system-prompt value must be non-empty, got: \(value)"
        )
        // Heuristic proxy for "won't reintroduce shedding": the value must avoid the SDK identity
        // trigger words. (The exact, binary-dependent proof is the local capture diagnostic.)
        let lowered = value.lowercased()
        XCTAssertNil(
            ["claude", "anthropic", "agent", "sdk"].first { lowered.contains($0) },
            "--append-system-prompt value must not contain an SDK identity trigger word, got: \(value)"
        )
    }

    func testNonGLMVariantsDoNotAppendIdentityPreambleFlag() async {
        // .standard is a hard contract: real-Anthropic usage is never shed and must stay untouched.
        // .kimi/.customCompatible lock the current GLM-only scope; if they later show the same
        // symptom, broaden the gate from `.glm` to `!= .standard` and drop those rows here.
        for variant in [ClaudeCodeRuntimeVariant.standard, .kimi, .customCompatible] {
            let controller = makeController(variant: variant)
            let args = await controller.test_buildArguments(existingSessionID: nil, model: nil)
            XCTAssertFalse(
                args.contains("--append-system-prompt"),
                "\(variant) must not append a system prompt, got: \(args)"
            )
        }
    }
}
