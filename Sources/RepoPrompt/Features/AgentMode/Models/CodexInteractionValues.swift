import Foundation
import RepoPromptDomainRuntime

package struct AgentRequestUserInputOption: Hashable {
    package let label: String
    package let description: String

    package init(label: String, description: String) {
        self.label = label
        self.description = description
    }
}

package struct AgentRequestUserInputQuestion: Hashable {
    package let id: String
    package let header: String
    package let question: String
    package let isOther: Bool
    package let isSecret: Bool
    package let options: [AgentRequestUserInputOption]

    package init(id: String, header: String, question: String, isOther: Bool, isSecret: Bool, options: [AgentRequestUserInputOption]) {
        self.id = id
        self.header = header
        self.question = question
        self.isOther = isOther
        self.isSecret = isSecret
        self.options = options
    }
}

package struct AgentRequestUserInputRequest: Identifiable, Hashable {
    package let id: UUID
    package let requestID: CodexAppServerRequestID
    package let method: String
    package let threadID: String
    package let turnID: String
    package let itemID: String
    package let askedAt: Date
    package let questions: [AgentRequestUserInputQuestion]
    /// Established from structured provider metadata, never the displayed question or bare tool name.
    package let computerUseCompanionVerified: Bool
    package let repoPromptAutoApprovalVerified: Bool

    package init(
        id: UUID? = nil,
        requestID: CodexAppServerRequestID,
        method: String,
        threadID: String,
        turnID: String,
        itemID: String,
        askedAt: Date = Date(),
        questions: [AgentRequestUserInputQuestion],
        repoPromptAutoApprovalVerified: Bool = false,
        computerUseCompanionVerified: Bool = false
    ) {
        self.id = id ?? Self.stableID(
            requestID: requestID,
            method: method,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID
        )
        self.requestID = requestID
        self.method = method
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.askedAt = askedAt
        self.questions = questions
        self.repoPromptAutoApprovalVerified = repoPromptAutoApprovalVerified
        self.computerUseCompanionVerified = computerUseCompanionVerified
    }

    package static func stableID(
        requestID: CodexAppServerRequestID,
        method: String,
        threadID: String,
        turnID: String,
        itemID: String
    ) -> UUID {
        StableUserInteractionIdentity.uuid(
            from: "request-user-input|\(requestID.displayValue)|\(method)|\(threadID)|\(turnID)|\(itemID)"
        )
    }
}

package struct AgentMCPElicitationRequest: Identifiable, Hashable {
    package let id: UUID
    package let requestID: CodexAppServerRequestID
    package let method: String
    package let threadID: String
    package let turnID: String
    package let itemID: String
    package let serverName: String?
    package let toolName: String?
    package let title: String
    package let prompt: String?
    package let message: String?
    package let schemaJSON: String?
    package let defaultContentJSON: String?
    package let rawParamsJSON: String
    package let details: [AgentApprovalDetail]

    package init(
        id: UUID? = nil,
        requestID: CodexAppServerRequestID,
        method: String,
        threadID: String,
        turnID: String,
        itemID: String,
        serverName: String? = nil,
        toolName: String? = nil,
        title: String = "MCP Elicitation Requested",
        prompt: String? = nil,
        message: String? = nil,
        schemaJSON: String? = nil,
        defaultContentJSON: String? = nil,
        rawParamsJSON: String,
        details: [AgentApprovalDetail] = []
    ) {
        self.id = id ?? Self.stableID(
            requestID: requestID,
            method: method,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID
        )
        self.requestID = requestID
        self.method = method
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.serverName = serverName
        self.toolName = toolName
        self.title = title
        self.prompt = prompt
        self.message = message
        self.schemaJSON = schemaJSON
        self.defaultContentJSON = defaultContentJSON
        self.rawParamsJSON = rawParamsJSON
        self.details = details
    }

    package static func stableID(
        requestID: CodexAppServerRequestID,
        method: String,
        threadID: String,
        turnID: String,
        itemID: String
    ) -> UUID {
        StableUserInteractionIdentity.uuid(
            from: "mcp-elicitation-request|\(requestID.displayValue)|\(method)|\(threadID)|\(turnID)|\(itemID)"
        )
    }
}

package struct AgentPermissionsRequest: Identifiable, Hashable {
    package let id: UUID
    package let requestID: CodexAppServerRequestID
    package let method: String
    package let threadID: String
    package let turnID: String
    package let itemID: String
    package let cwd: String
    package let reason: String?
    package let permissionsJSON: String
    package let details: [AgentApprovalDetail]

    package init(
        id: UUID? = nil,
        requestID: CodexAppServerRequestID,
        method: String,
        threadID: String,
        turnID: String,
        itemID: String,
        cwd: String,
        reason: String? = nil,
        permissionsJSON: String,
        details: [AgentApprovalDetail] = []
    ) {
        self.id = id ?? Self.stableID(
            requestID: requestID,
            method: method,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID
        )
        self.requestID = requestID
        self.method = method
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.cwd = cwd
        self.reason = reason
        self.permissionsJSON = permissionsJSON
        self.details = details
    }

    package static func stableID(
        requestID: CodexAppServerRequestID,
        method: String,
        threadID: String,
        turnID: String,
        itemID: String
    ) -> UUID {
        StableUserInteractionIdentity.uuid(
            from: "permissions-request|\(requestID.displayValue)|\(method)|\(threadID)|\(turnID)|\(itemID)"
        )
    }
}
