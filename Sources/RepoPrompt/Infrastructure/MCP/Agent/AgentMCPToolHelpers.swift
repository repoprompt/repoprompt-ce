import Foundation
import MCP

// MARK: - Shared MCP Tool Helpers

// SEARCH-HELPER: MCP, Value parsing, normalization, timestamp, agent_run, agent_manage

/// Shared utility functions used by `AgentRunMCPToolService` and `AgentManageMCPToolService`.
/// Extracted to eliminate duplication across the two tool services and the snapshot model.
enum AgentMCPToolHelpers {
    static let maximumTimeoutSeconds: TimeInterval = 86400

    // MARK: - String parsing

    /// Trims whitespace and returns nil for empty strings.
    static func normalizedString(_ value: Value?) -> String? {
        let trimmed = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Requires a non-empty string value, throwing if absent or blank.
    static func requireNonEmptyString(_ value: Value?, name: String) throws -> String {
        guard let normalized = normalizedString(value), !normalized.isEmpty else {
            throw MCPError.invalidParams("\(name) is required.")
        }
        return normalized
    }

    // MARK: - Bool parsing

    /// Parses a boolean from various Value representations (bool, string, int, double).
    static func parseBool(_ value: Value?) -> Bool? {
        switch value {
        case let .bool(boolValue):
            boolValue
        case let .string(stringValue):
            switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes":
                true
            case "false", "0", "no":
                false
            default:
                nil
            }
        case let .int(intValue):
            intValue != 0
        case let .double(doubleValue):
            doubleValue != 0
        case .null, .array, .object:
            nil
        default:
            nil
        }
    }

    // MARK: - Int parsing

    /// Converts a model-supplied double to an `Int` without trapping.
    ///
    /// `Int(someDouble)` is a runtime trap for non-finite values and for magnitudes outside `Int`'s
    /// representable range. That is reachable from ordinary tool arguments: the MCP `Value` decoder
    /// falls back to `.double` for any JSON numeral that does not fit `Int` (`1e300`,
    /// `99999999999999999999`), and no schema validation runs between the transport and these
    /// services. Saturating at the bounds lets each caller's own clamp or validation handle the
    /// value instead of crashing the app.
    static func saturatingInt(fromDouble value: Double) -> Int? {
        guard value.isFinite else { return nil }
        let truncated = value.rounded(.towardZero)
        // `Double(Int.max)` rounds up to 2^63, so `>=` is the correct out-of-range test; `Int.min`
        // is exactly representable, so `<=` saturates it without excluding the valid value.
        if truncated >= Double(Int.max) { return Int.max }
        if truncated <= Double(Int.min) { return Int.min }
        return Int(truncated)
    }

    // MARK: - Timeout parsing

    /// Parses a timeout in seconds from int, double, or string Value representations.
    static func parseTimeoutSeconds(_ value: Value?) throws -> TimeInterval? {
        guard let value else { return nil }
        let seconds: TimeInterval
        switch value {
        case let .int(intValue):
            seconds = TimeInterval(intValue)
        case let .double(doubleValue):
            guard doubleValue.isFinite, doubleValue >= 0 else {
                throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
            }
            seconds = doubleValue
        case let .string(stringValue):
            guard let parsed = Double(stringValue), parsed.isFinite, parsed >= 0 else {
                throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
            }
            seconds = parsed
        case .null:
            return nil
        case .bool, .array, .object:
            throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
        default:
            throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
        }
        guard seconds >= 0 else {
            throw MCPError.invalidParams("timeout must be a non-negative number of seconds.")
        }
        guard seconds <= maximumTimeoutSeconds else {
            throw MCPError.invalidParams("timeout must be \(Self.renderTimeout(maximumTimeoutSeconds)) seconds or less.")
        }
        return seconds
    }

    private static func renderTimeout(_ seconds: TimeInterval) -> String {
        seconds.rounded(.down) == seconds ? String(Int(seconds)) : String(seconds)
    }

    // MARK: - Timestamps

    /// Shared ISO 8601 formatter with fractional seconds, used across all agent MCP surfaces.
    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Formats a date as an ISO 8601 string.
    static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    // MARK: - Value helpers

    /// Returns `.string(value)` when non-nil, `.null` otherwise.
    static func stringOrNull(_ value: String?) -> Value {
        guard let value else { return .null }
        return .string(value)
    }
}
