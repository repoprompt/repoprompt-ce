//
//  AgentMessage.swift
//  RepoPrompt
//
//  Minimal message struct for headless agent providers.
//  Unlike AIMessage (legacy chat system with XML formatting, prompt sections, etc.),
//  this contains only what headless agents actually need.
//

import Foundation

enum AgentPromptContentPart: Equatable {
    case text(String)
    case image(AITransientImage)

    var text: String? {
        guard case let .text(text) = self else { return nil }
        return text
    }
}

/// A minimal message for headless agent providers.
/// Contains just the system prompt channel and user message channel.
public struct AgentMessage: Sendable, Equatable {
    /// System prompt / instructions for the agent
    public var systemPrompt: String

    /// The user's message / task
    public var userMessage: String

    var promptContentParts: [AgentPromptContentPart] = []

    /// Optional provider-specific session ID for resuming conversations
    /// Used by Claude CLI to resume with --resume <session-id> instead of replaying history
    public var resumeSessionID: String?

    public init(systemPrompt: String = "", userMessage: String, resumeSessionID: String? = nil) {
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.resumeSessionID = resumeSessionID
    }
}
