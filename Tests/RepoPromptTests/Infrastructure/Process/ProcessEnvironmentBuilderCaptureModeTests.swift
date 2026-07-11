import Foundation
@testable import RepoPromptApp
import XCTest

/// Coverage for `ProcessEnvironmentBuilder.preferredShellCaptureMode`.
///
/// Spec: docs/spec/codex-nvm-path-resolution.md — S-1 (Codex capture must be an
/// interactive login shell so `.zshrc`-only toolchains like nvm are captured) and
/// S-2 (Codex shares the cached interactive capture slot other providers use, so no
/// per-launch interactive spawn is introduced).
final class ProcessEnvironmentBuilderCaptureModeTests: XCTestCase {
    func testCodexAppServerUsesInteractiveLoginShellCapture() {
        let mode = ProcessEnvironmentBuilder.preferredShellCaptureMode(for: .codexAppServer)
        XCTAssertEqual(mode, .interactiveLoginShell)
    }

    func testCodexPreflightUsesInteractiveLoginShellCapture() {
        let mode = ProcessEnvironmentBuilder.preferredShellCaptureMode(for: .codexPreflight)
        XCTAssertEqual(mode, .interactiveLoginShell)
    }

    func testCodexSharesInteractiveCacheSlotWithOtherProviders() {
        let codexModes = [
            ProcessEnvironmentBuilder.preferredShellCaptureMode(for: .codexAppServer),
            ProcessEnvironmentBuilder.preferredShellCaptureMode(for: .codexPreflight)
        ]
        XCTAssertTrue(codexModes.allSatisfy { $0 == .interactiveLoginShell })
        XCTAssertEqual(
            ProcessEnvironmentBuilder.preferredShellCaptureMode(for: .cliRunner),
            .interactiveLoginShell
        )
    }
}
