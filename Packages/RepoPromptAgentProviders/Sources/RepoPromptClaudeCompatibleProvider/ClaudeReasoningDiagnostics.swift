import Foundation

enum ClaudeReasoningExtractionFeature {
    static let isEnabled = false
}

#if DEBUG
    enum ClaudeReasoningDebugLog {
        static let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
            .appendingPathComponent("claude-reasoning-debug.log", isDirectory: false)
        private static let lock = NSLock()

        static func emit(_ line: String) {
            print(line)
            append(line)
        }

        static func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let payload = "\(timestamp) \(line)\n"
            guard let data = payload.data(using: .utf8) else { return }
            let fileManager = FileManager.default
            try? fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL)
            {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }
#endif
