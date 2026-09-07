#if DEBUG
    import Darwin
    import Foundation

    /// Explicit test construction only; never selected by environment or settings.
    struct CodexManagedHTTPIntegrationConfiguration {
        enum Failure: Error { case invalidFixture, invalidRoot, noncanonicalRoot, noncanonicalResources, resourcesInHome, invalidProfile, insecureRoot }
        let resourcesURL: URL
        let rootURL: URL
        let responsesURL: String
        let sandboxProfileURL: URL

        init(resourcesURL: URL, rootURL: URL, responsesURL: String, sandboxProfileURL: URL) throws {
            try Self.requireHostedXCTest()
            // Foundation standardization aliases existing /private/tmp to /tmp.
            // Keep the supplied spelling and compare against kernel realpath.
            let root = rootURL
            guard root.path.hasPrefix("/private/tmp/") else { throw Failure.invalidRoot }
            guard try root.path == Self.canonicalPath(root) else { throw Failure.noncanonicalRoot }
            guard resourcesURL.isFileURL, try resourcesURL.path == Self.canonicalPath(resourcesURL) else { throw Failure.noncanonicalResources }
            let realHome = try Self.realUserHomePath()
            guard resourcesURL.path != realHome, !resourcesURL.path.hasPrefix(realHome + "/") else { throw Failure.resourcesInHome }
            guard sandboxProfileURL.path.hasPrefix(root.path + "/"), try sandboxProfileURL.path == Self.canonicalPath(sandboxProfileURL),
                  try (FileManager.default.attributesOfItem(atPath: sandboxProfileURL.path)[.type] as? FileAttributeType) == .typeRegular else { throw Failure.invalidProfile }
            let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
                  (attributes[.type] as? FileAttributeType) == .typeDirectory else { throw Failure.insecureRoot }
            self.resourcesURL = resourcesURL
            self.rootURL = root
            self.responsesURL = try Self.validatedLoopbackURL(responsesURL)
            self.sandboxProfileURL = sandboxProfileURL
        }

        static func requireHostedXCTest() throws {
            let hasRuntime = NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil
            let hasBundle = ([Bundle.main] + Bundle.allBundles).contains { $0.bundleURL.pathExtension == "xctest" }
            guard hasRuntime, hasBundle else { throw Failure.invalidFixture }
        }

        private static func canonicalPath(_ url: URL) throws -> String {
            guard url.isFileURL, let path = realpath(url.path, nil) else { throw Failure.invalidFixture }
            defer { free(path) }
            return String(cString: path)
        }

        static func realUserHomePath() throws -> String {
            guard let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir else { throw Failure.invalidFixture }
            return String(cString: path)
        }

        static func validatedLoopbackURL(_ value: String) throws -> String {
            guard let components = URLComponents(string: value), components.scheme == "http",
                  components.host == "127.0.0.1", let port = components.port, (1 ... 65535).contains(port),
                  components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
                  value == "http://127.0.0.1:\(port)/backend-api/codex" else { throw Failure.invalidFixture }
            return value
        }

        var environment: [String: String] {
            [
                "PATH": "/usr/bin:/bin",
                "LANG": "en_US.UTF-8",
                "HOME": rootURL.appendingPathComponent("home").path,
                "CFFIXED_USER_HOME": rootURL.appendingPathComponent("home").path,
                "TMPDIR": rootURL.appendingPathComponent("tmp").path
            ]
        }

        func resolve() throws -> CodexProviderHelpers.CodexExecutableResolution {
            try Self.requireHostedXCTest()
            let runtime = try CodexRuntimeAuthority.resolve(
                environment: [:], resourcesURL: resourcesURL,
                applicationSupportURL: rootURL.appendingPathComponent("support")
            ).get()
            return .init(
                commandName: "codex",
                resolvedCommand: runtime.executableURL.path,
                status: .available,
                runtime: runtime,
                userMessage: "",
                debugMessage: runtime.redactedDiagnosticSummary
            )
        }

        func spawn(command: String, arguments: [String], environment: [String: String], workingDirectory: String?) throws -> SpawnedProcess {
            try Self.requireHostedXCTest()
            let resolution = try resolve()
            guard let expected = resolution.runtime?.executableURL.path,
                  let workingDirectory, workingDirectory.hasPrefix(rootURL.path + "/") else { throw Failure.invalidFixture }
            try Self.validateExecutable(command, expected: expected)
            return try ProcessLauncher.spawn(
                command: "/usr/bin/sandbox-exec",
                arguments: ["-f", sandboxProfileURL.path, command] + arguments,
                environment: environment,
                workingDirectory: workingDirectory
            )
        }

        static func validateExecutable(_ command: String, expected: String) throws {
            guard command == expected else { throw Failure.invalidFixture }
        }
    }
#endif
