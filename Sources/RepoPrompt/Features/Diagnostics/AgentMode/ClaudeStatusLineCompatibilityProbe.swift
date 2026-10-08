#if DEBUG
    import Darwin
    import Foundation

    /// Explicit one-process experiment; never installs settings or supplies quota/router data.
    enum ClaudeStatusLineCompatibilityProbe {
        static func claimSettingsArguments(launchArguments: [String], isFirstParty: Bool, providerArguments: [String] = []) -> [String] {
            guard isFirstParty,
                  !providerArguments.contains(where: { $0 == "--settings" || $0.hasPrefix("--settings=") || $0 == "--setting-sources" || $0.hasPrefix("--setting-sources=") })
            else { return [] }
            let indices = launchArguments.indices.filter { launchArguments[$0] == "--claude-statusline-probe" }
            guard indices.count == 1, let index = indices.first, index + 1 < launchArguments.count else { return [] }
            let path = launchArguments[index + 1]
            guard path.hasPrefix("/") else { return [] }
            let settings = URL(fileURLWithPath: path)
            let root = settings.deletingLastPathComponent()
            guard settings.lastPathComponent == "settings.json", privateDirectory(root.path) else { return [] }
            let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { return [] }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o777 == 0o600, info.st_size > 0, info.st_size <= 65536
            else { return [] }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            guard let data = try? handle.read(upToCount: 65537), data.count <= 65536,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["statusLine"],
                  let statusLine = object["statusLine"] as? [String: Any],
                  Set(statusLine.keys) == ["type", "command"],
                  statusLine["type"] as? String == "command",
                  let command = statusLine["command"] as? String, !command.isEmpty
            else { return [] }
            // Exclusive on-disk claim avoids another controller instrumenting another process.
            let claim = open(root.appendingPathComponent("claimed").path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard claim >= 0 else { return [] }
            close(claim)
            return ["--settings", settings.path]
        }

        private static func privateDirectory(_ path: String) -> Bool {
            var info = stat()
            return lstat(path, &info) == 0 && info.st_uid == getuid()
                && info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o777 == 0o700
        }
    }
#endif
