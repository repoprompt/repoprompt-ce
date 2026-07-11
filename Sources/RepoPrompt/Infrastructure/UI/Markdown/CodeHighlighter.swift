//
//  CodeHighlighter.swift
//  RepoPrompt
//
//  Re-written 2025-06-10 to remove UI stalls by:
//
//  • Compiling regex patterns **once** instead of on every keystroke.
//  • Skipping syntax-highlighting for very large or HTML-dense blocks.
//

import AppKit
import Foundation

/// Centralised, lightweight regex-based syntax highlighter.
/// The rules are **language-agnostic** and cover the 80 % case for most
/// C-style languages, Python, Swift, SQL, HTML/XML and friends.
enum CodeHighlighter {
    /// Ceiling controls for regex work; strings beyond these fall back to plain text.
    private static let softMaxLength = 12000
    private static let htmlSoftMaxLength = 6000
    private static let chunkSizeUTF16 = 4096
    private static let chunkOverlapUTF16 = 256
    private static let maxMatchesPerChunkPerRule = 12000

    /// Apply colour attributes to `attributed` according to the rules below.
    ///
    /// ‑ Parameters:
    ///   ‑ attributed: The *mutable* attributed string that will receive colour.
    ///   ‑ code:       The plain-text source (must match `attributed.string`).
    static func applyHighlighting(
        to attributed: NSMutableAttributedString,
        code: String
    ) {
        let length = code.utf16.count
        guard length > 0 else { return }

        let htmlDense = isHtmlDense(code)
        let ceiling = htmlDense ? htmlSoftMaxLength : softMaxLength
        guard length <= ceiling else { return }

        let dark = isDarkMode()
        let chunks = chunkRanges(for: code)
        guard !chunks.isEmpty else { return }

        // Iterate through our single, lazily-compiled rule set.
        for (rx, colour) in Cached.compiled(darkMode: dark) {
            for chunk in chunks {
                enumerateMatchesSafely(rx, in: code, range: chunk) { matchRange in
                    attributed.addAttribute(.foregroundColor, value: colour, range: matchRange)
                }
            }
        }
    }

    // MARK: ‑ Internal cache -----------------------------------------------------

    /// Holds lazily-compiled regexes.  The array is rebuilt only when the user
    /// toggles dark/light mode (because colours change).
    private enum Cached {
        /// Light-mode colours follow the same ordering as `rawSpecs`.
        private static var lightCache: [(NSRegularExpression, NSColor)] = []

        /// Dark-mode colours follow the same ordering as `rawSpecs`.
        private static var darkCache: [(NSRegularExpression, NSColor)] = []

        /// Return the correct cache; build it the first time it is requested.
        static func compiled(darkMode: Bool) -> [(NSRegularExpression, NSColor)] {
            if darkMode {
                if darkCache.isEmpty {
                    darkCache = buildCache(dark: true)
                }
                return darkCache
            } else {
                if lightCache.isEmpty {
                    lightCache = buildCache(dark: false)
                }
                return lightCache
            }
        }

        /// Build either the dark- or light-mode cache.
        private static func buildCache(dark: Bool) -> [(NSRegularExpression, NSColor)] {
            rawSpecs(dark).compactMap { pattern, colour in
                guard let rx = try? NSRegularExpression(
                    pattern: pattern,
                    options: [.anchorsMatchLines]
                )
                else { return nil }
                return (rx, colour)
            }
        }

        /// All patterns paired with their colour for the requested appearance.
        private static func rawSpecs(_ dark: Bool) -> [(String, NSColor)] {
            typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)
            func c(_ d: RGB, _ l: RGB) -> NSColor {
                let rgb = dark ? d : l
                return NSColor(calibratedRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
            }

            return [
                // MARK: Keywords & control flow

                (
                    #"\b(func|function|def|class|struct|enum|interface|trait|impl|namespace|package|module|import|from|export|require|include|use|pub|private|protected|public|static|final|const|let|var|val|mut|ref|async|await|yield|throw|throws|try|catch|finally|except|raise|assert|with|as|is|inout|of|typeof|instanceof|new|delete|this|self|super|override|virtual|abstract|sealed|open|internal)\b"#,
                    c((0.7, 0.5, 1.0), (0.4, 0.0, 0.6))
                ), // purple

                (
                    #"\b(if|else|elif|switch|case|default|match|when|for|while|do|loop|foreach|break|continue|return|goto|guard|defer)\b"#,
                    c((0.9, 0.5, 0.7), (0.7, 0.0, 0.3))
                ), // magenta

                // MARK: Types

                (
                    #"\b(int|integer|float|double|decimal|bool|boolean|char|string|String|str|void|any|unknown|never|undefined|null|nil|None|object|Object|Array|List|Dict|Map|Set|Vector|Option|Result|Future|Promise|Observable|byte|short|long|size_t|uint|int8|int16|int32|int64|uint8|uint16|uint32|uint64|f32|f64|i8|i16|i32|i64|u8|u16|u32|u64|usize|isize)\b"#,
                    c((0.4, 0.8, 0.9), (0.0, 0.45, 0.6))
                ), // teal

                (
                    #"\b(type|typedef|typealias|extends|implements|inherits|satisfies|associatedtype|protocol|concept)\b"#,
                    c((0.4, 0.8, 0.9), (0.0, 0.45, 0.6))
                ), // teal

                // MARK: Strings / regex / templates

                (
                    #"(\"\"\"[\s\S]{0,8000}?\"\"\")|('''[\s\S]{0,8000}?''')"#,
                    c((0.8, 0.6, 0.4), (0.6, 0.2, 0.0))
                ), // orange

                (
                    #"\"(?:[^\"\\]|\\.)*\""#,
                    c((0.8, 0.6, 0.4), (0.6, 0.2, 0.0))
                ), // orange

                (
                    #"'(?:[^'\\]|\\.)*'"#,
                    c((0.8, 0.6, 0.4), (0.6, 0.2, 0.0))
                ), // orange

                (
                    #"`(?:[^`\\]|\\.)*`"#,
                    c((0.8, 0.6, 0.4), (0.6, 0.2, 0.0))
                ), // orange

                (
                    #"\/(?:[^\/\\\n]|\\.)+\/[gimsuvy]*"#,
                    c((0.9, 0.6, 0.3), (0.7, 0.3, 0.0))
                ), // dark orange

                // MARK: Comments

                (
                    #"(\/\/|#|--|%).*$"#,
                    c((0.5, 0.7, 0.5), (0.3, 0.5, 0.3))
                ), // green

                (
                    #"\/\*[\s\S]*?\*\/"#,
                    c((0.5, 0.7, 0.5), (0.3, 0.5, 0.3))
                ), // green

                (
                    #"<!--[\s\S]*?-->"#,
                    c((0.5, 0.7, 0.5), (0.3, 0.5, 0.3))
                ), // green

                // MARK: Literals & numbers

                (
                    #"\b(true|false|True|False|yes|no|YES|NO|on|off|ON|OFF)\b"#,
                    c((1.0, 0.7, 0.3), (0.7, 0.4, 0.0))
                ), // gold

                (
                    #"\b(null|nil|None|undefined|NaN|Infinity)\b"#,
                    c((1.0, 0.7, 0.3), (0.7, 0.4, 0.0))
                ), // gold

                (
                    #"\b0[xX][0-9a-fA-F]+\b"#,
                    c((0.6, 0.8, 1.0), (0.0, 0.3, 0.7))
                ), // blue

                (
                    #"\b0[bB][01]+\b"#,
                    c((0.6, 0.8, 1.0), (0.0, 0.3, 0.7))
                ), // blue

                (
                    #"\b\d+\.\d+([eE][+-]?\d+)?[fFdD]?\b"#,
                    c((0.6, 0.8, 1.0), (0.0, 0.3, 0.7))
                ), // blue

                (
                    #"\b\d+\b"#,
                    c((0.6, 0.8, 1.0), (0.0, 0.3, 0.7))
                ), // blue

                // MARK: Functions

                (
                    #"\b(func|function|def|fn|sub|proc|method)\s+([a-zA-Z_]\w*)"#,
                    c((1.0, 0.8, 0.4), (0.6, 0.4, 0.0))
                ), // amber

                (
                    #"\b([a-zA-Z_]\w*)\s*(?=\()"#,
                    c((1.0, 0.9, 0.6), (0.5, 0.35, 0.0))
                ), // light amber

                // MARK: Decorators / annotations

                (
                    #"(@\w+|#\[[\w\s,=]+\]|\[\w+\])"#,
                    c((0.8, 0.7, 1.0), (0.45, 0.25, 0.7))
                ), // violet

                // MARK: Pre-processor / UPPER_CASE

                (
                    #"^\s*#\s*\w+"#,
                    c((0.9, 0.6, 0.9), (0.6, 0.0, 0.6))
                ), // fuchsia

                (
                    #"\b[A-Z_][A-Z0-9_]+\b"#,
                    c((0.7, 0.9, 0.7), (0.0, 0.5, 0.0))
                ), // forest green

                // MARK: SQL

                (
                    #"\b(SELECT|FROM|WHERE|JOIN|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|TABLE|INDEX|VIEW|DATABASE|INTO|VALUES|SET|AND|OR|NOT|NULL|LIKE|BETWEEN|ORDER BY|GROUP BY|HAVING|LIMIT|OFFSET|UNION|DISTINCT|AS)\b"#,
                    c((0.6, 0.7, 1.0), (0.1, 0.2, 0.7))
                ), // royal blue

                // MARK: HTML/XML

                (
                    #"</?[A-Za-z][A-Za-z0-9:_-]*"#,
                    c((0.7, 0.8, 0.9), (0.15, 0.35, 0.55))
                ), // steel blue

                (
                    #"\b[A-Za-z_:][A-Za-z0-9:._-]*(?=\s*=)"#,
                    c((0.7, 0.8, 0.9), (0.15, 0.35, 0.55))
                ), // steel blue

                (
                    #"\"(?:[^\"\\]|\\.)*\""#,
                    c((0.7, 0.8, 0.9), (0.15, 0.35, 0.55))
                ), // steel blue

                (
                    #"'(?:[^'\\]|\\.)*'"#,
                    c((0.7, 0.8, 0.9), (0.15, 0.35, 0.55))
                ) // steel blue
            ]
        }
    }

    // MARK: ‑ Helpers ------------------------------------------------------------

    private static func isHtmlDense(_ s: String) -> Bool {
        let sampleLimit = 20000
        var examined = 0
        var angleCount = 0
        for scalar in s.unicodeScalars {
            if examined >= sampleLimit {
                break
            }
            examined &+= 1
            if scalar.value == 60 || scalar.value == 62 {
                angleCount &+= 1
            }
        }
        guard examined > 0 else { return false }
        return (Double(angleCount) / Double(examined)) > 0.015
    }

    private static func chunkRanges(for s: String) -> [NSRange] {
        let len = s.utf16.count
        guard len > 0 else { return [] }

        var ranges: [NSRange] = []
        var start = 0
        while start < len {
            let endExclusive = min(start + chunkSizeUTF16, len)
            ranges.append(NSRange(location: start, length: endExclusive - start))

            if endExclusive == len {
                break
            }
            start = max(endExclusive - chunkOverlapUTF16, start + 1)
        }
        return ranges
    }

    private static func enumerateMatchesSafely(
        _ rx: NSRegularExpression,
        in code: String,
        range: NSRange,
        apply: (NSRange) -> Void
    ) {
        var count = 0
        rx.enumerateMatches(in: code, options: [], range: range) { match, _, stop in
            guard let r = match?.range else { return }
            apply(r)
            count &+= 1
            if count >= maxMatchesPerChunkPerRule {
                stop.pointee = true
            }
        }
    }

    private static func isDarkMode() -> Bool {
        // NSApp appearance must be queried on main thread.
        if Thread.isMainThread {
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        } else {
            DispatchQueue.main.sync {
                NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            }
        }
    }
}
