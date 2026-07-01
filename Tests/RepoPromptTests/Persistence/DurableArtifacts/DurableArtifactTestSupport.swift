import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

enum DurableArtifactTestSupport {
    static let family = DurableArtifactFamily(rawValue: "archive-test-v1")!

    static func makeApplicationSupport() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("durable-artifacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        guard chmod(url.path, 0o700) == 0 else {
            throw DurableArtifactStoreError.ioFailure(operation: "test-root-mode", code: errno)
        }
        return url
    }

    static func makeStore(
        at applicationSupport: URL,
        now: UInt64 = 10000,
        crashPoint: DurableArtifactCrashPoint? = nil,
        crashExitPoint: DurableArtifactCrashPoint? = nil,
        forcedDigestByte: UInt8? = nil,
        randomBytes: @escaping @Sendable (Int) throws -> Data = { count in
            Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 + 17) })
        },
        token: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        crashAction: (@Sendable (DurableArtifactCrashPoint) throws -> Void)? = nil
    ) throws -> LocalDurableArtifactStore {
        let hooks = DurableArtifactStoreHooks(
            now: { now },
            randomBytes: randomBytes,
            token: token,
            crash: { point in
                if point == crashExitPoint { _exit(86) }
                if point == crashPoint { throw DurableArtifactStoreError.simulatedCrash(point) }
                try crashAction?(point)
            },
            transformDigest: { digest in
                forcedDigestByte.map { Data(repeating: $0, count: 32) } ?? digest
            }
        )
        return try LocalDurableArtifactStore(
            applicationSupportURL: applicationSupport,
            buildFlavor: "tests",
            framingPolicy: .default,
            diskPolicy: DurableArtifactDiskPolicy(
                quotaBytes: UInt64.max,
                minimumFreeReserveBytes: 0,
                minimumOrphanAgeSeconds: 0,
                quarantineGraceSeconds: 0,
                abandonedWorkAgeSeconds: 0
            ),
            hooks: hooks
        )
    }

    static func publish(
        _ store: LocalDurableArtifactStore,
        family: DurableArtifactFamily = family,
        identity: String = "identity",
        records: [String] = ["a", "b"],
        upperBound: UInt64 = 16 * 1024 * 1024
    ) throws -> DurableArtifactObjectID {
        let result = try store.publishObject(
            family: family,
            schemaVersion: 1,
            canonicalIdentity: Data(identity.utf8),
            admittedByteUpperBound: upperBound
        ) { writer in
            for record in records {
                try writer.appendRecord(Data(record.utf8))
            }
        }
        switch result {
        case let .published(id, _), let .coalesced(id, _): return id
        default: throw Failure.unexpectedPublication(result)
        }
    }

    static func objectURL(store: LocalDurableArtifactStore, id: DurableArtifactObjectID) -> URL {
        store.rootURL
            .appendingPathComponent("v1/objects", isDirectory: true)
            .appendingPathComponent(id.family.rawValue, isDirectory: true)
            .appendingPathComponent(String(id.digest.hex.prefix(2)), isDirectory: true)
            .appendingPathComponent(id.digest.hex)
    }

    static func expectation(
        id: DurableArtifactObjectID,
        identity: String = "identity"
    ) -> DurableArtifactObjectExpectation {
        DurableArtifactObjectExpectation(
            id: id,
            schemaVersion: 1,
            canonicalIdentity: Data(identity.utf8)
        )
    }

    enum Failure: Error {
        case unexpectedPublication(DurableArtifactPublicationResult)
    }
}

enum DurableArtifactSubprocess {
    struct Context {
        let action: String
        let root: URL
        let ready: URL?
        let release: URL?
        let result: URL?
        let parameter: String?
    }

    private static let actionKey = "RPCE_DURABLE_WORKER_ACTION"
    private static let rootKey = "RPCE_DURABLE_WORKER_ROOT"
    private static let readyKey = "RPCE_DURABLE_WORKER_READY"
    private static let releaseKey = "RPCE_DURABLE_WORKER_RELEASE"
    private static let resultKey = "RPCE_DURABLE_WORKER_RESULT"
    private static let parameterKey = "RPCE_DURABLE_WORKER_PARAMETER"

    static var context: Context? {
        let environment = ProcessInfo.processInfo.environment
        guard let action = environment[actionKey], let root = environment[rootKey] else { return nil }
        return Context(
            action: action,
            root: URL(fileURLWithPath: root, isDirectory: true),
            ready: environment[readyKey].map(URL.init(fileURLWithPath:)),
            release: environment[releaseKey].map(URL.init(fileURLWithPath:)),
            result: environment[resultKey].map(URL.init(fileURLWithPath:)),
            parameter: environment[parameterKey]
        )
    }

    static func spawn(
        testCase: AnyClass,
        testName: String,
        action: String,
        root: URL,
        ready: URL? = nil,
        release: URL? = nil,
        result: URL? = nil,
        parameter: String? = nil
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "\(String(describing: testCase))/\(testName)",
            Bundle(for: testCase).bundleURL.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[actionKey] = action
        environment[rootKey] = root.path
        environment[readyKey] = ready?.path
        environment[releaseKey] = release?.path
        environment[resultKey] = result?.path
        environment[parameterKey] = parameter
        process.environment = environment
        let output = root.appendingPathComponent(".worker-output-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        handle.closeFile()
        return process
    }

    static func signal(_ url: URL?) throws {
        guard let url else { return }
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func waitForSignal(_ url: URL?, timeout: TimeInterval = 15) throws {
        guard let url else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard Date() < deadline else { throw Failure.timeout(url.lastPathComponent) }
            usleep(10000)
        }
    }

    static func writeResult(_ value: String, to url: URL?) throws {
        guard let url else { return }
        try Data(value.utf8).write(to: url, options: .atomic)
    }

    static func readResult(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    static func wait(
        _ process: Process,
        expectedStatus: Int32 = 0,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                releaseAndTerminateIfRunning(process)
                XCTFail("Subprocess timed out", file: file, line: line)
                throw Failure.processTimeout
            }
            usleep(10000)
        }
        XCTAssertEqual(process.terminationStatus, expectedStatus, file: file, line: line)
    }

    static func releaseAndTerminateIfRunning(
        _ process: Process,
        release: URL? = nil,
        timeout: TimeInterval = 2
    ) {
        try? signal(release)
        guard process.isRunning else { return }
        let deadline = Date().addingTimeInterval(timeout)
        process.terminate()
        while process.isRunning, Date() < deadline {
            usleep(10000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    enum Failure: Error {
        case timeout(String)
        case processTimeout
    }
}

extension XCTestCase {
    func requireLease(
        _ store: LocalDurableArtifactStore,
        id: DurableArtifactObjectID,
        identity: String = "identity"
    ) throws -> DurableArtifactReadLease {
        switch try store.openObject(DurableArtifactTestSupport.expectation(id: id, identity: identity)) {
        case let .available(lease): return lease
        default:
            XCTFail("Expected an available durable object lease")
            throw DurableArtifactTestSupport.Failure.unexpectedPublication(.familyDisabled)
        }
    }
}
