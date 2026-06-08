import AppKit
import Foundation

/// Render-time policy for turning bare prose URLs into clickable links.
///
/// Keep this disabled by default. Call sites that render trusted prose can opt in;
/// code, tool output, diffs, logs, JSON, and other non-prose surfaces should not.
enum BareURLLinkificationPolicy: Equatable {
    case disabled
    case httpHTTPSOnly

    var isEnabled: Bool {
        self != .disabled
    }
}

enum BareURLLinkifier {
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func containsHTTPHTTPSURLSignal(in text: String) -> Bool {
        text.range(of: "http://", options: [.caseInsensitive]) != nil ||
            text.range(of: "https://", options: [.caseInsensitive]) != nil
    }

    private static let leadingBoundaryScalars: Set<UnicodeScalar> = ["(", "[", "{", "<", "\"", "'", "“", "‘"]
    private static let alwaysTrimmedTrailingScalars: Set<UnicodeScalar> = [".", ",", ";", ":", "!", "?", "\"", "'", "”", "’"]

    static func attributedString(
        text: String,
        attributes: [NSAttributedString.Key: Any],
        policy: BareURLLinkificationPolicy,
        suppressLinksTouchingEndBoundary: Bool = false
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        applyLinks(
            to: result,
            policy: policy,
            suppressLinksTouchingEndBoundary: suppressLinksTouchingEndBoundary
        )
        return result
    }

    static func applyLinks(
        to attributedString: NSMutableAttributedString,
        policy: BareURLLinkificationPolicy,
        suppressLinksTouchingEndBoundary: Bool = false
    ) {
        guard policy.isEnabled, attributedString.length > 0 else { return }
        guard let detector = linkDetector else { return }

        let text = attributedString.string
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        detector.enumerateMatches(in: text, options: [], range: fullRange) { result, _, _ in
            guard let result,
                  result.resultType == .link,
                  let candidate = allowedURLCandidate(from: result.range, in: text, policy: policy)
            else {
                return
            }
            guard !suppressLinksTouchingEndBoundary || NSMaxRange(candidate.range) < NSMaxRange(fullRange) else {
                return
            }

            attributedString.addRepoPromptBareURLLink(candidate.url, range: candidate.range)
        }
    }

    private static func allowedURLCandidate(
        from detectedRange: NSRange,
        in text: String,
        policy: BareURLLinkificationPolicy
    ) -> (range: NSRange, url: URL)? {
        guard policy == .httpHTTPSOnly else { return nil }
        let trimmedRange = trimURLRange(detectedRange, in: text)
        guard trimmedRange.length > 0 else { return nil }

        guard hasAllowedLeadingBoundary(before: trimmedRange.location, in: text) else { return nil }

        let rawCandidate = (text as NSString).substring(with: trimmedRange)
        let lowercasedCandidate = rawCandidate.lowercased()
        guard lowercasedCandidate.hasPrefix("http://") || lowercasedCandidate.hasPrefix("https://") else {
            return nil
        }
        guard let url = URL(string: rawCandidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return nil
        }
        return (trimmedRange, url)
    }

    private static func hasAllowedLeadingBoundary(before location: Int, in text: String) -> Bool {
        guard location > 0 else { return true }
        let previous = (text as NSString).character(at: location - 1)
        if let scalar = UnicodeScalar(previous), CharacterSet.whitespacesAndNewlines.contains(scalar) {
            return true
        }
        guard let scalar = UnicodeScalar(previous) else { return false }
        return leadingBoundaryScalars.contains(scalar)
    }

    private static func trimURLRange(_ range: NSRange, in text: String) -> NSRange {
        let nsText = text as NSString
        var location = range.location
        var length = range.length

        while length > 0, shouldTrimLeadingCharacter(nsText.character(at: location)) {
            location += 1
            length -= 1
        }

        var didTrim = true
        while length > 0, didTrim {
            didTrim = false
            let lastIndex = location + length - 1
            let character = nsText.character(at: lastIndex)
            if shouldAlwaysTrimTrailingCharacter(character) || shouldTrimUnbalancedClosingCharacter(character, in: nsText, range: NSRange(location: location, length: length)) {
                length -= 1
                didTrim = true
            }
        }

        return NSRange(location: location, length: length)
    }

    private static func shouldTrimLeadingCharacter(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return leadingBoundaryScalars.contains(scalar)
    }

    private static func shouldAlwaysTrimTrailingCharacter(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return alwaysTrimmedTrailingScalars.contains(scalar)
    }

    private static func shouldTrimUnbalancedClosingCharacter(
        _ character: unichar,
        in text: NSString,
        range: NSRange
    ) -> Bool {
        guard let pair = enclosingPair(for: character) else { return false }
        var openerCount = 0
        var closerCount = 0
        for offset in range.location ..< range.location + range.length {
            let current = text.character(at: offset)
            if current == pair.opener {
                openerCount += 1
            } else if current == pair.closer {
                closerCount += 1
            }
        }
        return closerCount > openerCount
    }

    private static func enclosingPair(for closer: unichar) -> (opener: unichar, closer: unichar)? {
        switch UnicodeScalar(closer) {
        case ")":
            ("(".utf16.first!, closer)
        case "]":
            ("[".utf16.first!, closer)
        case "}":
            ("{".utf16.first!, closer)
        case ">":
            ("<".utf16.first!, closer)
        default:
            nil
        }
    }
}

extension NSAttributedString.Key {
    static let repoPromptBareURLLink = NSAttributedString.Key("RepoPromptBareURLLink")
}

extension NSMutableAttributedString {
    func addRepoPromptLink(_ value: Any, range: NSRange) {
        addAttribute(.link, value: value, range: range)
        addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
        addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
    }

    func addRepoPromptBareURLLink(_ value: Any, range: NSRange) {
        addRepoPromptLink(value, range: range)
        addAttribute(.repoPromptBareURLLink, value: true, range: range)
    }

    func applyForegroundColor(_ color: NSColor, preservingLinkRanges: Bool) {
        let fullRange = NSRange(location: 0, length: length)
        guard preservingLinkRanges else {
            addAttribute(.foregroundColor, value: color, range: fullRange)
            return
        }
        enumerateAttribute(.link, in: fullRange) { value, range, _ in
            guard value == nil else { return }
            addAttribute(.foregroundColor, value: color, range: range)
        }
    }
}
