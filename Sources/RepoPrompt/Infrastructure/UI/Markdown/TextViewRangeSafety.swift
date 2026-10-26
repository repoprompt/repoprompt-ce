import AppKit

extension NSRange {
    func clamped(to length: Int) -> NSRange {
        if location == NSNotFound {
            return NSRange(location: length, length: 0)
        }
        let safeLocation = Swift.max(0, Swift.min(location, length))
        let maxLength = Swift.max(0, length - safeLocation)
        let safeLength = Swift.max(0, Swift.min(self.length, maxLength))
        return NSRange(location: safeLocation, length: safeLength)
    }
}

enum TextViewSelectionRestorePolicy {
    static func shouldScrollSelectionToVisibleAfterAttributedReplacement(
        isEditable: Bool,
        wasFirstResponder: Bool
    ) -> Bool {
        isEditable && wasFirstResponder
    }
}

extension NSTextView {
    func currentStringLength() -> Int {
        textStorage?.length ?? (string as NSString).length
    }

    func clampedSelectedRange() -> NSRange {
        selectedRange().clamped(to: currentStringLength())
    }

    @discardableResult
    func restoreSelectionCandidate(
        _ candidate: NSRange,
        scrollToVisible: Bool = false
    ) -> NSRange {
        let clamped = candidate.clamped(to: currentStringLength())
        if clamped != selectedRange() {
            setSelectedRange(clamped)
        }
        if scrollToVisible {
            scrollRangeToVisible(clamped)
        }
        return clamped
    }

    @discardableResult
    func clampSelectionToCurrentString(scrollToVisible: Bool = false) -> NSRange {
        restoreSelectionCandidate(selectedRange(), scrollToVisible: scrollToVisible)
    }
}
