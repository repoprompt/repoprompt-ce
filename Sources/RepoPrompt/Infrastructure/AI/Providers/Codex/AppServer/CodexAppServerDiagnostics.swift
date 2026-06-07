import Foundation

enum CodexAppServerDiagnostics {
    static let appServerDiagnosticsEnabledKey = "codexAppServerDiagnosticsEnabled"
    static let appServerDiagnosticsLogFilePathKey = "codexAppServerDiagnosticsLogFilePath"
    static let lastAppServerDiagnosticsLogFilePathKey = "codexLastAppServerDiagnosticsLogFilePath"
    static let rawEventLoggingEnabledKey = "codexRawEventLoggingEnabled"
    static let rawEventLogFilePathKey = "codexRawEventLogFilePath"
    static let lastRawEventLogFilePathKey = "codexLastRawEventLogFilePath"

    private static let sensitiveKeyFragments = [
        "api_key", "apikey", "authorization", "bearer", "cookie", "credential", "keychain",
        "password", "refresh", "secret", "session", "token"
    ]
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    final class Logger: @unchecked Sendable {
        private let fileURL: URL
        private let runID: UUID
        private let lock = NSLock()

        init(fileURL: URL, runID: UUID = UUID()) {
            self.fileURL = fileURL
            self.runID = runID
        }

        func record(kind: String, payload: [String: Any] = [:]) {
            var record: [String: Any] = [
                "kind": kind,
                "timestamp": CodexAppServerDiagnostics.timestampFormatter.string(from: Date()),
                "runID": runID.uuidString
            ]
            if !payload.isEmpty {
                record["payload"] = CodexAppServerDiagnostics.sanitizedJSONObject(payload)
            }
            append(record)
        }

        private func append(_ record: [String: Any]) {
            guard JSONSerialization.isValidJSONObject(record),
                  let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
                  var line = String(data: data, encoding: .utf8)
            else {
                return
            }
            line.append("\n")
            guard let lineData = line.data(using: .utf8) else { return }

            lock.lock()
            defer { lock.unlock() }
            do {
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                handle.write(lineData)
            } catch {
                return
            }
        }
    }

    static func appServerDiagnosticsEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: appServerDiagnosticsEnabledKey)
    }

    static func rawEventLoggingEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: rawEventLoggingEnabledKey)
    }

    static func appServerDiagnosticsLogFilePath(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: appServerDiagnosticsLogFilePathKey) ?? ""
    }

    static func setAppServerDiagnosticsLogFilePath(_ path: String, defaults: UserDefaults = .standard) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: appServerDiagnosticsLogFilePathKey)
        } else {
            defaults.set(path, forKey: appServerDiagnosticsLogFilePathKey)
        }
    }

    static func rawEventLogFilePath(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: rawEventLogFilePathKey) ?? ""
    }

    static func setRawEventLogFilePath(_ path: String, defaults: UserDefaults = .standard) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: rawEventLogFilePathKey)
        } else {
            defaults.set(path, forKey: rawEventLogFilePathKey)
        }
    }

    static func makeLoggerIfEnabled(defaults: UserDefaults = .standard) -> Logger? {
        guard appServerDiagnosticsEnabled(defaults: defaults) else { return nil }
        guard let fileURL = makeLogFileURL(
            overridePath: appServerDiagnosticsLogFilePath(defaults: defaults),
            defaultSubdirectory: "RepoPrompt/codex-app-server-diagnostics",
            filePrefix: "codex-app-server-diagnostics"
        ) else {
            return nil
        }
        defaults.set(fileURL.path, forKey: lastAppServerDiagnosticsLogFilePathKey)
        return Logger(fileURL: fileURL)
    }

    static func makeLogFileURL(
        overridePath: String?,
        defaultSubdirectory: String,
        filePrefix: String
    ) -> URL? {
        let directory: URL
        let trimmedOverride = overridePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedOverride.isEmpty {
            directory = URL(fileURLWithPath: NSString(string: trimmedOverride).expandingTildeInPath, isDirectory: true)
        } else {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(defaultSubdirectory, isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let fileName = "\(filePrefix)-\(formatter.string(from: Date())).jsonl"
        return directory.appendingPathComponent(fileName)
    }

    static func jsonRPCPayloadSummary(_ payload: [String: Any]) -> [String: Any] {
        var summary: [String: Any] = [
            "keys": Array(payload.keys).sorted()
        ]
        if let method = payload["method"] as? String {
            summary["method"] = method
        }
        if let id = payload["id"] {
            summary["id"] = sanitizedString(String(describing: id), maxLength: 120)
        }
        if let params = payload["params"] {
            summary["params"] = valueSummary(params)
        }
        if let result = payload["result"] {
            summary["result"] = valueSummary(result)
        }
        if let error = payload["error"] {
            summary["error"] = valueSummary(error)
        }
        return summary
    }

    static func valueSummary(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            let keys = Array(dictionary.keys).sorted()
            var summary: [String: Any] = [
                "type": "object",
                "keyCount": dictionary.count,
                "keys": Array(keys.prefix(80))
            ]
            if dictionary.count > 80 {
                summary["truncatedKeys"] = dictionary.count - 80
            }
            return summary
        }
        if let array = value as? [Any] {
            return [
                "type": "array",
                "count": array.count
            ]
        }
        if let string = value as? String {
            return [
                "type": "string",
                "characters": string.count,
                "isEmpty": string.isEmpty
            ]
        }
        if value is NSNull {
            return ["type": "null"]
        }
        return [
            "type": String(describing: type(of: value))
        ]
    }

    static func sanitizedJSONObject(_ value: Any, keyPath _: [String] = []) -> Any {
        if let dictionary = value as? [String: Any] {
            var output: [String: Any] = [:]
            for key in dictionary.keys.sorted().prefix(80) {
                guard let child = dictionary[key] else { continue }
                if isSensitiveKey(key) {
                    output[key] = "<redacted>"
                } else {
                    output[key] = sanitizedJSONObject(child)
                }
            }
            if dictionary.count > 80 {
                output["_truncatedKeys"] = dictionary.count - 80
            }
            return output
        }
        if let array = value as? [Any] {
            var output = array.prefix(40).map { sanitizedJSONObject($0) }
            if array.count > 40 {
                output.append("<truncated \(array.count - 40) items>")
            }
            return output
        }
        if let string = value as? String {
            return sanitizedString(string)
        }
        if let number = value as? NSNumber {
            return number
        }
        if value is NSNull {
            return NSNull()
        }
        return sanitizedString(String(describing: value))
    }

    static func sanitizedString(_ raw: String, maxLength: Int = 1200) -> String {
        var output = CommandExecutionOutputSanitizer.sanitize(raw)
        output = output.replacingOccurrences(of: "\0", with: "")
        if output.count > maxLength {
            let prefix = output.prefix(maxLength)
            return "\(prefix)…[\(output.count) chars]"
        }
        return output
    }

    static func lineRecordPayload(from data: Data, maxLength: Int = 1200) -> [String: Any] {
        let text = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        return [
            "byteCount": data.count,
            "text": sanitizedString(text, maxLength: maxLength)
        ]
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return sensitiveKeyFragments.contains { normalized.contains($0) }
    }
}
