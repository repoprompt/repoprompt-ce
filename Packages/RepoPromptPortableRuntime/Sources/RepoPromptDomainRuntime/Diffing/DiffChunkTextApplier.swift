import Foundation

public enum DiffChunkTextApplier {
    public static func apply(chunks: [DiffChunk], to originalText: String) throws -> String {
        guard !chunks.isEmpty else {
            return originalText
        }

        let decodedChunks = chunks.map { $0.withDecodedIndentation() }
        var adjustedStartLines = decodedChunks.map(\.startLine)
        var (currentLines, lineEnding) = String.splitContentPreservingLineEndings(originalText)
        let hadTrailingNewline = originalText.hasSuffix(lineEnding)

        for index in decodedChunks.indices {
            let appliedStartLine = adjustedStartLines[index]
            let chunk = decodedChunks[index]

            currentLines = try DiffApplicator.apply(chunk, to: currentLines, startingAt: appliedStartLine)

            let difference = chunk.lineCountDifference()
            guard difference != 0 else { continue }

            for laterIndex in decodedChunks.index(after: index) ..< decodedChunks.endIndex
                where adjustedStartLines[laterIndex] > appliedStartLine
            {
                adjustedStartLines[laterIndex] = clamp(
                    adjustedStartLines[laterIndex] + difference,
                    to: 0 ... currentLines.count
                )
            }
        }

        let joined = currentLines.joined(separator: lineEnding)
        return hadTrailingNewline ? joined + lineEnding : joined
    }

    private static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
