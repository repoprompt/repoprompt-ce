import Foundation
import RepoPromptInstrumentation

#if DEBUG
    import os

    /// Debug-only, opt-in instrumentation for workspace/window restore and Agent activation hot paths.
    ///
    /// Enable in debug builds with either:
    /// - `defaults write com.repoprompt.RepoPrompt enableWorkspaceRestorePerfLogging -bool YES`
    /// - `RP_WORKSPACE_RESTORE_PERF_LOGGING=1`
    ///
    /// This file is compiled behind `#if DEBUG`; release builds do not include the logger,
    /// and call sites are also wrapped in `#if DEBUG` to avoid production overhead.
    enum WorkspaceRestorePerfLog {
        private static let logger = Logger(subsystem: "com.repoprompt.restore", category: "workspace-restore")
        private static let defaultsKey = "enableWorkspaceRestorePerfLogging"
        private static let environmentKey = "RP_WORKSPACE_RESTORE_PERF_LOGGING"
        private static let enabledEnvironmentValues: Set<String> = ["1", "true", "yes", "on"]
        private static let bufferLimit = 2000
        private static let bufferLock = NSLock()
        private static var processOverrideEnabled: Bool?
        private static var recentMetricLines: [String] = []

        static var isEnabled: Bool {
            if let override = debugProcessOverrideEnabled {
                return override
            }
            return defaultsEnabled || environmentEnabled
        }

        static var defaultsEnabled: Bool {
            UserDefaults.standard.bool(forKey: defaultsKey)
        }

        static var environmentEnabled: Bool {
            let rawValue = ProcessInfo.processInfo.environment[environmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return rawValue.map { enabledEnvironmentValues.contains($0) } ?? false
        }

        static var debugProcessOverrideEnabled: Bool? {
            bufferLock.lock()
            defer { bufferLock.unlock() }
            return processOverrideEnabled
        }

        static func timestampMSIfEnabled() -> Double? {
            guard isEnabled else { return nil }
            return timestampMS()
        }

        static func timestampMS() -> Double {
            CFAbsoluteTimeGetCurrent() * 1000
        }

        static func elapsedMS(since startMS: Double) -> Double {
            timestampMS() - startMS
        }

        static func formatMS(_ value: Double) -> String {
            String(format: "%.1fms", value)
        }

        static func formatElapsedMS(since startMS: Double) -> String {
            formatMS(elapsedMS(since: startMS))
        }

        static func shortID(_ id: UUID?) -> String {
            id?.uuidString.prefix(8).description ?? "nil"
        }

        @MainActor
        private static var agentActivationTrueCount = 0

        @MainActor
        static func nextAgentActivationTrueCount() -> Int {
            agentActivationTrueCount += 1
            return agentActivationTrueCount
        }

        static func log(_ message: @autoclosure () -> String) {
            guard isEnabled else { return }
            let renderedMessage = message()
            appendRecentMetricLine(renderedMessage)
            logger.debug("\(renderedMessage, privacy: .public)")
        }

        static func event(_ name: String, fields: [String: String] = [:]) {
            log(renderEvent(name, fields: fields))
        }

        static func setDebugProcessOverrideEnabled(_ enabled: Bool?) {
            bufferLock.lock()
            processOverrideEnabled = enabled
            bufferLock.unlock()
        }

        static func clearRecentMetricLines() {
            bufferLock.lock()
            recentMetricLines.removeAll(keepingCapacity: true)
            bufferLock.unlock()
        }

        static func recentMetricLinesSnapshot(limit requestedLimit: Int) -> [String] {
            let limit = max(1, min(requestedLimit, bufferLimit))
            bufferLock.lock()
            let lines = Array(recentMetricLines.suffix(limit))
            bufferLock.unlock()
            return lines
        }

        static func debugStateSnapshot(lineLimit: Int) -> [String: Any] {
            let lines = recentMetricLinesSnapshot(limit: lineLimit)
            return [
                "enabled": isEnabled,
                "defaults_enabled": defaultsEnabled,
                "environment_enabled": environmentEnabled,
                "process_override_enabled": debugProcessOverrideEnabled ?? NSNull(),
                "line_count": lines.count,
                "buffer_limit": bufferLimit,
                "lines": lines
            ]
        }

        private static func appendRecentMetricLine(_ message: String) {
            let line = "t+\(formatMS(timestampMS())) \(message)"
            bufferLock.lock()
            recentMetricLines.append(line)
            if recentMetricLines.count > bufferLimit {
                recentMetricLines.removeFirst(recentMetricLines.count - bufferLimit)
            }
            bufferLock.unlock()
        }

        private static func renderEvent(_ name: String, fields: [String: String]) -> String {
            guard !fields.isEmpty else { return name }
            let suffix = fields.keys.sorted().map { key in
                "\(key)=\(sanitize(fields[key] ?? ""))"
            }.joined(separator: " ")
            return "\(name) \(suffix)"
        }

        private static func sanitize(_ raw: String) -> String {
            raw
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: " ", with: "_")
        }
    }
#endif

/// App-owned forwarding implementation; source ordering and logger buffering stay unchanged.
struct AppWorkspaceRestorePerfRecorder: WorkspaceRestorePerfRecording {
    var isEnabled: Bool {
        #if DEBUG
            WorkspaceRestorePerfLog.isEnabled
        #else
            false
        #endif
    }

    func timestampMSIfEnabled() -> Double? {
        #if DEBUG
            WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #else
            nil
        #endif
    }

    func timestampMS() -> Double {
        #if DEBUG
            WorkspaceRestorePerfLog.timestampMS()
        #else
            CFAbsoluteTimeGetCurrent() * 1000
        #endif
    }

    func elapsedMS(since startMS: Double) -> Double {
        #if DEBUG
            WorkspaceRestorePerfLog.elapsedMS(since: startMS)
        #else
            timestampMS() - startMS
        #endif
    }

    func formatMS(_ value: Double) -> String {
        #if DEBUG
            WorkspaceRestorePerfLog.formatMS(value)
        #else
            String(format: "%.1fms", value)
        #endif
    }

    func formatElapsedMS(since startMS: Double) -> String {
        #if DEBUG
            WorkspaceRestorePerfLog.formatElapsedMS(since: startMS)
        #else
            formatMS(elapsedMS(since: startMS))
        #endif
    }

    func shortID(_ id: UUID?) -> String {
        #if DEBUG
            WorkspaceRestorePerfLog.shortID(id)
        #else
            id?.uuidString.prefix(8).description ?? "nil"
        #endif
    }

    @MainActor func nextAgentActivationTrueCount() -> Int {
        #if DEBUG
            WorkspaceRestorePerfLog.nextAgentActivationTrueCount()
        #else
            0
        #endif
    }

    func log(_ message: @autoclosure () -> String) {
        #if DEBUG
            WorkspaceRestorePerfLog.log(message())
        #endif
    }

    func event(_ name: String, fields: [String: String] = [:]) {
        #if DEBUG
            WorkspaceRestorePerfLog.event(name, fields: fields)
        #endif
    }
}
