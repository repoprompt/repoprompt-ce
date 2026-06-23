#if DEBUG
    import Darwin
    import Foundation
    import RepoPromptCore

    enum LegacyIgnoreDebugMetricsPolicy {
        private static let enabledEnvironmentValues: Set<String> = ["1", "true", "yes", "on"]
        private static let dumpOutputFileName = "ignore-metrics.jsonl"

        static func install() {
            let environment = ProcessInfo.processInfo.environment
            let dumpEnabled = isTruthy(environment["REPOPROMPT_IGNORE_METRICS_DUMP"])
                || UserDefaults.standard.bool(forKey: "RepoPromptIgnoreMetricsDumpEnabled")
            let recordingEnabled = isTruthy(environment["REPOPROMPT_IGNORE_METRICS_ENABLED"])
                || isTruthy(environment["REPOPROMPT_REPLAY_BENCHMARK_VERBOSE_TELEMETRY"])
                || dumpEnabled
                || UserDefaults.standard.bool(forKey: "RepoPromptIgnoreMetricsEnabled")

            IgnoreDebugMetricsRecorder.installRuntimePolicy(
                recordingEnabled: recordingEnabled,
                dumpEnabled: dumpEnabled,
                dumpHandler: appendSecureDump
            )
        }

        private static func isTruthy(_ value: String?) -> Bool {
            guard let value = value?.lowercased() else { return false }
            return enabledEnvironmentValues.contains(value)
        }

        private static func appendSecureDump(_ data: Data) {
            guard let outputURL = secureDumpOutputURL() else { return }
            let fd = open(outputURL.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { return }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.write(contentsOf: Data([0x0A]))
        }

        private static func secureDumpOutputURL() -> URL? {
            let fileManager = FileManager.default
            let directoryURL = fileManager.temporaryDirectory
                .appendingPathComponent("com.repoprompt.ignore-metrics.\(getuid())", isDirectory: true)
            if fileManager.fileExists(atPath: directoryURL.path) {
                guard isDirectoryAndNotSymlink(directoryURL) else { return nil }
            } else {
                do {
                    try fileManager.createDirectory(
                        at: directoryURL,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                } catch {
                    return nil
                }
            }

            let outputURL = directoryURL.appendingPathComponent(dumpOutputFileName, isDirectory: false)
            if fileManager.fileExists(atPath: outputURL.path), !isRegularFileAndNotSymlink(outputURL) {
                return nil
            }
            return outputURL
        }

        private static func isDirectoryAndNotSymlink(_ url: URL) -> Bool {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return false }
            return (info.st_mode & S_IFMT) == S_IFDIR
        }

        private static func isRegularFileAndNotSymlink(_ url: URL) -> Bool {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return false }
            return (info.st_mode & S_IFMT) == S_IFREG
        }
    }
#endif
