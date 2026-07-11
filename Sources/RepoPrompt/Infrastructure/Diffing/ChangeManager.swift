import Foundation

class ChangeManager {
    private var fileContent: [String]
    private var changes: [FileChange]
    private var appliedChanges: [FileChange] = []
    private var lineEnding: String
    private let fileAction: FileAction
    private let hadTrailingNewline: Bool

    init(
        fileContent: [String],
        changes: [FileChange],
        lineEnding: String,
        fileAction: FileAction,
        hadTrailingNewline: Bool = false
    ) {
        self.fileContent = fileContent
        self.changes = changes.sorted(by: { $0.startLine < $1.startLine })
        self.lineEnding = lineEnding
        self.fileAction = fileAction
        self.hadTrailingNewline = hadTrailingNewline
        // adjustChangePositions()
    }

    private func adjustChangePositions() {
        let optimalLines = OptimalLineFinderUtility.findOptimalLinesInParallel(for: changes, in: fileContent)
        for i in 0 ..< changes.count {
            if let optimalLine = optimalLines[changes[i].id] {
                changes[i] = FileChange(
                    id: changes[i].id,
                    startLine: optimalLine,
                    description: changes[i].description,
                    diffChunk: changes[i].diffChunk
                )
            }
        }
    }

    func applyChange(_ change: FileChange) -> (updatedContent: [String], appliedChangeIds: Set<UUID>, error: Error?) {
        guard let index = changes.firstIndex(where: { $0.id == change.id }) else {
            return (fileContent, Set(), DiffApplicationError.invalidChange)
        }

        let adjustedChange = changes[index]
        do {
            let newContent = try DiffApplicator.apply(adjustedChange.diffChunk, to: fileContent, startingAt: adjustedChange.startLine)
            fileContent = newContent
            appliedChanges.append(adjustedChange)
            updateChangePositions(from: adjustedChange.startLine, by: adjustedChange.diffChunk.lineCountDifference())
            return (fileContent, Set([change.id]), nil)
        } catch {
            return (fileContent, Set(), error)
        }
    }

    func revertChange(_ change: FileChange) -> (updatedContent: [String], appliedChangeIds: Set<UUID>, error: Error?) {
        guard let index = appliedChanges.firstIndex(where: { $0.id == change.id }) else {
            return (fileContent, Set(appliedChanges.map(\.id)), DiffApplicationError.changeNotApplied)
        }

        let appliedChange = appliedChanges[index]
        do {
            let newContent = try DiffApplicator.revert(appliedChange.diffChunk, from: fileContent, startingAt: appliedChange.startLine)
            fileContent = newContent
            appliedChanges.remove(at: index)
            updateChangePositions(from: appliedChange.startLine, by: -appliedChange.diffChunk.lineCountDifference())
            return (fileContent, Set(appliedChanges.map(\.id)), nil)
        } catch {
            return (fileContent, Set(appliedChanges.map(\.id)), error)
        }
    }

    // File: Models/ChangeManager.swift
    private func updateChangePositions(from startLine: Int, by difference: Int) {
        for i in 0 ..< changes.count {
            guard changes[i].startLine > startLine else { continue }

            var newStart = changes[i].startLine + difference
            // Clamp so we never go out of bounds after large deletions/insertions
            if newStart < 0 {
                newStart = 0
            }
            if newStart > fileContent.count {
                newStart = fileContent.count
            }

            changes[i] = FileChange(
                id: changes[i].id,
                startLine: newStart,
                description: changes[i].description,
                diffChunk: changes[i].diffChunk
            )
        }
    }

    func updateContent(_ newContent: [String], lineEnding: String) {
        fileContent = newContent
        self.lineEnding = lineEnding
        appliedChanges.removeAll()

        changes = changes.sorted(by: { $0.startLine < $1.startLine })
    }

    func changeGroups(threshold: Int = 3) -> [ChangeGroup] {
        var groups: [ChangeGroup] = []
        var currentGroup: ChangeGroup?

        for change in changes {
            if let group = currentGroup, group.canAddChange(change, threshold: threshold) {
                group.addChange(change)
            } else {
                if let group = currentGroup {
                    groups.append(group)
                }
                currentGroup = ChangeGroup(startLine: change.startLine)
                currentGroup?.addChange(change)
            }
        }

        if let group = currentGroup {
            groups.append(group)
        }

        return groups
    }

    /// ChangeManager.swift
    func currentChanges() -> [FileChange] {
        changes
    }

    /// Returns the joined content, re-appending the terminating newline in case
    /// the original file ended with one.
    func updatedContent() -> String {
        let joined = fileContent.joined(separator: lineEnding)
        return hadTrailingNewline ? joined + lineEnding : joined
    }

    /// Returns the current file content as an array of lines
    func currentContentLines() -> [String] {
        fileContent
    }
}

enum ChangeApplicationError: Error {
    case invalidChange
    case changeNotApplied
}

class ChangeGroup {
    let startLine: Int
    private(set) var changes: [FileChange] = []

    init(startLine: Int) {
        self.startLine = startLine
    }

    func canAddChange(_ change: FileChange, threshold: Int) -> Bool {
        guard let lastChange = changes.last else { return true }
        return change.startLine - (lastChange.startLine + lastChange.diffChunk.lines.count) <= threshold
    }

    func addChange(_ change: FileChange) {
        changes.append(change)
    }
}
