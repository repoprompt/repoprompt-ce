import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

public actor ProviderRegistry {
    private let configuredExecutables: [ProviderKind: String]
    public init(configuredExecutables: [ProviderKind: String]) {
        self.configuredExecutables = configuredExecutables
    }

    public func capabilities() -> [ProviderCapability] {
        ProviderKind.allCases.map { kind in
            guard let path = configuredExecutables[kind] else { return ProviderCapability(kind: kind, enabled: false, executable: nil, supportsResume: false, supportsSteering: false, reasonUnavailable: "not configured") }
            let executable = FileManager.default.isExecutableFile(atPath: path)
            return ProviderCapability(kind: kind, enabled: executable, executable: executable ? path : nil, supportsResume: kind == .codex || kind == .claudeCompatible, supportsSteering: false, reasonUnavailable: executable ? nil : "configured binary is not executable")
        }
    }
}

public enum ProcStatParser {
    public struct Stat: Equatable, Sendable { public let pid: Int32
        public let parentPID: Int32
        public let processGroupID: Int32
        public let sessionID: Int32
        public let startTimeTicks: UInt64
    }

    public static func parse(_ line: String) -> Stat? {
        guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { return nil }
        let pidText = line[..<open].trimmingCharacters(in: .whitespaces)
        let suffix = line[line.index(after: close)...].split(separator: " ")
        guard let pid = Int32(pidText), suffix.count > 19, let parent = Int32(suffix[1]), let group = Int32(suffix[2]), let session = Int32(suffix[3]), let start = UInt64(suffix[19]) else { return nil }
        return Stat(pid: pid, parentPID: parent, processGroupID: group, sessionID: session, startTimeTicks: start)
    }
}

public actor ProviderProcessSupervisor {
    private let processPort: any ProcessSupervisionPort
    private let clock: any RuntimeClock
    private let store: SQLiteServiceStore?
    private var families: [UUID: [ProcessIdentity]] = [:]
    public init(processPort: any ProcessSupervisionPort, clock: any RuntimeClock = SystemRuntimeClock(), store: SQLiteServiceStore? = nil) {
        self.processPort = processPort
        self.clock = clock
        self.store = store
    }

    public func register(runID: UUID, leader: ProcessIdentity, connectionGeneration: Int64 = 1) async throws {
        let containmentMode = try await processPort.containmentMode(for: leader)
        families[runID] = [leader]
        try await store?.persistProcessFamily(runID: runID, leader: leader.persisted, connectionGeneration: connectionGeneration, containmentMode: containmentMode)
    }

    public func forget(runID: UUID) async {
        families[runID] = nil
        try? await store?.updateProcessFamilyState(runID: runID, state: "exited")
    }

    public func recoverPersistedFamilies(graceScans: Int = 100) async throws {
        guard let store else { return }
        for persisted in try await store.activeProcessFamilies() {
            let persistedLeader = ProcessIdentity(persisted.leader)
            do {
                try await processPort.reconstruct(leader: persistedLeader, containmentMode: persisted.containmentMode)
            } catch {
                try await store.updateProcessFamilyState(runID: persisted.runID, state: "identity-mismatch")
                continue
            }
            guard let leader = try await processPort.inspect(pid: persistedLeader.pid),
                  leader.representsSameProcessInstance(as: persistedLeader)
            else {
                try await store.updateProcessFamilyState(runID: persisted.runID, state: "identity-mismatch")
                continue
            }
            families[persisted.runID] = [leader]
            try await cancel(runID: persisted.runID, graceScans: graceScans)
        }
    }

    public func cancel(runID: UUID, termSignal: Int32 = 15, killSignal: Int32 = 9, graceScans: Int = 100) async throws {
        guard let recorded = families[runID], let recordedLeader = recorded.first else { return }
        guard let leader = try await processPort.inspect(pid: recordedLeader.pid),
              leader.representsSameProcessInstance(as: recordedLeader)
        else {
            families[runID] = nil
            try await store?.updateProcessFamilyState(runID: runID, state: "identity-mismatch")
            return
        }
        try await store?.updateProcessFamilyState(runID: runID, state: "terminating")
        var discovered = Set(recorded)
        let initialDescendants = try await verifiedDescendants(of: leader)
        discovered.formUnion(initialDescendants)
        try await persistMembers(runID: runID, members: Array(discovered))
        try await signalGroups(termSignal, members: Array(discovered))

        // Re-scan for the entire grace window. Providers commonly fork cleanup helpers
        // after TERM; a single ancestry snapshot lets those late children escape.
        for _ in 0 ..< max(1, graceScans) {
            try await clock.sleep(for: .milliseconds(100))
            let descendants = try await verifiedDescendants(of: leader)
            let previousCount = discovered.count
            discovered.formUnion(descendants)
            if discovered.count != previousCount {
                try await persistMembers(runID: runID, members: Array(discovered))
            }
        }
        var survivors: [ProcessIdentity] = []
        for member in discovered {
            if let observed = try await processPort.inspect(pid: member.pid),
               observed.representsSameProcessInstance(as: member)
            {
                survivors.append(observed)
            }
        }
        let containedKill = try await processPort.terminateContainedFamily(leader: leader)
        if !survivors.isEmpty, !containedKill { try await signalGroups(killSignal, members: survivors) }
        for member in discovered {
            try await processPort.reap(pid: member.pid)
        }
        families[runID] = nil
        try await store?.updateProcessFamilyState(runID: runID, state: "reaped", members: discovered.map(\.persisted))
    }

    private func verifiedDescendants(of leader: ProcessIdentity) async throws -> [ProcessIdentity] {
        try await processPort.descendants(of: leader.pid).filter {
            $0.bootID == leader.bootID && $0.helperTokenDigest == leader.helperTokenDigest
        }
    }

    private func signalGroups(_ signal: Int32, members: [ProcessIdentity]) async throws {
        let byProcessGroup = Dictionary(grouping: members, by: \ProcessIdentity.processGroupID)
        for (processGroupID, groupMembers) in byProcessGroup {
            try await processPort.signal(signal, processGroupID: processGroupID, verifiedMembers: groupMembers)
        }
    }

    private func persistMembers(runID: UUID, members: [ProcessIdentity]) async throws {
        try await store?.persistProcessMembers(runID: runID, members: members.map(\.persisted))
    }
}

extension ProcessIdentity {
    /// Parentage and executable paths can legitimately change when a process
    /// is reparented or calls exec. Boot identity plus PID start time and the
    /// private helper token identify the immutable Linux process instance.
    func representsSameProcessInstance(as other: ProcessIdentity) -> Bool {
        pid == other.pid &&
            startTimeTicks == other.startTimeTicks &&
            bootID == other.bootID &&
            helperTokenDigest == other.helperTokenDigest
    }

    var persisted: PersistedProcessIdentity {
        PersistedProcessIdentity(pid: pid, parentPID: parentPID, processGroupID: processGroupID, sessionID: sessionID, startTimeTicks: startTimeTicks, bootID: bootID, executablePath: executablePath, helperTokenDigest: helperTokenDigest)
    }

    init(_ persisted: PersistedProcessIdentity) {
        self.init(pid: persisted.pid, parentPID: persisted.parentPID, processGroupID: persisted.processGroupID, sessionID: persisted.sessionID, startTimeTicks: persisted.startTimeTicks, bootID: persisted.bootID, executablePath: persisted.executablePath, helperTokenDigest: persisted.helperTokenDigest)
    }
}
