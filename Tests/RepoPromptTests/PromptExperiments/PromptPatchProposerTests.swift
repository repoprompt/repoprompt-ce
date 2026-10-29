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

        func testInlineSourceRoundTripsRuntimeTextWithoutChangingSurroundingCode() throws {
            let cases: [(String, String, String, String, String)] = [
                ("json", "{\"prompt\":", #""Hello\n\"world\"""#, ",\"other\":7}\n", "Hello\n\"world\""),
                ("json", "{\"prompt\":", #""Hello\ud83d\ude00""#, ",\"other\":7}\n", "Hello😀"),
                ("py", "PROMPT = ", "'Hello\\nworld'", "\nKEEP = 7\n", "Hello\nworld"),
                ("py", "PROMPT = ", "\"\"\"Hello\n  world\"\"\"", "\nKEEP = 7\n", "Hello\n  world"),
                ("py", "PROMPT = ", #"r"C:\tmp\prompt""#, "\nKEEP = 7\n", #"C:\tmp\prompt"#),
                ("js", "const prompt = ", "`Hello\nworld`", ";\nconst keep = 7;\n", "Hello\nworld"),
                ("ts", "const prompt: string = ", #"'Hello\u{1F600}'"#, ";\nconst keep = 7;\n", "Hello😀"),
                ("swift", "let prompt = ", #""Hello\nworld""#, "\nlet keep = 7\n", "Hello\nworld"),
                ("swift", "let prompt = ", "\"\"\"\n    Hello\n      world\n    \"\"\"", "\nlet keep = 7\n", "Hello\n  world"),
                ("swift", "let prompt = ", "##\"Use \\##\"quotes\\##\" and \\n\"##", "\nlet keep = 7\n", #"Use "quotes" and \n"#)
            ]
            let candidate = "Use \"quotes\", 'apostrophes', \\paths, ${name}, \\(value)\nnext 😀\u{0}\u{8}\u{2028}"
            for (ext, prefix, literal, suffix, decoded) in cases {
                let file = try projectFile(ext: ext, content: prefix + literal + suffix)
                let imported = try PromptLabSource.importFile(url: file, selection: literal)
                XCTAssertEqual(imported.prompt, decoded, "\(ext): \(literal)")
                XCTAssertEqual(imported.selection, literal)
                let metadata = try XCTUnwrap(imported.literal)
                let encoded = PromptLabSourceCodec.encoded(candidate, language: metadata.language)
                try PromptPatchProposer().apply(source: imported, candidate: Data(candidate.utf8))
                let applied = try String(contentsOf: file, encoding: .utf8)
                XCTAssertEqual(applied, prefix + encoded + suffix, "Every byte outside the source literal stays unchanged.")
                XCTAssertEqual(try PromptLabSource.importFile(url: file, selection: encoded).prompt, candidate)
                if ext == "json" {
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(applied.utf8)) as? [String: Any])
                    XCTAssertEqual(object["prompt"] as? String, candidate, "The JSON runtime must see the exact optimized prompt.")
                    XCTAssertEqual(object["other"] as? Int, 7)
                }
            }
        }

        func testEngineerPatchRequiresEveryRuntimeMarkerExactlyOnceBeforeAnyWrite() throws {
            let (root, _) = try sourceTree()
            let directory = root.appendingPathComponent("AppResources/Prompts/engineer", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let prompt = directory.appendingPathComponent("prompt.md")
            let original = AgentModePrompts.engineerTemplateMarkers.joined(separator: "\n") + "\n"
            try Data(original.utf8).write(to: prompt)
            let baseline = BuiltInPromptRegistry.sha256Hex(Data(original.utf8))
            let proposer = PromptPatchProposer(sourceRoot: root)
            for marker in AgentModePrompts.engineerTemplateMarkers {
                for invalid in [original.replacingOccurrences(of: marker, with: ""), original + marker] {
                    XCTAssertThrowsError(try proposer.proposedDiff(promptID: .engineer, baselineSHA256: baseline, candidate: Data(invalid.utf8))) { error in
                        guard case PromptPatchProposer.PatchError.invalidEngineerTemplate = error else { return XCTFail("Unexpected error: \(error)") }
                    }
                    XCTAssertThrowsError(try proposer.apply(promptID: .engineer, baselineSHA256: baseline, candidate: Data(invalid.utf8)))
                    XCTAssertEqual(try String(contentsOf: prompt, encoding: .utf8), original)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("previous").path))
                }
            }
            let valid = original + "Additional optimized instructions.\n"
            XCTAssertNoThrow(try proposer.proposedDiff(promptID: .engineer, baselineSHA256: baseline, candidate: Data(valid.utf8)))
            try proposer.apply(promptID: .engineer, baselineSHA256: baseline, candidate: Data(valid.utf8))
            XCTAssertEqual(try String(contentsOf: prompt, encoding: .utf8), valid)
        }

        func testSelectingEncodedContentsDecodesEscapesAndPatchesOnlyTheirLiteral() throws {
            let file = try projectFile(ext: "py", content: "PROMPT = 'Use \\" + "n for a newline.'\nKEEP = 'unchanged'\n")
            let source = try PromptLabSource.importFile(url: file, selection: #"Use \n for a newline."#)
            XCTAssertEqual(source.prompt, "Use \n for a newline.")
            try PromptPatchProposer().apply(source: source, candidate: Data("Say \"hello\".\nThen stop.".utf8))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "PROMPT = \"Say \\\"hello\\\".\\nThen stop.\"\nKEEP = 'unchanged'\n")
        }

        func testCodePreviewCannotBecomeWholeFilePromptOrOverwriteCode() throws {
            for ext in ["py", "swift", "js", "json", "rs"] {
                let content = ext == "json" ? #"{"prompt":"Original"}"# : "let prompt = \"Original\""
                let file = try projectFile(ext: ext, content: content)
                let preview = try PromptLabSource.importFile(url: file)
                XCTAssertEqual(preview.prompt, content)
                XCTAssertThrowsError(try preview.validated())
                XCTAssertThrowsError(try PromptPatchProposer().apply(source: preview, candidate: Data("Winner".utf8)))
                XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), content)
            }
            let file = try projectFile(ext: "prompt", content: "Original\n")
            let source = try PromptLabSource.importFile(url: file)
            XCTAssertNoThrow(try source.validated())
            try PromptPatchProposer().apply(source: source, candidate: Data("Winner".utf8))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Winner\n")
        }

        func testDynamicAmbiguousAndPartialSourceSelectionsRefuseAutomaticApplication() throws {
            let cases: [(String, String, String)] = [
                ("py", #"PROMPT = f"Hello {name}""#, #"f"Hello {name}""#),
                ("py", #"PROMPT = "Hello" + name"#, #""Hello""#),
                ("py", #"PROMPT = "Hello" "world""#, #""Hello""#),
                ("py", #"PROMPT = "Hello {}".format(name)"#, #""Hello {}""#),
                ("py", #"PROMPT = "Hello %s" % name"#, #""Hello %s""#),
                ("py", #"PROMPT = "Hello\ud83d\ude00""#, #""Hello\ud83d\ude00""#),
                ("js", "const prompt = `Hello ${name}`;", "`Hello ${name}`"),
                ("js", "const prompt = String.raw`Hello`;", "`Hello`"),
                ("swift", #"let prompt = "Hello \(name)""#, #""Hello \(name)""#),
                ("swift", "let prompt = #\"Hello \\#(name)\"#", "#\"Hello \\#(name)\"#"),
                ("json", #"{"prompt":"Hello"}"#, "prompt"),
                ("py", "# 'comment'\nPROMPT = 'Hello'", "'comment'"),
                ("js", "/* 'comment' */\nconst prompt = 'Hello';", "'comment'"),
                ("py", "PROMPT = 'Hello world'", "Hello"),
                ("py", "A = 'Hello'\nB = 'Hello'", "'Hello'")
            ]
            for (ext, content, selection) in cases {
                let file = try projectFile(ext: ext, content: content)
                XCTAssertThrowsError(try PromptLabSource.importFile(url: file, selection: selection), "\(ext): \(selection)")
                XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), content)
            }
        }

        func testLiteralSnapshotRejectsSourceChangesAndForgedMetadata() throws {
            let original = #"{"prompt":"Original","other":7}"#
            let file = try projectFile(ext: "json", content: original)
            var source = try PromptLabSource.importFile(url: file, selection: "Original")
            source.literal?.language = .swift
            XCTAssertThrowsError(try source.validated())
            XCTAssertThrowsError(try PromptPatchProposer().apply(source: source, candidate: Data("Winner".utf8)))
            source = try PromptLabSource.importFile(url: file, selection: "Original")
            try Data(original.replacingOccurrences(of: "7", with: "8").utf8).write(to: file)
            XCTAssertThrowsError(try PromptPatchProposer().apply(source: source, candidate: Data("Winner".utf8)))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original.replacingOccurrences(of: "7", with: "8"))
        }

        func testSourceImportResolvesAncestorAliasesButRejectsFinalLinks() throws {
            let file = try projectFile(ext: "prompt", content: "Original")
            let directory = file.deletingLastPathComponent()
            let alias = directory.appendingPathComponent("alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
            let imported = try PromptLabSource.importFile(url: alias.appendingPathComponent(file.lastPathComponent))
            XCTAssertEqual(imported.filePath, file.resolvingSymlinksInPath().path)
            try PromptPatchProposer().apply(source: imported, candidate: Data("Winner".utf8))
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Winner")
            let link = directory.appendingPathComponent("linked.prompt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            XCTAssertThrowsError(try PromptLabSource.importFile(url: link))
        }

        func testLegacySourceRecordWithoutLiteralMetadataStillDecodes() throws {
            let data = Data(#"{"kind":"pasted","title":"Example","prompt":"Original"}"#.utf8)
            let source = try JSONDecoder().decode(PromptLabSource.self, from: data)
            XCTAssertNil(source.literal)
            XCTAssertEqual(source.prompt, "Original")
        }

        private func projectFile(ext: String, content: String) throws -> URL {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-source-\(UUID().uuidString)", isDirectory: true)
            roots.append(root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("prompt.\(ext)")
            try Data(content.utf8).write(to: file)
            return file
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
