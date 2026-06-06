//
//  MCPControlMessages.swift
//  RepoPromptShared
//
//  Shared control message definitions for app ↔ CLI communication.
//  Used for explicit termination signals and run completion notifications.
//

import Foundation

// MARK: - Control Method Names

/// Control method names for RepoPrompt-specific MCP notifications.
/// These are sent as JSON-RPC notifications (no "id" field) so no response is expected.
public enum RepoPromptControlMethod {
    /// Sent by app to CLI to request clean termination.
    /// CLI should exit gracefully without retrying.
    public static let terminate = "repoprompt/control/terminate"

    /// Sent by app to CLI when a run (context builder, discover agent) completes.
    /// CLI should exit with success status.
    public static let runCompleted = "repoprompt/control/run_completed"

    /// Sent by app to CLI during long-running operations to indicate progress.
    /// CLI can display on stderr to prevent agent timeouts.
    public static let progress = "repoprompt/control/progress"
}

// MARK: - Termination Reasons

/// Reasons why a connection was terminated.
public enum TerminationReason: String, Codable, Sendable {
    /// User clicked disconnect/boot in the MCP status dashboard
    case userBootFromDashboard = "user_boot_from_dashboard"

    /// Context builder or discover agent run completed successfully
    case runCompleted = "run_completed"

    /// Context builder or discover agent run was cancelled
    case runCancelled = "run_cancelled"

    /// Server is shutting down
    case serverShutdown = "server_shutdown"

    /// Connection was idle too long
    case idleTimeout = "idle_timeout"

    /// Approval was denied
    case approvalDenied = "approval_denied"

    /// Connection was replaced by a new connection for the same runID
    case connectionReplaced = "connection_replaced"
}

// MARK: - Control Notification Payloads

/// Parameters for the terminate control notification.
public struct RepoPromptTerminateParams: Codable, Sendable {
    /// Why the connection is being terminated
    public let reason: TerminationReason

    /// Optional human-readable message for logging
    public let message: String?

    /// When the termination was requested (ISO8601)
    public let requestedAt: Date

    public init(reason: TerminationReason, message: String? = nil, requestedAt: Date = Date()) {
        self.reason = reason
        self.message = message
        self.requestedAt = requestedAt
    }
}

/// Parameters for the run completed control notification.
public struct RepoPromptRunCompletedParams: Codable, Sendable {
    /// Type of run that completed
    public let runType: String // "context_builder", "discover_agent", etc.

    /// Whether the run completed successfully
    public let success: Bool

    /// Optional summary message
    public let summary: String?

    /// When the run completed
    public let completedAt: Date

    public init(runType: String, success: Bool, summary: String? = nil, completedAt: Date = Date()) {
        self.runType = runType
        self.success = success
        self.summary = summary
        self.completedAt = completedAt
    }
}

/// Kind of progress update.
public enum RepoPromptProgressKind: String, Codable, Sendable, Hashable {
    /// Discrete stage transition (e.g., "discovering" → "planning")
    case stage
    /// Periodic heartbeat to indicate operation is still running
    case heartbeat
}

/// Parameters for the progress control notification.
public struct RepoPromptProgressParams: Codable, Sendable, Hashable {
    /// Tool or operation name (e.g., "context_builder", "oracle_send")
    public let tool: String

    /// Kind of progress update
    public let kind: RepoPromptProgressKind

    /// Current stage name (e.g., "discovering", "planning", "waiting_for_response")
    public let stage: String

    /// Short human-readable message
    public let message: String

    /// When this progress was emitted (ISO8601 string)
    public let emittedAt: String

    public init(tool: String, kind: RepoPromptProgressKind, stage: String, message: String, emittedAt: Date = Date()) {
        self.tool = tool
        self.kind = kind
        self.stage = stage
        self.message = message
        // Format date as ISO8601 string for cross-decoder compatibility
        let formatter = ISO8601DateFormatter()
        self.emittedAt = formatter.string(from: emittedAt)
    }
}

// MARK: - JSON-RPC Notification Structure

/// A JSON-RPC 2.0 notification (no id field, so no response expected).
public struct RepoPromptControlNotification<T: Codable & Sendable>: Codable, Sendable {
    public let jsonrpc: String
    public let method: String
    public let params: T

    public init(method: String, params: T) {
        jsonrpc = "2.0"
        self.method = method
        self.params = params
    }

    /// Encodes the notification as a JSON line (with trailing newline) for MCP transport.
    public func encodedJSONLine() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(self) else { return nil }
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

// MARK: - Convenience Factories

public extension RepoPromptControlNotification where T == RepoPromptTerminateParams {
    /// Creates a terminate notification with the given reason.
    static func terminate(reason: TerminationReason, message: String? = nil) -> Self {
        RepoPromptControlNotification(
            method: RepoPromptControlMethod.terminate,
            params: RepoPromptTerminateParams(reason: reason, message: message)
        )
    }
}

public extension RepoPromptControlNotification where T == RepoPromptRunCompletedParams {
    /// Creates a run completed notification.
    static func runCompleted(runType: String, success: Bool, summary: String? = nil) -> Self {
        RepoPromptControlNotification(
            method: RepoPromptControlMethod.runCompleted,
            params: RepoPromptRunCompletedParams(runType: runType, success: success, summary: summary)
        )
    }
}

public extension RepoPromptControlNotification where T == RepoPromptProgressParams {
    /// Creates a progress notification for a stage transition.
    static func stage(tool: String, stage: String, message: String) -> Self {
        RepoPromptControlNotification(
            method: RepoPromptControlMethod.progress,
            params: RepoPromptProgressParams(tool: tool, kind: .stage, stage: stage, message: message)
        )
    }

    /// Creates a heartbeat progress notification.
    static func heartbeat(tool: String, stage: String, message: String) -> Self {
        RepoPromptControlNotification(
            method: RepoPromptControlMethod.progress,
            params: RepoPromptProgressParams(tool: tool, kind: .heartbeat, stage: stage, message: message)
        )
    }
}

// MARK: - Kill Signal Files (Filesystem Side-Channel)

/// Kill signals are written to a shared directory that the CLI watches with a DispatchSource.
/// This works for both network and filesystem transports as a reliable side-channel.
/// The CLI sets up a watcher on this directory and exits when it sees its session killed.
public enum MCPKillSignal {
    /// Kill signal file for a specific session token in the caller-selected flavor directory.
    public static func signalFileURL(forSessionToken token: String, directory: URL) -> URL {
        directory.appendingPathComponent("\(token).kill")
    }

    /// Content of a kill signal file
    public struct SignalContent: Codable, Sendable {
        public let reason: TerminationReason
        public let message: String?
        public let killedAt: Date

        public init(reason: TerminationReason, message: String?, killedAt: Date) {
            self.reason = reason
            self.message = message
            self.killedAt = killedAt
        }
    }

    /// Writes a kill signal file for a session.
    /// CLI watches this directory with a DispatchSource and exits when it sees its session killed.
    public static func writeKillSignal(
        sessionToken: String,
        reason: TerminationReason,
        message: String? = nil,
        directory: URL
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let content = SignalContent(
            reason: reason,
            message: message,
            killedAt: Date()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(content)

        let url = signalFileURL(forSessionToken: sessionToken, directory: directory)
        try data.write(to: url, options: .atomic)
    }

    /// Reads a kill signal if it exists for this session.
    public static func readKillSignal(forSessionToken token: String, directory: URL) -> SignalContent? {
        let url = signalFileURL(forSessionToken: token, directory: directory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SignalContent.self, from: data)
    }

    /// Removes a kill signal file (called by CLI after acknowledging).
    public static func removeKillSignal(forSessionToken token: String, directory: URL) {
        try? FileManager.default.removeItem(at: signalFileURL(forSessionToken: token, directory: directory))
    }

    /// Cleans up old kill signal files (older than 1 hour).
    public static func cleanupStaleSignals(in directory: URL) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600) // 1 hour

        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in contents where url.pathExtension == "kill" {
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let modDate = attrs[.modificationDate] as? Date,
               modDate < cutoff
            {
                try? fm.removeItem(at: url)
            }
        }
    }
}

// MARK: - Detection Helpers

/// Helpers for detecting control messages in incoming data.
public enum RepoPromptControlDetection {
    /// Fast check if a JSON line might be a control notification (before full parse).
    /// Checks for the method prefix bytes.
    public static func mightBeControlNotification(_ data: Data) -> Bool {
        // Look for "repoprompt/control/" in the data
        let marker = "repoprompt/control/".data(using: .utf8)!
        return data.range(of: marker) != nil
    }

    /// Parses a JSON line and extracts the method if it's a notification.
    /// Returns nil if not a notification or parsing fails.
    public static func extractNotificationMethod(from jsonLine: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: jsonLine) as? [String: Any],
              json["id"] == nil, // Notifications have no id
              let method = json["method"] as? String
        else { return nil }
        return method
    }

    /// Parses terminate params from a JSON line.
    public static func parseTerminateParams(from jsonLine: Data) -> RepoPromptTerminateParams? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let notification = try? decoder.decode(
            RepoPromptControlNotification<RepoPromptTerminateParams>.self,
            from: jsonLine
        ) else { return nil }
        return notification.params
    }

    /// Parses run completed params from a JSON line.
    public static func parseRunCompletedParams(from jsonLine: Data) -> RepoPromptRunCompletedParams? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let notification = try? decoder.decode(
            RepoPromptControlNotification<RepoPromptRunCompletedParams>.self,
            from: jsonLine
        ) else { return nil }
        return notification.params
    }

    /// Parses progress params from a JSON line.
    public static func parseProgressParams(from jsonLine: Data) -> RepoPromptProgressParams? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let notification = try? decoder.decode(
            RepoPromptControlNotification<RepoPromptProgressParams>.self,
            from: jsonLine
        ) else { return nil }
        return notification.params
    }
}
