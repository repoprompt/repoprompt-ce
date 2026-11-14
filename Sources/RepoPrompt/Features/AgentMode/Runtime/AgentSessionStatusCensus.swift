import Foundation
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

/// Demand-owned cache, not a link observer or an execution owner. No authority writes.
@MainActor
final class AgentSessionStatusCensus {
    struct Sample: Equatable {
        let candidate: AgentSessionLinkEndpointCandidate
        let status: AgentSessionLinkStatusProjection?
        let outcome: DomainAgentSessionLaneBoard.RunOutcome?
        let ownerIdentity: ObjectIdentifier?
        let sessionIdentity: ObjectIdentifier?
        var workspaceName: String?
        var workspaceRoots: [String] = []
        var oversightRole: AgentSessionOversightRole = .none

        init(
            candidate: AgentSessionLinkEndpointCandidate,
            status: AgentSessionLinkStatusProjection?,
            outcome: DomainAgentSessionLaneBoard.RunOutcome?,
            ownerIdentity: ObjectIdentifier? = nil,
            sessionIdentity: ObjectIdentifier? = nil
        ) {
            self.candidate = candidate
            self.status = status
            self.outcome = outcome
            self.ownerIdentity = ownerIdentity
            self.sessionIdentity = sessionIdentity
        }
    }

    struct Row: Equatable {
        let sample: Sample
        let sequence: UInt64
        let observedAt: Date
    }

    typealias Endpoint = DomainAgentSessionLinkEndpointIdentity
    private let capture: () -> [Sample]
    private let isEnabled: @MainActor () -> Bool
    private let observe: (AgentSessionLinkEndpointCandidate, @escaping @MainActor () -> Void) -> AgentSessionLinkObservationToken?
    private var tokens: [Endpoint: AgentSessionLinkObservationToken] = [:]
    private var rows: [Endpoint: Row] = [:]
    private var sequence: UInt64 = 0
    private var timer: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var sink: (([Row]) -> Void)?
    private(set) var publicationCount = 0

    init(
        capture: @escaping () -> [Sample],
        observe: @escaping (AgentSessionLinkEndpointCandidate, @escaping @MainActor () -> Void) -> AgentSessionLinkObservationToken?,
        isEnabled: @escaping @MainActor () -> Bool = { GlobalSettingsStore.shared.experimentalCommandCenter() }
    ) {
        self.capture = capture
        self.observe = observe
        self.isEnabled = isEnabled
    }

    static func appCensus(isEnabled: @escaping @MainActor () -> Bool = { GlobalSettingsStore.shared.experimentalCommandCenter() }) -> AgentSessionStatusCensus {
        let manager = WindowStatesManager.shared
        return AgentSessionStatusCensus(capture: {
            guard !manager.isTerminating else { return [] }
            let candidates = manager.sessionRuntimeWindows.filter {
                !$0.isClosing && manager.modelRoutingWindow(withID: $0.windowID) === $0
            }.flatMap { window in
                let vm = window.agentModeViewModel
                // Include retained live stashed contexts too. The link picker enumerates compose
                // tabs only; a human census must not hide a still-running stashed session.
                let ids = Set(vm.sessions.values.compactMap(\.activeAgentSessionID))
                return vm.agentSessionLinkCandidates(forSessionIDs: ids, includeLocation: false).values.flatMap(\.self)
            }
            return candidates.map { candidate in
                let vm = manager.modelRoutingWindow(withID: candidate.windowID)?.agentModeViewModel
                let eligible = candidate.hasLoadedPersistedState && !candidate.bindingTransitionInProgress
                    && candidate.restorationReadiness.permitsBoundOperationAndSave
                    && candidate.persistentBindingGeneration != nil
                    && !candidate.isClosing && !candidate.isDeletionInProgress
                let status = eligible ? vm?.agentSessionLinkStatusProjection(for: candidate) : nil
                let outcome = eligible ? vm?.sessions[candidate.tabID].map {
                    AgentModeViewModel.laneBoard(for: $0, blockers: [], subagentCounts: (0, 0)).runOutcome
                } : nil
                var sample = Sample(
                    candidate: candidate,
                    status: status,
                    outcome: outcome,
                    ownerIdentity: vm.map(ObjectIdentifier.init),
                    sessionIdentity: vm?.sessions[candidate.tabID].map(ObjectIdentifier.init)
                )
                let workspace = manager.modelRoutingWindow(withID: candidate.windowID)?.workspaceManager.workspace(withID: candidate.workspaceID)
                sample.workspaceName = workspace?.name
                sample.workspaceRoots = workspace?.repoPaths ?? []
                sample.oversightRole = vm?.agentSidebarOversightRole(tabID: candidate.tabID, expectedSessionID: candidate.sessionID) ?? .none
                return sample
            }
        }, observe: { candidate, changed in
            manager.modelRoutingWindow(withID: candidate.windowID)?.agentModeViewModel
                .agentSessionLinkInstallObservation(for: candidate, onChange: changed)
        }, isEnabled: isEnabled)
    }

    /// One consumer (the single-instance center). One narrow token per exact endpoint. A 1 Hz
    /// safety census detects retention/handoff and workspace changes; settled signals additionally
    /// request a coalesced capture (at most ten signal batches/sec). UI publication is coalesced
    /// separately by the read model.
    func start(_ sink: @escaping ([Row]) -> Void) {
        guard isEnabled() else { stop()
            return
        }
        guard self.sink == nil else { return }
        self.sink = sink
        publicationCount = 0
        refresh()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        sink = nil
        timer?.cancel()
        timer = nil
        pending?.cancel()
        pending = nil
        tokens.values.forEach { $0.invalidate() }
        tokens.removeAll()
        rows.removeAll()
    }

    private func scheduleRefresh() {
        guard isEnabled(), sink != nil, pending == nil else { return }
        // Settled signals may arrive for every stream chunk. At most 10 batches/sec, not one UI
        // publication per token/event. No async hop occurs between sample and sequence allocation.
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            pending = nil
            refresh()
        }
    }

    func refresh() {
        guard isEnabled() else { stop()
            return
        }
        guard let sink else { return }
        let samples = capture()
        let endpoints = Set(samples.map(\.candidate.domainEndpoint))
        for endpoint in Array(tokens.keys) where !endpoints.contains(endpoint) {
            tokens.removeValue(forKey: endpoint)?.invalidate()
        }
        var next: [Endpoint: Row] = [:]
        for sample in samples {
            let endpoint = sample.candidate.domainEndpoint
            if let previous = rows[endpoint],
               previous.sample.ownerIdentity != sample.ownerIdentity || previous.sample.sessionIdentity != sample.sessionIdentity
            {
                tokens.removeValue(forKey: endpoint)?.invalidate()
            }
            if tokens[endpoint] == nil {
                tokens[endpoint] = observe(sample.candidate) { [weak self] in self?.scheduleRefresh() }
            }
            if let previous = rows[endpoint], previous.sample == sample {
                next[endpoint] = previous
            } else {
                sequence &+= 1
                next[endpoint] = Row(sample: sample, sequence: sequence, observedAt: Date())
            }
        }
        guard next != rows || publicationCount == 0 else { return }
        rows = next
        publicationCount += 1
        sink(next.values.sorted { $0.sample.candidate.sessionID.uuidString < $1.sample.candidate.sessionID.uuidString })
    }
}
