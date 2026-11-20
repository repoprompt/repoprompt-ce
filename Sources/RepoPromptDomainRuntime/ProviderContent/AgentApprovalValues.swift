import Foundation

package struct AgentApprovalDetail: Identifiable, Hashable {
    package let id: UUID
    package let label: String
    package let value: String
    package let isCode: Bool

    package static func stableID(
        requestSeed: String,
        index: Int,
        label: String,
        value: String,
        isCode: Bool
    ) -> UUID {
        StableUserInteractionIdentity.uuid(
            from: "approval-detail|\(requestSeed)|\(index)|\(label)|\(isCode)|\(value)"
        )
    }

    private static func defaultStableID(
        label: String,
        value: String,
        isCode: Bool
    ) -> UUID {
        StableUserInteractionIdentity.uuid(from: "approval-detail-default|\(label)|\(isCode)|\(value)")
    }

    package init(id: UUID? = nil, label: String, value: String, isCode: Bool = false) {
        self.id = id ?? Self.defaultStableID(label: label, value: value, isCode: isCode)
        self.label = label
        self.value = value
        self.isCode = isCode
    }
}

package enum AgentApprovalKind: String, Hashable {
    case commandExecution
    case fileChange
}

package enum AgentApprovalDecision: Hashable {
    case accept
    case acceptForSession
    case acceptWithExecpolicyAmendment(String)
    case decline
    case cancel

    package static func parseExecpolicyAmendment(_ json: String) -> [String]? {
        guard let values = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String],
              !values.isEmpty
        else { return nil }
        return values
    }
}

package enum AgentApprovalRequestID: Hashable {
    package var identitySeed: String {
        switch self {
        case let .codex(receipt): receipt.identitySeed
        case let .claudeControl(id), let .acp(id): id
        }
    }

    case codex(CodexServerRequestReceipt)
    case claudeControl(String)
    case acp(String)

    package var displayValue: String {
        switch self {
        case let .codex(receipt):
            receipt.requestID.displayValue
        case let .claudeControl(id):
            id
        case let .acp(id):
            id
        }
    }
}

/// Provider-projected scope of the session decision; nil preserves legacy presentation.
package enum AgentApprovalSessionScope: Hashable {
    case oneTime
    case editsSession
}

package struct AgentApprovalRequest: Identifiable, Hashable {
    package let id: UUID
    package let requestID: AgentApprovalRequestID
    package let method: String
    package let kind: AgentApprovalKind
    package let threadID: String
    package let turnID: String
    package let itemID: String
    package let reason: String?
    package let command: String?
    package let cwd: String?
    package let grantRoot: String?
    package let proposedExecpolicyAmendmentJSON: String?
    /// Codex's top-level advertised choices. Nil preserves legacy behavior; empty permits nothing.
    package let availableDecisions: [AgentApprovalDecision]?
    /// ACP-only snapshot of genuine one-time allow availability; submission rechecks the live request.
    package let overseerOneTimeAllowAvailable: Bool?
    /// ACP-only availability of the ordinary one-time decision, derived from live provider options.
    package let plainApproveAvailable: Bool?
    /// Live request scope only; this does not store or grant consent.
    package let sessionApprovalScope: AgentApprovalSessionScope?
    package let details: [AgentApprovalDetail]

    package init(
        id: UUID? = nil,
        requestID: AgentApprovalRequestID,
        method: String,
        kind: AgentApprovalKind,
        threadID: String,
        turnID: String,
        itemID: String,
        reason: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        grantRoot: String? = nil,
        proposedExecpolicyAmendmentJSON: String? = nil,
        availableDecisions: [AgentApprovalDecision]? = nil,
        overseerOneTimeAllowAvailable: Bool? = nil,
        plainApproveAvailable: Bool? = nil,
        sessionApprovalScope: AgentApprovalSessionScope? = nil,
        details: [AgentApprovalDetail] = []
    ) {
        self.id = id ?? Self.stableID(
            requestID: requestID,
            method: method,
            kind: kind,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID
        )
        self.requestID = requestID
        self.method = method
        self.kind = kind
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.reason = reason
        self.command = command
        self.cwd = cwd
        self.grantRoot = grantRoot
        self.proposedExecpolicyAmendmentJSON = proposedExecpolicyAmendmentJSON
        self.availableDecisions = availableDecisions
        self.overseerOneTimeAllowAvailable = overseerOneTimeAllowAvailable
        self.plainApproveAvailable = plainApproveAvailable
        self.sessionApprovalScope = sessionApprovalScope
        self.details = details
    }

    package static func stableID(
        requestID: AgentApprovalRequestID,
        method: String,
        kind: AgentApprovalKind,
        threadID: String,
        turnID: String,
        itemID: String
    ) -> UUID {
        StableUserInteractionIdentity.uuid(
            from: "approval-request|\(requestID.identitySeed)|\(method)|\(kind.rawValue)|\(threadID)|\(turnID)|\(itemID)"
        )
    }

    package var title: String {
        switch kind {
        case .commandExecution:
            "Command Approval"
        case .fileChange:
            "File Change Approval"
        }
    }

    /// Request authority only. The coordinator additionally intersects the live Computer Use rule.
    package func allows(_ decision: AgentApprovalDecision) -> Bool {
        guard case .codex = requestID else {
            switch decision {
            case .accept: return supportsPlainApprove
            case .acceptForSession: return sessionApprovalScope != .oneTime
            case .acceptWithExecpolicyAmendment: return kind == .commandExecution && sessionApprovalScope == nil
            case .decline, .cancel: return true
            }
        }
        if case let .acceptWithExecpolicyAmendment(json) = decision {
            guard kind == .commandExecution,
                  let amendment = AgentApprovalDecision.parseExecpolicyAmendment(json)
            else { return false }
            guard let availableDecisions else { return true }
            return availableDecisions.contains { advertised in
                guard case let .acceptWithExecpolicyAmendment(value) = advertised else { return false }
                guard let advertised = AgentApprovalDecision.parseExecpolicyAmendment(value) else { return false }
                return advertised.elementsEqual(amendment) { $0.utf8.elementsEqual($1.utf8) }
            }
        }
        return availableDecisions?.contains(decision) ?? true
    }

    package var rememberedDecision: AgentApprovalDecision? {
        if case .codex = requestID, let availableDecisions {
            if let amendment = availableDecisions.first(where: {
                if case .acceptWithExecpolicyAmendment = $0 { return allows($0) }
                return false
            }) { return amendment }
        } else if let json = proposedExecpolicyAmendmentJSON, !json.isEmpty {
            let decision = AgentApprovalDecision.acceptWithExecpolicyAmendment(json)
            if allows(decision) { return decision }
        }
        return allows(.acceptForSession) ? .acceptForSession : nil
    }

    /// The amendment shown alongside Remember, without letting legacy metadata override a list.
    package var presentedExecpolicyAmendmentJSON: String? {
        if case .codex = requestID, availableDecisions != nil {
            guard case let .acceptWithExecpolicyAmendment(json)? = rememberedDecision else { return nil }
            return json
        }
        return proposedExecpolicyAmendmentJSON
    }

    package var supportsExecpolicyAmendment: Bool {
        guard kind == .commandExecution, sessionApprovalScope == nil else { return false }
        guard case .codex = requestID, availableDecisions != nil else { return true }
        if case .acceptWithExecpolicyAmendment? = rememberedDecision { return true }
        return false
    }

    package var supportsPlainApprove: Bool {
        switch requestID {
        case .codex: allows(.accept)
        case .acp: plainApproveAvailable == true
        case .claudeControl: true
        }
    }

    package var supportsAlwaysAllow: Bool {
        if case .codex = requestID { return rememberedDecision != nil }
        return sessionApprovalScope != .oneTime
    }

    package var sessionApprovalLabel: String {
        sessionApprovalScope == .editsSession ? "Allow edits this session" : "Always Allow"
    }
}
