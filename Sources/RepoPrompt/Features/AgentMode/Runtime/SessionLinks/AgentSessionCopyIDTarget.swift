import AppKit
import Foundation
import RepoPromptDomainRuntime

/// Generation-bearing capture of the exact session incarnation a Copy Session ID action was offered
/// for.
///
/// Capturing only `(tabID, sessionID)` would let a row rebind between render and click and still
/// write a "successful" clipboard value for a session the user never saw. Carrying both generations
/// makes the revalidation an exact incarnation comparison instead of a name comparison.
struct AgentSessionCopyIDTarget: Equatable {
    let windowID: Int
    let workspaceID: UUID
    let tabID: UUID
    let sessionID: UUID
    let persistentBindingGeneration: UUID?
    let bindingTransitionGeneration: UInt64

    init(
        windowID: Int,
        workspaceID: UUID,
        tabID: UUID,
        sessionID: UUID,
        persistentBindingGeneration: UUID?,
        bindingTransitionGeneration: UInt64
    ) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.sessionID = sessionID
        self.persistentBindingGeneration = persistentBindingGeneration
        self.bindingTransitionGeneration = bindingTransitionGeneration
    }

    init(candidate: AgentSessionLinkEndpointCandidate) {
        self.init(
            windowID: candidate.windowID,
            workspaceID: candidate.workspaceID,
            tabID: candidate.tabID,
            sessionID: candidate.sessionID,
            persistentBindingGeneration: candidate.persistentBindingGeneration,
            bindingTransitionGeneration: candidate.bindingTransitionGeneration
        )
    }

    var domainEndpoint: DomainAgentSessionLinkEndpointIdentity {
        DomainAgentSessionLinkEndpointIdentity(
            windowID: windowID,
            workspaceID: workspaceID,
            tabID: tabID,
            sessionID: sessionID,
            persistentBindingGeneration: persistentBindingGeneration,
            bindingTransitionGeneration: bindingTransitionGeneration
        )
    }
}

/// Default clipboard writer. Injected in tests so a copy assertion never touches the real
/// pasteboard.
enum AgentSessionCopyIDClipboard {
    static func write(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

/// Pure decision for the three Copy Session ID surfaces (sidebar hover strip, sidebar context menu,
/// titlebar options menu) so all three fail closed identically and can be tested without UI.
enum AgentSessionCopyIDPolicy {
    enum Outcome: Equatable {
        /// The exact canonical UUID to write. Never a short alias or routing URL.
        case copied(String)
        /// The captured incarnation no longer exists. Perform **zero** clipboard writes and show no
        /// false success.
        case staleTarget
        /// The row is live but is not an eligible oversight endpoint.
        case ineligible
    }

    /// Offer the action only for live, exactly-bound, top-level sessions. Child sessions,
    /// sessionless/provisional rows, and endpoints that are closing or rebinding never get it.
    static func isOfferable(_ candidate: AgentSessionLinkEndpointCandidate) -> Bool {
        AgentSessionLinkEndpointEligibility.targetResolveFailure(for: candidate) == nil
    }

    /// Revalidates immediately before the clipboard write.
    ///
    /// - Parameter liveCandidates: the current candidate set, re-read at click time rather than
    ///   captured at render time.
    static func outcome(
        for target: AgentSessionCopyIDTarget,
        liveCandidates: [AgentSessionLinkEndpointCandidate]
    ) -> Outcome {
        let endpoint = target.domainEndpoint
        let matches = liveCandidates.filter { $0.domainEndpoint == endpoint }
        // Exactly one live incarnation, byte-for-byte and generation-for-generation.
        guard matches.count == 1 else { return .staleTarget }
        guard isOfferable(matches[0]) else { return .ineligible }
        return .copied(target.sessionID.uuidString)
    }
}
