import CryptoKit
import Foundation

/// The caller's continuation note is opaque provider input. Validation never normalizes its body.
enum AgentSessionSelfCompactNotePolicy {
    static let fallbackMaximumUTF8Bytes = 65536
    static let maximumIdempotencyKeyUTF8Bytes = 200
    private static let digestDomain = "agent_self.compact/v1\n"

    enum Validation: Equatable {
        case valid(byteCount: Int)
        case empty
        case tooLong(byteCount: Int, maximum: Int)
        case invalidScalar
    }

    /// Ten percent of the model window at four bytes/token, without overflowing Int.
    static func noteLimit(windowTokens: Int?) -> (maximumUTF8Bytes: Int, basis: String) {
        guard let windowTokens, windowTokens > 0 else {
            return (fallbackMaximumUTF8Bytes, "unknown context window fallback")
        }
        return (
            (windowTokens / 5) * 2 + (windowTokens % 5) * 2 / 5,
            "10% of context window at 4 UTF-8 bytes/token"
        )
    }

    static func maximumNoteUTF8Bytes(windowTokens: Int?) -> Int {
        noteLimit(windowTokens: windowTokens).maximumUTF8Bytes
    }

    /// Byte limits govern admission only. Persisted notes use nil to retain content integrity
    /// checks without rejecting notes admitted under a larger or no-longer-known model window.
    static func validation(of note: String, maximum: Int?) -> Validation {
        let byteCount = note.utf8.count
        if let maximum, byteCount > maximum {
            return .tooLong(byteCount: byteCount, maximum: maximum)
        }
        guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        guard !containsDisallowedControl(in: note) else {
            return .invalidScalar
        }
        return .valid(byteCount: byteCount)
    }

    static func idempotencyKeyIsValid(_ key: String) -> Bool {
        !key.isEmpty
            && key.utf8.count <= maximumIdempotencyKeyUTF8Bytes
            && !containsDisallowedControl(in: key)
    }

    static func digest(of note: String) -> String {
        let hash = SHA256.hash(data: Data((digestDomain + note).utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func containsDisallowedControl(in text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            if value == 0x09 || value == 0x0A || value == 0x0D {
                return false
            }
            return value <= 0x1F || (0x7F ... 0x9F).contains(value)
        }
    }
}
