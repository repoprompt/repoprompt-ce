import Foundation

enum WorkspaceTextLineCounter {
    static func countLines(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var count = 0
        var previousWasCarriageReturn = false
        var lastWasLineEnding = false

        for byte in text.utf8 {
            switch byte {
            case 10:
                if previousWasCarriageReturn {
                    previousWasCarriageReturn = false
                } else {
                    count += 1
                }
                lastWasLineEnding = true
            case 13:
                count += 1
                previousWasCarriageReturn = true
                lastWasLineEnding = true
            default:
                previousWasCarriageReturn = false
                lastWasLineEnding = false
            }
        }

        return lastWasLineEnding ? count : count + 1
    }
}
