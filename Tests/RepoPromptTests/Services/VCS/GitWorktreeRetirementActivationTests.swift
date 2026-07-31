import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    final class GitWorktreeRetirementDebugLaunchActivationTests: XCTestCase {
        override func setUp() {
            super.setUp()
            GitWorktreeRetirementActivation.resetForTesting()
        }

        override func tearDown() {
            GitWorktreeRetirementActivation.resetForTesting()
            super.tearDown()
        }

        func testValidDebugLaunchPolicyReceiptActivatesRetirement() throws {
            let outcome = GitWorktreeRetirementDebugLaunchActivation.installIfRequested(
                environment: [
                    GitWorktreeRetirementDebugLaunchActivation.environmentKey:
                        GitWorktreeRetirementDebugLaunchActivation.requiredReceipt
                ]
            )

            XCTAssertEqual(outcome, .activated)
            XCTAssertTrue(GitWorktreeRetirementActivation.isEnabled)

            let source = try String(
                contentsOf: RepoRoot.url().appendingPathComponent("Sources/RepoPrompt/App/RepoPromptApp.swift"),
                encoding: .utf8
            )
            let activationCall = try XCTUnwrap(
                source.range(of: "GitWorktreeRetirementDebugLaunchActivation.installIfRequested")
            )
            let appMainCall = try XCTUnwrap(source.range(of: "RepoPromptSwiftUIApp.main()"))
            XCTAssertLessThan(
                source.distance(from: source.startIndex, to: activationCall.lowerBound),
                source.distance(from: source.startIndex, to: appMainCall.lowerBound),
                "DEBUG retirement activation must run before SwiftUI app initialization starts the MCP server"
            )
        }

        func testMissingAndInvalidDebugLaunchPolicyReceiptsRemainDisabled() {
            XCTAssertEqual(
                GitWorktreeRetirementDebugLaunchActivation.installIfRequested(environment: [:]),
                .notRequested
            )
            XCTAssertFalse(GitWorktreeRetirementActivation.isEnabled)

            XCTAssertEqual(
                GitWorktreeRetirementDebugLaunchActivation.installIfRequested(
                    environment: [
                        GitWorktreeRetirementDebugLaunchActivation.environmentKey: "true"
                    ]
                ),
                .refused
            )
            XCTAssertFalse(GitWorktreeRetirementActivation.isEnabled)
        }

        func testDebugLaunchActivationInstallsOnlyOnce() {
            let environment = [
                GitWorktreeRetirementDebugLaunchActivation.environmentKey:
                    GitWorktreeRetirementDebugLaunchActivation.requiredReceipt
            ]

            XCTAssertEqual(
                GitWorktreeRetirementDebugLaunchActivation.installIfRequested(environment: environment),
                .activated
            )
            XCTAssertEqual(
                GitWorktreeRetirementDebugLaunchActivation.installIfRequested(environment: environment),
                .alreadyActivated
            )
            XCTAssertTrue(GitWorktreeRetirementActivation.isEnabled)
        }
    }
#endif

final class GitWorktreeRetirementActivationReleaseSeparationTests: XCTestCase {
    func testReleaseSourceProjectionHasNoRetirementActivationInstallationPath() throws {
        let root = try RepoRoot.url()
        let files = [
            "Sources/RepoPrompt/App/RepoPromptApp.swift",
            "Sources/RepoPrompt/Infrastructure/VCS/GitWorktreeRetirement.swift",
            "Sources/RepoPrompt/Infrastructure/VCS/GitWorktreeRetirementDebugLaunchActivation.swift"
        ]
        let projection = try files.map { path in
            try releaseProjection(
                String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            )
        }.joined(separator: "\n")

        for forbidden in [
            "REPOPROMPT_DEBUG_WORKTREE_RETIREMENT_POLICY_RECEIPT",
            "GitWorktreeRetirementDebugLaunchActivation",
            "GitWorktreeRetirementOperatorPolicyAuthority",
            "static func install("
        ] {
            XCTAssertFalse(projection.contains(forbidden), "Release source projection leaked \(forbidden)")
        }
    }

    private func releaseProjection(_ source: String) -> String {
        struct Frame {
            let parentIncluded: Bool
            let debugCondition: Bool
        }

        var frames: [Frame] = []
        var included = true
        var output: [String] = []
        for line in source.components(separatedBy: .newlines) {
            let directive = line.trimmingCharacters(in: .whitespaces)
            if directive.hasPrefix("#if ") {
                let isDebug = directive == "#if DEBUG"
                frames.append(Frame(parentIncluded: included, debugCondition: isDebug))
                included = included && !isDebug
            } else if directive == "#else", let frame = frames.last {
                included = frame.parentIncluded && frame.debugCondition
            } else if directive == "#endif", let frame = frames.popLast() {
                included = frame.parentIncluded
            } else if included {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }
}
