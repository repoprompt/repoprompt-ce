import Foundation

extension Array {
    /// Append an element while maintaining a maximum count.
    /// Removes oldest elements (from front) if count exceeds max.
    mutating func appendBounded(_ element: Element, maxCount: Int) {
        append(element)
        if count > maxCount {
            removeFirst(count - maxCount)
        }
    }
}
