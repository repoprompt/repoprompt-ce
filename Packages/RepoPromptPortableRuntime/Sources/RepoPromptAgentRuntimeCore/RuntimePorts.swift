import Foundation

public protocol RuntimeClock: Sendable {
    func now() -> Date
    func sleep(for duration: Duration) async throws
}

public struct SystemRuntimeClock: RuntimeClock {
    public init() {}
    public func now() -> Date {
        Date()
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public protocol RuntimeIDGenerator: Sendable { func next() -> UUID }
public struct SystemRuntimeIDGenerator: RuntimeIDGenerator { public init() {}
    public func next() -> UUID {
        UUID()
    }
}

public struct ProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let processGroupID: Int32
    public let sessionID: Int32
    public let startTimeTicks: UInt64
    public let bootID: String
    public let executablePath: String
    public let helperTokenDigest: String

    public init(pid: Int32, parentPID: Int32, processGroupID: Int32, sessionID: Int32, startTimeTicks: UInt64, bootID: String, executablePath: String, helperTokenDigest: String) {
        self.pid = pid
        self.parentPID = parentPID
        self.processGroupID = processGroupID
        self.sessionID = sessionID
        self.startTimeTicks = startTimeTicks
        self.bootID = bootID
        self.executablePath = executablePath
        self.helperTokenDigest = helperTokenDigest
    }
}

public protocol ProcessSupervisionPort: Sendable {
    func launch(executable: String, arguments: [String], environment: [String: String], workingDirectory: String, helperToken: String) async throws -> ProcessIdentity
    func inspect(pid: Int32) async throws -> ProcessIdentity?
    func descendants(of pid: Int32) async throws -> [ProcessIdentity]
    func signal(_ signal: Int32, processGroupID: Int32, verifiedMembers: [ProcessIdentity]) async throws
    func reap(pid: Int32) async throws
    /// Returns the durable containment mechanism established for the leader.
    func containmentMode(for leader: ProcessIdentity) async throws -> String
    /// Rehydrates restart-safe identity and containment state from persistence.
    func reconstruct(leader: ProcessIdentity, containmentMode: String) async throws
    /// Returns true when a delegated outer containment boundary accepted a
    /// complete-family kill (Linux cgroup v2). False selects ancestry/PGID fallback.
    func terminateContainedFamily(leader: ProcessIdentity) async throws -> Bool
}

public extension ProcessSupervisionPort {
    func containmentMode(for _: ProcessIdentity) async throws -> String {
        "process-group"
    }

    func reconstruct(leader _: ProcessIdentity, containmentMode _: String) async throws {}

    func terminateContainedFamily(leader _: ProcessIdentity) async throws -> Bool {
        false
    }
}

public protocol RuntimeEventSink: Sendable {
    func record(_ event: RuntimeEvent) async throws
}

public struct RuntimeEvent: Sendable {
    public let projectID: UUID
    public let sessionID: UUID?
    public let runID: UUID?
    public let type: String
    public let payload: Data
    public init(projectID: UUID, sessionID: UUID?, runID: UUID?, type: String, payload: Data) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.runID = runID
        self.type = type
        self.payload = payload
    }
}
