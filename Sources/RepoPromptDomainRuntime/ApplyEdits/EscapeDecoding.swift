import Foundation

package enum EscapeDecodingMode: Equatable {
    case none
    case cStyle
    case smartHeuristic
}

package struct EscapeDecoder {
    package func decode(_ text: String, mode: EscapeDecodingMode) -> String {
        switch mode {
        case .none:
            return text
        case .cStyle:
            return text.unescaped()
        case .smartHeuristic:
            guard Self.shouldDecode(text) else { return text }
            return text.unescaped()
        }
    }

    private static func shouldDecode(_ text: String) -> Bool {
        if text.contains("\\n") || text.contains("\\t") || text.contains("\\r") {
            return true
        }
        if text.contains("\\\"") || text.contains("\\\\") {
            return true
        }
        return false
    }
}
