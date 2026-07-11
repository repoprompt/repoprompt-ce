import Foundation

enum SimpleUnifiedPatchApplier {
    enum Op {
        case context(String)
        case minus(String)
        case plus(String)
    }

    struct Hunk {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let ops: [Op]
    }

    // Debug toggle and helper
    private static let debug: Bool = false
    private static func log(_ message: String) {
        if debug {
            print("[PatchApplier] \(message)")
        }
    }

    /// Apply a (possibly multi-hunk) unified diff.
    /// Supports '+', '-', and optional ' ' (context) lines.
    /// Tracks line count deltas across hunks and clamps insertions to EOF.
    static func apply(patch: String, to text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        let hadTrailingNewline = text.hasSuffix("\n")
        guard var hunks = parse(patch) else {
            log("parse failed: no hunks")
            return nil
        }

        // Enforce deterministic order: sort by oldStart (stable), tie-break on newStart
        hunks.sort { lhs, rhs in
            if lhs.oldStart == rhs.oldStart {
                return lhs.newStart < rhs.newStart
            }
            return lhs.oldStart < rhs.oldStart
        }
        if debug {
            let headers = hunks.enumerated().map { i, h in
                "#\(i){-\(h.oldStart),\(h.oldCount) +\(h.newStart),\(h.newCount) ops:\(h.ops.count)}"
            }.joined(separator: ", ")
            log("sorted hunks: [\(headers)]")
        }

        var delta = 0
        for (idx, hunk) in hunks.enumerated() {
            log("apply hunk[\(idx)] header: -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) (delta=\(delta))")
            guard apply(hunk: hunk, to: &lines, delta: &delta) else {
                log("FAILED applying hunk[\(idx)]")
                return nil
            }
            log("applied hunk[\(idx)] ok; new delta=\(delta)")
        }
        var output = lines.joined(separator: "\n")
        if hadTrailingNewline {
            output += "\n"
        }
        return output
    }

    // MARK: - Parser

    static func parseHunks(_ patch: String) -> [Hunk]? {
        parse(patch)
    }

    private static func parse(_ patch: String) -> [Hunk]? {
        let allLines = patch.components(separatedBy: "\n")
        var index = 0
        var hunks: [Hunk] = []
        while index < allLines.count {
            let line = allLines[index]
            if line.hasPrefix("@@") {
                guard let header = parseHeader(line) else {
                    log("parse header failed at line \(index): \(line)")
                    return nil
                }
                if debug {
                    log("found hunk header @@ -\(header.oldStart),\(header.oldCount) +\(header.newStart),\(header.newCount) @@")
                }
                index += 1
                var ops: [Op] = []
                while index < allLines.count {
                    let payload = allLines[index]
                    if payload.hasPrefix("@@") {
                        break
                    }
                    if payload.hasPrefix("---") || payload.hasPrefix("+++") {
                        index += 1
                        continue
                    }
                    if payload.hasPrefix("+") {
                        ops.append(.plus(String(payload.dropFirst())))
                    } else if payload.hasPrefix("-") {
                        ops.append(.minus(String(payload.dropFirst())))
                    } else if payload.hasPrefix(" ") {
                        ops.append(.context(String(payload.dropFirst())))
                    } else if payload.isEmpty {
                        // Treat empty line as context ONLY if it's not the trailing line of this hunk.
                        // If the next line starts a new hunk/header or we're at EOF, skip it to avoid spurious context at EOF.
                        let nextLine: String? = (index + 1 < allLines.count) ? allLines[index + 1] : nil
                        let nextStartsHeader = nextLine?.hasPrefix("@@") == true || nextLine?.hasPrefix("---") == true || nextLine?.hasPrefix("+++") == true
                        if let _ = nextLine, !nextStartsHeader {
                            ops.append(.context(""))
                        } else {
                            // skip trailing empty context at end of hunk/patch
                        }
                    }
                    index += 1
                }
                if debug {
                    log("collected ops: \(ops.count)")
                }
                hunks.append(Hunk(oldStart: header.oldStart, oldCount: header.oldCount, newStart: header.newStart, newCount: header.newCount, ops: ops))
            } else {
                index += 1
            }
        }
        if debug {
            log("parse finished: hunks=\(hunks.count)")
        }
        return hunks.isEmpty ? nil : hunks
    }

    private static func parseHeader(_ line: String) -> (oldStart: Int, oldCount: Int, newStart: Int, newCount: Int)? {
        guard line.hasPrefix("@@") else { return nil }
        let cleaned = line.replacingOccurrences(of: "@@", with: "")
        let parts = cleaned.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count >= 2 else { return nil }
        func parseSpan(_ span: Substring) -> (Int, Int)? {
            let raw = span.dropFirst()
            let components = raw.split(separator: ",")
            guard components.count == 2, let a = Int(components[0]), let b = Int(components[1]) else { return nil }
            return (a, b)
        }
        guard
            let (oldStart, oldCount) = parseSpan(parts[0]),
            let (newStart, newCount) = parseSpan(parts[1])
        else { return nil }
        return (oldStart, oldCount, newStart, newCount)
    }

    private static func apply(hunk: Hunk, to lines: inout [String], delta: inout Int) -> Bool {
        // First attempt: index based on oldStart plus accumulated delta
        let expectedIndex = clamp((hunk.oldStart - 1) + delta, 0 ... (lines.count))
        log(" attempt#1 at expectedIndex=\(expectedIndex)")
        if let res = applyOpsTransactional(ops: hunk.ops, lines: lines, index: expectedIndex, delta: delta), res.success {
            lines = res.lines
            delta = res.delta
            log(" attempt#1 succeeded")
            return true
        }
        log(" attempt#1 failed")

        // Second attempt: re-anchor using leading context lines near expected index
        let leadCtx = leadingContext(hunk.ops, maxCount: 3)
        if !leadCtx.isEmpty {
            log(" attempt#2 (leading-context) with context=\(leadCtx)")
            if let anchor = findAnchorIndex(lines: lines, around: expectedIndex, context: leadCtx, window: 12) {
                log("  context anchor found at \(anchor)")
                if let res = applyOpsTransactional(ops: hunk.ops, lines: lines, index: anchor, delta: delta), res.success {
                    lines = res.lines
                    delta = res.delta
                    log(" attempt#2 succeeded at anchor=\(anchor)")
                    return true
                } else {
                    log(" attempt#2 failed at anchor=\(anchor)")
                }
            } else {
                log("  context anchor not found near expectedIndex")
            }
        } else {
            log(" attempt#2 skipped (no leading context)")
        }

        // Third attempt: anchor using the first deletion line (more specific than blank context)
        if let minusVal = firstMinus(hunk.ops) {
            log(" attempt#3 (minus-anchor) for value='\(minusVal)'")
            if let minusIdx = findLineIndex(lines: lines, value: minusVal, around: expectedIndex, window: 48) {
                let startIdx = clamp(minusIdx - leadCtx.count, 0 ... lines.count)
                log("  minus anchor found at \(minusIdx); trying startIdx=\(startIdx)")
                if let res = applyOpsTransactional(ops: hunk.ops, lines: lines, index: startIdx, delta: delta), res.success {
                    lines = res.lines
                    delta = res.delta
                    log(" attempt#3 succeeded at startIdx=\(startIdx)")
                    return true
                } else {
                    log(" attempt#3 failed at startIdx=\(startIdx)")
                }
            } else {
                log("  minus anchor not found near expectedIndex")
            }
        } else {
            log(" attempt#3 skipped (no minus op)")
        }

        // Final attempt: use newStart as an alternate anchor if provided
        if hunk.newStart > 0 {
            let alt = clamp(hunk.newStart - 1, 0 ... (lines.count))
            log(" attempt#4 (newStart fallback) at altIndex=\(alt)")
            if let res = applyOpsTransactional(ops: hunk.ops, lines: lines, index: alt, delta: delta), res.success {
                lines = res.lines
                delta = res.delta
                log(" attempt#4 succeeded")
                return true
            }
            log(" attempt#4 failed")
        } else {
            log(" attempt#4 skipped (no newStart)")
        }
        return false
    }

    private static func applyOpsTransactional(ops: [Op], lines: [String], index: Int, delta: Int) -> (success: Bool, lines: [String], delta: Int)? {
        var newLines = lines
        var idx = index
        var d = delta

        for (opIdx, op) in ops.enumerated() {
            switch op {
            case let .context(value):
                guard idx < newLines.count, newLines[idx] == value else {
                    let actual = (idx < newLines.count) ? newLines[idx] : "<EOF>"
                    log("  mismatch at op#\(opIdx) CONTEXT: expected='\(value)' actual='\(actual)' at idx=\(idx)")
                    return (false, lines, delta)
                }
                idx += 1
            case let .minus(value):
                guard idx < newLines.count, newLines[idx] == value else {
                    let actual = (idx < newLines.count) ? newLines[idx] : "<EOF>"
                    log("  mismatch at op#\(opIdx) MINUS: expected='\(value)' actual='\(actual)' at idx=\(idx)")
                    return (false, lines, delta)
                }
                newLines.remove(at: idx)
                d -= 1
            case let .plus(value):
                let clamped = clamp(idx, 0 ... newLines.count)
                newLines.insert(value, at: clamped)
                idx = clamped + 1
                d += 1
            }
        }
        return (true, newLines, d)
    }

    private static func leadingContext(_ ops: [Op], maxCount: Int = 3) -> [String] {
        var out: [String] = []
        for op in ops {
            switch op {
            case let .context(value):
                out.append(value)
                if out.count >= maxCount {
                    return out
                }
            default:
                return out
            }
        }
        return out
    }

    private static func firstMinus(_ ops: [Op]) -> String? {
        for op in ops {
            if case let .minus(val) = op {
                return val
            }
        }
        return nil
    }

    private static func findAnchorIndex(lines: [String], around expected: Int, context: [String], window: Int = 12) -> Int? {
        guard !context.isEmpty else { return nil }
        let lower = max(0, expected - window)
        let upper = min(lines.count, expected + window)
        let maxStart = max(0, upper - context.count)
        var i = lower
        while i <= maxStart {
            var matched = true
            for (j, ctx) in context.enumerated() {
                if i + j >= lines.count || lines[i + j] != ctx {
                    matched = false
                    break
                }
            }
            if matched {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func findLineIndex(lines: [String], value: String, around expected: Int, window: Int = 48) -> Int? {
        let lower = max(0, expected - window)
        let upper = min(lines.count - 1, expected + window)
        if lower > upper {
            return nil
        }
        // Prefer proximity: search outward from expected index
        var left = expected
        var right = expected + 1
        while left >= lower || right <= upper {
            if left >= lower, left < lines.count, lines[left] == value {
                return left
            }
            if right <= upper, right < lines.count, lines[right] == value {
                return right
            }
            left -= 1
            right += 1
        }
        return nil
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        if value < range.lowerBound {
            return range.lowerBound
        }
        if value > range.upperBound {
            return range.upperBound
        }
        return value
    }
}

enum UnifiedPatchGrader {
    /// Compute how many hunks from a unified patch were successfully applied.
    /// Returns (applied: Int, total: Int) for partial credit calculation.
    static func coverage(baseline: String, final: String, patch: String) -> (applied: Int, total: Int) {
        guard let hunks = SimpleUnifiedPatchApplier.parseHunks(patch) else {
            return (0, 0)
        }

        let baselineLines = baseline.components(separatedBy: "\n")
        let finalLines = final.components(separatedBy: "\n")

        var appliedCount = 0
        for hunk in hunks {
            if isHunkApplied(hunk: hunk, baseline: baselineLines, final: finalLines) {
                appliedCount += 1
            }
        }

        return (appliedCount, hunks.count)
    }

    /// Check if a specific hunk appears to have been applied by verifying:
    /// - Minus lines are no longer present (or present in reduced quantity)
    /// - Plus lines are now present in the final text
    private static func isHunkApplied(hunk: SimpleUnifiedPatchApplier.Hunk, baseline: [String], final: [String]) -> Bool {
        var minusLines: [String] = []
        var plusLines: [String] = []

        for op in hunk.ops {
            switch op {
            case let .minus(line):
                minusLines.append(line)
            case let .plus(line):
                plusLines.append(line)
            case .context:
                break
            }
        }

        // If there are no changes in this hunk, consider it applied
        if minusLines.isEmpty && plusLines.isEmpty {
            return true
        }

        // Check minus lines: they should be removed or reduced in final
        var minusScore = 0.0
        for minusLine in minusLines {
            let baselineCount = baseline.count(where: { $0 == minusLine })
            let finalCount = final.count(where: { $0 == minusLine })
            if finalCount < baselineCount {
                minusScore += 1.0
            }
        }

        // Check plus lines: they should appear in final
        var plusScore = 0.0
        for plusLine in plusLines {
            if final.contains(plusLine) {
                plusScore += 1.0
            }
        }

        // Hunk is considered applied if both conditions are met reasonably well
        let minusOK = minusLines.isEmpty || (minusScore / Double(minusLines.count)) >= 0.5
        let plusOK = plusLines.isEmpty || (plusScore / Double(plusLines.count)) >= 0.5

        return minusOK && plusOK
    }
}
