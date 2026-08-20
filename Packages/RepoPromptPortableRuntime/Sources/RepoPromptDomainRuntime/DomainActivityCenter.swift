import Foundation

public enum DomainActivityKind: String, Codable, CaseIterable, Sendable {
    case oracle
    case contextBuilder = "context_builder"
    case agentRun = "agent_run"
    case agentExplore = "agent_explore"
    case agentManage = "agent_manage"
    case interaction
    case sessionControl = "session_control"
}

public enum DomainActivityState: String, Codable, Sendable {
    case queued
    case running
    case waitingForInteraction = "waiting_for_interaction"
    case cancelling
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .queued, .running, .waitingForInteraction, .cancelling:
            false
        }
    }
}

public struct DomainActivityToken: Hashable, Sendable {
    public let runtimeID: UUID
    public let runtimeGeneration: UInt64
    public let activityID: UUID
    public let generation: UInt64
}

public struct DomainActivitySnapshot: Equatable, Sendable {
    public let token: DomainActivityToken
    public let kind: DomainActivityKind
    public let toolName: String
    public let invocationID: UUID?
    public let sessionID: UUID?
    public let state: DomainActivityState
    public let statusText: String?
    public let startedAt: Date
    public let updatedAt: Date
    public let terminalCommitID: UUID?
    public let publicationSequence: UInt64
}

public struct DomainActivityCenterSnapshot: Sendable {
    public let publicationSequence: UInt64
    public let active: [DomainActivitySnapshot]
    public let recentTerminal: [DomainActivitySnapshot]
}

public enum DomainActivityPublicationResult: Equatable, Sendable {
    case accepted
    case stale
    case duplicateTerminal
    case rejectedTerminalConflict
}

public actor DomainActivityCenter {
    private let identity: DomainRuntimeIdentity
    private let terminalLimit: Int
    private var publicationSequence: UInt64 = 0
    private var nextGeneration: UInt64 = 1
    private var active: [UUID: DomainActivitySnapshot] = [:]
    private var terminal: [DomainActivitySnapshot] = []
    private var subscribers: [UUID: AsyncStream<DomainActivityCenterSnapshot>.Continuation] = [:]
    private var isShuttingDown = false

    public init(identity: DomainRuntimeIdentity, terminalLimit: Int = 128) {
        self.identity = identity
        self.terminalLimit = max(1, terminalLimit)
    }

    public func begin(
        kind: DomainActivityKind,
        toolName: String,
        invocationID: UUID? = nil,
        sessionID: UUID? = nil,
        statusText: String? = nil,
        now: Date = Date()
    ) -> DomainActivityToken? {
        guard !isShuttingDown else { return nil }
        let token = DomainActivityToken(
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            activityID: UUID(),
            generation: nextGeneration
        )
        nextGeneration &+= 1
        publicationSequence &+= 1
        active[token.activityID] = DomainActivitySnapshot(
            token: token,
            kind: kind,
            toolName: toolName,
            invocationID: invocationID,
            sessionID: sessionID,
            state: .running,
            statusText: statusText,
            startedAt: now,
            updatedAt: now,
            terminalCommitID: nil,
            publicationSequence: publicationSequence
        )
        publish()
        return token
    }

    @discardableResult
    public func update(
        _ token: DomainActivityToken,
        state: DomainActivityState,
        statusText: String? = nil,
        now: Date = Date()
    ) -> DomainActivityPublicationResult {
        guard isCurrent(token), var value = active[token.activityID] else { return .stale }
        guard !state.isTerminal else { return .rejectedTerminalConflict }
        publicationSequence &+= 1
        value = DomainActivitySnapshot(
            token: value.token,
            kind: value.kind,
            toolName: value.toolName,
            invocationID: value.invocationID,
            sessionID: value.sessionID,
            state: state,
            statusText: statusText ?? value.statusText,
            startedAt: value.startedAt,
            updatedAt: now,
            terminalCommitID: nil,
            publicationSequence: publicationSequence
        )
        active[token.activityID] = value
        publish()
        return .accepted
    }

    @discardableResult
    public func finish(
        _ token: DomainActivityToken,
        state: DomainActivityState,
        commitID: UUID,
        statusText: String? = nil,
        now: Date = Date()
    ) -> DomainActivityPublicationResult {
        if let existing = terminal.first(where: { $0.token == token }) {
            return existing.terminalCommitID == commitID ? .duplicateTerminal : .rejectedTerminalConflict
        }
        guard isCurrent(token), let value = active.removeValue(forKey: token.activityID) else { return .stale }
        guard state.isTerminal else {
            active[token.activityID] = value
            return .rejectedTerminalConflict
        }
        publicationSequence &+= 1
        terminal.insert(
            DomainActivitySnapshot(
                token: value.token,
                kind: value.kind,
                toolName: value.toolName,
                invocationID: value.invocationID,
                sessionID: value.sessionID,
                state: state,
                statusText: statusText ?? value.statusText,
                startedAt: value.startedAt,
                updatedAt: now,
                terminalCommitID: commitID,
                publicationSequence: publicationSequence
            ),
            at: 0
        )
        if terminal.count > terminalLimit {
            terminal.removeLast(terminal.count - terminalLimit)
        }
        publish()
        return .accepted
    }

    public func snapshot() -> DomainActivityCenterSnapshot {
        makeSnapshot()
    }

    public func snapshots() -> AsyncStream<DomainActivityCenterSnapshot> {
        let subscriberID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[subscriberID] = continuation
            continuation.yield(makeSnapshot())
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeSubscriber(subscriberID) }
            }
        }
    }

    public func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        let values = active.values
        active.removeAll()
        for value in values {
            publicationSequence &+= 1
            terminal.insert(
                DomainActivitySnapshot(
                    token: value.token,
                    kind: value.kind,
                    toolName: value.toolName,
                    invocationID: value.invocationID,
                    sessionID: value.sessionID,
                    state: .cancelled,
                    statusText: "Runtime shutdown interrupted this activity.",
                    startedAt: value.startedAt,
                    updatedAt: Date(),
                    terminalCommitID: UUID(),
                    publicationSequence: publicationSequence
                ),
                at: 0
            )
        }
        if terminal.count > terminalLimit {
            terminal.removeLast(terminal.count - terminalLimit)
        }
        publish()
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    private func isCurrent(_ token: DomainActivityToken) -> Bool {
        token.runtimeID == identity.runtimeID
            && token.runtimeGeneration == identity.lifecycleGeneration
            && active[token.activityID]?.token == token
    }

    private func makeSnapshot() -> DomainActivityCenterSnapshot {
        DomainActivityCenterSnapshot(
            publicationSequence: publicationSequence,
            active: active.values.sorted { $0.publicationSequence < $1.publicationSequence },
            recentTerminal: terminal
        )
    }

    private func publish() {
        let snapshot = makeSnapshot()
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
