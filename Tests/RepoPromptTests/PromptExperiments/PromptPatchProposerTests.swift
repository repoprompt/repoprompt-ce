import Foundation
@testable import RepoPromptApp
import XCTest

#if DEBUG
    @MainActor
    final class PromptPatchProposerTests: XCTestCase {
        private var roots: [URL] = []

        override func tearDown() {
            for root in roots {
                try? FileManager.default.removeItem(at: root)
            }
            roots = []
            super.tearDown()
        }

        func testProposeAndApplyArchivesOldCanonicalForUpgrade() throws {
            let (root, prompt) = try sourceTree()
            let old = Data("Old built-in prompt\n".utf8)
            let baseline = BuiltInPromptRegistry.sha256Hex(old)
            let proposer = PromptPatchProposer(sourceRoot: root)
            let candidate = Data("New built-in prompt".utf8)

            let diff = try proposer.proposedDiff(promptID: .oraclePlan, baselineSHA256: baseline, candidate: candidate)
            XCTAssertTrue(diff.contains("AppResources/Prompts/oracle-plan/prompt.md"))
            XCTAssertTrue(diff.contains("-Old built-in prompt"))
            XCTAssertTrue(diff.contains("+New built-in prompt"))
            XCTAssertEqual(try Data(contentsOf: prompt), old)

            try proposer.apply(promptID: .oraclePlan, baselineSHA256: baseline, candidate: candidate)
            XCTAssertEqual(try String(contentsOf: prompt, encoding: .utf8), "New built-in prompt\n")
            let registry = BuiltInPromptRegistry(promptsDirectory: root.appendingPathComponent("AppResources/Prompts"))
            XCTAssertEqual(registry.previousCanonicalTexts(.oraclePlan), ["Old built-in prompt"])
            let architectID = try XCTUnwrap(UUID(uuidString: "8E81AAC2-79CE-4897-A59E-EFD81EEBB7E9"))
            let canonical = try StoredPromptRecord(id: architectID, title: "[Architect]", content: registry.resource(.oraclePlan).text)
            let oldStoredDefault = StoredPromptRecord(id: architectID, title: "[Architect]", content: "Old built-in prompt")
            XCTAssertTrue(PromptViewModel.matchesArchivedCanonical(oldStoredDefault, canonical: canonical, promptID: .oraclePlan, registry: registry))
            XCTAssertFalse(PromptViewModel.matchesArchivedCanonical(
                StoredPromptRecord(id: architectID, title: "[Architect]", content: "User-edited prompt"),
                canonical: canonical, promptID: .oraclePlan, registry: registry
            ))
        }

        func testChangedSourceConflictsWithoutWrite() throws {
            let (root, prompt) = try sourceTree()
            let baseline = BuiltInPromptRegistry.sha256Hex(Data("Old built-in prompt\n".utf8))
            let proposer = PromptPatchProposer(sourceRoot: root)
            try Data("User changed source\n".utf8).write(to: prompt)
            XCTAssertThrowsError(try proposer.apply(promptID: .oraclePlan, baselineSHA256: baseline, candidate: Data("Winner".utf8))) { error in
                guard case PromptPatchProposer.PatchError.baselineConflict = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(try String(contentsOf: prompt, encoding: .utf8), "User changed source\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: prompt.deletingLastPathComponent().appendingPathComponent("previous").path))
        }

        func testSymlinkPromptAndParentAreRejected() throws {
            let (root, prompt) = try sourceTree()
            let baseline = try BuiltInPromptRegistry.sha256Hex(Data(contentsOf: prompt))
            let external = root.appendingPathComponent("external.md")
            try Data("External\n".utf8).write(to: external)
            try FileManager.default.removeItem(at: prompt)
            try FileManager.default.createSymbolicLink(at: prompt, withDestinationURL: external)
            let proposer = PromptPatchProposer(sourceRoot: root)
            XCTAssertThrowsError(try proposer.proposedDiff(promptID: .oraclePlan, baselineSHA256: baseline, candidate: Data("Winner".utf8)))
            XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "External\n")

            try FileManager.default.removeItem(at: prompt)
            let prompts = prompt.deletingLastPathComponent().deletingLastPathComponent()
            let displaced = root.appendingPathComponent("displaced-prompts")
            try FileManager.default.moveItem(at: prompts, to: displaced)
            try FileManager.default.createSymbolicLink(at: prompts, withDestinationURL: displaced)
            XCTAssertThrowsError(try proposer.proposedDiff(promptID: .oraclePlan, baselineSHA256: baseline, candidate: Data("Winner".utf8)))
        }

        func testSymlinkPreviousArchiveIsRejectedWithoutChangingSource() throws {
            let (root, prompt) = try sourceTree()
            let old = try Data(contentsOf: prompt)
            let baseline = BuiltInPromptRegistry.sha256Hex(old)
            let previous = prompt.deletingLastPathComponent().appendingPathComponent("previous")
            try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: false)
            let archive = previous.appendingPathComponent("\(baseline).md")
            let external = root.appendingPathComponent("external.md")
            try Data("External\n".utf8).write(to: external)
            try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: external)
            XCTAssertThrowsError(try PromptPatchProposer(sourceRoot: root).apply(
                promptID: .oraclePlan, baselineSHA256: baseline, candidate: Data("Winner".utf8)
            ))
            XCTAssertEqual(try Data(contentsOf: prompt), old)
            XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "External\n")
        }

        func testMissingExplicitRootAndUnchangedCandidateReject() throws {
            let (root, _) = try sourceTree()
            let old = Data("Old built-in prompt\n".utf8)
            let baseline = BuiltInPromptRegistry.sha256Hex(old)
            XCTAssertThrowsError(try PromptPatchProposer(sourceRoot: nil).proposedDiff(promptID: .oraclePlan, baselineSHA256: baseline, candidate: old))
            XCTAssertThrowsError(try PromptPatchProposer(sourceRoot: root).proposedDiff(promptID: .oraclePlan, baselineSHA256: baseline, candidate: old))
        }

        func testDefaultSourceRootFallsBackToTheCompiledCheckoutAndHonoursTheOverride() throws {
            // <repo>/Tests/RepoPromptTests/PromptExperiments/PromptPatchProposerTests.swift
            var checkout = URL(fileURLWithPath: #filePath)
            for _ in 0 ..< 4 {
                checkout.deleteLastPathComponent()
            }
            let fallback = try XCTUnwrap(PromptPatchProposer.defaultSourceRoot(environment: [:]))
            XCTAssertEqual(fallback.standardizedFileURL.path, checkout.standardizedFileURL.path)

            // The fallback is a working (read-only here) proposal source with the usual SHA check.
            let prompt = fallback.appendingPathComponent("AppResources/Prompts/oracle-plan/prompt.md")
            let baseline = try Data(contentsOf: prompt)
            let proposer = PromptPatchProposer(sourceRoot: fallback)
            let diff = try proposer.proposedDiff(
                promptID: .oraclePlan,
                baselineSHA256: BuiltInPromptRegistry.sha256Hex(baseline),
                candidate: baseline + Data("Extra line.\n".utf8)
            )
            XCTAssertTrue(diff.contains("+Extra line."))
            XCTAssertThrowsError(try proposer.proposedDiff(
                promptID: .oraclePlan, baselineSHA256: String(repeating: "0", count: 64), candidate: Data("x".utf8)
            ))

            let (override, _) = try sourceTree()
            XCTAssertEqual(
                PromptPatchProposer.defaultSourceRoot(environment: [PromptPatchProposer.sourceRootEnvironmentKey: override.path])?.path,
                override.path,
                "the environment override wins over the compiled checkout"
            )
            XCTAssertNil(
                PromptPatchProposer.defaultSourceRoot(environment: [:], compiledSourcePath: "/nonexistent/a/b/c/d/File.swift"),
                "no fallback without a real checkout"
            )
        }

        private func sourceTree() throws -> (URL, URL) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-patch-\(UUID().uuidString)", isDirectory: true)
            roots.append(root)
            let directory = root.appendingPathComponent("AppResources/Prompts/oracle-plan", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let prompt = directory.appendingPathComponent("prompt.md")
            try Data("Old built-in prompt\n".utf8).write(to: prompt)
            return (root, prompt)
        }
    }
#endif
