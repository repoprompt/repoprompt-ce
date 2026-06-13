import Foundation
import RepoPromptShared

enum MCPToolWorkCountDiagnostics {
    struct GitInvocationSnapshot: Equatable {
        let operation: String
        let requestIdentity: MCPRequestTimelineIdentity?
        let repositories: [String]
        let commandCount: Int
        let commandCountsByRepository: [String: Int]
        let processQueueWaitMicroseconds: Int
        let spawnMicroseconds: Int
        let outputBytes: Int
        let parseMicroseconds: Int
        let commands: [String]
        let outcome: String
    }

    struct ReadFileInvocationSnapshot: Equatable {
        let requestIdentity: MCPRequestTimelineIdentity?
        let source: String
        let readBytes: Int
        let returnedBytes: Int
        let returnedLines: Int
        let decodeMicroseconds: Int
        let cacheHit: Bool
        let outcome: String
    }

    #if DEBUG
        private final class GitInvocationCapture: @unchecked Sendable {
            private let lock = NSLock()
            let operation: String
            let requestIdentity: MCPRequestTimelineIdentity?
            private var repositories: [String] = []
            private var commandCount = 0
            private var commandCountsByRepository: [String: Int] = [:]
            private var processQueueWaitMicroseconds = 0
            private var spawnMicroseconds = 0
            private var outputBytes = 0
            private var parseMicroseconds = 0
            private var commands: [String] = []

            init(operation: String, requestIdentity: MCPRequestTimelineIdentity?) {
                self.operation = operation
                self.requestIdentity = requestIdentity
            }

            func setRepositories(_ values: [String]) {
                lock.lock()
                repositories = Array(Set(values)).sorted()
                lock.unlock()
            }

            func recordCommand(
                repository: String,
                arguments: [String],
                processQueueWaitMicroseconds: Int,
                spawnMicroseconds: Int,
                outputBytes: Int
            ) {
                lock.lock()
                commandCount += 1
                commandCountsByRepository[repository, default: 0] += 1
                self.processQueueWaitMicroseconds += max(0, processQueueWaitMicroseconds)
                self.spawnMicroseconds += max(0, spawnMicroseconds)
                self.outputBytes += max(0, outputBytes)
                if !repositories.contains(repository) {
                    repositories.append(repository)
                    repositories.sort()
                }
                if commands.count < 128 {
                    commands.append(arguments.prefix(4).joined(separator: " "))
                }
                lock.unlock()
            }

            func recordParse(microseconds: Int) {
                lock.lock()
                parseMicroseconds += max(0, microseconds)
                lock.unlock()
            }

            func snapshot(outcome: String) -> GitInvocationSnapshot {
                lock.lock()
                defer { lock.unlock() }
                return GitInvocationSnapshot(
                    operation: operation,
                    requestIdentity: requestIdentity,
                    repositories: repositories,
                    commandCount: commandCount,
                    commandCountsByRepository: commandCountsByRepository,
                    processQueueWaitMicroseconds: processQueueWaitMicroseconds,
                    spawnMicroseconds: spawnMicroseconds,
                    outputBytes: outputBytes,
                    parseMicroseconds: parseMicroseconds,
                    commands: commands,
                    outcome: outcome
                )
            }
        }

        private final class ReadFileInvocationCapture: @unchecked Sendable {
            private let lock = NSLock()
            let requestIdentity: MCPRequestTimelineIdentity?
            private var source = "unknown"
            private var readBytes = 0
            private var returnedBytes = 0
            private var returnedLines = 0
            private var decodeMicroseconds = 0
            private var cacheHit = false

            init(requestIdentity: MCPRequestTimelineIdentity?) {
                self.requestIdentity = requestIdentity
            }

            func recordDiskRead(bytes: Int, decodeMicroseconds: Int) {
                lock.lock()
                source = "disk"
                readBytes += max(0, bytes)
                self.decodeMicroseconds += max(0, decodeMicroseconds)
                lock.unlock()
            }

            func recordExternalRead(bytes: Int, decodeMicroseconds: Int) {
                lock.lock()
                source = "external_disk"
                readBytes += max(0, bytes)
                self.decodeMicroseconds += max(0, decodeMicroseconds)
                lock.unlock()
            }

            func recordResult(returnedBytes: Int, returnedLines: Int, cacheHit: Bool) {
                lock.lock()
                self.returnedBytes = max(0, returnedBytes)
                self.returnedLines = max(0, returnedLines)
                self.cacheHit = cacheHit
                if cacheHit, source == "unknown" {
                    source = "interactive_cache"
                }
                lock.unlock()
            }

            func snapshot(outcome: String) -> ReadFileInvocationSnapshot {
                lock.lock()
                defer { lock.unlock() }
                return ReadFileInvocationSnapshot(
                    requestIdentity: requestIdentity,
                    source: source,
                    readBytes: readBytes,
                    returnedBytes: returnedBytes,
                    returnedLines: returnedLines,
                    decodeMicroseconds: decodeMicroseconds,
                    cacheHit: cacheHit,
                    outcome: outcome
                )
            }
        }

        private final class History: @unchecked Sendable {
            private let lock = NSLock()
            private let limit = 64
            private var git: [GitInvocationSnapshot] = []
            private var readFile: [ReadFileInvocationSnapshot] = []

            func append(_ snapshot: GitInvocationSnapshot) {
                lock.lock()
                git.append(snapshot)
                if git.count > limit { git.removeFirst(git.count - limit) }
                lock.unlock()
            }

            func append(_ snapshot: ReadFileInvocationSnapshot) {
                lock.lock()
                readFile.append(snapshot)
                if readFile.count > limit { readFile.removeFirst(readFile.count - limit) }
                lock.unlock()
            }

            func snapshots() -> (git: [GitInvocationSnapshot], readFile: [ReadFileInvocationSnapshot]) {
                lock.lock()
                defer { lock.unlock() }
                return (git, readFile)
            }

            func reset() {
                lock.lock()
                git.removeAll(keepingCapacity: false)
                readFile.removeAll(keepingCapacity: false)
                lock.unlock()
            }
        }

        private static let history = History()
        @TaskLocal private static var currentGitCapture: GitInvocationCapture?
        @TaskLocal private static var currentReadFileCapture: ReadFileInvocationCapture?
    #endif

    static func withGitInvocation<T>(
        operation: String,
        _ body: () async throws -> T
    ) async rethrows -> T {
        #if DEBUG
            let capture = GitInvocationCapture(
                operation: operation,
                requestIdentity: MCPRequestTimelineContext.current
            )
            return try await $currentGitCapture.withValue(capture) {
                do {
                    let value = try await body()
                    history.append(capture.snapshot(outcome: "success"))
                    return value
                } catch {
                    history.append(capture.snapshot(outcome: error is CancellationError ? "cancelled" : "error"))
                    throw error
                }
            }
        #else
            return try await body()
        #endif
    }

    static func setGitRepositories(_ repositories: [String]) {
        #if DEBUG
            currentGitCapture?.setRepositories(repositories)
        #endif
    }

    static func gitCommandRecorder() -> @Sendable (
        _ repository: String,
        _ arguments: [String],
        _ processQueueWaitMicroseconds: Int,
        _ spawnMicroseconds: Int,
        _ outputBytes: Int
    ) -> Void {
        #if DEBUG
            let capture = currentGitCapture
            return { repository, arguments, processQueueWaitMicroseconds, spawnMicroseconds, outputBytes in
                capture?.recordCommand(
                    repository: repository,
                    arguments: arguments,
                    processQueueWaitMicroseconds: processQueueWaitMicroseconds,
                    spawnMicroseconds: spawnMicroseconds,
                    outputBytes: outputBytes
                )
            }
        #else
            return { _, _, _, _, _ in }
        #endif
    }

    static func measureGitParse<T>(_ body: () throws -> T) rethrows -> T {
        #if DEBUG
            let start = DispatchTime.now().uptimeNanoseconds
            defer {
                let end = DispatchTime.now().uptimeNanoseconds
                currentGitCapture?.recordParse(microseconds: elapsedMicroseconds(start: start, end: end))
            }
        #endif
        return try body()
    }

    static func withReadFileInvocation<T>(_ body: () async throws -> T) async rethrows -> T {
        #if DEBUG
            let capture = ReadFileInvocationCapture(requestIdentity: MCPRequestTimelineContext.current)
            return try await $currentReadFileCapture.withValue(capture) {
                do {
                    let value = try await body()
                    history.append(capture.snapshot(outcome: "success"))
                    return value
                } catch {
                    history.append(capture.snapshot(outcome: error is CancellationError ? "cancelled" : "error"))
                    throw error
                }
            }
        #else
            return try await body()
        #endif
    }

    static func recordReadFileDiskRead(bytes: Int, decodeMicroseconds: Int) {
        #if DEBUG
            currentReadFileCapture?.recordDiskRead(bytes: bytes, decodeMicroseconds: decodeMicroseconds)
        #endif
    }

    static func readFileExternalRecorder() -> @Sendable (_ bytes: Int, _ decodeMicroseconds: Int) -> Void {
        #if DEBUG
            let capture = currentReadFileCapture
            return { bytes, decodeMicroseconds in
                capture?.recordExternalRead(bytes: bytes, decodeMicroseconds: decodeMicroseconds)
            }
        #else
            return { _, _ in }
        #endif
    }

    static func recordReadFileResult(returnedBytes: Int, returnedLines: Int, cacheHit: Bool) {
        #if DEBUG
            currentReadFileCapture?.recordResult(
                returnedBytes: returnedBytes,
                returnedLines: returnedLines,
                cacheHit: cacheHit
            )
        #endif
    }

    #if DEBUG
        static func debugSnapshots() -> (git: [GitInvocationSnapshot], readFile: [ReadFileInvocationSnapshot]) {
            history.snapshots()
        }

        static func resetDebugHistory() {
            history.reset()
        }

        static func resetForTesting() {
            resetDebugHistory()
        }

        private static func elapsedMicroseconds(start: UInt64, end: UInt64) -> Int {
            guard end >= start else { return 0 }
            return Int(clamping: (end - start) / 1000)
        }
    #endif
}
