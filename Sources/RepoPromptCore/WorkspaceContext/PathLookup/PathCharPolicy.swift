// File: RepoPrompt/Models/PathCharPolicy.swift
import Foundation

/// Centralized policy shared by canonicalization, cleaning, and early user input normalization.
///
/// - Allowed ASCII remains: [A–Z a–z 0–9 . _ - [ ] ( ) { } + ! # % @ /]
/// - We *fold* common lookalikes into their ASCII equivalents (e.g., EN DASH → '-')
package enum PathCharPolicy {
    @inline(__always)
    package static func isAllowedASCIIByte(_ b: UInt8) -> Bool {
        switch b {
        case 0x30 ... 0x39, // 0-9
             0x41 ... 0x5A, // A-Z
             0x61 ... 0x7A, // a-z
             0x2E, // .
             0x5F, // _
             0x2D, // -
             0x5B, 0x5D, // [ ]
             0x28, 0x29, // ( )
             0x7B, 0x7D, // { }
             0x2B, // +
             0x21, // !
             0x23, // #
             0x25, // %
             0x40, // @
             0x2F: // /
            true
        default:
            false
        }
    }

    @inline(__always)
    package static func toLowerASCII(_ b: UInt8) -> UInt8 {
        (0x41 ... 0x5A).contains(b) ? b &+ 0x20 : b
    }

    // MARK: - Drop invisible/format characters

    @inline(__always)
    package static func isZeroWidthOrFormat(_ sc: UnicodeScalar) -> Bool {
        switch sc.value {
        case 0x200B, // ZERO WIDTH SPACE
             0x200C, // ZERO WIDTH NON-JOINER
             0x200D, // ZERO WIDTH JOINER
             0x2060, // WORD JOINER
             0xFEFF, // ZERO WIDTH NO-BREAK SPACE (BOM)
             0x200E, // LRM (optional)
             0x200F: // RLM (optional)
            true
        default:
            false
        }
    }

    /// Emit folded ASCII for a single scalar (supports 1→N mappings).
    /// If no folding applies, appends the original scalar.
    @inline(__always)
    package static func emitFolded(_ sc: UnicodeScalar, into view: inout String.UnicodeScalarView) {
        let v = sc.value
        let hyphen = UnicodeScalar(0x2D)! // '-'
        let slash = UnicodeScalar(0x2F)! // '/'

        // Multi-length first (so we don't fall through)
        switch v {
        case 0x2E3B: // ⸻ THREE‑EM DASH → '---'
            view.append(hyphen)
            view.append(hyphen)
            view.append(hyphen)
            return
        case 0x2E3A: // ⸺ TWO‑EM DASH   → '--'
            view.append(hyphen)
            view.append(hyphen)
            return
        default:
            break
        }

        // Single-char folds
        switch v {
        // Dashes / hyphens → '-'
        case 0x2010, // ‐ hyphen
             0x2011, // ‑ non-breaking hyphen
             0x2012, // ‒ figure dash
             0x2013, // – en dash
             0x2014, // — em dash
             0x2015, // ― horizontal bar
             0x2043, // ⁃ hyphen bullet
             0x2212, // − minus
             0xFE63, // ﹣ small hyphen-minus
             0xFF0D: // － fullwidth hyphen-minus
            view.append(hyphen)
            return
        // Slashes → '/'
        case 0x2044, // ⁄ fraction slash
             0x2215, // ∕ division slash
             0xFF0F: // ／ fullwidth solidus
            view.append(slash)
            return
        // (macOS-only) Backslash/Yen handling removed
        // Fullwidth underscore/period/brackets/parens/braces/punct/@
        case 0xFF3F: view.append(UnicodeScalar(0x5F)!)
            return // '_'
        case 0xFF0E: view.append(UnicodeScalar(0x2E)!)
            return // '.'
        case 0xFF3B: view.append(UnicodeScalar(0x5B)!)
            return // '['
        case 0xFF3D: view.append(UnicodeScalar(0x5D)!)
            return // ']'
        case 0xFF08: view.append(UnicodeScalar(0x28)!)
            return // '('
        case 0xFF09: view.append(UnicodeScalar(0x29)!)
            return // ')'
        case 0xFF5B: view.append(UnicodeScalar(0x7B)!)
            return // '{'
        case 0xFF5D: view.append(UnicodeScalar(0x7D)!)
            return // '}'
        case 0xFF0B: view.append(UnicodeScalar(0x2B)!)
            return // '+'
        case 0xFF01: view.append(UnicodeScalar(0x21)!)
            return // '!'
        case 0xFF03: view.append(UnicodeScalar(0x23)!)
            return // '#'
        case 0xFF05: view.append(UnicodeScalar(0x25)!)
            return // '%'
        case 0xFF20: view.append(UnicodeScalar(0x40)!)
            return // '@'
        // Spaces & space-like → ASCII space
        case 0x00A0, // NBSP
             0x1680, // OGHAM SPACE MARK
             0x2000 ... 0x200A, // EN/EM/etc. spaces
             0x202F, // NARROW NBSP
             0x205F, // MEDIUM MATH SPACE
             0x3000: // IDEOGRAPHIC SPACE
            view.append(UnicodeScalar(0x20)!)
            return
        // Fullwidth ASCII digits/letters → ASCII
        case 0xFF10 ... 0xFF19: view.append(UnicodeScalar(0x30 + (v - 0xFF10))!)
            return
        case 0xFF21 ... 0xFF3A: view.append(UnicodeScalar(0x41 + (v - 0xFF21))!)
            return
        case 0xFF41 ... 0xFF5A: view.append(UnicodeScalar(0x61 + (v - 0xFF41))!)
            return
        default:
            break
        }

        // No folding
        view.append(sc)
    }

    /// Fold when non-ASCII is present; also normalize composition.
    package static func foldHomoglyphsIfNeeded(_ s: String) -> String {
        var hasNonASCII = false
        for b in s.utf8 where b >= 0x80 {
            hasNonASCII = true
            break
        }
        if !hasNonASCII { return s }

        let base = s.precomposedStringWithCanonicalMapping

        // Non-ASCII path: fold scalars in one pass
        var view = String.UnicodeScalarView()
        view.reserveCapacity(base.unicodeScalars.count)
        for sc in base.unicodeScalars {
            if isZeroWidthOrFormat(sc) { continue } // drop invisibles
            emitFolded(sc, into: &view) // handles multi-length (⸻ → ---)
        }
        return String(view)
    }
}
