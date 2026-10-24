import Foundation

extension String {
    /// Creates a URL-friendly slug from the string
    /// - Parameters:
    ///   - maxLength: Maximum length of the slug (default: 24)
    ///   - separator: Character to use for separating words (default: "-")
    /// - Returns: A slugified version of the string
    package func slugify(maxLength: Int = 24, separator: String = "-") -> String {
        // Convert to lowercase
        let lowercased = lowercased()

        // Replace spaces and special characters with separator
        let alphanumericSet = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: separator))
        let components = lowercased.components(separatedBy: alphanumericSet.inverted)
        let filtered = components.filter { !$0.isEmpty }.joined(separator: separator)

        // Remove consecutive separators
        let regex = try? NSRegularExpression(pattern: "\(separator){2,}", options: [])
        let range = NSRange(location: 0, length: filtered.utf16.count)
        let cleaned = regex?.stringByReplacingMatches(in: filtered, options: [], range: range, withTemplate: separator) ?? filtered

        // Trim separators from ends
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: separator))

        // Truncate to max length
        if trimmed.count > maxLength {
            let endIndex = trimmed.index(trimmed.startIndex, offsetBy: maxLength)
            return String(trimmed[..<endIndex])
        }

        return trimmed.isEmpty ? "untitled" : trimmed
    }
}
