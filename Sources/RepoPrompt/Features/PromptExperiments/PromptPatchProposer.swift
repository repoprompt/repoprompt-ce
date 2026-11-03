#if DEBUG
    import Foundation

    /// Source-checkout-only patch preparation and application. The packaged prompt bundle is
    /// never a write target. The checkout root defaults to the one this DEBUG build was compiled
    /// from; REPOPROMPT_PROMPT_EXPERIMENT_SOURCE_ROOT overrides it.
    struct PromptPatchProposer {
        static let sourceRootEnvironmentKey = "REPOPROMPT_PROMPT_EXPERIMENT_SOURCE_ROOT"

        enum PatchError: LocalizedError {
            case sourceRootUnavailable
            case unsafeSourcePath
            case baselineConflict
            case invalidCandidate
            case invalidEngineerTemplate
            case unchangedCandidate
            case archiveConflict

            var errorDescription: String? {
                switch self {
                case .sourceRootUnavailable: "No source checkout was found for this build; set REPOPROMPT_PROMPT_EXPERIMENT_SOURCE_ROOT to the checkout root before proposing a patch."
                case .unsafeSourcePath: "The prompt source path is not a contained regular file, or includes a symbolic link."
                case .baselineConflict: "The source prompt changed since experiment approval; no patch was written."
                case .invalidCandidate: "The retained candidate is empty or is not valid UTF-8."
                case .invalidEngineerTemplate: "The Engineer candidate must preserve each required runtime template marker exactly once. This candidate cannot be applied; choose a valid candidate or run a new experiment."
                case .unchangedCandidate: "The candidate does not change the source prompt."
                case .archiveConflict: "The previous-canonical archive path already contains different data or is unsafe."
                }
            }
        }

        private let sourceRoot: URL?
        private let fileManager: FileManager

        init(sourceRoot: URL? = PromptPatchProposer.defaultSourceRoot(), fileManager: FileManager = .default) {
            self.sourceRoot = sourceRoot
            self.fileManager = fileManager
        }

        /// The environment override when set; otherwise the checkout this file was compiled from
        /// (same approach as `BuiltInPromptRegistry.defaultPromptsDirectory`). Conductor launches
        /// the debug app with `open -n`, which does not forward shell environment. The returned
        /// root is only a candidate: containment, symlink and baseline-SHA checks still apply.
        static func defaultSourceRoot(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            compiledSourcePath: String? = nil
        ) -> URL? {
            if let override = environment[sourceRootEnvironmentKey], !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            // <repo>/Sources/RepoPrompt/Features/PromptExperiments/PromptPatchProposer.swift
            var root = URL(fileURLWithPath: compiledSourcePath ?? #filePath)
            for _ in 0 ..< 5 {
                root.deleteLastPathComponent()
            }
            var isDirectory: ObjCBool = false
            let prompts = root.appendingPathComponent("AppResources/Prompts", isDirectory: true).path
            guard FileManager.default.fileExists(atPath: prompts, isDirectory: &isDirectory), isDirectory.boolValue,
                  FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
            else { return nil }
            return root.standardizedFileURL
        }

        func proposedDiff(promptID: BuiltInPromptID, baselineSHA256: String, candidate: Data) throws -> String {
            let source = try sourceURL(for: promptID)
            let baseline = try checkedBaseline(at: source, expectedSHA256: baselineSHA256)
            let replacement = try candidateBytes(candidate, promptID: promptID)
            guard replacement != baseline else { throw PatchError.unchangedCandidate }
            let path = "AppResources/Prompts/\(promptID.rawValue)/prompt.md"
            let chunks = UnifiedDiffGenerator.diffChunks(
                oldLines: String(decoding: baseline, as: UTF8.self).components(separatedBy: "\n"),
                newLines: String(decoding: replacement, as: UTF8.self).components(separatedBy: "\n")
            )
            return UnifiedDiffGenerator.build(filePath: path, chunks: chunks)
        }

        func apply(promptID: BuiltInPromptID, baselineSHA256: String, candidate: Data) throws {
            let source = try sourceURL(for: promptID)
            let baseline = try checkedBaseline(at: source, expectedSHA256: baselineSHA256)
            let replacement = try candidateBytes(candidate, promptID: promptID)
            guard replacement != baseline else { throw PatchError.unchangedCandidate }

            // Archive the exact old resource bytes before changing the canonical source. This
            // keeps persisted, unedited Architect/Review defaults recognizable after an upgrade.
            let previous = source.deletingLastPathComponent().appendingPathComponent("previous", isDirectory: true)
            try ensureArchiveDirectory(previous)
            let archive = previous.appendingPathComponent("\(baselineSHA256).md")
            if (try? fileManager.destinationOfSymbolicLink(atPath: archive.path)) != nil {
                throw PatchError.archiveConflict
            }
            if fileManager.fileExists(atPath: archive.path) {
                guard try isRegularNotSymlink(archive),
                      try Data(contentsOf: archive) == baseline
                else { throw PatchError.archiveConflict }
            } else {
                try baseline.write(to: archive, options: .atomic)
            }
            // No auto-merge: the final source check is immediately before the atomic replace.
            _ = try checkedBaseline(at: source, expectedSHA256: baselineSHA256)
            try replacement.write(to: source, options: .atomic)
        }

        func projectBaseline(source: PromptLabSource) throws -> Data {
            guard source.kind == .file, let path = source.filePath, let sha256 = source.originalFileSHA256 else {
                throw PatchError.sourceRootUnavailable
            }
            let selected = URL(fileURLWithPath: path).standardizedFileURL
            let url = try PromptLabSource.canonicalSource(selected)
            guard url == selected else { throw PatchError.unsafeSourcePath }
            return try checkedBaseline(at: url, expectedSHA256: sha256)
        }

        func proposedDiff(source: PromptLabSource, candidate: Data) throws -> String {
            let baseline = try projectBaseline(source: source)
            let replacement = try projectReplacement(source: source, baseline: baseline, candidate: candidate)
            let chunks = UnifiedDiffGenerator.diffChunks(
                oldLines: String(decoding: baseline, as: UTF8.self).components(separatedBy: "\n"),
                newLines: String(decoding: replacement, as: UTF8.self).components(separatedBy: "\n")
            )
            return UnifiedDiffGenerator.build(filePath: source.filePath ?? source.title, chunks: chunks)
        }

        func apply(source: PromptLabSource, candidate: Data) throws {
            let baseline = try projectBaseline(source: source)
            let replacement = try projectReplacement(source: source, baseline: baseline, candidate: candidate)
            _ = try projectBaseline(source: source)
            try replacement.write(to: URL(fileURLWithPath: source.filePath!), options: .atomic)
        }

        private func projectReplacement(source: PromptLabSource, baseline: Data, candidate: Data) throws -> Data {
            guard let text = String(data: candidate, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let original = String(data: baseline, encoding: .utf8)
            else { throw PatchError.invalidCandidate }
            let result = try PromptLabSourceCodec.replacement(source: source, original: original, candidate: text)
            let replacement = Data(result.utf8)
            guard replacement != baseline else { throw PatchError.unchangedCandidate }
            return replacement
        }

        private func sourceURL(for promptID: BuiltInPromptID) throws -> URL {
            guard let sourceRoot else { throw PatchError.sourceRootUnavailable }
            let root = sourceRoot.standardizedFileURL
            guard !root.pathComponents.contains(where: { $0.hasSuffix(".app") }) else {
                throw PatchError.unsafeSourcePath
            }
            let relative = ["AppResources", "Prompts", promptID.rawValue, BuiltInPromptID.promptFileName]
            var url = root
            guard try isDirectoryNotSymlink(url) else { throw PatchError.unsafeSourcePath }
            for component in relative.dropLast() {
                url.appendPathComponent(component, isDirectory: true)
                guard try isDirectoryNotSymlink(url) else { throw PatchError.unsafeSourcePath }
            }
            url.appendPathComponent(relative[relative.count - 1])
            guard url.standardizedFileURL.path.hasPrefix(root.path + "/"),
                  try isRegularNotSymlink(url)
            else { throw PatchError.unsafeSourcePath }
            return url
        }

        private func checkedBaseline(at url: URL, expectedSHA256: String) throws -> Data {
            guard try isRegularNotSymlink(url) else { throw PatchError.unsafeSourcePath }
            let data = try Data(contentsOf: url)
            guard BuiltInPromptRegistry.sha256Hex(data) == expectedSHA256 else { throw PatchError.baselineConflict }
            return data
        }

        private func candidateBytes(_ candidate: Data, promptID: BuiltInPromptID) throws -> Data {
            guard let text = String(data: candidate, encoding: .utf8), !text.isEmpty else { throw PatchError.invalidCandidate }
            if promptID == .engineer, !AgentModePrompts.isValidEngineerTemplate(text) { throw PatchError.invalidEngineerTemplate }
            return Data((text.hasSuffix("\n") ? text : text + "\n").utf8)
        }

        private func ensureArchiveDirectory(_ url: URL) throws {
            if fileManager.fileExists(atPath: url.path) {
                guard try isDirectoryNotSymlink(url) else { throw PatchError.archiveConflict }
            } else {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            }
        }

        private func isRegularNotSymlink(_ url: URL) throws -> Bool {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true
        }

        private func isDirectoryNotSymlink(_ url: URL) throws -> Bool {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }
#endif
