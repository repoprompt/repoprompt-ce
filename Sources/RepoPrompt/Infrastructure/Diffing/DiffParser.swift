// File: RepoPrompt/Models/DiffParserUtils.swift

import Foundation
import SwiftUI

/// Central on/off switch for every debug print in the diff-parser stack.
enum DebugFlags { static var parser = false }

/// Convenience wrapper so we can write `dprint("…")` instead of
/// `if DebugFlags.parser { print("…") }`.
@inline(__always)
func dprint(_ msg: @autoclosure () -> String) {
    #if DEBUG
        if DebugFlags.parser { print(msg()) }
    #endif
}

enum DiffParserUtils {
    private static func dbg(_ msg: @autoclosure () -> String) {
        dprint(msg())
    }

    // MARK: - Regex cache & helpers (perf)

    /// Small thread-safe cache for compiled regexes keyed by their pattern string.
    private static let _regexCache = NSCache<NSString, NSRegularExpression>()

    /// Returns a cached compiled regex for `pattern` or compiles & caches it.
    /// Default options match the heavy extractors' needs.
    private static func cachedRegex(
        _ pattern: String,
        options: NSRegularExpression.Options = [.dotMatchesLineSeparators, .caseInsensitive]
    ) -> NSRegularExpression? {
        let lookupState = EditFlowPerf.begin(EditFlowPerf.Stage.Parser.diffRegexCacheLookup)
        var cacheHit = false
        var status = "miss"
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Parser.diffRegexCacheLookup,
                lookupState,
                EditFlowPerf.Dimensions(status: status, cacheHit: cacheHit)
            )
        }

        let key = pattern as NSString
        if let rx = _regexCache.object(forKey: key) {
            cacheHit = true
            status = "hit"
            return rx
        }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            status = "compile_failed"
            return nil
        }
        _regexCache.setObject(compiled, forKey: key)
        return compiled
    }

    /// Replace all matches for a compiled regex.
    private static func replaceAll(_ s: String, using rx: NSRegularExpression, with template: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return rx.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }

    /// Returns the first match range (as `Range<String.Index>`) if any.
    private static func firstMatchRange(in s: String, using rx: NSRegularExpression) -> Range<String.Index>? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = rx.firstMatch(in: s, options: [], range: range) else { return nil }
        return Range(m.range, in: s)
    }

    static func escapeString(_ input: String) -> String {
        var result = input
        let escapePatterns = [
            "\"": "\\\"",
            "\\": "\\\\",
            "\n": "\\n",
            "\t": "\\t"
        ]

        for (unescaped, escaped) in escapePatterns {
            result = result.replacingOccurrences(of: unescaped, with: escaped)
        }

        return result
    }

    /// Optionally decode HTML entities first, then escape. Use this anywhere
    /// you suspect the input might contain encoded characters like &lt; or &quot;.
    static func decodeAndEscapeString(_ input: String) -> String {
        escapeString(input)
    }

    static var isDebugEnabled: Bool = false
    private static let backtickTags: Set<String> = ["start_selector", "end_selector", "content", "search"]

    // MARK: - Fence Seam and Sibling Boundary Cleanup

    /// Tags that indicate boundaries inside a <change> block.
    /// We only treat *these* as structural siblings (not arbitrary HTML/JSX).
    private static let siblingTags: [String] = [
        "description", "search", "content",
        "start_selector", "end_selector",
        "new", "change", "file"
    ]

    /// Removes fence-only lines and the common inline seam `===<tag>`.
    /// Conservative: only drops fence markers that sit at the start of a line
    /// and (optionally) run into a tag; never touches code `===` followed by text.
    static func sanitizeFenceSeams(_ s: String) -> String {
        var out = s

        // Drop a single leading newline that fences often inject
        if let rx = cachedRegex(#"^\r?\n"#, options: []), // anchor to start-of-string
           let r = firstMatchRange(in: out, using: rx)
        {
            out.removeSubrange(r)
        }

        // 1) Remove fence-only lines anywhere (global), including a final fence line.
        if let rx = cachedRegex(#"(?m)^[ \t]*=+[ \t]*\r?\n"#, options: []) {
            out = replaceAll(out, using: rx, with: "")
        }
        if let rx = cachedRegex(#"(?m)^[ \t]*=+[ \t]*$"#, options: []) {
            out = replaceAll(out, using: rx, with: "")
        }

        // 2) Remove inline seam "===<tag" at the start of ANY line (global),
        //    but only if <tag> is a known structural sibling.
        if let rx = cachedRegex(#"(?im)^[ \t]*=+[ \t]*(?=<(?:description|search|content|start_selector|end_selector|new|change|file)\b)"#, options: []) {
            out = replaceAll(out, using: rx, with: "")
        }

        return out
    }

    /// If we failed to find a clean closing tag in lenient mode, stop the payload
    /// at the first *sibling* tag that begins at the start of a line.
    static func trimAtSiblingBoundary(
        _ text: String,
        currentTag: String
    ) -> String {
        let siblings = siblingTags.filter { $0.caseInsensitiveCompare(currentTag) != .orderedSame }
        guard !siblings.isEmpty else { return text }
        let alternation = siblings.joined(separator: "|")
        let pattern = #"(?im)^[ \t]*<(?:"# + alternation + #")\b"#
        guard let rx = cachedRegex(pattern, options: []) else { return text }
        let full = NSRange(text.startIndex..., in: text)
        if let m = rx.firstMatch(in: text, options: [], range: full),
           let cut = Range(m.range, in: text)
        {
            return String(text[..<cut.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// If the entire payload is a single line wrapped by inline fences
    /// like `===  content  ====`, strip both sides while preserving the
    /// **left-side** inner spaces and dropping the right-side pre-fence spaces.
    /// This avoids touching real `===` operators in code.
    static func stripInlineFenceWrappersIfSingleLine(_ s: String) -> String {
        if s.contains("\n") || s.contains("\r") { return s }
        let pattern = #"^[ \t]*=+([^\r\n]*?)[ \t]*=+[ \t]*$"#
        guard let rx = cachedRegex(pattern, options: []) else { return s }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = rx.firstMatch(in: s, options: [], range: range), m.numberOfRanges >= 2 else { return s }
        return ns.substring(with: m.range(at: 1))
    }

    /// If the entire payload is a single line and starts with an inline fence,
    /// strip the leading `=` fence but **preserve** the inner whitespace right
    /// after the fence (e.g. "===    code" → "    code").
    static func stripLeadingInlineFenceIfSingleLinePreservingInnerSpace(_ s: String) -> String {
        if s.contains("\n") || s.contains("\r") { return s }
        let pattern = #"^[ \t]*=+([ \t]*)([^\r\n]*)$"#
        guard let rx = cachedRegex(pattern, options: []) else { return s }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = rx.firstMatch(in: s, options: [], range: range), m.numberOfRanges >= 3 else { return s }
        let innerWs = ns.substring(with: m.range(at: 1))
        let body = ns.substring(with: m.range(at: 2))
        return innerWs + body
    }

    /// If the entire payload is a single line and ends with an inline fence,
    /// strip the trailing fence (and any whitespace right before it).
    static func stripTrailingInlineFenceIfSingleLine(_ s: String) -> String {
        if s.contains("\n") || s.contains("\r") { return s }
        let pattern = #"^([^\r\n]*?)[ \t]*=+[ \t]*$"#
        guard let rx = cachedRegex(pattern, options: []) else { return s }
        let ns = s as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = rx.firstMatch(in: s, options: [], range: range), m.numberOfRanges >= 2 else { return s }
        return ns.substring(with: m.range(at: 1))
    }

    /// Consistent, defensive cleanup for both strict and lenient captures.
    /// • Removes single-line inline wrappers (=== ... ===) safely
    /// • If only one side remains (leading or trailing), strip that too
    ///   while preserving inner left whitespace
    /// • Removes fence-only lines and inline seams (===<tag)
    /// • Trims at the first sibling boundary that starts at line-begin
    static func postProcessPayload(_ payload: String, forTag tag: String) -> String {
        // 1) Single-line full wrapper (=== ... ===)
        var out = stripInlineFenceWrappersIfSingleLine(payload)
        // 2) If only one side remained, strip the residue conservatively
        out = stripLeadingInlineFenceIfSingleLinePreservingInnerSpace(out)
        out = stripTrailingInlineFenceIfSingleLine(out)
        // 3) Remove fence-only lines and seam markers
        out = sanitizeFenceSeams(out)
        // 4) Stop at sibling boundary if a sibling tag starts on a new line
        out = trimAtSiblingBoundary(out, currentTag: tag)
        return out
    }

    /// Primary content extraction.
    /// - Parameters:
    ///   - input: The raw text containing the fenced content.
    ///   - tag: The tag name within <tag>...</tag>.
    ///   - flexible: If `true`, tries more lenient patterns that allow partial or missing end-tags.
    /// - Returns: The extracted content if found, otherwise `nil`.
    static func extractContent(
        from input: String,
        tag: String,
        flexible: Bool = false
    ) -> String? {
        // Tags that rely on === fences
        if backtickTags.contains(tag) {
            // ----------------------------------------------------------------------
            // We now attach metadata (`isLenient`) to each regex so we can decide
            // later whether aggressive clean-up (orphan-fence removal) is safe.
            // ----------------------------------------------------------------------
            typealias Pattern = (name: String, regex: String, isLenient: Bool)

            let bodyAfterFence = "([^\\n]*\\n[\\s\\S]*?)"

            // ---------------- STRICT ----------------
            let strictPatterns: [Pattern] = [
                (
                    "Fence-pair + </tag>",
                    "<\(tag)>\\s*(={3,})" + bodyAfterFence + "\\n\\s*\\1\\s*</\(tag)>",
                    false
                ),
                //  ⬇️  ALLOWS MULTI-LINE BODY UNTIL THE CLOSING FENCE – even if that
                //     fence sits on the *same* line as the final code character.
                (
                    "Fence-pair + </tag> (same line, multi-line body)",
                    "<\(tag)>\\s*(={3,})([\\s\\S]*?)\\1\\s*</\(tag)>",
                    false
                ),
                (
                    "Fence-pair + </change>",
                    "<\(tag)>\\s*(={3,})" + bodyAfterFence + "\\n\\s*\\1\\s*</change>",
                    false
                ),
                (
                    "Fence-pair + </file>",
                    "<\(tag)>\\s*(={3,})" + bodyAfterFence + "\\n\\s*\\1\\s*</file>",
                    false
                ),
                // ⚠️ allow optional newline in front of the closing fence
                (
                    "Fence (closing optional)",
                    "<\(tag)>\\s*(={3,})" + bodyAfterFence +
                        "(?:\\n?\\s*\\1\\s*)?(?:</\(tag)>|</change>|</file>)",
                    false
                ),
                (
                    "Closing fence only",
                    "<\(tag)>\\s*([\\s\\S]*?)\\n?\\s*(?:={3,})\\s*</\(tag)>",
                    false
                ),
                (
                    "Plain pattern (strict)",
                    "<\(tag)>\\s*([\\s\\S]*?)\\s*(?:</\(tag)>|</change>|</file>)",
                    false
                )
            ]

            // ── FLEXIBLE patterns ─────────────────────────────────────────────
            let flexiblePatterns: [Pattern] = [
                (
                    "Strict flexible ===",
                    "<\(tag)>\\s*(={3,})" + bodyAfterFence +
                        "\\n?\\s*\\1\\s*(?:</\(tag)>|$)",
                    true
                ), // ← NOT lenient
                //  ⬇️  same-line version with multi-line body support
                (
                    "Same-line flexible ===",
                    "<\(tag)>\\s*(={3,})([\\s\\S]*?)\\1\\s*(?:</\(tag)>|$)",
                    true
                ),
                (
                    "Matching === flexible",
                    "<\(tag)>\\s*(={3,})" + bodyAfterFence +
                        "\\n?\\s*\\1\\s*(?:</\(tag)>|$)",
                    true
                ),
                // The genuinely forgiving patterns ↓
                (
                    "Lenient === flexible",
                    "<\(tag)>\\s*={3,}" + bodyAfterFence +
                        "\\n?\\s*={3,}\\s*(?:</\(tag)>|$)",
                    true
                ),
                (
                    "Tag content flexible (possible ===)",
                    "<\(tag)>\\s*(?:={3,}[^\\n]*\\n)?([\\s\\S]*?)(?:\\n?\\s*={3,}\\s*)?(?:</\(tag)>|$)",
                    true
                ),
                (
                    "Most lenient flexible ===",
                    "<\(tag)[^>]*>\\s*(?:={3,}[^\\n]*\\n)?([\\s\\S]*)",
                    true
                ),
                (
                    "Plain pattern (flexible)",
                    "<\(tag)\\s*>([\\s\\S]*?)</\(tag)>",
                    true
                )
            ]

            let patterns = flexible ? flexiblePatterns : strictPatterns

            dprint("📐 extractContent for tag '<\(tag)>' - flexible=\(flexible)")
            dprint("   Trying \(patterns.count) patterns")

            for pat in patterns {
                // ➊ Try the current regex
                dprint("   → Trying pattern '\(pat.name)' (lenient=\(pat.isLenient))")
                guard var result = extractWithPattern(pat.regex, from: input) else {
                    continue
                }

                // ------------------------------------------------------------------
                // ➋ Clean-up phase – differs for “lenient/flexible” vs. “strict”
                // ------------------------------------------------------------------
                if pat.isLenient {
                    // ----------------------------------------------------------
                    //  LENIENT  (flexible == true)
                    // ----------------------------------------------------------

                    // • drop *leading* fence-only lines:  “=== …\n”
                    while let orphan = result.range(
                        of: #"^\s*=+\s*\r?\n"#,
                        options: [.regularExpression]
                    ) {
                        result.removeSubrange(orphan)
                    }

                    // • drop blank line(s) that may follow those orphans
                    while let blank = result.range(
                        of: #"^[ \t]*\r?\n"#,
                        options: [.regularExpression]
                    ) {
                        result.removeSubrange(blank)
                    }

                    // • drop *trailing* fence-only lines:  “\n===”
                    while let trailingFence = result.range(
                        of: #"\r?\n\s*=+\s*$"#,
                        options: [.regularExpression]
                    ) {
                        result.removeSubrange(trailingFence)
                    }

                    // • remove a single stray leading newline if still present
                    if let leadingNL = result.range(
                        of: #"^\r?\n"#,
                        options: [.regularExpression]
                    ) {
                        result.removeSubrange(leadingNL)
                    }

                } else {
                    // ----------------------------------------------------------
                    //  STRICT  (flexible == false)
                    // ----------------------------------------------------------

                    // • strip a single newline injected by the opening fence
                    if let leadingNL = result.range(
                        of: #"^\r?\n"#,
                        options: [.regularExpression]
                    ) {
                        result.removeSubrange(leadingNL)
                    }

                    // • remove any *leading* fence-only line (rare, but happens
                    //   if the diff starts on the next line)
                    while let leadingFence = result.range(
                        of: #"^\s*=+\s*\r?\n"#,
                        options: [.regularExpression]
                    ) {
                        result.removeSubrange(leadingFence)
                    }

                    // • remove fence-only line(s) at the end  "\n==="
                    while let trailingFence = result.range(
                        of: #"\r?\n\s*=+\s*$"#,
                        options: [.regularExpression]
                    ) {
                        result.removeSubrange(trailingFence)
                    }

                    // NOTE: Removed broad inline fence stripper that was removing
                    // legitimate === operators in code. The global sanitizer now
                    // handles real fences and seams safely.
                }

                // ------------------------------------------------------------------
                // ➌ If we get here, the capture is usable – return it.
                // ------------------------------------------------------------------
                dbg("📌  <\(tag)> matched '\(pat.name)'  flexible=\(flexible)")
                return postProcessPayload(result, forTag: tag)
            }

            // ➍ No pattern matched cleanly
            return nil
        }

        // ----------------------------------------------------------------------
        //  Fallback for non-fence tags  <title> … </title>
        // ----------------------------------------------------------------------
        let basic = "<\(tag)\\s*>([\\s\\S]*?)</\(tag)>"
        if let result = extractWithPattern(basic, from: input) {
            return postProcessPayload(result, forTag: tag)
        }
        return nil
    }

    /// A small helper to compile and run a regex, returning the last capture group if matched.
    private static func extractWithPattern(
        _ pattern: String,
        from input: String
    ) -> String? {
        dprint("🔍 extractWithPattern called with pattern: \(pattern)")
        dprint("   Input length: \(input.count) characters")

        guard let regex = cachedRegex(pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else {
            if isDebugEnabled {
                print("Error: Invalid regex pattern: \(pattern)")
            }
            dprint("❌ Failed to compile regex pattern")
            return nil
        }
        let range = NSRange(input.startIndex..., in: input)

        guard let match = regex.firstMatch(in: input, options: [], range: range) else {
            dprint("❌ No match found for pattern: \(pattern)")
            return nil
        }

        dprint("✅ Match found! Number of capture groups: \(match.numberOfRanges - 1)")

        // Usually the relevant content is in capture group #1.
        // If there are multiple groups, we grab the last one,
        // because some patterns store content in the second or third group.
        let contentGroupIndex = max(1, match.numberOfRanges - 1)
        let captureGroupRange = match.range(at: contentGroupIndex)

        dprint("   Using capture group index: \(contentGroupIndex)")
        dprint("   Capture range: location=\(captureGroupRange.location), length=\(captureGroupRange.length)")

        guard let swiftRange = Range(captureGroupRange, in: input) else {
            if isDebugEnabled {
                print("Error: Unable to extract content for pattern: \(pattern)")
            }
            dprint("❌ Unable to convert NSRange to Swift Range")
            return nil
        }

        let result = String(input[swiftRange])
        dprint("   Extracted content length: \(result.count) characters")
        return result
    }

    /// Splits a `<file>` body into raw `<change>` blocks, tolerating:
    ///   • missing `</change>`
    ///   • nested or subsequent `<change>` tags
    ///   • missing final `</file>`
    ///
    /// Each returned block *starts* with `<change …>` and ends **before**
    /// the next `<change>` opener (if earlier than a matching `</change>`),
    /// otherwise it ends just after the first encountered closing delimiter
    /// (`</change>` or `</file>`).  If none exist it extends to EOF.
    static func sliceIntoChangeBlocks(_ fileBody: String) -> [String] {
        var blocks: [String] = []

        dprint("🔪 sliceIntoChangeBlocks called")
        dprint("   File body length: \(fileBody.count) characters")

        let openPattern = "<change\\b[^>]*>"
        let closePattern = "</change>"

        dprint("   Using regex patterns:")
        dprint("     - Open: \(openPattern)")
        dprint("     - Close: \(closePattern)")

        let openRegex = try! NSRegularExpression(
            pattern: openPattern,
            options: [.caseInsensitive]
        )
        let closeRegex = try! NSRegularExpression(
            pattern: closePattern,
            options: [.caseInsensitive]
        )

        let nsBody = fileBody as NSString
        var cursor = 0

        dprint("   Starting search for <change> blocks...")

        while let open =
            openRegex.firstMatch(
                in: fileBody,
                options: [],
                range: NSRange(
                    location: cursor,
                    length: nsBody.length - cursor
                )
            )
        {
            let openStart = open.range.location
            let searchFrom = open.range.upperBound

            dprint("   Found <change> at location \(openStart)")

            // Next opener (if any) after the current one
            let nextOpen = openRegex.firstMatch(
                in: fileBody,
                options: [],
                range: NSRange(
                    location: searchFrom,
                    length: nsBody.length - searchFrom
                )
            )

            // Earliest legitimate terminator candidates
            let closeChange = closeRegex.firstMatch(
                in: fileBody,
                options: [],
                range: NSRange(
                    location: searchFrom,
                    length: nsBody.length - searchFrom
                )
            )

            let closeFileRange = nsBody.range(
                of: "</file>",
                options: .caseInsensitive,
                range: NSRange(
                    location: searchFrom,
                    length: nsBody.length - searchFrom
                )
            )
            let closeFile = (closeFileRange.location != NSNotFound)
                ? closeFileRange
                : nil

            // Determine end-of-block index
            var endIdx = nsBody.length // default → EOF

            func minLocation(_ r: NSRange?) -> Int? {
                guard let r else { return nil }
                return r.location
            }

            // 1⃣ prefer matching </change> if it comes before next opener
            if let close = closeChange,
               nextOpen == nil || close.range.location < nextOpen!.range.location
            {
                endIdx = close.range.location + close.range.length
            }
            // 2⃣ otherwise stop at next opener
            else if let next = nextOpen {
                endIdx = next.range.location
            }
            // 3⃣ otherwise stop at </file> if present
            else if let f = closeFile {
                endIdx = f.location
            }

            let blockRange = NSRange(
                location: openStart,
                length: endIdx - openStart
            )
            blocks.append(nsBody.substring(with: blockRange))

            cursor = endIdx
        }

        dbg("🔀  Sliced \(blocks.count) <change> block(s)")
        return blocks
    }

    /// Pulls out every `<file …>` … `</file>` block (or to EOF if the closer
    /// is missing) and returns a tuple with the raw path, action and body.
    /// • Handles normal quotes (") and “smart” quotes.
    static func extractFileEntries(from input: String)
        -> [(path: String, action: String, body: String)]
    {
        typealias Entry = (path: String, action: String, body: String)
        var results: [Entry] = []

        let ns = input as NSString
        let length = ns.length

        let openRE = try! NSRegularExpression(
            pattern: "<file\\b[^>]*>",
            options: [.caseInsensitive]
        )
        let closeRE = try! NSRegularExpression(
            pattern: "</file>",
            options: [.caseInsensitive]
        )

        var cursor = 0
        while cursor < length {
            // Find the next opener
            guard let open = openRE.firstMatch(
                in: input,
                options: [],
                range: NSRange(location: cursor, length: length - cursor)
            ) else {
                break
            }

            let openRange = open.range
            let openEnd = openRange.upperBound
            let openTag = ns.substring(with: openRange)

            /// Parse attributes (normal & smart quotes)
            func attr(_ name: String) -> String? {
                let p = "\(name)\\s*=\\s*[\"\u{201C}\u{201D}]([^\"\u{201C}\u{201D}]+)[\"\u{201C}\u{201D}]"
                guard let r = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
                      let m = r.firstMatch(
                          in: openTag,
                          options: [],
                          range: NSRange(location: 0, length: (openTag as NSString).length)
                      ),
                      let gr = Range(m.range(at: 1), in: openTag)
                else { return nil }
                return String(openTag[gr])
            }

            guard let path = attr("path"), let action = attr("action") else {
                // Move cursor forward to avoid infinite loop on malformed opener
                cursor = openEnd
                continue
            }

            // NEW: self-closing <file ... /> → empty body
            let selfClosing = openTag.range(of: #"/\s*>$"#, options: [.regularExpression]) != nil
            if selfClosing {
                results.append((path: path, action: action, body: ""))
                cursor = openEnd
                continue
            }

            // Find matching </file> with nesting depth; nested <file> openers
            // are only used for balancing and are NOT added as separate entries.
            var depth = 1
            var scanPos = openEnd
            var bodyEnd = length // default → EOF if unclosed

            while scanPos < length {
                let nextOpen = openRE.firstMatch(
                    in: input,
                    options: [],
                    range: NSRange(location: scanPos, length: length - scanPos)
                )
                let nextClose = closeRE.firstMatch(
                    in: input,
                    options: [],
                    range: NSRange(location: scanPos, length: length - scanPos)
                )

                // Earliest next tag
                let useOpen: Bool
                let tagRange: NSRange?
                switch (nextOpen, nextClose) {
                case let (o?, c?):
                    useOpen = o.range.location < c.range.location
                    tagRange = useOpen ? o.range : c.range
                case (let o?, nil):
                    useOpen = true
                    tagRange = o.range
                case (nil, let c?):
                    useOpen = false
                    tagRange = c.range
                default:
                    tagRange = nil
                    useOpen = false
                }

                guard let tr = tagRange else { break }

                if useOpen {
                    depth += 1
                    scanPos = tr.upperBound
                } else {
                    depth -= 1
                    if depth == 0 {
                        bodyEnd = tr.location // exclude the closer
                        scanPos = tr.upperBound
                        break
                    }
                    scanPos = tr.upperBound
                }
            }

            let bodyRange = NSRange(location: openEnd, length: max(0, bodyEnd - openEnd))
            let body = ns.substring(with: bodyRange)

            results.append((path: path, action: action, body: body))
            dbg("🗂️  <file> '\(path)' action='\(action)' bodyLen=\(body.count)")

            // Resume search after the outer closer (or opener if unclosed)
            cursor = max(scanPos, openEnd)
        }

        return results
    }

    static func packAsXML(path: String, description: String, content: String) -> String {
        """
        <file path="\(path)" action="modify">
        <change>
        <description>\(description)</description>
        <content>
        ===
        \(content)
        ===
        </content>
        </change>
        </file>
        """
    }

    static func packAsXML(path: String, description: String, search: String, replacement: String) -> String {
        """
        <file path="\(path)" action="modify">
        <change>
        <description>\(description)</description>
        <search>
        ===
        \(search)
        ===
        </search>
        <content>
        ===
        \(replacement)
        ===
        </content>
        </change>
        </file>
        """
    }

    private static let ENABLE_CHANGE_PARSING_LOGS = false // Control logging output

    static func parseChanges(
        _ content: String,
        filePath: String,
        fileAction: FileAction,
        lineEnding: String,
        fileExists: Bool,
        usesSpaces: Bool,
        originalFileContent: String
    ) -> [Change] {
        var changes: [Change] = []
        var warnings: [String] = []
        let parseState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Parser.diffParseChanges,
            EditFlowPerf.Dimensions(
                status: fileExists ? "file_exists" : "file_missing",
                inputBytes: content.utf8.count,
                fileAction: fileAction.rawValue
            )
        )
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Parser.diffParseChanges,
                parseState,
                EditFlowPerf.Dimensions(
                    status: fileExists ? "file_exists" : "file_missing",
                    inputBytes: content.utf8.count,
                    changeCount: changes.count,
                    warningCount: warnings.count,
                    fileAction: fileAction.rawValue
                )
            )
        }

        if ENABLE_CHANGE_PARSING_LOGS {
            print("\nParsing changes for file: \(filePath)")
        }

        // NEW: slice the file body into <change> blocks in a lenient way
        let changeBlocks = DiffParserUtils.sliceIntoChangeBlocks(content)

        for (index, changeRaw) in changeBlocks.enumerated() {
            // ——— description ———
            let description =
                DiffParserUtils.extractContent(
                    from: changeRaw,
                    tag: "description"
                ) ??
                "" // description is optional but warned
            if description.isEmpty {
                warnings.append("Missing <description> in change #\(index + 1) – \(filePath)")
            }

            // ——— content (prefer strict; always post-process) ———
            var changeContentText: String?
            if let strict = DiffParserUtils.extractContent(from: changeRaw, tag: "content", flexible: false) {
                // Already post-processed by extractContent
                changeContentText = strict
            } else if let lenient = DiffParserUtils.extractLenientContent(from: changeRaw, tag: "content") {
                print("Leniently parsing change #\(index + 1) – \(filePath)")
                // Already post-processed by extractLenientContent
                changeContentText = lenient
            }

            // Decide change type from fileAction
            let changeType: ChangeType = switch fileAction {
            case .delete: .remove
            case .modify, .rewrite:
                fileExists ? .modify : .add
            default: .add
            }

            /*

             // Optional selectors/search
             let startSelector = DiffParserUtils
             .extractContent(from: changeRaw, tag: "start_selector")
             .flatMap { DiffParserUtils.splitContentToLines($0, usesSpaces) }

             let endSelector   = DiffParserUtils
             .extractContent(from: changeRaw, tag: "end_selector")
             .flatMap { DiffParserUtils.splitContentToLines($0, usesSpaces) }
             */

            // ——— search (optional; same policy) ———
            var searchRaw: String?
            if let strictSearch = DiffParserUtils.extractContent(from: changeRaw, tag: "search", flexible: false) {
                searchRaw = strictSearch
            } else if let lenientSearch = DiffParserUtils.extractLenientContent(from: changeRaw, tag: "search") {
                searchRaw = lenientSearch
            }
            let searchBlock = searchRaw.flatMap { DiffParserUtils.splitContentToLines($0, usesSpaces) }

            if changeType == .remove {
                changeContentText = originalFileContent
            }

            // Decode main content into encoded lines
            let decodedLines = changeContentText
                .map { DiffParserUtils.splitContentToLines($0, usesSpaces) }

            let newChange = Change(
                id: UUID(),
                type: changeType,
                summary: description.trimmingCharacters(in: .whitespacesAndNewlines),
                isSelected: fileExists || changeType == .add,
                content: decodedLines,
                startSelector: nil,
                endSelector: nil,
                searchBlock: searchBlock
            )

            changes.append(newChange)
        }

        // ---------------------------------------------------------------------
        // Fallback: if no <change> tags at all, treat whole file as one change
        if changes.isEmpty,
           fileAction == .rewrite || fileAction == .modify || fileAction == .create,
           let entire = DiffParserUtils.extractLenientContent(from: content, tag: "content")
        {
            let decoded = DiffParserUtils.splitContentToLines(entire, usesSpaces)
            let fallback = Change(
                id: UUID(),
                type: fileAction == .create ? .add
                    : (fileExists ? .modify : .add),
                summary: fileAction == .create
                    ? "Initial content for new file"
                    : "Rewrite entire file",
                isSelected: true,
                content: decoded,
                startSelector: nil,
                endSelector: nil,
                searchBlock: nil
            )
            changes.append(fallback)
        }

        if ENABLE_CHANGE_PARSING_LOGS, !warnings.isEmpty {
            print("Warnings while parsing \(filePath):")
            warnings.forEach { print("  - \($0)") }
        }
        return changes
    }

    /// Leniently extracts the *first* `<tag>` … `</tag>` payload, but if the
    /// explicit close-tag is missing we fall back to `</change>`, `</file>`,
    /// or end-of-string.  Returns `nil` if no `<tag>` was found at all.
    static func extractLenientContent(
        from input: String,
        tag: String
    ) -> String? {
        guard let openRange =
            input.range(
                of: "<\(tag)\\b[^>]*>",
                options: [.regularExpression, .caseInsensitive]
            )
        else { return nil }

        // Content starts right after the matched opening tag.
        let contentStart = openRange.upperBound
        // Try normal close tag first
        if let close =
            input.range(
                of: "</\(tag)>",
                options: [.caseInsensitive],
                range: contentStart ..< input.endIndex
            )
        {
            let raw = String(input[contentStart ..< close.lowerBound])
            // NEW: defensively clean seams and stop at sibling boundaries
            return postProcessPayload(raw, forTag: tag)
        }

        // Fallback close candidates
        let fallbacks = ["</change>", "</file"]
        if let fbClose =
            fallbacks
                .compactMap({ input.range(
                    of: $0,
                    options: [.caseInsensitive],
                    range: contentStart ..< input.endIndex
                ) })
                .sorted(by: { $0.lowerBound < $1.lowerBound })
                .first
        {
            let raw = String(input[contentStart ..< fbClose.lowerBound])
            // NEW: defensively clean seams and stop at sibling boundaries
            return postProcessPayload(raw, forTag: tag)
        }

        // No close tag at all – take remainder
        let raw = String(input[contentStart...])
        // NEW: defensively clean seams and stop at sibling boundaries
        return postProcessPayload(raw, forTag: tag)
    }

    static func splitContentToLines(_ content: String, _ usesSpaces: Bool) -> [String] {
        dprint("📝 splitContentToLines called with usesSpaces=\(usesSpaces)")
        dprint("   Content length: \(content.count) characters")

        // Always process content as raw lines and encode indentation ourselves
        // (No longer detecting pre-encoded indentation markers)
        dprint("   Processing raw lines")
        let (lines, _) = String.splitContentPreservingLineEndings(content)
        dprint("   Split into \(lines.count) raw lines")
        let decodedLines = lines.map { $0.decodingHTMLEntities() }

        let encodedLines = decodedLines.map { line in
            if !usesSpaces {
                String.encodeIndentationAsTabs(line)
            } else {
                String.encodeIndentationAsSpaces(line)
            }
        }

        dprint("   Returning \(encodedLines.count) encoded lines")
        return encodedLines
    }

    // LEGACY: Old version that detected pre-encoded indentation markers
    // Kept for reference but no longer used
    private static func splitContentToLinesLegacy(_ content: String, _ usesSpaces: Bool) -> [String] {
        let indentationPattern = "(<(s|t)(\\d+)>)(\\s*)(.*?)(?=(?:<s\\d+>|<t\\d+>)|$)"
        let indentationRegex = try! NSRegularExpression(pattern: indentationPattern, options: [.dotMatchesLineSeparators])

        let fullRange = NSRange(content.startIndex..., in: content)
        let hasIndentationEncoding = indentationRegex.firstMatch(in: content, options: [], range: fullRange) != nil

        if !hasIndentationEncoding {
            let (lines, _) = String.splitContentPreservingLineEndings(content)
            let decodedLines = lines.map { $0.decodingHTMLEntities() }

            return decodedLines.map { line in
                if !usesSpaces {
                    String.encodeIndentationAsTabs(line)
                } else {
                    String.encodeIndentationAsSpaces(line)
                }
            }
        }

        // Branch ② – already-encoded lines (existing <s#>/<t#> markers)
        var lines: [String] = []

        let nsContent = content as NSString
        let matches = indentationRegex.matches(in: content, options: [], range: NSRange(location: 0, length: nsContent.length))

        for match in matches {
            guard match.numberOfRanges == 6 else { continue }

            let fullTag = nsContent.substring(with: match.range(at: 1))
            let indentTypeChar = usesSpaces ? "s" : "t"
            let indentLevelStr = nsContent.substring(with: match.range(at: 3))
            let extraWhitespace = nsContent.substring(with: match.range(at: 4))
            let lineContent = nsContent.substring(with: match.range(at: 5))

            var indentLevel = (Int(indentLevelStr) ?? 0)
            if indentLevel != 0 && indentTypeChar != "s" {
                indentLevel /= 4
            }

            let newIndentLevel = extraWhitespace.isEmpty
                ? indentLevel
                : (indentTypeChar == "s" ? indentLevel + 4 : indentLevel + 1)
            let newTag = "<\(indentTypeChar)\(newIndentLevel)>"

            if lineContent.isEmpty {
                lines.append(fullTag)
            } else {
                let contentLines = lineContent.components(separatedBy: .newlines)
                for (index, line) in contentLines.enumerated() {
                    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                    if index == 0 || !trimmedLine.isEmpty {
                        lines.append(newTag + trimmedLine)
                    }
                }
            }
        }

        return lines
    }

    static func removeThinkTag(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<think>") else { return input }
        // Look for the closing tag
        guard let closingRange = trimmed.range(of: "</think>") else { return input }
        let indexAfterClosing = closingRange.upperBound
        // Return the remaining string after the </think> tag
        return String(trimmed[indexAfterClosing...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes leading `<![CDATA[` and trailing `]]>` if present.
    static func stripCDATA(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<![CDATA["), trimmed.hasSuffix("]]>") {
            // Drop `<![CDATA[` (9 chars) and `]]>` (3 chars) from the ends
            let startIndex = trimmed.index(trimmed.startIndex, offsetBy: 9)
            let endIndex = trimmed.index(trimmed.endIndex, offsetBy: -3)
            return String(trimmed[startIndex ..< endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}

class DiffParser {
    private let fileManager: WorkspaceFilesViewModel

    private func dbg(_ msg: @autoclosure () -> String) {
        dprint(msg())
    }

    init(fileManager: WorkspaceFilesViewModel) {
        self.fileManager = fileManager
    }

    /// Merges two actions for the same file into a single effective action
    /// following these rules:
    ///   delete + create  -> rewrite
    ///   create + delete  -> rewrite
    ///   any + rewrite    -> rewrite
    ///   create + modify  -> create (can't modify a file that doesn't exist yet)
    ///   otherwise        -> keeps the newestAction
    private func mergedAction(_ previous: FileAction, _ newest: FileAction) -> FileAction {
        if (previous == .delete && newest == .create) ||
            (previous == .create && newest == .delete) { return .rewrite }
        if previous == .rewrite || newest == .rewrite { return .rewrite }
        // Special case: create + modify should stay as create
        // (you can't modify a file that will be created)
        if previous == .create, newest == .modify { return .create }
        return newest // fallback: latest wins
    }

    /// Converts a raw diff-XML string into an array of `ParsedFile`.
    /// The heavy lifting is delegated to small helpers so the core loop
    /// is straightforward and easy to unit-test.
    func parse(_ rawInput: String) async throws -> [ParsedFile] {
        var parsedFileMap: [String: ParsedFile] = [:]
        var errors: [ParserError] = []

        // 1️⃣  Pre-processing that strips <think>, CDATA, smart quotes, etc.
        let thinkFree = DiffParserUtils.removeThinkTag(from: rawInput)
        let stripped = DiffParserUtils
            .stripCDATA(thinkFree)
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
        let input = stripped.decodingHTMLEntities()

        let fileEntries = DiffParserUtils.extractFileEntries(from: input)
        dbg("🔍  Found \(fileEntries.count) <file> entrie(s)")

        for (filePathRaw, actionRaw, fileBody) in fileEntries {
            dbg("🚩  Parsing <file> path='\(filePathRaw)' action='\(actionRaw)'")

            // ---- Normalise path / action --------------------------------------
            let filePath = DiffParserUtils.decodeAndEscapeString(filePathRaw)
            let actionString = DiffParserUtils.decodeAndEscapeString(actionRaw)

            // ---- Handle <file action="rename"> up front -----------------------
            if actionString.lowercased() == "rename" {
                await handleRename(
                    oldPath: filePath,
                    fileBody: fileBody,
                    parsedFileMap: &parsedFileMap,
                    errors: &errors
                )
                continue
            }

            // ---- Validate action string ---------------------------------------
            guard let originalAction = FileAction(rawValue: actionString) else {
                errors.append(.invalidFileAction(filePath: filePath, action: actionString))
                continue
            }

            // ---- Resolve via FileSystemService (if any) -----------------------
            var canonicalPath = filePath // default = as-is
            var canBeLoaded = false
            var loadedFile = fileBody // default = diff payload
            let isCreate = originalAction == .create
            let isDelete = originalAction == .delete

            // Extract file-level <content> lazily; only when needed (create/rewrite)
            // Extract file-level <content> lazily; only when needed (create/rewrite)
            let resolveMainContent: () -> String = {
                if let s = DiffParserUtils.extractContent(from: fileBody, tag: "content", flexible: false) {
                    // extractContent already post-processes
                    return s
                }
                if let s = DiffParserUtils.extractLenientContent(from: fileBody, tag: "content") {
                    // extractLenientContent already post-processes
                    return s
                }
                return ""
            }

            if let location = await fileManager.pathLocation(filePath, exactMatchOnly: isCreate || isDelete) {
                // Fetch the would-be *absolute* path for the service's correction
                let candidateCanonical = URL(fileURLWithPath: location.rootPath)
                    .appendingPathComponent(location.correctedPath)
                    .path

                // -----------------------------------------------------------------
                // SAME-COMPONENT test for CREATE actions
                // • If the user supplied a *relative* path, compare it with the
                //   service’s *relative* correction (`svc.correctedPath`).
                // • If the user supplied an *absolute* path, compare it with the
                //   *absolute* canonical path returned by the service.
                // -----------------------------------------------------------------
                var useCandidate = true
                if isCreate {
                    let origCount = filePath
                        .split(separator: "/")
                        .count(where: { !$0.isEmpty })

                    let candCount: Int = if filePath.hasPrefix("/") { // absolute input
                        candidateCanonical
                            .split(separator: "/")
                            .count(where: { !$0.isEmpty })

                    } else { // relative input
                        location.correctedPath
                            .split(separator: "/")
                            .count(where: { !$0.isEmpty })
                    }

                    useCandidate = (origCount == candCount)
                }

                if useCandidate {
                    canonicalPath = candidateCanonical

                    // Get latest content from FileViewModel
                    if let file = await fileManager.findFile(
                        atPath: location.correctedPath,
                        rootIdentifier: location.rootIdentifier
                    ) {
                        canBeLoaded = true
                        // latestContent is an async getter
                        loadedFile = await file.latestContent ?? ""
                    } else {
                        // File doesn't exist in hierarchy yet
                        canBeLoaded = false
                    }
                }
            }

            // ---- Convert create → rewrite if we discover an existing file -----
            var effectiveAction = originalAction
            if isCreate, canBeLoaded {
                effectiveAction = .rewrite
            }
            if !canBeLoaded, effectiveAction == .create {
                // "create" file truly doesn't exist yet, treat diff body as new
                canBeLoaded = true
            }

            // ---- Handle modify on non-existent file (error but continue) -----
            if originalAction == .modify, !canBeLoaded {
                errors.append(.fileNotFoundForModify(filePath: canonicalPath))
            }

            // ---- Convert rewrite → add if file doesn't exist -----
            if originalAction == .rewrite, !canBeLoaded {
                effectiveAction = .create
                canBeLoaded = true // Treat as new file
            }

            // ---- Guard against multiple rewrite actions for the same file ----
            if effectiveAction == .rewrite,
               let existingRewrite = parsedFileMap[canonicalPath],
               existingRewrite.action == .rewrite
            {
                dbg("⚠️  Skipping additional rewrite for '\(canonicalPath)' – only the first rewrite per file is processed")
                continue
            }

            // ---- Detect indentation style & line ending -----------------------
            let (lines, detectedLE) = String.splitContentPreservingLineEndings(loadedFile)
            let (indentType, _) = String.detectIndentationTypeFromLines(lines)
            let usesSpaces = indentType == "s"

            // ---- Parse <change> blocks (or fallback) --------------------------
            let changes = DiffParserUtils.parseChanges(
                fileBody,
                filePath: canonicalPath,
                fileAction: effectiveAction,
                lineEnding: detectedLE,
                fileExists: canBeLoaded,
                usesSpaces: usesSpaces,
                originalFileContent: loadedFile // ← NEW
            )

            /// Join content lines from parsed changes for non-create/rewrite files
            func contentFromChanges(_ ch: [Change]) -> String {
                ch.compactMap { $0.content?.joined(separator: "\n") }.joined(separator: "\n")
            }

            // ---- Aggregate results -------------------------------------------
            if let existing = parsedFileMap[canonicalPath] {
                // ❶ Combine change arrays
                var combinedChanges = existing.changes + changes

                // ❷ If we are about to turn this into a rewrite, strip any full-file
                //    "remove" change that originated from the preliminary *delete*.
                let combinedAction = mergedAction(existing.action, effectiveAction)
                if combinedAction == .rewrite {
                    combinedChanges.removeAll(where: { $0.type == .remove })
                    // Optionally: convert remaining `.add` changes to `.modify`
                    combinedChanges = combinedChanges.map { change in
                        guard change.type == .add else { return change }
                        var c = change
                        c.type = .modify
                        return c
                    }
                }

                // ❸ Re-build ParsedFile because `action` is a `let`
                // For create actions, always use the new content to ensure we have the latest content
                let updatedFileContent: String
                if combinedAction == .create || combinedAction == .rewrite {
                    updatedFileContent = resolveMainContent()
                } else {
                    // Keep existing content if present; otherwise derive from combined changes
                    let derived = contentFromChanges(combinedChanges)
                    updatedFileContent = existing.fileContent.isEmpty ? derived : existing.fileContent
                }

                let updated = ParsedFile(
                    fileName: existing.fileName,
                    changes: combinedChanges,
                    fileContent: updatedFileContent,
                    canBeLoaded: existing.canBeLoaded || canBeLoaded,
                    action: combinedAction,
                    lineEnding: existing.lineEnding.isEmpty ? detectedLE : existing.lineEnding
                )
                parsedFileMap[canonicalPath] = updated
            } else {
                let initialFileContent: String = if effectiveAction == .create || effectiveAction == .rewrite {
                    resolveMainContent()
                } else {
                    contentFromChanges(changes)
                }

                parsedFileMap[canonicalPath] = ParsedFile(
                    fileName: canonicalPath,
                    changes: changes,
                    fileContent: initialFileContent,
                    canBeLoaded: canBeLoaded,
                    action: effectiveAction,
                    lineEnding: detectedLE
                )
            }

            if changes.isEmpty, effectiveAction != .delete {
                errors.append(.noChangesInFile(filePath: canonicalPath))
            }
        }

        // Return even if `errors` not empty – caller can inspect them.
        return Array(parsedFileMap.values)
    }

    ///  MARK: ––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––––
    /// Special-case handler that converts a `<file action="rename">`
    /// block into a *delete* (old path) + *create* (new path) pair.
    private func handleRename(
        oldPath: String,
        fileBody: String,
        parsedFileMap: inout [String: ParsedFile],
        errors: inout [ParserError]
    ) async {
        dbg("🔀  RENAME detected  '\(oldPath)'  →  (new path parsed below)")

        // 1. Extract the `<new path="…">`
        let newRegex = try! NSRegularExpression(
            pattern: "<new\\s+path\\s*=\\s*[\"“”]([^\"“”]+)[\"“”]\\s*/?>",
            options: [.caseInsensitive]
        )

        guard
            let m = newRegex.firstMatch(
                in: fileBody,
                options: [],
                range: NSRange(location: 0, length: fileBody.utf16.count)
            ),
            let newRange = Range(m.range(at: 1), in: fileBody)
        else {
            errors.append(.missingTag(tag: "new"))
            return
        }

        let newPathRaw = DiffParserUtils.decodeAndEscapeString(String(fileBody[newRange]))
        let newPath = newPathRaw

        // -----------------------------------------------------------------
        // Load the old file's content (best-effort – not fatal if missing)
        var loadedOld = ""
        var canonicalOld = oldPath
        var lineEnding = "\n"
        var usesSpaces = true

        if let locationOld = await fileManager.pathLocation(oldPath, exactMatchOnly: true) {
            canonicalOld = URL(fileURLWithPath: locationOld.rootPath)
                .appendingPathComponent(locationOld.correctedPath)
                .path

            // Use FileViewModel to load old file content
            if let file = await fileManager.findFile(
                atPath: locationOld.correctedPath,
                rootIdentifier: locationOld.rootIdentifier
            ) {
                if let data = await file.latestContent {
                    loadedOld = data
                }
            }
        }

        let (lns, le) = String.splitContentPreservingLineEndings(loadedOld)
        lineEnding = le
        let (indent, _) = String.detectIndentationTypeFromLines(lns)
        usesSpaces = indent == "s"
        let encodedLines = DiffParserUtils.splitContentToLines(loadedOld, usesSpaces)

        // -----------------------------------------------------------------
        // 2. Build the *delete* entry — now with an explicit Change block
        //    that flags every original line for removal.
        let deleteChange = Change(
            id: UUID(),
            type: .remove,
            summary: "Rename from \(oldPath) to \(newPath)",
            isSelected: true,
            content: encodedLines, // every old line becomes a “-” diff line
            startSelector: nil,
            endSelector: nil,
            searchBlock: nil
        )

        let deleteFile = ParsedFile(
            fileName: canonicalOld,
            changes: [deleteChange], // <-- previously “[]”
            fileContent: loadedOld,
            canBeLoaded: !loadedOld.isEmpty,
            action: .delete,
            lineEnding: lineEnding
        )
        parsedFileMap[canonicalOld] = deleteFile

        // -----------------------------------------------------------------
        // 3. Build the *create* entry  (single "add everything" change)
        let createChange = Change(
            id: UUID(),
            type: .add,
            summary: "Rename from \(oldPath) to \(newPath)",
            isSelected: true,
            content: encodedLines,
            startSelector: nil,
            endSelector: nil,
            searchBlock: nil
        )

        // Resolve a canonical path if the destination folder already exists
        let createFile = ParsedFile(
            fileName: newPath,
            changes: [createChange],
            fileContent: loadedOld,
            canBeLoaded: false, // new file does not exist yet
            action: .create,
            lineEnding: lineEnding
        )
        parsedFileMap[newPath] = createFile
    }
}

// MARK: - Supporting Models and Enums

struct FileContentRequest {
    let filePath: String
    let startLine: Int
    let endLine: Int?

    func printDetails() {
        print("File Content Request:")
        print("  File Path: \(filePath)")
        print("  Start Line: \(startLine)")
        print("  End Line: \(endLine ?? -1)")
        print("")
    }
}

struct ParsedFile: Identifiable, Equatable {
    let id = UUID()
    let fileName: String
    var changes: [Change]
    let fileContent: String
    var canBeLoaded: Bool
    let action: FileAction
    let lineEnding: String

    static func == (lhs: ParsedFile, rhs: ParsedFile) -> Bool {
        lhs.id == rhs.id
    }

    func printLightDetails() {
        print("Parsed File:")
        print("  ID: \(id)")
        print("  File Name: \(fileName)")
        print("  Can Be Loaded: \(canBeLoaded)")
        print("  Action: \(action.rawValue)")
        print("  Line Ending: \(lineEnding)")
        print("  Changes count: \(changes.count)")
        print("")
    }

    func printDetails() {
        print("Parsed File:")
        print("  ID: \(id)")
        print("  File Name: \(fileName)")
        print("  Can Be Loaded: \(canBeLoaded)")
        print("  Action: \(action.rawValue)")
        print("  Line Ending: \(lineEnding)")
        print("  Changes:")
        for change in changes {
            change.printDetails()
        }
        print("  File Content:")
        print(fileContent)
        print("")
    }
}

struct Change: Identifiable {
    let id: UUID
    var type: ChangeType
    var summary: String
    var isSelected: Bool
    var content: [String]?
    var startSelector: [String]?
    var endSelector: [String]?
    var searchBlock: [String]?

    func printDetails() {
        print("    Change:")
        print("      ID: \(id)")
        print("      Type: \(type.rawValue)")
        print("      Summary: \(summary)")
        print("      Is Selected: \(isSelected)")
        if let content {
            print("      Content:")
            for line in content {
                print("        \(line)")
            }
        }
        if let startSelector {
            print("      Start Selector:")
            for line in startSelector {
                print("        \(line)")
            }
        }
        if let endSelector {
            print("      End Selector:")
            for line in endSelector {
                print("        \(line)")
            }
        }
        if let searchBlock {
            print("      Search Block:")
            for line in searchBlock {
                print("        \(line)")
            }
        }
        print("")
    }
}

enum FileAction: String {
    case modify
    case create
    case delete
    case rewrite

    func printDetails() {
        print("File Action: \(rawValue)")
    }
}

enum ChangeType: String {
    case add
    case modify
    case remove

    var displayString: String {
        switch self {
        case .add: "Added"
        case .modify: "Modified"
        case .remove: "Removed"
        }
    }

    var color: Color {
        switch self {
        case .add: .green
        case .modify: .yellow
        case .remove: .red
        }
    }

    func printDetails() {
        print("Change Type:")
        print("  Raw Value: \(rawValue)")
        print("  Display String: \(displayString)")
        print("  Color: \(color)")
        print("")
    }
}

enum ParserError: Error {
    case noValidChangesFound(errors: [ParserError])
    case missingDescription(filePath: String)
    case missingContent(filePath: String)
    case noChangesInFile(filePath: String)
    case invalidFileAction(filePath: String, action: String)
    case missingTag(tag: String)
    case parsingError(filePath: String, error: Error)
    case changeParsingError(filePath: String, error: Error)
    case generalParsingError(error: Error)
    case invalidContentRange(tag: String)
    case fileNotFoundForModify(filePath: String)
}
