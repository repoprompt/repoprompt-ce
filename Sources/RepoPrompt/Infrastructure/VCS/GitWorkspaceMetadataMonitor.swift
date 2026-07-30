import CoreFoundation
import CoreServices
import Dispatch
import Foundation

enum GitWorkspaceMetadataMonitorError: LocalizedError, Equatable {
    case repositoryLimitExceeded
    case retainLimitExceeded
    case pathLimitExceeded(requested: Int, limit: Int)
    case invalidPath
    case unwatchablePath
    case streamCreationFailed
    case streamStartFailed

    var errorDescription: String? {
        switch self {
        case .repositoryLimitExceeded:
            "The bounded Git metadata repository monitor limit was exceeded."
        case .retainLimitExceeded:
            "The bounded Git metadata retain limit was exceeded."
        case let .pathLimitExceeded(requested, limit):
            "Git metadata monitoring requested \(requested) paths, exceeding the limit of \(limit)."
        case .invalidPath:
            "Git metadata monitoring requires canonical absolute paths."
        case .unwatchablePath:
            "Git metadata monitoring could not find an existing ancestor to watch."
        case .streamCreationFailed:
            "Git metadata FSEvent stream creation failed."
        case .streamStartFailed:
            "Git metadata FSEvent stream activation failed."
        }
    }
}

/// Recursive, event-driven Git metadata observation. Coverage admission is
/// transactional: every requested canonical source is watched or retain fails
/// without installing a token or partial source set. No Git command or timer
/// polling is performed.
actor GitWorkspaceMetadataMonitor {
    nonisolated static let defaultMaximumRepositoryCount = 128
    nonisolated static let defaultMaximumPathsPerRepository = 32
    nonisolated static let defaultMaximumRetainsPerRepository = 64

    struct RetainToken: Hashable {
        fileprivate let id: UUID
        fileprivate let repositoryKey: GitWorkspaceAuthorityRepositoryKey
        fileprivate let coveredTargetKeys: Set<String>
    }

    #if DEBUG
        struct Snapshot: Equatable {
            let retainedRepositoryCount: Int
            let retainTokenCount: Int
            let sourceCount: Int
            let coveredPathCount: Int
            let acceptedEventCount: Int
            let acceptedWatermarks: [GitWorkspaceAuthorityRepositoryKey: UInt64]
            let pollingCommandCount: Int
        }
    #endif

    fileprivate struct WatchTarget: Hashable {
        fileprivate enum Scope: Hashable {
            case exactFile
            case subtree
            case prefixControl(repositoryRootPath: String, relativePrefix: String)
        }

        let targetURL: URL
        let watchRootURL: URL
        let scope: Scope
        let eventKinds: Set<GitWorkspaceMetadataEventKind>

        var key: String {
            switch scope {
            case .exactFile:
                "exactFile:\(targetURL.standardizedFileURL.path)"
            case .subtree:
                "subtree:\(targetURL.standardizedFileURL.path)"
            case let .prefixControl(repositoryRootPath, relativePrefix):
                "prefixControl:\(repositoryRootPath):\(relativePrefix)"
            }
        }

        func matchingEventKinds(
            _ eventPath: String,
            flags: FSEventStreamEventFlags
        ) -> Set<GitWorkspaceMetadataEventKind> {
            let targetPath = targetURL.standardizedFileURL.path
            guard let canonicalEventPath = Self.canonicalEventPathPreservingFinalComponent(eventPath) else {
                return []
            }
            let matches = switch scope {
            case .exactFile:
                // Some replacement/deletion batches are reported at the
                // watched parent even with file-level events enabled. Treat
                // that parent cut conservatively as an exact-source change;
                // never risk retaining stale external Git policy contents.
                canonicalEventPath == targetPath
                    || canonicalEventPath == targetURL.deletingLastPathComponent().path
            case .subtree:
                canonicalEventPath == targetPath || canonicalEventPath.hasPrefix(targetPath + "/")
            case let .prefixControl(repositoryRootPath, relativePrefix):
                Self.prefixControlScopeMatches(
                    canonicalEventPath: canonicalEventPath,
                    repositoryRootPath: repositoryRootPath,
                    relativePrefix: relativePrefix,
                    flags: flags
                )
            }
            return matches ? eventKinds : []
        }

        private static func canonicalEventPathPreservingFinalComponent(_ eventPath: String) -> String? {
            let rawURL = URL(fileURLWithPath: eventPath).standardizedFileURL
            guard rawURL.isFileURL,
                  rawURL.path.hasPrefix("/"),
                  !rawURL.path.contains("\0")
            else { return nil }
            guard rawURL.path != "/" else { return "/" }
            let canonicalParent = rawURL.deletingLastPathComponent()
                .resolvingSymlinksInPath()
                .standardizedFileURL
            return canonicalParent.appendingPathComponent(rawURL.lastPathComponent).standardizedFileURL.path
        }

        private static func prefixControlScopeMatches(
            canonicalEventPath: String,
            repositoryRootPath: String,
            relativePrefix: String,
            flags: FSEventStreamEventFlags
        ) -> Bool {
            guard canonicalEventPath == repositoryRootPath
                || canonicalEventPath.hasPrefix(repositoryRootPath + "/")
            else { return false }
            let relativePath = canonicalEventPath == repositoryRootPath
                ? ""
                : String(canonicalEventPath.dropFirst(repositoryRootPath.count + 1))
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)

            let isAtOrBelowPrefix = relativePrefix.isEmpty
                || relativePath == relativePrefix
                || relativePath.hasPrefix(relativePrefix + "/")
            let isPrefixAncestor = relativePath.isEmpty
                || relativePath == relativePrefix
                || relativePrefix.hasPrefix(relativePath + "/")
            let parent = relativePath.isEmpty
                ? ""
                : String(relativePath.split(separator: "/").dropLast().joined(separator: "/"))
            let parentIsPrefixAncestor = parent.isEmpty
                || parent == relativePrefix
                || relativePrefix.hasPrefix(parent + "/")
            if let gitComponentIndex = components.firstIndex(of: ".git") {
                // The checkout's own `.git` metadata is covered by typed Git
                // metadata targets and can be extremely noisy. A nested exact
                // `.git` path, however, is traversal topology: directory,
                // gitfile, create, remove, and replacement events must
                // invalidate prefix-control evidence. Ignore descendants of
                // either metadata directory after matching the boundary.
                guard gitComponentIndex > components.startIndex else { return false }
                guard gitComponentIndex == components.index(before: components.endIndex) else { return false }
                let boundaryDirectory = components[..<gitComponentIndex].joined(separator: "/")
                return relativePrefix.isEmpty
                    || boundaryDirectory == relativePrefix
                    || boundaryDirectory.hasPrefix(relativePrefix + "/")
                    || relativePrefix.hasPrefix(boundaryDirectory + "/")
            }
            let isControl = [".gitignore", ".repo_ignore", ".cursorignore", ".gitattributes"]
                .contains(components.last.map(String.init) ?? "")
                && (isAtOrBelowPrefix || parentIsPrefixAncestor)
            if isControl { return true }

            let itemIsDirectory = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
            let itemIsSymlink = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsSymlink) != 0
            // Directory and symlink topology can move controls into or out of
            // the physical traversal domain. Root/ancestor events are also a
            // conservative topology cut even when FSEvents omits item flags.
            return (itemIsDirectory || itemIsSymlink) && (isAtOrBelowPrefix || isPrefixAncestor)
                || relativePath.isEmpty
        }
    }

    private struct Record {
        var targetKeysByTokenID: [UUID: Set<String>]
        var sourcesByTargetKey: [String: GitMetadataFSEventSource]
        let onEvent: @Sendable (Set<GitWorkspaceMetadataEventKind>) -> Void
    }

    private let acceptedWatermarks = GitMetadataAcceptedWatermarks()
    private var records: [GitWorkspaceAuthorityRepositoryKey: Record] = [:]
    private var acceptedEventCount = 0
    private let maximumRepositoryCount: Int
    private let maximumPathsPerRepository: Int
    private let maximumRetainsPerRepository: Int

    init(
        maximumRepositoryCount: Int = defaultMaximumRepositoryCount,
        maximumPathsPerRepository: Int = defaultMaximumPathsPerRepository,
        maximumRetainsPerRepository: Int = defaultMaximumRetainsPerRepository
    ) {
        precondition(maximumRepositoryCount > 0)
        precondition(maximumPathsPerRepository > 0)
        precondition(maximumRetainsPerRepository > 0)
        self.maximumRepositoryCount = maximumRepositoryCount
        self.maximumPathsPerRepository = maximumPathsPerRepository
        self.maximumRetainsPerRepository = maximumRetainsPerRepository
    }

    nonisolated func acceptedWatermark(
        for repositoryKey: GitWorkspaceAuthorityRepositoryKey
    ) -> UInt64 {
        acceptedWatermarks.value(for: repositoryKey)
    }

    nonisolated func acceptedWatermarkIsCurrent(
        for repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        expected: UInt64
    ) -> Bool {
        acceptedWatermarks.withCurrentValue(
            for: repositoryKey,
            expected: expected
        ) { true } ?? false
    }

    /// Serializes an authority install linearization point with synchronous
    /// event acceptance. If an event was accepted during collection, the body
    /// never runs; an event accepted afterward observes the installed value as
    /// a prior generation and makes its lease immediately non-current.
    nonisolated func withCurrentAcceptedWatermark<T>(
        for repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        expected: UInt64,
        _ body: () -> T
    ) -> T? {
        acceptedWatermarks.withCurrentValue(
            for: repositoryKey,
            expected: expected,
            body
        )
    }

    /// Validates a complete multi-root watermark cut while holding the monitor
    /// lock exactly once. Duplicate repository keys must already have been
    /// coalesced to one exact expected value by the caller.
    nonisolated func withCurrentAcceptedWatermarks<T>(
        _ expected: [GitWorkspaceAuthorityRepositoryKey: UInt64],
        _ body: () -> T
    ) -> T? {
        acceptedWatermarks.withCurrentValues(expected, body)
    }

    func retain(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        paths: [URL],
        onEvent: @escaping @Sendable (Set<GitWorkspaceMetadataEventKind>) -> Void
    ) throws -> RetainToken {
        let requestedTargets = try Self.resolveWatchTargets(paths)
        return try retain(repositoryKey: repositoryKey, targets: requestedTargets, onEvent: onEvent)
    }

    func retainPrefixControlScope(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        repositoryRoot: URL,
        prefix: GitRepositoryRelativeRootPrefix,
        onEvent: @escaping @Sendable (Set<GitWorkspaceMetadataEventKind>) -> Void
    ) throws -> RetainToken {
        let target = try Self.resolvePrefixControlWatchTarget(
            repositoryRoot: repositoryRoot,
            prefix: prefix
        )
        return try retain(repositoryKey: repositoryKey, targets: [target], onEvent: onEvent)
    }

    private func retain(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        targets requestedTargets: [WatchTarget],
        onEvent: @escaping @Sendable (Set<GitWorkspaceMetadataEventKind>) -> Void
    ) throws -> RetainToken {
        let token = RetainToken(
            id: UUID(),
            repositoryKey: repositoryKey,
            coveredTargetKeys: Set(requestedTargets.map(\.key))
        )

        if var record = records[repositoryKey] {
            guard record.targetKeysByTokenID.count < maximumRetainsPerRepository else {
                throw GitWorkspaceMetadataMonitorError.retainLimitExceeded
            }
            let existingKeys = Set(record.sourcesByTargetKey.keys)
            let unionCount = existingKeys.union(requestedTargets.map(\.key)).count
            guard unionCount <= maximumPathsPerRepository else {
                throw GitWorkspaceMetadataMonitorError.pathLimitExceeded(
                    requested: unionCount,
                    limit: maximumPathsPerRepository
                )
            }
            let newTargets = requestedTargets.filter { !existingKeys.contains($0.key) }
            let newSources = try makeSources(
                targets: newTargets,
                repositoryKey: repositoryKey
            )
            record.sourcesByTargetKey.merge(newSources) { existing, _ in existing }
            record.targetKeysByTokenID[token.id] = token.coveredTargetKeys
            records[repositoryKey] = record
            return token
        }

        guard records.count < maximumRepositoryCount else {
            throw GitWorkspaceMetadataMonitorError.repositoryLimitExceeded
        }
        guard requestedTargets.count <= maximumPathsPerRepository else {
            throw GitWorkspaceMetadataMonitorError.pathLimitExceeded(
                requested: requestedTargets.count,
                limit: maximumPathsPerRepository
            )
        }
        guard !requestedTargets.isEmpty else {
            throw GitWorkspaceMetadataMonitorError.unwatchablePath
        }
        let sources = try makeSources(targets: requestedTargets, repositoryKey: repositoryKey)
        records[repositoryKey] = Record(
            targetKeysByTokenID: [token.id: token.coveredTargetKeys],
            sourcesByTargetKey: sources,
            onEvent: onEvent
        )
        return token
    }

    /// Flushes all sources retained by the exact typed prefix-control token,
    /// crosses each source's private callback queue, and then checks the
    /// callback-accepted watermark. This is the synchronous linearization cut
    /// used by prefix evidence lookup and conditional admission.
    func flushCoverageAndCheckCurrent(
        _ token: RetainToken,
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        repositoryRoot: URL,
        prefix: GitRepositoryRelativeRootPrefix,
        expectedAcceptedWatermark: UInt64
    ) -> Bool {
        guard token.repositoryKey == repositoryKey,
              let requested = try? Self.resolvePrefixControlWatchTarget(
                  repositoryRoot: repositoryRoot,
                  prefix: prefix
              ),
              token.coveredTargetKeys == Set([requested.key]),
              let record = records[repositoryKey],
              record.targetKeysByTokenID[token.id] == token.coveredTargetKeys,
              token.coveredTargetKeys.isSubset(of: Set(record.sourcesByTargetKey.keys))
        else { return false }
        for key in token.coveredTargetKeys.sorted() {
            guard let source = record.sourcesByTargetKey[key] else { return false }
            source.flushSync()
        }
        guard let currentRecord = records[repositoryKey],
              currentRecord.targetKeysByTokenID[token.id] == token.coveredTargetKeys,
              token.coveredTargetKeys.isSubset(of: Set(currentRecord.sourcesByTargetKey.keys)),
              acceptedWatermark(for: repositoryKey) == expectedAcceptedWatermark
        else { return false }
        return true
    }

    func coverageIsCurrent(
        _ token: RetainToken,
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        paths: [URL],
        expectedAcceptedWatermark: UInt64
    ) -> Bool {
        guard token.repositoryKey == repositoryKey,
              let requestedTargets = try? Self.resolveWatchTargets(paths),
              token.coveredTargetKeys == Set(requestedTargets.map(\.key)),
              let record = records[repositoryKey],
              record.targetKeysByTokenID[token.id] == token.coveredTargetKeys,
              token.coveredTargetKeys.isSubset(of: Set(record.sourcesByTargetKey.keys)),
              acceptedWatermark(for: repositoryKey) == expectedAcceptedWatermark
        else { return false }
        return true
    }

    /// Flushes the complete typed metadata observation before allowing a
    /// repository-wide monitor gap to recover. Narrow prefix-control coverage
    /// is intentionally validated by the separate overload above.
    func flushCoverageAndCheckCurrent(
        _ token: RetainToken,
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        paths: [URL],
        expectedAcceptedWatermark: UInt64
    ) -> Bool {
        guard token.repositoryKey == repositoryKey,
              let requestedTargets = try? Self.resolveWatchTargets(paths),
              token.coveredTargetKeys == Set(requestedTargets.map(\.key)),
              let record = records[repositoryKey],
              record.targetKeysByTokenID[token.id] == token.coveredTargetKeys,
              token.coveredTargetKeys.isSubset(of: Set(record.sourcesByTargetKey.keys))
        else { return false }
        for key in token.coveredTargetKeys.sorted() {
            guard let source = record.sourcesByTargetKey[key] else { return false }
            source.flushSync()
        }
        guard let currentRecord = records[repositoryKey],
              currentRecord.targetKeysByTokenID[token.id] == token.coveredTargetKeys,
              token.coveredTargetKeys.isSubset(of: Set(currentRecord.sourcesByTargetKey.keys)),
              acceptedWatermark(for: repositoryKey) == expectedAcceptedWatermark
        else { return false }
        return true
    }

    func release(_ token: RetainToken) {
        guard var record = records[token.repositoryKey],
              record.targetKeysByTokenID.removeValue(forKey: token.id) != nil
        else { return }
        if record.targetKeysByTokenID.isEmpty {
            record.sourcesByTargetKey.values.forEach { $0.cancel() }
            records.removeValue(forKey: token.repositoryKey)
        } else {
            let retainedTargetKeys = record.targetKeysByTokenID.values.reduce(into: Set<String>()) {
                $0.formUnion($1)
            }
            let obsoleteKeys = Set(record.sourcesByTargetKey.keys).subtracting(retainedTargetKeys)
            for key in obsoleteKeys {
                record.sourcesByTargetKey.removeValue(forKey: key)?.cancel()
            }
            records[token.repositoryKey] = record
        }
    }

    private func makeSources(
        targets: [WatchTarget],
        repositoryKey: GitWorkspaceAuthorityRepositoryKey
    ) throws -> [String: GitMetadataFSEventSource] {
        var created: [String: GitMetadataFSEventSource] = [:]
        do {
            for target in targets {
                let source = try GitMetadataFSEventSource(target: target) { [weak self] (kinds: Set<GitWorkspaceMetadataEventKind>) in
                    guard let self else { return }
                    acceptedWatermarks.accept(repositoryKey)
                    Task { await self.acceptedEvent(repositoryKey: repositoryKey, kinds: kinds) }
                }
                created[target.key] = source
            }
            return created
        } catch {
            created.values.forEach { $0.cancel() }
            throw error
        }
    }

    private func acceptedEvent(
        repositoryKey: GitWorkspaceAuthorityRepositoryKey,
        kinds: Set<GitWorkspaceMetadataEventKind>
    ) {
        guard let record = records[repositoryKey] else { return }
        acceptedEventCount &+= 1
        record.onEvent(kinds)
    }

    #if DEBUG
        /// Deterministic callback-equivalent injection. Acceptance advances
        /// synchronously before actor delivery, matching the real FSEvents
        /// callback ordering without introducing a polling test seam.
        func injectAcceptedEventForTesting(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey,
            kinds: Set<GitWorkspaceMetadataEventKind>
        ) {
            acceptedWatermarks.accept(repositoryKey)
            acceptedEvent(repositoryKey: repositoryKey, kinds: kinds)
        }

        /// Models the callback acceptance cut before the actor-delivery task is
        /// scheduled. This lets currentness tests deterministically exercise a
        /// lagging consumer while the accepted watermark has already advanced.
        func acceptEventWithoutDeliveryForTesting(
            repositoryKey: GitWorkspaceAuthorityRepositoryKey
        ) {
            acceptedWatermarks.accept(repositoryKey)
        }

        func flushForTesting(repositoryKey: GitWorkspaceAuthorityRepositoryKey) async {
            records[repositoryKey]?.sourcesByTargetKey.values.forEach { $0.flushSync() }
        }

        func snapshotForTesting() -> Snapshot {
            Snapshot(
                retainedRepositoryCount: records.count,
                retainTokenCount: records.values.reduce(0) { $0 + $1.targetKeysByTokenID.count },
                sourceCount: records.values.reduce(0) { $0 + $1.sourcesByTargetKey.count },
                coveredPathCount: records.values.reduce(0) { $0 + $1.sourcesByTargetKey.count },
                acceptedEventCount: acceptedEventCount,
                acceptedWatermarks: acceptedWatermarks.snapshot(),
                pollingCommandCount: 0
            )
        }

        nonisolated static func prefixControlScopeMatchesForTesting(
            repositoryRoot: URL,
            prefix: GitRepositoryRelativeRootPrefix,
            eventPath: String,
            flags: FSEventStreamEventFlags
        ) throws -> Bool {
            let target = try resolvePrefixControlWatchTarget(
                repositoryRoot: repositoryRoot,
                prefix: prefix
            )
            return !target.matchingEventKinds(eventPath, flags: flags).isEmpty
        }
    #endif

    private static func resolveWatchTargets(_ paths: [URL]) throws -> [WatchTarget] {
        let manager = FileManager.default
        var result: [String: WatchTarget] = [:]
        for rawPath in paths {
            // FSEvents reports canonical volume paths (for example
            // /private/var rather than the /var symlink). Canonicalize both
            // existing targets and missing targets through their existing
            // ancestors so exact-file matching remains stable across create,
            // replace, and delete events.
            let targetURL = rawPath.resolvingSymlinksInPath().standardizedFileURL
            guard targetURL.isFileURL,
                  targetURL.path.hasPrefix("/"),
                  !targetURL.path.contains("\0")
            else {
                throw GitWorkspaceMetadataMonitorError.invalidPath
            }
            var isDirectory: ObjCBool = false
            let targetExists = manager.fileExists(atPath: targetURL.path, isDirectory: &isDirectory)
            let scope: WatchTarget.Scope = targetURL.hasDirectoryPath || (targetExists && isDirectory.boolValue)
                ? .subtree
                : .exactFile
            var watchRoot = scope == .subtree && targetExists
                ? targetURL
                : targetURL.deletingLastPathComponent()
            while watchRoot.path != "/",
                  !manager.fileExists(atPath: watchRoot.path, isDirectory: &isDirectory)
            {
                watchRoot.deleteLastPathComponent()
            }
            guard manager.fileExists(atPath: watchRoot.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw GitWorkspaceMetadataMonitorError.unwatchablePath
            }
            let target = WatchTarget(
                targetURL: targetURL,
                watchRootURL: watchRoot,
                scope: scope,
                eventKinds: Self.eventKinds(for: targetURL)
            )
            result[target.key] = target
        }
        return result.values.sorted { $0.key < $1.key }
    }

    private static func resolvePrefixControlWatchTarget(
        repositoryRoot: URL,
        prefix: GitRepositoryRelativeRootPrefix
    ) throws -> WatchTarget {
        let root = repositoryRoot.resolvingSymlinksInPath().standardizedFileURL
        guard root.isFileURL,
              root.path.hasPrefix("/"),
              !root.path.contains("\0")
        else { throw GitWorkspaceMetadataMonitorError.invalidPath }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw GitWorkspaceMetadataMonitorError.unwatchablePath }
        return WatchTarget(
            targetURL: root,
            watchRootURL: root,
            scope: .prefixControl(
                repositoryRootPath: root.path,
                relativePrefix: prefix.value
            ),
            eventKinds: [.ignoreAuthority, .attributeAuthority]
        )
    }

    private static func eventKinds(for url: URL) -> Set<GitWorkspaceMetadataEventKind> {
        switch url.lastPathComponent {
        case "HEAD": [.head, .symbolicReference]
        case "index": [.index]
        case "packed-refs": [.packedReferences, .references]
        case "refs": [.references, .symbolicReference]
        case "sparse-checkout": [.sparseCheckout]
        case "exclude": [.ignoreAuthority]
        case "attributes": [.attributeAuthority]
        case "config", "config.worktree": [.configuration, .ignoreAuthority, .attributeAuthority, .sparseCheckout]
        case ".git": [.dotGit]
        default: [.configuration, .ignoreAuthority, .attributeAuthority]
        }
    }
}

private final class GitMetadataAcceptedWatermarks: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [GitWorkspaceAuthorityRepositoryKey: UInt64] = [:]

    func accept(_ key: GitWorkspaceAuthorityRepositoryKey) {
        lock.lock()
        values[key, default: 0] &+= 1
        lock.unlock()
    }

    func value(for key: GitWorkspaceAuthorityRepositoryKey) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return values[key] ?? 0
    }

    func snapshot() -> [GitWorkspaceAuthorityRepositoryKey: UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func withCurrentValue<T>(
        for key: GitWorkspaceAuthorityRepositoryKey,
        expected: UInt64,
        _ body: () -> T
    ) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard values[key, default: 0] == expected else { return nil }
        return body()
    }

    func withCurrentValues<T>(
        _ expected: [GitWorkspaceAuthorityRepositoryKey: UInt64],
        _ body: () -> T
    ) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard expected.allSatisfy({ values[$0.key, default: 0] == $0.value }) else { return nil }
        return body()
    }
}

private final class GitMetadataFSEventSource: @unchecked Sendable {
    private let target: GitWorkspaceMetadataMonitor.WatchTarget
    private let onEvent: @Sendable (Set<GitWorkspaceMetadataEventKind>) -> Void
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var directorySource: DispatchSourceFileSystemObject?
    private var selfPointer: UnsafeMutableRawPointer?
    private var isCancelled = false

    init(
        target: GitWorkspaceMetadataMonitor.WatchTarget,
        onEvent: @escaping @Sendable (Set<GitWorkspaceMetadataEventKind>) -> Void
    ) throws {
        self.target = target
        self.onEvent = onEvent
        queue = DispatchQueue(
            label: "com.repoprompt.git-workspace-metadata.\(UUID().uuidString)",
            qos: .utility
        )
        if case .exactFile = target.scope {
            let descriptor = open(target.watchRootURL.path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw GitWorkspaceMetadataMonitorError.unwatchablePath
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .attrib, .extend, .link, .revoke],
                queue: queue
            )
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                var kinds = target.eventKinds
                if !source.data.intersection([.rename, .delete, .revoke]).isEmpty {
                    kinds.insert(.monitorGap)
                }
                self.onEvent(kinds)
            }
            source.setCancelHandler {
                close(descriptor)
            }
            directorySource = source
            source.resume()
            return
        }
        selfPointer = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: selfPointer,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            [target.watchRootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            flags
        )
        guard let stream else {
            releaseSelfPointer()
            throw GitWorkspaceMetadataMonitorError.streamCreationFailed
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            releaseSelfPointer()
            throw GitWorkspaceMetadataMonitorError.streamStartFailed
        }
        // Retain does not succeed until the dispatch-backed stream has crossed
        // an activation barrier. This closes the create/delete race where a
        // caller mutates a newly retained external source immediately after
        // retain returns.
        FSEventStreamFlushSync(stream)
        queue.sync {}
    }

    func flushSync() {
        lock.lock()
        let stream = isCancelled ? nil : stream
        lock.unlock()
        if let stream {
            FSEventStreamFlushSync(stream)
            // FlushSync requests delivery, but callbacks target this private
            // dispatch queue. A queue barrier makes the accepted watermark a
            // true synchronous cut for conditional authority installation.
            queue.sync {}
        } else {
            queue.sync {}
        }
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let stream = stream
        self.stream = nil
        let directorySource = directorySource
        self.directorySource = nil
        lock.unlock()
        directorySource?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        releaseSelfPointer()
    }

    deinit {
        cancel()
    }

    private func handle(
        eventCount: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags: UnsafePointer<FSEventStreamEventFlags>,
        eventIDs: UnsafePointer<FSEventStreamEventId>
    ) {
        guard let payload = FileSystemService.buildOwnedFSEventPayload(
            numEvents: eventCount,
            eventPaths: eventPaths,
            eventFlags: eventFlags,
            eventIds: eventIDs
        ) else { return }
        var kinds = Set<GitWorkspaceMetadataEventKind>()
        for entry in payload.entries {
            let gapMask = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagRootChanged
                    | kFSEventStreamEventFlagEventIdsWrapped
            )
            if entry.flags & gapMask != 0 {
                kinds.insert(.monitorGap)
            }
            kinds.formUnion(target.matchingEventKinds(entry.path, flags: entry.flags))
        }
        if !kinds.isEmpty {
            onEvent(kinds)
        }
    }

    private func releaseSelfPointer() {
        lock.lock()
        let pointer = selfPointer
        selfPointer = nil
        lock.unlock()
        if let pointer {
            Unmanaged<GitMetadataFSEventSource>.fromOpaque(pointer).release()
        }
    }

    private static let callback: FSEventStreamCallback = {
        _, context, eventCount, eventPaths, eventFlags, eventIDs in
        guard let context else { return }
        let source = Unmanaged<GitMetadataFSEventSource>.fromOpaque(context).takeUnretainedValue()
        source.handle(
            eventCount: Int(eventCount),
            eventPaths: eventPaths,
            eventFlags: eventFlags,
            eventIDs: eventIDs
        )
    }
}
