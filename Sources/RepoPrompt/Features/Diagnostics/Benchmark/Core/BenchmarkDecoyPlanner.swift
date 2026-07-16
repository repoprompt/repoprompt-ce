import Foundation

/// Types of decoys we can produce.
/// - identicalCoreVariantHalo: core lines are identical to target; surrounding lines differ
/// - altReexport: barrel/re-export graph variant (not produced by default in this file)
/// - altFunctionOrder: identical functions but different neighbors/order (not produced by default here)
/// - patchContextMirror: mirrors unified diff context with tempting identical blocks elsewhere
enum DecoyKind {
    case identicalCoreVariantHalo
    case altReexport
    case altFunctionOrder
    case patchContextMirror
}

/// Description of a produced decoy.
struct DecoySpec {
    let path: String
    let sourcePath: String
    let kind: DecoyKind
    /// Line span of the identical core inside the decoy file, 0-based inclusive.
    let coreLineSpan: ClosedRange<Int>?
}

/// Internal representation of a target core region inside a source file.
struct CoreRegion {
    let startLine: Int // inclusive, 0-based
    let endLine: Int // inclusive, 0-based
    let lines: [String] // exact lines of the core
    let beforeLine: String? // immediate line before core (in the source file)
    let afterLine: String? // immediate line after core (in the source file)
}

/// Entry point for planning and materializing decoys.
enum DecoyPlanner {
    /// Generate decoys for a given task and materialize them into the in-memory file system.
    /// Returns a list of DecoySpec entries describing produced decoys.
    static func materialize(
        for task: BenchmarkTaskSpec,
        on fs: inout BenchmarkMockFileSystem,
        baseline: BenchmarkMockFileSystemSnapshot,
        policy: DecoyPolicy
    ) -> [DecoySpec] {
        guard policy.style != .off, policy.maxDecoysPerTask > 0 else {
            return []
        }

        // Determine the list of primary paths to base decoys on.
        // Prefer per-entry params (guards/blocks/regions/inserts) when present,
        // else fall back to the first candidate in selectFiles.
        let candidatePrimaryPaths = primaryEditTargets(for: task)
        guard !candidatePrimaryPaths.isEmpty else { return [] }

        var produced: [DecoySpec] = []
        var decoyBudget = policy.maxDecoysPerTask

        // Optionally embed intra-file shadows on safe task types first (they don't count toward path budget)
        if policy.enableIntraFileShadows, policy.maxIntraFileShadows > 0 {
            let safeForShadows = isSafeForSameFileShadows(task.type)
            if safeForShadows {
                var shadowsLeft = policy.maxIntraFileShadows
                for path in candidatePrimaryPaths {
                    guard shadowsLeft > 0 else { break }
                    guard var text = fs.content(for: path) ?? baseline.content(for: path) else { continue }
                    guard let core = locateCore(for: task, in: text, path: path) else { continue }
                    let updated = embedShadowCore(in: text, core: core, language: task.language, startMarker: "// SHADOW START (do not edit)", endMarker: "// SHADOW END (do not edit)")
                    if updated != text {
                        fs.setFile(path, content: updated)
                        text = updated
                        shadowsLeft -= 1
                    }
                }
            }
        }

        // Materialize separate decoy files with identical-core + variant halo
        outer: for sourcePath in candidatePrimaryPaths {
            guard decoyBudget > 0 else { break }
            guard let source = fs.content(for: sourcePath) ?? baseline.content(for: sourcePath) else { continue }
            guard let core = locateCore(for: task, in: source, path: sourcePath) else { continue }

            // Derive candidate decoy paths
            var candidatePaths = variants(for: sourcePath, placement: policy.placement, count: max(policy.maxDecoysPerTask, 3))
            // Filter out any that already exist
            candidatePaths.removeAll { p in
                fs.content(for: p) != nil || baseline.content(for: p) != nil
            }
            if candidatePaths.isEmpty {
                continue
            }

            // For each decoy path, insert halo variants (slight differences near the core boundaries).
            var variantIndex = 0
            while decoyBudget > 0, !candidatePaths.isEmpty {
                let decoyPath = candidatePaths.removeFirst()
                let halo = haloVariantStrings(language: task.language, core: core, index: variantIndex)
                let (content, newSpan) = buildDecoyFile(from: source, core: core, language: task.language, haloVariant: halo)
                fs.setFile(decoyPath, content: content)
                produced.append(DecoySpec(path: decoyPath, sourcePath: sourcePath, kind: .identicalCoreVariantHalo, coreLineSpan: newSpan))
                variantIndex += 1
                decoyBudget -= 1
                if decoyBudget == 0 {
                    break outer
                }
            }
        }

        // Optionally create context mirror decoys for insert_guard and apply_unified_patch tasks
        let shouldCreateMirrors = switch task.type {
        case .insertGuardTs, .insertGuardGo, .insertGuardSwift,
             .applyUnifiedPatchTs, .applyUnifiedPatchGo, .applyUnifiedPatchSwift:
            true
        default:
            false
        }

        if shouldCreateMirrors, decoyBudget > 0 {
            var mirrorsCreated = 0
            let maxMirrorsPerTask: Int = switch task.type {
            case .applyUnifiedPatchTs, .applyUnifiedPatchGo, .applyUnifiedPatchSwift:
                policy.style == .gauntlet ? 10 : 6
            default:
                2 // Hard cap to prevent excessive proliferation
            }

            for sourcePath in candidatePrimaryPaths {
                guard decoyBudget > 0, mirrorsCreated < maxMirrorsPerTask else { break }
                guard let source = fs.content(for: sourcePath) ?? baseline.content(for: sourcePath) else { continue }
                guard let core = locateCore(for: task, in: source, path: sourcePath) else { continue }

                // Create unique mirror path by including directory slug to avoid collisions
                let fileName = (sourcePath as NSString).lastPathComponent
                let ext = (fileName as NSString).pathExtension
                // Convert path separators to underscores for uniqueness
                let slug = sourcePath
                    .replacingOccurrences(of: "/", with: "__")
                    .replacingOccurrences(of: "\\", with: "__")
                    .replacingOccurrences(of: ".", with: "_")
                let mirrorPath = "mirror_context/\(slug)__context.\(ext)"

                // Skip if already exists
                if fs.content(for: mirrorPath) != nil || baseline.content(for: mirrorPath) != nil {
                    continue
                }

                // Build and write mirror content
                let mirrorContent = buildContextMirror(from: source, core: core, language: task.language)
                fs.setFile(mirrorPath, content: mirrorContent)
                produced.append(DecoySpec(path: mirrorPath, sourcePath: sourcePath, kind: .patchContextMirror, coreLineSpan: nil))
                decoyBudget -= 1
                mirrorsCreated += 1
            }
        }

        return produced
    }
}

// MARK: - Primary target inference

private extension DecoyPlanner {
    /// Chooses the "primary" edit targets for a task using per-case params when available.
    static func primaryEditTargets(for task: BenchmarkTaskSpec) -> [String] {
        var paths: [String] = []

        func uniqueAppend(_ path: String) {
            let norm = BenchmarkMockFileSystem.normalize(path)
            guard !norm.isEmpty else { return }
            if !paths.contains(norm) {
                paths.append(norm)
            }
        }

        switch task.type {
        case .insertGuardTs, .insertGuardGo, .insertGuardSwift:
            if let arr = task.params["guards"]?.arrayValue {
                for item in arr {
                    if let p = item.objectValue?["path"]?.stringValue {
                        uniqueAppend(p)
                    }
                }
            } else if let p = task.params["file"]?.stringValue {
                uniqueAppend(p)
            } else if let p = task.selectFiles.first {
                uniqueAppend(p)
            }
        case .patchBlockTs, .patchBlockGo, .patchBlockSwift:
            if let arr = task.params["blocks"]?.arrayValue {
                for item in arr {
                    if let p = item.objectValue?["path"]?.stringValue {
                        uniqueAppend(p)
                    }
                }
            } else if let p = task.selectFiles.first {
                uniqueAppend(p)
            }
        case .swapArgsInRegionTs, .swapArgsInRegionGo, .swapArgsInRegionSwift:
            if let arr = task.params["regions"]?.arrayValue {
                for item in arr {
                    if let p = item.objectValue?["path"]?.stringValue {
                        uniqueAppend(p)
                    }
                }
            } else if let p = task.selectFiles.first {
                uniqueAppend(p)
            }
        case .moveFunctionTs, .moveFunctionGo, .moveFunctionSwift,
             .applyUnifiedPatchTs, .applyUnifiedPatchGo, .applyUnifiedPatchSwift,
             .removeXTs, .removeXGo, .removeXSwift,
             .indexOnlyAppsTs, .indexOnlyAppsGo, .indexOnlyAppsSwift:
            if let p = task.selectFiles.first {
                uniqueAppend(p)
            }
        default:
            // For other tasks, best-effort: prefer first selection
            if let p = task.selectFiles.first {
                uniqueAppend(p)
            }
        }

        return paths
    }

    /// Decide whether it's safe to embed an intra-file shadow core for this task type.
    /// Prefer tasks where duplicates won't confuse acceptance logic.
    static func isSafeForSameFileShadows(_ type: BenchmarkCaseType) -> Bool {
        switch type {
        case .removeXTs, .removeXGo, .removeXSwift:
            true
        case .swapArgsInRegionTs, .swapArgsInRegionGo, .swapArgsInRegionSwift:
            true
        // Avoid intra-file shadows for anchor/UID-based tasks to prevent confusion with acceptance.
        case .insertGuardTs, .insertGuardGo, .insertGuardSwift,
             .patchBlockTs, .patchBlockGo, .patchBlockSwift,
             .moveFunctionTs, .moveFunctionGo, .moveFunctionSwift,
             .indexOnlyAppsTs, .indexOnlyAppsGo, .indexOnlyAppsSwift,
             .applyUnifiedPatchTs, .applyUnifiedPatchGo, .applyUnifiedPatchSwift,
             .curlyFixTs, .curlyFixGo, .curlyFixSwift,
             .renameExportImportsTs, .renameExportImportsGo, .renameExportImportsSwift,
             .insertFunctionBottomTs, .insertFunctionBottomGo, .insertFunctionBottomSwift:
            false
        }
    }
}

// MARK: - Core location per task

extension DecoyPlanner {
    /// Locate a "core" region for this task inside the provided text.
    /// - Parameter path: The source path (used to resolve UID/path-specific params).
    static func locateCore(for task: BenchmarkTaskSpec, in text: String, path: String? = nil) -> CoreRegion? {
        switch task.type {
        case .insertGuardTs, .insertGuardGo, .insertGuardSwift:
            // Check for markerless mode
            if task.params["markerless"]?.boolValue == true,
               let functionName = task.params["functionName"]?.stringValue,
               let insertAfterPattern = task.params["insertAfterPattern"]?.stringValue
            {
                return locateInsertGuardMarkerlessCore(in: text, language: task.language, functionName: functionName, insertAfterPattern: insertAfterPattern)
            }
            // Fallback to anchor-based
            let uid = uidForPath(task: task, arrayKey: "guards", pathKey: "path", uidKey: "uid", fallbackUidKey: "uid", path: path)
            return locateAnchoredCore(
                in: text,
                startToken: "// ANCHOR:start:\(uid ?? "")",
                endToken: "// ANCHOR:end:\(uid ?? "")",
                fallbackTokenPrefix: "// ANCHOR:start:"
            )
        case .patchBlockTs, .patchBlockGo, .patchBlockSwift:
            // Check for markerless mode
            if task.params["markerless"]?.boolValue == true,
               let functionName = task.params["functionName"]?.stringValue
            {
                return locateFunctionCore(in: text, language: task.language, name: functionName)
            }
            // Fallback to anchor-based
            let uid = uidForPath(task: task, arrayKey: "blocks", pathKey: "path", uidKey: "uid", fallbackUidKey: "uid", path: path)
            return locateAnchoredCore(
                in: text,
                startToken: "/* BLOCK START:\(uid ?? "") */",
                endToken: "/* BLOCK END:\(uid ?? "") */",
                fallbackTokenPrefix: "/* BLOCK START:"
            )
        case .swapArgsInRegionTs, .swapArgsInRegionGo, .swapArgsInRegionSwift:
            // Check for markerless mode
            if task.params["markerless"]?.boolValue == true,
               let functionName = task.params["functionName"]?.stringValue
            {
                return locateSwapArgsMarkerlessCore(in: text, language: task.language, functionName: functionName)
            }
            // Fallback to anchor-based
            let uid = uidForPath(task: task, arrayKey: "regions", pathKey: "path", uidKey: "uid", fallbackUidKey: "uid", path: path)
            return locateAnchoredCore(
                in: text,
                startToken: "/* START_SWAP:\(uid ?? "") */",
                endToken: "/* END_SWAP:\(uid ?? "") */",
                fallbackTokenPrefix: "/* START_SWAP:"
            )
        case .moveFunctionTs, .moveFunctionGo, .moveFunctionSwift:
            // Use function name(s); prefer single-move params
            if let name = task.params["fromName"]?.stringValue {
                return locateFunctionCore(in: text, language: task.language, name: name)
            } else if let moves = task.params["moves"]?.arrayValue {
                if let first = moves.first?.objectValue?["from"]?.stringValue {
                    return locateFunctionCore(in: text, language: task.language, name: first)
                }
            }
            return nil
        case .indexOnlyAppsTs:
            return locateIndexCoreTS(in: text)
        case .indexOnlyAppsGo:
            return locateIndexCoreGo(in: text)
        case .indexOnlyAppsSwift:
            return locateIndexCoreSwift(in: text)
        case .removeXTs, .removeXGo, .removeXSwift:
            return locateRemoveXCore(in: text, token: "CALL_X(")
        case .applyUnifiedPatchTs, .applyUnifiedPatchGo, .applyUnifiedPatchSwift:
            if let patch = task.params["patch"]?.stringValue {
                return locatePatchHunkCore(in: text, patch: patch)
            }
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Decoy path variants

extension DecoyPlanner {
    /// Produce candidate decoy paths for the given source path based on placement strategy.
    static func variants(for path: String, placement: DecoyPolicy.Placement, count: Int) -> [String] {
        let normalized = BenchmarkMockFileSystem.normalize(path)
        let fileName = (normalized as NSString).lastPathComponent
        let dir = (normalized as NSString).deletingLastPathComponent

        func siblingDirCandidates() -> [String] {
            var out: [String] = []
            out.append("\(dir)_shadow/\(fileName)")
            out.append("\(dir)/alt/\(fileName)")
            out.append("\(dir)/copy/\(fileName)")
            out.append("\(dir)/mirror/\(fileName)")
            return out
        }

        func crossRootCandidates() -> [String] {
            var out: [String] = []
            out.append("shadow/\(fileName)")
            out.append("sandbox/\(fileName)")
            out.append("mirror/\(fileName)")
            out.append("decoys/\(fileName)")
            return out
        }

        let candidates: [String] = switch placement {
        case .siblingDir:
            siblingDirCandidates()
        case .crossRoot:
            crossRootCandidates()
        case .mixed:
            siblingDirCandidates() + crossRootCandidates()
        }

        // Deduplicate and trim to requested count
        var seen = Set<String>()
        var results: [String] = []
        for p in candidates {
            let norm = BenchmarkMockFileSystem.normalize(p)
            if !norm.isEmpty, seen.insert(norm).inserted {
                results.append(norm)
            }
            if results.count >= max(0, count) {
                break
            }
        }
        return results
    }
}

// MARK: - Build decoy content

extension DecoyPlanner {
    /// Construct a decoy file content by inserting variant halo lines around an identical core region.
    /// Returns the new content and the updated core line span inside that content.
    static func buildDecoyFile(
        from original: String,
        core: CoreRegion,
        language: BenchmarkLanguage,
        haloVariant: (before: String?, after: String?)
    ) -> (content: String, span: ClosedRange<Int>) {
        var lines = splitLinesPreservingTrailing(original)

        var start = core.startLine
        var end = core.endLine

        if let before = haloVariant.before {
            let insertAt = max(0, start)
            let prefixed = before
            lines.insert(prefixed, at: insertAt)
            start += 1
            end += 1
        }
        if let after = haloVariant.after {
            let insertAt = min(lines.count, end + 1) // line immediately after core end
            let prefixed = after
            lines.insert(prefixed, at: insertAt)
            // No need to move end; core itself unchanged
        }

        let content = lines.joined(separator: "\n")
        return (content, start ... end)
    }

    /// Append a shadow copy of the core region to the end of the file, fenced by marker comments.
    static func embedShadowCore(
        in original: String,
        core: CoreRegion,
        language: BenchmarkLanguage,
        startMarker: String,
        endMarker: String
    ) -> String {
        let lines = splitLinesPreservingTrailing(original)
        var out = lines
        // Append spacer newline if file doesn't already end with one
        if let last = out.last, !last.isEmpty {
            out.append("")
        }
        out.append(startMarker)
        out.append(contentsOf: core.lines)
        out.append(endMarker)
        return out.joined(separator: "\n")
    }

    /// Build a context mirror decoy: a small file containing the core lines with minimal wrapping.
    /// This creates near-match confusion across files when models skim multiple files.
    static func buildContextMirror(
        from original: String,
        core: CoreRegion,
        language: BenchmarkLanguage
    ) -> String {
        let comment = lineCommentPrefix(for: language)
        var out: [String] = []

        // Add header
        out.append("\(comment) Context mirror file - similar to target but with variations")
        out.append("")

        // Add 1-2 helper lines before the core fragment
        let indent = leadingIndentation(of: core.lines.first ?? "")
        out.append("\(comment) Helper context")
        if let before = core.beforeLine {
            // Include the line before core, but with slight variation
            out.append(
                before.replacingOccurrences(of: "const", with: "let")
                    .replacingOccurrences(of: "let", with: "var")
            )
        }

        // Include the core lines verbatim (without anchors)
        for line in core.lines {
            // Strip anchor comments if present
            if line.contains("ANCHOR:start:") || line.contains("ANCHOR:end:") {
                continue
            }
            out.append(line)
        }

        // Add 1-2 helper lines after the core fragment
        if let after = core.afterLine {
            out.append(after.replacingOccurrences(of: "return", with: "// return"))
        }
        out.append("\(indent)\(comment) End mirror fragment")

        return out.joined(separator: "\n")
    }
}

// MARK: - Halo variant helpers

private extension DecoyPlanner {
    static func haloVariantStrings(
        language: BenchmarkLanguage,
        core: CoreRegion,
        index: Int
    ) -> (before: String?, after: String?) {
        let indent = leadingIndentation(of: core.lines.first ?? "")
        let comment = lineCommentPrefix(for: language)
        // Vary the halo messages slightly by index to produce different contexts
        let beforeMsg = "\(comment) halo:\(index) pre"
        let afterMsg = "\(comment) halo:\(index) post"

        // Do not generate identical before/after to the original immediate lines if possible
        let before: String? = "\(indent)\(beforeMsg)"
        let after: String? = "\(indent)\(afterMsg)"
        return (before, after)
    }
}

// MARK: - Core location helpers

private extension DecoyPlanner {
    static func locateAnchoredCore(
        in text: String,
        startToken: String,
        endToken: String,
        fallbackTokenPrefix: String
    ) -> CoreRegion? {
        let lines = splitLinesPreservingTrailing(text)
        // First try exact UID tokens
        if let startIdx = lines.firstIndex(where: { $0.contains(startToken) }) {
            if let endIdx = lines[startIdx...].firstIndex(where: { $0.contains(endToken) }) {
                let coreStart = min(lines.count - 1, startIdx + 1)
                let coreEnd = max(coreStart, endIdx - 1)
                let before = startIdx > 0 ? lines[startIdx - 1] : nil
                let after = endIdx + 1 < lines.count ? lines[endIdx + 1] : nil
                let slice = Array(lines[coreStart ... coreEnd])
                return CoreRegion(startLine: coreStart, endLine: coreEnd, lines: slice, beforeLine: before, afterLine: after)
            }
        }
        // Fallback: first occurrence of prefixed anchor if UID missing
        if let startIdx = lines.firstIndex(where: { $0.contains(fallbackTokenPrefix) }) {
            // Find next matching end token using the detected UID if present
            let uid = extractUID(from: lines[startIdx], prefix: fallbackTokenPrefix)
            let endTok = endTokenContaining(uid: uid, originalEndToken: endToken, anchorTypePrefix: fallbackTokenPrefix)
            if let endIdx = lines[startIdx...].firstIndex(where: { $0.contains(endTok) || $0.contains("END") || $0.contains("end") }) {
                let coreStart = min(lines.count - 1, startIdx + 1)
                let coreEnd = max(coreStart, endIdx - 1)
                let before = startIdx > 0 ? lines[startIdx - 1] : nil
                let after = endIdx + 1 < lines.count ? lines[endIdx + 1] : nil
                let slice = Array(lines[coreStart ... coreEnd])
                return CoreRegion(startLine: coreStart, endLine: coreEnd, lines: slice, beforeLine: before, afterLine: after)
            }
        }
        return nil
    }

    static func extractUID(from line: String, prefix: String) -> String {
        // Example line contains "/* BLOCK START:ABCD */" or "// ANCHOR:start:UID"
        if let range = line.range(of: prefix) {
            let after = line[range.upperBound...]
            // Grab until next non-UID char
            var collected = ""
            for ch in after {
                if ch == " " || ch == "*" || ch == "/" || ch == "-" {
                    break
                }
                if ch == ":" {
                    continue
                }
                collected.append(ch)
            }
            // Trim trailing ornaments
            return collected.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    static func endTokenContaining(uid: String, originalEndToken: String, anchorTypePrefix: String) -> String {
        if uid.isEmpty {
            return originalEndToken
        }
        // Map the fallback prefix to the corresponding end marker form:
        // START_SWAP -> END_SWAP, ANCHOR:start: -> ANCHOR:end:
        if anchorTypePrefix.contains("START_SWAP") {
            return "/* END_SWAP:\(uid) */"
        }
        if anchorTypePrefix.contains("ANCHOR:start:") {
            return "// ANCHOR:end:\(uid)"
        }
        if anchorTypePrefix.contains("BLOCK START:") {
            return "/* BLOCK END:\(uid) */"
        }
        return originalEndToken
    }

    static func locateInsertGuardMarkerlessCore(in text: String, language: BenchmarkLanguage, functionName: String, insertAfterPattern: String) -> CoreRegion? {
        let lines = splitLinesPreservingTrailing(text)
        // Find the function signature
        let signatureIndex: Int? = switch language {
        case .ts:
            lines.firstIndex(where: { $0.contains("function \(functionName)(") })
        case .go:
            lines.firstIndex(where: { $0.contains("func \(functionName)(") })
        case .swift:
            lines.firstIndex(where: { $0.contains("func \(functionName)(") })
        }
        guard let sigIdx = signatureIndex else { return nil }

        // Find the insertAfterPattern line within the function
        var patternIdx: Int?
        var balance = 0
        var braceOpened = false
        var endIdx = sigIdx

        // First pass: find function bounds and pattern line
        search: for i in sigIdx ..< lines.count {
            let line = lines[i]
            for ch in line {
                if ch == "{" {
                    balance += 1
                    braceOpened = true
                } else if ch == "}" {
                    balance -= 1
                    if braceOpened, balance == 0 {
                        endIdx = i
                        break search
                    }
                }
            }
            // Look for pattern inside function body
            if braceOpened, line.contains(insertAfterPattern), patternIdx == nil {
                patternIdx = i
            }
        }

        guard let patIdx = patternIdx else { return nil }

        // Core region: 3-6 lines around the insertion point (after pattern line)
        // Include: pattern line, insertion point (pattern+1), and 1-2 lines after
        let coreStart = patIdx
        let coreEnd = min(endIdx - 1, patIdx + 3) // pattern + next 3 lines (or until function end)

        let before = coreStart - 1 >= 0 ? lines[coreStart - 1] : nil
        let after = coreEnd + 1 < lines.count ? lines[coreEnd + 1] : nil
        let slice = Array(lines[coreStart ... coreEnd])

        return CoreRegion(startLine: coreStart, endLine: coreEnd, lines: slice, beforeLine: before, afterLine: after)
    }

    static func locateFunctionCore(in text: String, language: BenchmarkLanguage, name: String) -> CoreRegion? {
        let lines = splitLinesPreservingTrailing(text)
        // Regex-like simple scanning; look for signature and braces
        let signatureIndex: Int? = switch language {
        case .ts:
            // match: [export] [async] function name(
            lines.firstIndex(where: { $0.contains("function \(name)(") })
        case .go:
            // match: func [receiver] name(
            lines.firstIndex(where: { $0.contains("func \(name)(") })
        case .swift:
            // match: [public|private|...] func name(
            lines.firstIndex(where: { $0.contains("func \(name)(") })
        }
        guard let sigIdx = signatureIndex else { return nil }
        // Find matching closing brace from the line with opening "{"
        // Move forward to find first "{" and then track balance
        var openLine = sigIdx
        var braceOpened = false
        var balance = 0
        var endIdx = sigIdx
        search: for i in sigIdx ..< lines.count {
            let line = lines[i]
            for ch in line {
                if ch == "{" {
                    balance += 1
                    braceOpened = true
                } else if ch == "}" {
                    balance -= 1
                    if braceOpened, balance == 0 {
                        endIdx = i
                        break search
                    }
                }
            }
            if !braceOpened, line.contains("{") {
                openLine = i
            }
        }
        // Core region: from line after the opening brace to the line before the closing brace
        // If opening brace on same line, core starts at next line
        let bodyStart = min(lines.count - 1, openLine + 1)
        let bodyEnd = max(bodyStart, endIdx - 1)
        let before = bodyStart - 1 >= 0 ? lines[bodyStart - 1] : nil
        let after = bodyEnd + 1 < lines.count ? lines[bodyEnd + 1] : nil
        let slice = Array(lines[bodyStart ... bodyEnd])
        return CoreRegion(startLine: bodyStart, endLine: bodyEnd, lines: slice, beforeLine: before, afterLine: after)
    }

    static func locateSwapArgsMarkerlessCore(in text: String, language: BenchmarkLanguage, functionName: String) -> CoreRegion? {
        // First, locate the function
        guard let funcCore = locateFunctionCore(in: text, language: language, name: functionName) else {
            return nil
        }

        // Now find use() calls within the function body
        let lines = splitLinesPreservingTrailing(text)
        let funcStart = funcCore.startLine
        let funcEnd = funcCore.endLine

        var useCallLines: [Int] = []
        for i in funcStart ... funcEnd {
            if i < lines.count, lines[i].contains("use(") {
                useCallLines.append(i)
            }
        }

        guard let first = useCallLines.first, let last = useCallLines.last else {
            // No use() calls found, return the whole function body as core
            return funcCore
        }

        // Return the contiguous region containing all use() calls
        let coreStart = first
        let coreEnd = last
        let before = coreStart - 1 >= 0 ? lines[coreStart - 1] : nil
        let after = coreEnd + 1 < lines.count ? lines[coreEnd + 1] : nil
        let slice = Array(lines[coreStart ... coreEnd])
        return CoreRegion(startLine: coreStart, endLine: coreEnd, lines: slice, beforeLine: before, afterLine: after)
    }

    static func locateIndexCoreTS(in text: String) -> CoreRegion? {
        let lines = splitLinesPreservingTrailing(text)
        guard let sigIdx = lines.firstIndex(where: { $0.contains("export default function index()") }) else { return nil }
        return locateBodyAfterSignature(in: lines, signatureIndex: sigIdx)
    }

    static func locateIndexCoreGo(in text: String) -> CoreRegion? {
        let lines = splitLinesPreservingTrailing(text)
        guard let sigIdx = lines.firstIndex(where: { $0.contains("func index()") }) else { return nil }
        return locateBodyAfterSignature(in: lines, signatureIndex: sigIdx)
    }

    static func locateIndexCoreSwift(in text: String) -> CoreRegion? {
        let lines = splitLinesPreservingTrailing(text)
        // Prefer public signature, fallback to func index()
        let sigIdx = lines.firstIndex(where: { $0.contains("public func index()") }) ?? lines.firstIndex(where: { $0.contains("func index()") })
        guard let idx = sigIdx else { return nil }
        return locateBodyAfterSignature(in: lines, signatureIndex: idx)
    }

    static func locateBodyAfterSignature(in lines: [String], signatureIndex: Int) -> CoreRegion? {
        var openLine = signatureIndex
        var braceOpened = false
        var balance = 0
        var endIdx = signatureIndex
        search: for i in signatureIndex ..< lines.count {
            let line = lines[i]
            for ch in line {
                if ch == "{" {
                    balance += 1
                    braceOpened = true
                } else if ch == "}" {
                    balance -= 1
                    if braceOpened, balance == 0 {
                        endIdx = i
                        break search
                    }
                }
            }
            if !braceOpened, line.contains("{") {
                openLine = i
            }
        }
        let bodyStart = min(lines.count - 1, openLine + 1)
        let bodyEnd = max(bodyStart, endIdx - 1)
        let before = bodyStart - 1 >= 0 ? lines[bodyStart - 1] : nil
        let after = bodyEnd + 1 < lines.count ? lines[bodyEnd + 1] : nil
        let slice = Array(lines[bodyStart ... bodyEnd])
        return CoreRegion(startLine: bodyStart, endLine: bodyEnd, lines: slice, beforeLine: before, afterLine: after)
    }

    static func locateRemoveXCore(in text: String, token: String) -> CoreRegion? {
        let lines = splitLinesPreservingTrailing(text)
        var indexes: [Int] = []
        for (i, line) in lines.enumerated() {
            if line.contains(token) {
                indexes.append(i)
            }
        }
        guard let first = indexes.first, let last = indexes.last else { return nil }
        // Expand one line above and one below to capture loop context if available
        let coreStart = max(0, first)
        let coreEnd = min(lines.count - 1, last)
        let before = coreStart - 1 >= 0 ? lines[coreStart - 1] : nil
        let after = coreEnd + 1 < lines.count ? lines[coreEnd + 1] : nil
        let slice = Array(lines[coreStart ... coreEnd])
        return CoreRegion(startLine: coreStart, endLine: coreEnd, lines: slice, beforeLine: before, afterLine: after)
    }

    static func locatePatchHunkCore(in text: String, patch: String) -> CoreRegion? {
        guard let hunks = SimpleUnifiedPatchApplier.parseHunks(patch), !hunks.isEmpty else { return nil }
        let lines = splitLinesPreservingTrailing(text)
        // Use the first hunk's old range as the "core" (tempting context)
        let h0 = hunks[0]
        let start0 = max(1, h0.oldStart) - 1
        let end0 = max(start0, start0 + max(0, h0.oldCount) - 1)
        let boundedStart = min(start0, max(0, lines.count - 1))
        let boundedEnd = min(end0, max(0, lines.count - 1))
        let before = boundedStart - 1 >= 0 ? lines[boundedStart - 1] : nil
        let after = boundedEnd + 1 < lines.count ? lines[boundedEnd + 1] : nil
        let slice = Array(lines[boundedStart ... boundedEnd])
        return CoreRegion(startLine: boundedStart, endLine: boundedEnd, lines: slice, beforeLine: before, afterLine: after)
    }

    static func uidForPath(
        task: BenchmarkTaskSpec,
        arrayKey: String,
        pathKey: String,
        uidKey: String,
        fallbackUidKey: String,
        path: String?
    ) -> String? {
        if let arr = task.params[arrayKey]?.arrayValue {
            // Prefer UID for the matching path entry
            if let p = path {
                for item in arr {
                    if let obj = item.objectValue, obj[pathKey]?.stringValue == p {
                        return obj[uidKey]?.stringValue
                    }
                }
            }
            // Fallback: first UID in the array
            for item in arr {
                if let uid = item.objectValue?[uidKey]?.stringValue {
                    return uid
                }
            }
        }
        // Fallback: top-level UID if present
        if let uid = task.params[fallbackUidKey]?.stringValue {
            return uid
        }
        return nil
    }
}

// MARK: - Small utilities

private extension DecoyPlanner {
    static func splitLinesPreservingTrailing(_ text: String) -> [String] {
        // Keep empty trailing line if present by avoiding omittingEmptySubsequences
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func leadingIndentation(of line: String) -> String {
        var indent = ""
        for ch in line {
            if ch == " " || ch == "\t" {
                indent.append(ch)
            } else {
                break
            }
        }
        return indent
    }

    static func lineCommentPrefix(for language: BenchmarkLanguage) -> String {
        // For TS, Go, and Swift we can safely use //
        "//"
    }
}
