//
//  Service.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-06-20.
//

import Foundation
import MCP
import RepoPromptDomainRuntime
import SwiftUI

@preconcurrency
protocol Service: AnyObject {
    var domainRegistrationID: MCPDomainToolRegistrationID { get }
    var tools: [Tool] { get async }

    var isActivated: Bool { get async }
    func activate() async throws
}

/// ---------------------------------------------------------------------
///  Default no-op behaviour – a Service can become "active" lazily
/// ---------------------------------------------------------------------
extension Service {
    var isActivated: Bool {
        get async { true }
    }

    func activate() async throws {}

    /// Dispatch a tool call to the matching `Tool` implementation.
    /// RepoPrompt CE keeps registered tools callable; feature availability is not gated here.
    func call(
        tool name: String,
        with arguments: [String: Value]
    ) async throws -> Value? {
        for tool in await tools where tool.name == name {
            return try await tool.callAsFunction(arguments)
        }
        return nil
    }
}

/// ---------------------------------------------------------------------
///  Convenience builder so individual services can declare their tools
///  with a clean DSL style (`@ToolBuilder var tools: [Tool] { … }`)
/// ---------------------------------------------------------------------
@resultBuilder
struct ToolBuilder {
    static func buildBlock(_ tools: Tool...) -> [Tool] {
        tools
    }
}
