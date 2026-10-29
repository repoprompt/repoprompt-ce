#if DEBUG
    import Foundation
    import MCP
    import RepoPromptProcess

    /// Host-owned tests, decoded before any model invocation. Expected values are never
    /// written into the agent's workspace or sent to the code under test.
    struct PromptExperimentAgentAcceptance: Decodable {
        struct Check: Decodable {
            let id: String
            let path: String
            let function: String
            let arguments: [Value]
            let expected: Value
            let expectedError: String?
            let preserveArguments: Bool?

            enum CodingKeys: String, CodingKey {
                case id, path, function, arguments, expected
                case expectedError = "expected_error"
                case preserveArguments = "preserve_arguments"
            }
        }

        let schemaVersion: Int
        let checks: [Check]
        let preserveFiles: [String]?
        let maxTurns: Int?
        let timeoutSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case checks
            case preserveFiles = "preserve_files"
            case maxTurns = "max_turns"
            case timeoutSeconds = "timeout_seconds"
        }

        var maximumTurns: Int {
            maxTurns ?? 16
        }

        var duration: TimeInterval {
            TimeInterval(timeoutSeconds ?? 180)
        }

        static func decode(_ text: String) throws -> Self {
            let spec: Self
            do {
                let data = Data(text.utf8)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(object.keys).isSubset(of: ["schema_version", "checks", "preserve_files", "max_turns", "timeout_seconds"]),
                      let checks = object["checks"] as? [[String: Any]],
                      checks.allSatisfy({ Set($0.keys).isSubset(of: ["id", "path", "function", "arguments", "expected", "expected_error", "preserve_arguments"]) })
                else { throw PromptExperimentAuthorityError.invalidRequest("Unknown or malformed Engineer acceptance-test fields.") }
                spec = try JSONDecoder().decode(Self.self, from: data)
            } catch {
                throw PromptExperimentAuthorityError.invalidRequest("Engineer expected_output must be a versioned acceptance-test JSON object: \(error.localizedDescription)")
            }
            guard spec.schemaVersion == 1, (1 ... 32).contains(spec.checks.count),
                  (1 ... 64).contains(spec.maximumTurns), (10 ... 900).contains(Int(spec.duration)),
                  Set(spec.checks.map(\.id)).count == spec.checks.count
            else {
                throw PromptExperimentAuthorityError.invalidRequest("Engineer tests require schema_version 1, 1–32 unique checks, max_turns 1–64, and timeout_seconds 10–900.")
            }
            for check in spec.checks {
                try validateRelativePath(check.path)
                guard check.path.hasSuffix(".py"), !check.id.isEmpty, check.id.count <= 100,
                      check.function.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
                else {
                    throw PromptExperimentAuthorityError.invalidRequest("Engineer checks need an ID, a relative Python file path, and a function name.")
                }
            }
            for path in spec.preserveFiles ?? [] {
                try validateRelativePath(path)
            }
            return spec
        }

        static func validateRelativePath(_ path: String) throws {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
                  !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !parts.contains(where: { $0 == ".git" || $0 == ".claude" || $0 == ".codex" }),
                  path.utf8.count <= 1024
            else { throw PromptExperimentAuthorityError.invalidRequest("Fixture paths must be regular relative paths without traversal or provider configuration directories.") }
        }
    }

    struct PromptExperimentAgentCheckResult {
        let passed: Bool
        let feedback: String
    }

    @MainActor
    protocol PromptExperimentAgentChecking {
        func preflight() async throws
        func check(_ check: PromptExperimentAgentAcceptance.Check, workspace: URL, timeout: TimeInterval) async throws -> PromptExperimentAgentCheckResult
    }

    /// Executes actual edited code in a read-only OS sandbox. Each check gets a fresh
    /// process, fixed interpreter, CPU limit and deadline; code cannot spawn arbitrary
    /// tools, access the network, read the user's files, or edit its workspace.
    @MainActor
    final class PromptExperimentPythonAcceptanceRunner: PromptExperimentAgentChecking {
        private let python: URL
        private var preflightSucceeded = false

        init(python: URL) {
            self.python = python.resolvingSymlinksInPath()
        }

        func preflight() async throws {
            guard !preflightSucceeded else { return }
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
                  FileManager.default.isExecutableFile(atPath: python.path)
            else { throw PromptExperimentAuthorityError.runtimeUnavailable("Engineer acceptance tests require the packaged Python runtime and macOS sandbox-exec.") }
            let probe = FileManager.default.temporaryDirectory.appendingPathComponent("engineer-sandbox-probe-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: probe) }
            let source = probe.appendingPathComponent("probe.py")
            try "def verify():\n    return 'RPCE_ENGINEER_SANDBOX_READY'\n".write(to: source, atomically: true, encoding: .utf8)
            let result = try await process(workspace: probe).run(
                args: [
                    "-p",
                    Self.sandboxProfile(workspace: probe, python: python),
                    python.path,
                    "-I",
                    "-S",
                    "-B",
                    "-c",
                    Self.checkProgram, source.path, "verify", "[]", probe.path
                ],
                stdin: nil, outputMode: .none, timeout: 5, cancelChildOnTaskCancellation: true
            )
            guard result.status == 0, !result.timedOut,
                  let record = try? JSONDecoder().decode([String: Value].self, from: result.stdout),
                  record["value"] == .string("RPCE_ENGINEER_SANDBOX_READY")
            else { throw PromptExperimentAuthorityError.runtimeUnavailable("The isolated Engineer acceptance runtime failed its sandbox launch check. No agent task was started.") }
            preflightSucceeded = true
        }

        func check(_ check: PromptExperimentAgentAcceptance.Check, workspace: URL, timeout: TimeInterval) async throws -> PromptExperimentAgentCheckResult {
            try await preflight()
            let source = workspace.appendingPathComponent(check.path)
            guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  source.resolvingSymlinksInPath().path.hasPrefix(workspace.resolvingSymlinksInPath().path + "/")
            else { return .init(passed: false, feedback: "\(check.id): target file is missing or escaped the fixture.") }
            let args = try String(decoding: JSONEncoder().encode(check.arguments), as: UTF8.self)
            let sandbox = Self.sandboxProfile(workspace: workspace, python: python)
            let result = try await process(workspace: workspace).run(
                args: ["-p", sandbox, python.path, "-I", "-S", "-B", "-c", Self.checkProgram, source.path, check.function, args, workspace.path],
                stdin: nil, outputMode: .none, timeout: min(5, max(0.05, timeout)), cancelChildOnTaskCancellation: true
            )
            try Task.checkCancellation()
            guard !result.timedOut, result.status == 0,
                  let record = try? JSONDecoder().decode([String: Value].self, from: result.stdout)
            else { return .init(passed: false, feedback: "\(check.id): code failed, exceeded the check deadline, or returned an invalid result.") }
            let behaviorPassed = if let expectedError = check.expectedError {
                record["error"] == .string(expectedError)
            } else {
                record["value"] == check.expected
            }
            let passed = behaviorPassed && (check.preserveArguments != true || record["arguments"] == .array(check.arguments))
            if passed { return .init(passed: true, feedback: "\(check.id): passed.") }
            if behaviorPassed {
                return .init(passed: false, feedback: "\(check.id): the function changed input arguments that must remain unchanged.")
            }
            let expected = check.expectedError.map { Value.string("throws \($0)") } ?? check.expected
            let observed = record["error"].map { Value.object(["error": $0]) } ?? record["value"] ?? .null
            func excerpt(_ value: Value) -> String {
                String(String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self).prefix(250))
            }
            return .init(passed: false, feedback: "\(check.id): expected \(excerpt(expected)); observed \(excerpt(observed)).")
        }

        private func process(workspace: URL) -> CLIProcessRunner {
            CLIProcessRunner(config: CLIProcessConfiguration(
                command: "/usr/bin/sandbox-exec", processPurpose: .tool, workingDirectory: workspace.path,
                environmentFilter: { _, _ in ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"] },
                shellLookupMode: .disabled, captureStdoutTailBytes: 65536, captureStderrTailBytes: 8192
            ))
        }

        static func sandboxProfile(workspace: URL, python: URL) -> String {
            func quoted(_ path: String) -> String {
                "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
            var pythonRoot = python.deletingLastPathComponent().deletingLastPathComponent().path
            // Apple's framework launcher lives below Resources/Python.app rather than bin.
            // Permit its own versioned runtime; arbitrary project files remain outside it.
            let components = python.pathComponents
            if let framework = components.firstIndex(where: { $0.hasSuffix(".framework") }),
               components.count > framework + 2, components[framework + 1] == "Versions"
            {
                pythonRoot = NSString.path(withComponents: Array(components.prefix(framework + 3)))
            }
            return """
            (version 1)
            (deny default)
            (allow process-exec (literal \(quoted(python.path))))
            (allow process-info* sysctl-read)
            (allow file-read-metadata)
            (allow file-read* (subpath "/System") (subpath "/usr/lib") (subpath "/usr/share")
                (subpath \(quoted(pythonRoot))) (subpath \(quoted(workspace.resolvingSymlinksInPath().path)))
                (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random"))
            """
        }

        /// Darwin rejects an address-space cap below existing mappings, which can already
        /// include hundreds of GiB of reservations. Probe its accounting before loading
        /// candidate code; only the final cap lowers the inherited hard limit. This bounds
        /// additional mappings, not resident memory within an existing reservation.
        static let addressSpaceLimitProgram = """
        def rpce_limit_address_space(resource, platform, maximum):
            allowance = 512 * 1024 * 1024
            original = resource.getrlimit(resource.RLIMIT_AS)
            ceiling = min([maximum] + [value for value in original if value != resource.RLIM_INFINITY])
            if ceiling <= 0:
                raise RuntimeError("No usable inherited address-space allowance")
            set_limit = resource.setrlimit
            address_space = resource.RLIMIT_AS
            if platform != "darwin":
                limit = min(allowance, ceiling)
            else:
                def accepts(value):
                    requested = (value, original[1])
                    try:
                        set_limit(address_space, requested)
                    except ValueError:
                        return False
                    # Restore the prebuilt tuple before allocating any search values.
                    set_limit(address_space, original)
                    return True
                lower, upper = 0, min(allowance, ceiling)
                while not accepts(upper):
                    if upper == ceiling:
                        raise RuntimeError("Cannot establish the Darwin address-space baseline")
                    lower, upper = upper, min(upper * 2, ceiling)
                while upper - lower > 1024 * 1024:
                    middle = (lower + upper) // 2
                    if accepts(middle):
                        upper = middle
                    else:
                        lower = middle
                limit = min(ceiling, upper + allowance)
            set_limit(address_space, (limit, limit))
            return limit
        """

        /// The host compares the observed result. No expected value or test manifest is
        /// present in this process. -I/-S disables user packages, startup hooks and site.py.
        static let checkProgram = addressSpaceLimitProgram + "\n" + """
        import contextlib, importlib.util, io, json, os, resource, sys
        resource.setrlimit(resource.RLIMIT_CPU, (4, 4))
        rpce_limit_address_space(resource, sys.platform, sys.maxsize)
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
        path, function, encoded, workspace = sys.argv[1:]
        sys.path[:0] = [os.path.dirname(path), workspace]
        arguments = json.loads(encoded)
        sink = io.StringIO()
        try:
            with contextlib.redirect_stdout(sink), contextlib.redirect_stderr(sink):
                spec = importlib.util.spec_from_file_location("rpce_candidate", path)
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                value = getattr(module, function)(*arguments)
            result = {"value": value}
        except BaseException as error:
            result = {"error": type(error).__name__}
        result["arguments"] = arguments
        sys.stdout.write(json.dumps(result, allow_nan=False, separators=(",", ":")))
        """
    }
#endif
