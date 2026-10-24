import Foundation

/// Name-only opt-in policy. No wildcard matching or credential-value inspection.
package enum ProviderEnvironmentNames {
    package static func parsed(_ text: String) -> [String]? {
        normalized(text.split { $0 == "," || $0.isWhitespace }.map(String.init))
    }

    package static func normalized(_ names: [String]) -> [String]? {
        guard names.allSatisfy(isValid) else { return nil }
        return Set(names).sorted()
    }

    private static func isValid(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        func isLetter(_ byte: UInt8) -> Bool {
            (65 ... 90).contains(byte) || (97 ... 122).contains(byte) || byte == 95
        }
        guard let first = bytes.first, isLetter(first) else { return false }
        return bytes.dropFirst().allSatisfy { isLetter($0) || (48 ... 57).contains($0) }
    }
}
