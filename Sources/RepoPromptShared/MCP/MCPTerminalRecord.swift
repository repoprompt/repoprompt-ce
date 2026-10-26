import CryptoKit
import Foundation

public enum MCPTerminalLayer: String, Codable, Sendable {
    case appAcceptedSocket = "app_accepted_socket"
    case proxy
}

public enum MCPTerminalInitiator: String, Codable, Sendable {
    case app
    case host
    case peer
    case proxy
    case transport
    case unknown
}

public struct MCPTerminalRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let monotonicUptime: TimeInterval
    public let layer: MCPTerminalLayer
    public let initiator: MCPTerminalInitiator
    public let reason: String
    public let sessionFingerprint: MCPTerminalFingerprint?
    public let localPID: Int
    public let peerPID: Int?
    public let appConnectionID: UUID?
    public let connectionGeneration: UInt64?
    public let errno: Int32?
    public let errorDescription: String?
    public let toolName: String?
    public let invocationID: UUID?
    public let elapsedMilliseconds: Double?
    public let handlerPhase: String?
    public let handlerPhaseAgeMilliseconds: Double?
    public let executionDeadlineMilliseconds: Double?
    public let cleanupGraceMilliseconds: Double?
    public let bridgeActiveRequestCount: Int?
    public let bridgeResponseInDeliveryCount: Int?
    public let bridgeCancellationTombstoneCount: Int?
    public let bridgeRecentCompletionCount: Int?
    public let bridgePendingTransactionCount: Int?
    public let bridgeHasForwardedProtocolFrame: Bool?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        monotonicUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        layer: MCPTerminalLayer,
        initiator: MCPTerminalInitiator,
        reason: String,
        sessionToken: String?,
        localPID: Int,
        peerPID: Int?,
        appConnectionID: UUID?,
        connectionGeneration: UInt64?,
        errno: Int32?,
        errorDescription: String?,
        bridgeActiveRequestCount: Int? = nil,
        bridgeResponseInDeliveryCount: Int? = nil,
        bridgeCancellationTombstoneCount: Int? = nil,
        bridgeRecentCompletionCount: Int? = nil,
        bridgePendingTransactionCount: Int? = nil,
        bridgeHasForwardedProtocolFrame: Bool? = nil,
        toolName: String? = nil,
        invocationID: UUID? = nil,
        elapsedMilliseconds: Double? = nil,
        handlerPhase: String? = nil,
        handlerPhaseAgeMilliseconds: Double? = nil,
        executionDeadlineMilliseconds: Double? = nil,
        cleanupGraceMilliseconds: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.monotonicUptime = monotonicUptime
        self.layer = layer
        self.initiator = initiator
        self.reason = Self.privacySafeText(
            reason,
            maximumLength: 512,
            sensitiveValues: [sessionToken]
        ) ?? "unknown"
        sessionFingerprint = MCPTerminalFingerprint.session(sessionToken)
        self.localPID = localPID
        self.peerPID = peerPID
        self.appConnectionID = appConnectionID
        self.connectionGeneration = connectionGeneration
        self.errno = errno
        self.errorDescription = Self.privacySafeText(
            errorDescription,
            maximumLength: 2048,
            sensitiveValues: [sessionToken]
        )
        self.toolName = Self.privacySafeText(
            toolName,
            maximumLength: 256,
            sensitiveValues: [sessionToken]
        )
        self.invocationID = invocationID
        self.elapsedMilliseconds = Self.nonNegativeFinite(elapsedMilliseconds)
        self.handlerPhase = Self.privacySafeText(
            handlerPhase,
            maximumLength: 256,
            sensitiveValues: [sessionToken]
        )
        self.handlerPhaseAgeMilliseconds = Self.nonNegativeFinite(handlerPhaseAgeMilliseconds)
        self.executionDeadlineMilliseconds = Self.nonNegativeFinite(executionDeadlineMilliseconds)
        self.cleanupGraceMilliseconds = Self.nonNegativeFinite(cleanupGraceMilliseconds)
        self.bridgeActiveRequestCount = bridgeActiveRequestCount
        self.bridgeResponseInDeliveryCount = bridgeResponseInDeliveryCount
        self.bridgeCancellationTombstoneCount = bridgeCancellationTombstoneCount
        self.bridgeRecentCompletionCount = bridgeRecentCompletionCount
        self.bridgePendingTransactionCount = bridgePendingTransactionCount
        self.bridgeHasForwardedProtocolFrame = bridgeHasForwardedProtocolFrame
    }

    private enum CodingKeys: String, CodingKey {
        // Preserve the legacy camel-case wire contract. Only the appended watchdog
        // attribution fields use the operational snake-case key convention.
        case id
        case timestamp
        case monotonicUptime
        case layer
        case initiator
        case reason
        case sessionFingerprint
        case localPID
        case peerPID
        case appConnectionID
        case connectionGeneration
        case errno
        case errorDescription
        case bridgeActiveRequestCount
        case bridgeResponseInDeliveryCount
        case bridgeCancellationTombstoneCount
        case bridgeRecentCompletionCount
        case bridgePendingTransactionCount
        case bridgeHasForwardedProtocolFrame
        case toolName = "tool_name"
        case invocationID = "invocation_id"
        case elapsedMilliseconds = "elapsed_ms"
        case handlerPhase = "handler_phase"
        case handlerPhaseAgeMilliseconds = "handler_phase_age_ms"
        case executionDeadlineMilliseconds = "execution_deadline_ms"
        case cleanupGraceMilliseconds = "cleanup_grace_ms"
    }

    private static func nonNegativeFinite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }

    private static func privacySafeText(
        _ value: String?,
        maximumLength: Int,
        sensitiveValues: [String?]
    ) -> String? {
        guard let value else { return nil }
        var sanitized = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        for sensitiveValue in sensitiveValues.compactMap(\.self) where !sensitiveValue.isEmpty {
            sanitized = sanitized.replacingOccurrences(
                of: sensitiveValue,
                with: "<redacted>"
            )
        }

        let credentialURLPattern = #"(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#
        if let regex = try? NSRegularExpression(pattern: credentialURLPattern) {
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                range: range,
                withTemplate: "$1<redacted>@"
            )
        }

        let sensitiveKeyPattern = #"(?i)([\"']?[a-z0-9_.-]*(?:authorization|proxy-authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|session[_-]?token|token|secret|password|credential|private[_-]?key|cookie|set-cookie|environment|request[_-]?payload|payload|prompt)[a-z0-9_.-]*[\"']?\s*[:=]\s*)(?:bearer\s+[^\s,;&]+|basic\s+[^\s,;&]+|\"[^\"]*\"|'[^']*'|[^\s,;&]+)"#
        if let regex = try? NSRegularExpression(pattern: sensitiveKeyPattern) {
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                range: range,
                withTemplate: "$1<redacted>"
            )
        }

        let standaloneSecretPatterns = [
            #"(?i)\b(bearer|basic)\s+[a-z0-9._~+/=-]+"#,
            #"\beyJ[a-zA-Z0-9_-]{8,}\.[a-zA-Z0-9_-]{8,}\.[a-zA-Z0-9_-]{8,}\b"#,
            #"\bsk-[a-zA-Z0-9_-]{16,}\b"#
        ]
        for pattern in standaloneSecretPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                range: range,
                withTemplate: "<redacted>"
            )
        }

        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumLength))
    }
}

public struct MCPTerminalFingerprint: Codable, CustomStringConvertible, Equatable, Sendable {
    private static let salt = "RepoPrompt.CE.MCP.terminal.v1:"
    private let value: String

    public var description: String {
        value
    }

    private init(value: String) {
        self.value = value
    }

    public static func session(_ sessionToken: String?) -> MCPTerminalFingerprint? {
        guard let sessionToken, !sessionToken.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data((salt + sessionToken).utf8))
        return MCPTerminalFingerprint(
            value: "sha256:" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard value.range(
            of: #"^sha256:[0-9a-f]{16}$"#,
            options: .regularExpression
        ) != nil else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid MCP terminal fingerprint"
            )
        }
        self.value = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum MCPTerminalRecordStore {
    private static let retainedRecordLimit = 256

    @discardableResult
    public static func write(
        _ record: MCPTerminalRecord,
        to directory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: record.timestamp)
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = directory.appendingPathComponent(
            "terminal-\(timestamp)-\(record.id.uuidString).json",
            isDirectory: false
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        // Retention is best-effort: never discard the terminal event we just
        // captured merely because an older diagnostic could not be removed.
        try? pruneTerminalRecords(
            in: directory,
            keeping: retainedRecordLimit,
            preserving: fileURL,
            fileManager: fileManager
        )
        return fileURL
    }

    private static func pruneTerminalRecords(
        in directory: URL,
        keeping limit: Int,
        preserving preservedRecord: URL,
        fileManager: FileManager
    ) throws {
        let terminalRecords = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).filter { fileURL in
            fileURL.pathExtension == "json"
                && fileURL.lastPathComponent.hasPrefix("terminal-")
        }.sorted { lhs, rhs in
            lhs.lastPathComponent > rhs.lastPathComponent
        }

        guard terminalRecords.count > limit else { return }
        let preservedPath = preservedRecord.standardizedFileURL.path
        var retainedPaths: Set<String> = [preservedPath]
        for record in terminalRecords where retainedPaths.count < limit {
            retainedPaths.insert(record.standardizedFileURL.path)
        }
        for staleRecord in terminalRecords where !retainedPaths.contains(staleRecord.standardizedFileURL.path) {
            do {
                try fileManager.removeItem(at: staleRecord)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            }
        }
    }

    @discardableResult
    public static func writeBestEffort(
        _ record: MCPTerminalRecord,
        to directory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        try? write(record, to: directory, fileManager: fileManager)
    }
}
