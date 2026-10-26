import Foundation

package enum DomainActivityKind: String, Codable, CaseIterable, Sendable {
    case oracle
    case contextBuilder = "context_builder"
    case agentRun = "agent_run"
    case agentExplore = "agent_explore"
    case agentManage = "agent_manage"
    case interaction
    case sessionControl = "session_control"
}

package enum DomainActivityState: String, Codable, Sendable {
    case queued
    case running
    case waitingForInteraction = "waiting_for_interaction"
    case cancelling
    case completed
    case failed
    case cancelled

    package var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .queued, .running, .waitingForInteraction, .cancelling:
            false
        }
    }
}

package struct DomainActivityToken: Hashable, Sendable {
    package let runtimeID: UUID
    package let runtimeGeneration: UInt64
    package let activityID: UUID
    package let generation: UInt64
}

package struct DomainActivitySnapshot: Equatable, Sendable {
    package let token: DomainActivityToken
    package let kind: DomainActivityKind
    package let toolName: String
    package let invocationID: UUID?
    package let sessionID: UUID?
    package let state: DomainActivityState
    package let statusText: String?
    package let startedAt: Date
    package let updatedAt: Date
    package let terminalCommitID: UUID?
    package let publicationSequence: UInt64
}

package struct DomainActivityCenterSnapshot: Sendable {
    package let publicationSequence: UInt64
    package let active: [DomainActivitySnapshot]
    package let recentTerminal: [DomainActivitySnapshot]
}

package enum DomainActivityPublicationResult: Equatable, Sendable {
    case accepted
    case stale
    case duplicateTerminal
    case rejectedTerminalConflict
}

package actor DomainActivityCenter {
    private let identity: DomainRuntimeIdentity
    private let terminalLimit: Int
    private var publicationSequence: UInt64 = 0
    private var nextGeneration: UInt64 = 1
    private var active: [UUID: DomainActivitySnapshot] = [:]
    private var terminal: [DomainActivitySnapshot] = []
    private var subscribers: [UUID: AsyncStream<DomainActivityCenterSnapshot>.Continuation] = [:]
    private var isShuttingDown = false

    package init(identity: DomainRuntimeIdentity, terminalLimit: Int = 128) {
        self.identity = identity
        self.terminalLimit = max(1, terminalLimit)
    }

    package func begin(
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
    package func update(
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
    package func finish(
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

    package func snapshot() -> DomainActivityCenterSnapshot {
        makeSnapshot()
    }

    package func snapshots() -> AsyncStream<DomainActivityCenterSnapshot> {
        let subscriberID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[subscriberID] = continuation
            continuation.yield(makeSnapshot())
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeSubscriber(subscriberID) }
            }
        }
    }

    package func shutdown() {
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
