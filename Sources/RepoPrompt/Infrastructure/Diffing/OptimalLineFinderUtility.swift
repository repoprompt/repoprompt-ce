import Dispatch
import Foundation
import RepoPromptDomainRuntime

class OptimalLineFinderUtility {
    static func findOptimalLine(for change: FileChange, in content: [String], around startLine: Int, searchRadius: Int = 5) -> Int {
        // Check if the first context line has high similarity
        if let firstContextLine = change.diffChunk.lines.first(where: { $0.type == .context }) {
            if startLine < content.count,
               firstContextLine.content.similarity(to: content[startLine]) > 0.99
            {
                return startLine // Return original line if similarity is very high
            }
        }

        let lowerBound = max(0, startLine - searchRadius)
        let upperBound = min(content.count - 1, startLine + searchRadius)

        guard lowerBound <= upperBound else { return startLine } // Return original line if bounds are invalid

        let searchRange = lowerBound ... upperBound

        let queue = DispatchQueue(label: "com.repoprompt.linesearch", attributes: .concurrent)
        let group = DispatchGroup()

        var bestScore = -1
        var bestLine = startLine
        let lock = NSLock()

        for line in searchRange {
            group.enter()
            queue.async(group: group) {
                let score = self.scoreMatch(diffChunk: change.diffChunk, in: content, startingAt: line)
                lock.lock()
                if score > bestScore {
                    bestScore = score
                    bestLine = line
                }
                lock.unlock()
                group.leave()
            }
        }

        group.wait()
        return bestScore > -1 ? bestLine : startLine // Return original line if no better match found
    }

    private static func scoreMatch(diffChunk: DiffChunk, in content: [String], startingAt line: Int) -> Int {
        var score = 0
        var contentIndex = line
        var maxScore = 0 // To normalize the score

        for diffLine in diffChunk.lines {
            guard contentIndex < content.count else { break }

            switch diffLine.type {
            case .context, .removal:
                let distance = diffLine.content.levenshteinDistance(to: content[contentIndex])
                let lineScore = max(diffLine.content.count, content[contentIndex].count) - distance
                score += lineScore
                maxScore += max(diffLine.content.count, content[contentIndex].count)

                // Increment contentIndex for both context and removal lines
                contentIndex += 1

            case .addition:
                // Skip additions entirely
                continue
            }
        }

        // Normalize the score to be between 0 and 100
        return maxScore > 0 ? Int((Double(score) / Double(maxScore)) * 100) : 0
    }

    static func findOptimalLinesInParallel(for changes: [FileChange], in content: [String], searchRadius: Int = 5) -> [UUID: Int] {
        let queue = DispatchQueue(label: "com.repoprompt.optimallinefinder", attributes: .concurrent)
        let group = DispatchGroup()

        let result = Array(repeating: NSLock(), count: changes.count)
        var optimalLines = [UUID: Int]()

        for (index, change) in changes.enumerated() {
            group.enter()
            queue.async(group: group) {
                let optimalLine = self.findOptimalLine(for: change, in: content, around: change.startLine, searchRadius: searchRadius)
                result[index].lock()
                optimalLines[change.id] = optimalLine
                result[index].unlock()
                group.leave()
            }
        }

        group.wait()
        return optimalLines
    }
}
