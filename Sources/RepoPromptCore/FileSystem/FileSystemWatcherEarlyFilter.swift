import Foundation

/// Filters only callback entries proven ignored by the current immutable root rules.
package final class FileSystemWatcherEarlyFilter: @unchecked Sendable {
    struct Result {
        let payload: FSEventCallbackPayload?
        let filteredEntryCount: Int
    }

    #if DEBUG
        package struct Snapshot: Equatable {
            package let isValid: Bool
            package let filteredEntryCount: UInt64
        }
    #endif

    private let lock = NSLock()
    private let standardizedRootPath: String
    private let rootPrefix: String
    private var rules: IgnoreRulesSnapshot?
    private var generation: UInt64 = 0
    private var explicitlyManagedIgnoredFiles = Set<String>()
    private var filteredEntryCount: UInt64 = 0

    init(rootPath: String) {
        standardizedRootPath = (rootPath as NSString).standardizingPath
        rootPrefix = standardizedRootPath.hasSuffix("/") ? standardizedRootPath : standardizedRootPath + "/"
    }

    @discardableResult
    func invalidate() -> UInt64 {
        lock.lock()
        generation &+= 1
        rules = nil
        let currentGeneration = generation
        lock.unlock()
        return currentGeneration
    }

    func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func install(_ snapshot: IgnoreRulesSnapshot, generation expectedGeneration: UInt64) {
        lock.lock()
        if generation == expectedGeneration {
            rules = snapshot
        }
        lock.unlock()
    }

    func addExplicitlyManagedIgnoredFile(_ relativePath: String) {
        lock.lock()
        explicitlyManagedIgnoredFiles.insert(relativePath)
        lock.unlock()
    }

    func filter(_ payload: FSEventCallbackPayload) -> Result {
        guard !payload.entries.isEmpty else {
            return Result(payload: nil, filteredEntryCount: 0)
        }
        if payload.entries.contains(where: { Self.isIgnoreControlPath($0.path) }) {
            invalidate()
            return Result(payload: payload, filteredEntryCount: 0)
        }
        if payload.entries.contains(where: { Self.hasRecoveryFlags($0.flags) }) {
            return Result(payload: payload, filteredEntryCount: 0)
        }

        lock.lock()
        guard let rules else {
            lock.unlock()
            return Result(payload: payload, filteredEntryCount: 0)
        }

        var retainedEntries: [FSEventCallbackEntry] = []
        retainedEntries.reserveCapacity(payload.entries.count)
        var filteredCount = 0
        for entry in payload.entries {
            if isProvablyIgnored(entry, rules: rules) {
                filteredCount += 1
            } else {
                retainedEntries.append(entry)
            }
        }
        filteredEntryCount &+= UInt64(filteredCount)
        lock.unlock()

        return Result(
            payload: retainedEntries.isEmpty ? nil : FSEventCallbackPayload(entries: retainedEntries),
            filteredEntryCount: filteredCount
        )
    }

    #if DEBUG
        package func snapshotForTesting() -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            return Snapshot(
                isValid: rules != nil,
                filteredEntryCount: filteredEntryCount
            )
        }
    #endif

    /// Called with `lock` held.
    private func isProvablyIgnored(_ entry: FSEventCallbackEntry, rules: IgnoreRulesSnapshot) -> Bool {
        let standardizedPath = (entry.path as NSString).standardizingPath
        guard standardizedPath.hasPrefix(rootPrefix) else { return false }
        let relativePath = String(standardizedPath.dropFirst(rootPrefix.count))
        guard !relativePath.isEmpty,
              !explicitlyManagedIgnoredFiles.contains(relativePath)
        else { return false }

        let isFile = entry.flags.contains(.itemIsFile)
        let isDirectory = entry.flags.contains(.itemIsDirectory)
        let isSymlink = entry.flags.contains(.itemIsSymlink)
        guard isFile != isDirectory, !isSymlink else { return false }

        let components = relativePath.split(separator: "/")
        var pathSoFar = ""
        for (index, component) in components.enumerated() {
            pathSoFar = pathSoFar.isEmpty ? String(component) : pathSoFar + "/" + component
            let isLast = index == components.count - 1
            let candidateIsDirectory = !isLast || isDirectory
            if rules.isIgnored(relativePath: pathSoFar, isDirectory: candidateIsDirectory) {
                if !isLast, rules.requiresTraversal(for: pathSoFar) {
                    continue
                }
                return true
            }
        }
        return false
    }

    private static func isIgnoreControlPath(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        return filename == ".gitignore" || filename == ".repo_ignore" || filename == ".cursorignore"
    }

    private static func hasRecoveryFlags(_ flags: FileSystemWatchEventFlags) -> Bool {
        !flags.intersection([.mustScanSubdirectories, .droppedEvents, .rootChanged]).isEmpty
    }
}
