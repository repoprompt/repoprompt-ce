import Darwin
@testable import RepoPromptApp
import XCTest

/// Opt-in, bounded benchmark comparing the tracked-checkout APFS clone fast path with an
/// ordinary `git worktree add` checkout through the real `GitService` creation path.
///
/// Skipped unless `/tmp/rpce-worktree-clone-benchmark/enabled` exists. The marker may contain
/// `key=value` lines (`smallFiles`, `largeFiles`, `largeMiB`, `runs`). The fixture lives under
/// the same directory, results are written to `results.json` there, and every benchmark
/// worktree and the fixture repository are removed when the test finishes.
final class GitWorktreeCloneCheckoutBenchmarkTests: XCTestCase {
    private static let benchmarkRoot = URL(fileURLWithPath: "/tmp/rpce-worktree-clone-benchmark", isDirectory: true)

    private struct Sample: Encodable {
        let strategy: String
        let elapsedMilliseconds: Double
        let firstStatusMilliseconds: Double
        let freeSpaceDeltaBytes: Int64
        let worktreePrivateBytes: Int64?
        let worktreeLogicalBytes: Int64
        let eligibilityMilliseconds: Double?
        let materializationMilliseconds: Double?
        let verificationMilliseconds: Double?
    }

    private struct Summary: Encodable {
        let trackedFileCount: Int
        let trackedLogicalBytes: Int64
        let runsPerStrategy: Int
        let samples: [Sample]
        let medianElapsedMilliseconds: [String: Double]
        let medianFirstStatusMilliseconds: [String: Double]
        let medianFreeSpaceDeltaBytes: [String: Int64]
        let medianPrivateBytes: [String: Int64]
    }

    func testBenchmarkTrackedCheckoutCloneAgainstOrdinaryCheckout() async throws {
        let marker = Self.benchmarkRoot.appendingPathComponent("enabled")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw XCTSkip("Create \(marker.path) to run the worktree clone benchmark.")
        }
        let settings = Self.settings(from: (try? String(contentsOf: marker, encoding: .utf8)) ?? "")
        let smallFiles = settings["smallFiles"] ?? 3000
        let largeFiles = settings["largeFiles"] ?? 6
        let largeMiB = settings["largeMiB"] ?? 8
        let runs = max(1, settings["runs"] ?? 5)

        let fixture = try ReviewGitRepositoryFixture(name: "fixture", parentDirectory: Self.benchmarkRoot)
        defer { fixture.cleanup() }
        let source = try fixture.makeRepository(named: "repo", files: ["README.md": "benchmark\n"])
        var logicalBytes: Int64 = 0
        for index in 0 ..< smallFiles {
            let line = "line \(index) " + String(repeating: "abcdefghij", count: 12) + "\n"
            let contents = String(repeating: line, count: 32)
            logicalBytes += Int64(contents.utf8.count)
            try fixture.write(contents, to: "src/dir\(index % 100)/file\(index).txt", at: source)
        }
        for index in 0 ..< largeFiles {
            var bytes = Data(count: largeMiB * 1024 * 1024)
            bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            logicalBytes += Int64(bytes.count)
            let url = source.appendingPathComponent("assets/blob\(index).bin")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }
        try Self.runGit(["add", "-A"], at: source)
        try Self.runGit(["commit", "-q", "-m", "benchmark payload"], at: source)
        let trackedFileCount = try Self.runGit(["ls-files"], at: source).split(separator: "\n").count

        // Warm caches and the process environment once per strategy; discard those samples.
        for clone in [true, false] {
            _ = try await measure(source: source, clone: clone)
        }
        var samples: [Sample] = []
        for run in 0 ..< runs {
            for clone in run.isMultiple(of: 2) ? [true, false] : [false, true] {
                try await samples.append(measure(source: source, clone: clone))
            }
        }

        func median<T: Comparable>(_ values: [T]) -> T? {
            guard !values.isEmpty else { return nil }
            return values.sorted()[values.count / 2]
        }
        var elapsed: [String: Double] = [:]
        var status: [String: Double] = [:]
        var freeSpace: [String: Int64] = [:]
        var privateBytes: [String: Int64] = [:]
        for strategy in Set(samples.map(\.strategy)) {
            let group = samples.filter { $0.strategy == strategy }
            elapsed[strategy] = median(group.map(\.elapsedMilliseconds))
            status[strategy] = median(group.map(\.firstStatusMilliseconds))
            freeSpace[strategy] = median(group.map(\.freeSpaceDeltaBytes))
            privateBytes[strategy] = median(group.compactMap(\.worktreePrivateBytes))
        }
        let summary = Summary(
            trackedFileCount: trackedFileCount,
            trackedLogicalBytes: logicalBytes,
            runsPerStrategy: runs,
            samples: samples,
            medianElapsedMilliseconds: elapsed,
            medianFirstStatusMilliseconds: status,
            medianFreeSpaceDeltaBytes: freeSpace,
            medianPrivateBytes: privateBytes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        try data.write(to: Self.benchmarkRoot.appendingPathComponent("results.json"))
        print("RPCE_WORKTREE_CLONE_BENCHMARK \(String(decoding: data, as: UTF8.self))")
        XCTAssertEqual(samples.count(where: { $0.strategy == "cloned" }), runs)
    }

    private func measure(source: URL, clone: Bool) async throws -> Sample {
        let plan = try GitWorktreeDefaultPathPlanner.plan(.init(
            mainWorktreeRoot: source,
            existingWorktreeRoots: [source],
            detach: true,
            purpose: .standaloneCreate(now: Date())
        ))
        try FileManager.default.createDirectory(at: plan.appManagedContainer, withIntermediateDirectories: true)
        let planned = plan.createRequest
        let request = GitWorktreeCreateRequest(
            path: planned.path,
            detach: true,
            appManagedContainer: planned.appManagedContainer,
            mainWorktreeRoot: planned.mainWorktreeRoot,
            knownWorktreeRoots: planned.knownWorktreeRoots,
            copyWorktreeIncludeFiles: planned.copyWorktreeIncludeFiles,
            cloneTrackedCheckout: clone
        )
        let service = GitService()
        sync()
        let freeBefore = try Self.availableBytes(Self.benchmarkRoot)
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await service.createWorktreeWithResult(request: request, at: source)
        let elapsed = clock.now - started
        sync()
        let freeAfter = try Self.availableBytes(Self.benchmarkRoot)
        let worktree = URL(fileURLWithPath: result.descriptor.path, isDirectory: true)
        let statusStarted = clock.now
        let status = try Self.runGit(["status", "--porcelain"], at: worktree)
        let statusElapsed = clock.now - statusStarted
        XCTAssertEqual(status, "")
        let strategy = result.checkoutReport?.strategy.rawValue ?? "unknown"
        if clone {
            XCTAssertEqual(strategy, "cloned", String(describing: result.checkoutReport))
        }
        let (privateBytes, logicalBytes) = Self.worktreeBytes(worktree)
        try FileManager.default.removeItem(at: worktree)
        try Self.runGit(["worktree", "prune"], at: source)
        return Sample(
            strategy: strategy,
            elapsedMilliseconds: Self.milliseconds(elapsed),
            firstStatusMilliseconds: Self.milliseconds(statusElapsed),
            freeSpaceDeltaBytes: freeBefore - freeAfter,
            worktreePrivateBytes: privateBytes,
            worktreeLogicalBytes: logicalBytes,
            eligibilityMilliseconds: result.checkoutReport?.eligibilityMilliseconds,
            materializationMilliseconds: result.checkoutReport?.materializationMilliseconds,
            verificationMilliseconds: result.checkoutReport?.verificationMilliseconds
        )
    }

    /// Drains stdout before waiting so large listings cannot fill the pipe and deadlock.
    @discardableResult
    private static func runGit(_ arguments: [String], at root: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = root
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitWorktreeCloneCheckoutBenchmarkTests.git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"]
            )
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func settings(from text: String) -> [String: Int] {
        var values: [String: Int] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let value = Int(parts[1]) { values[parts[0]] = value }
        }
        return values
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    private static func availableBytes(_ url: URL) throws -> Int64 {
        var status = statfs()
        guard statfs(url.path, &status) == 0 else { throw POSIXError(.EIO) }
        return Int64(status.f_bavail) * Int64(status.f_bsize)
    }

    /// Sums APFS private size (bytes not shared with any clone) and logical size of regular
    /// files in the worktree, excluding Git metadata.
    private static func worktreeBytes(_ root: URL) -> (Int64?, Int64) {
        var privateTotal: Int64? = 0
        var logicalTotal: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == ".git" { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true
            else { continue }
            logicalTotal += Int64(values.fileSize ?? 0)
            if let size = privateSize(url.path), let current = privateTotal {
                privateTotal = current + size
            } else {
                privateTotal = nil
            }
        }
        return (privateTotal, logicalTotal)
    }

    private static func privateSize(_ path: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = attrgroup_t(0x0000_0008) // ATTR_CMNEXT_PRIVATESIZE
        var buffer = [UInt8](repeating: 0, count: 32)
        let options = UInt32(0x0000_0020 | 0x0000_0001) // FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW
        let status = buffer.withUnsafeMutableBytes { bytes in
            getattrlist(path, &request, bytes.baseAddress, bytes.count, options)
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
    }
}
