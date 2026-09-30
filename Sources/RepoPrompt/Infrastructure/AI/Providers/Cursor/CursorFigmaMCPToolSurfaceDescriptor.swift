import Foundation

/// Provider-local contract for a Settings-only observation of Cursor's documented Figma MCP
/// tool listing. This is never authentication proof, runtime authority, or revocation authority.
struct CursorFigmaMCPToolSurfaceDescriptor: Equatable {
    static let targetIdentifier = "figma"
    static let acceptedExecutableBuild = "2026.08.25-3e8eec8"
    static let requiredToolNames: Set<String> = [
        "whoami",
        "get_design_context",
        "get_variable_defs"
    ]
    static let defaultObservationLifetime: TimeInterval = 5 * 60

    let provider: ExternalMCPRuntimeProvider = .cursor
    let executableProfile: CLILaunchProfile = CLILaunchProfiles.cursor
    let timeout: TimeInterval
    let outputByteLimit: Int
    let observationLifetime: TimeInterval

    init(
        timeout: TimeInterval = 15,
        outputByteLimit: Int = 64 * 1024,
        observationLifetime: TimeInterval = Self.defaultObservationLifetime
    ) {
        precondition(timeout > 0)
        precondition(outputByteLimit > 0 && outputByteLimit < Int.max)
        precondition(observationLifetime > 0)
        self.timeout = timeout
        self.outputByteLimit = outputByteLimit
        self.observationLifetime = observationLifetime
    }

    var versionArguments: [String] {
        ["--version"]
    }

    /// Enables the configured Figma MCP after provider login and before tool verification.
    var enableArguments: [String] {
        ["mcp", "enable", Self.targetIdentifier]
    }

    /// The only MCP command this observation core uses to verify the enabled tool surface.
    var listToolsArguments: [String] {
        ["mcp", "list-tools", Self.targetIdentifier]
    }
}

enum CursorFigmaMCPExecutableBuildMatcher {
    static func parse(stdout: Data, outputByteLimit: Int) -> CursorFigmaMCPExecutableBuildValidation {
        guard stdout.count <= outputByteLimit else { return .outputTooLarge }
        guard let output = String(data: stdout, encoding: .utf8) else { return .invalidUTF8 }

        let build = output.hasSuffix("\n") ? String(output.dropLast()) : output
        guard !build.isEmpty, !build.contains("\n"), !build.contains("\r"), isBuildIdentifier(build) else {
            return .malformed
        }
        return build == CursorFigmaMCPToolSurfaceDescriptor.acceptedExecutableBuild ? .accepted : .unsupported
    }

    private static func isBuildIdentifier(_ build: String) -> Bool {
        let components = build.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0].utf8.count == 10,
              components[1].utf8.count == 7,
              components[0].utf8.enumerated().allSatisfy({ index, byte in
                  switch index {
                  case 4, 7: byte == 46
                  default: byte >= 48 && byte <= 57
                  }
              }),
              components[1].utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
              })
        else {
            return false
        }
        return true
    }
}

enum CursorFigmaMCPExecutableBuildValidation: Equatable {
    case accepted
    case unsupported
    case outputTooLarge
    case invalidUTF8
    case malformed
}

/// Opaque subprocess result used only by the dormant Cursor tool-surface observation.
struct CursorFigmaMCPToolSurfaceProbeProcessResult: Equatable {
    let stdout: Data
    let stderr: Data
    let status: Int32
    let timedOut: Bool
}

/// Sanitized observation outcome. Diagnostics never include subprocess output.
enum CursorFigmaMCPToolSurfaceProbeOutcome: Equatable {
    case candidate(CursorFigmaMCPToolSurfaceCandidate)
    case unavailable(CursorFigmaMCPToolSurfaceProbeDiagnostic)

    var diagnostics: [String] {
        switch self {
        case .candidate:
            []
        case let .unavailable(diagnostic):
            [diagnostic.message]
        }
    }
}

enum CursorFigmaMCPToolSurfaceProbeDiagnostic: Equatable {
    case cancelled
    case invalidExecutable
    case executableUnavailable
    case timedOut
    case nonzeroExit
    case outputTooLarge
    case invalidUTF8
    case malformedVersion
    case unsupportedBuild
    case malformedToolSurface
    case missingRequiredTool
    case duplicateTool
    case loginBusy
    case processFailed

    var message: String {
        switch self {
        case .cancelled:
            "Cursor Figma tool-surface observation was cancelled."
        case .invalidExecutable:
            "Cursor Figma tool-surface observation requires an absolute executable."
        case .executableUnavailable:
            "Cursor Agent CLI is unavailable for Figma tool observation."
        case .timedOut:
            "Cursor Figma tool-surface observation timed out."
        case .nonzeroExit:
            "Cursor Figma tool-surface observation command failed."
        case .outputTooLarge:
            "Cursor Figma tool-surface observation exceeded its output limit."
        case .invalidUTF8:
            "Cursor Figma tool-surface observation received non-UTF-8 output."
        case .malformedVersion:
            "Cursor Figma tool-surface observation received an invalid version response."
        case .unsupportedBuild:
            "Cursor Figma tool-surface observation requires the reviewed Cursor build."
        case .malformedToolSurface:
            "Cursor Figma tool-surface observation received an invalid tool listing."
        case .missingRequiredTool:
            "Cursor Figma tool-surface observation is missing a required tool."
        case .duplicateTool:
            "Cursor Figma tool-surface observation received duplicate tool names."
        case .loginBusy:
            "Another Cursor Figma login is already active in Settings."
        case .processFailed:
            "Cursor Figma tool-surface observation could not run."
        }
    }
}

/// The only retained successful observation. It contains fixed metadata only, never command
/// output, tool descriptions, arguments, account details, or provider configuration.
struct CursorFigmaMCPToolSurfaceCandidate: Equatable {
    let observedAt: Date
    let expiresAt: Date
    let executableBuild: String
    let targetIdentifier: String
}

private actor CursorFigmaMCPToolSurfaceCandidateCache {
    private var entry: (executableIdentity: ExecutableFileIdentity, candidate: CursorFigmaMCPToolSurfaceCandidate)?

    func store(_ candidate: CursorFigmaMCPToolSurfaceCandidate, for executableIdentity: ExecutableFileIdentity) {
        entry = (executableIdentity, candidate)
    }

    func candidate(
        for executableIdentity: ExecutableFileIdentity,
        at date: Date
    ) -> CursorFigmaMCPToolSurfaceCandidate? {
        guard let entry else { return nil }
        guard date < entry.candidate.expiresAt else {
            self.entry = nil
            return nil
        }
        return entry.executableIdentity == executableIdentity ? entry.candidate : nil
    }
}

enum CursorFigmaMCPToolSurfaceCachePolicy: Equatable {
    case allowCachedCandidate
    case requireFreshObservation
}

/// A fail-closed observation core. Settings may consume its sanitized outcome, but authentication,
/// proof, revocation, configuration-reading, and runtime code must not call this type.
final class CursorFigmaMCPToolSurfaceProbe: @unchecked Sendable {
    struct Invocation: @unchecked Sendable {
        let configuration: CLIProcessConfiguration
        let arguments: [String]
        let timeout: TimeInterval
    }

    typealias ProcessRunner = @Sendable (Invocation) async throws -> CursorFigmaMCPToolSurfaceProbeProcessResult
    typealias DateProvider = @Sendable () -> Date

    private let descriptor: CursorFigmaMCPToolSurfaceDescriptor
    private let processRunner: ProcessRunner
    private let now: DateProvider
    private let cache = CursorFigmaMCPToolSurfaceCandidateCache()

    init(
        descriptor: CursorFigmaMCPToolSurfaceDescriptor = .init(),
        processRunner: @escaping ProcessRunner = { invocation in
            let result = try await CLIProcessRunner(config: invocation.configuration).run(
                args: invocation.arguments,
                stdin: nil,
                outputMode: .none,
                timeout: invocation.timeout,
                cancelChildOnTaskCancellation: true
            )
            return .init(
                stdout: result.stdout,
                stderr: result.stderr,
                status: result.status,
                timedOut: result.timedOut
            )
        },
        now: @escaping DateProvider = Date.init
    ) {
        self.descriptor = descriptor
        self.processRunner = processRunner
        self.now = now
    }

    func observe(
        executableIdentity: ExecutableFileIdentity,
        environment: [String: String],
        requiresEnable: Bool = false,
        cachePolicy: CursorFigmaMCPToolSurfaceCachePolicy = .allowCachedCandidate
    ) async -> CursorFigmaMCPToolSurfaceProbeOutcome {
        guard !Task.isCancelled else { return .unavailable(.cancelled) }
        let executablePath = executableIdentity.canonicalPath
        guard executablePath.hasPrefix("/") else { return .unavailable(.invalidExecutable) }
        do {
            try executableIdentity.validateForTrustedPathLaunch(atPath: executablePath)
        } catch {
            return .unavailable(.executableUnavailable)
        }
        if !requiresEnable,
           cachePolicy == .allowCachedCandidate,
           let cached = await cache.candidate(for: executableIdentity, at: now())
        {
            return .candidate(cached)
        }

        let configuration = CLIProcessConfiguration(
            command: executablePath,
            workingDirectory: nil,
            environment: environment,
            additionalPaths: [],
            launchPurpose: .cliRunner,
            requiresAbsoluteExecutable: true,
            enableDebugLogging: false,
            shellLookupMode: .disabled,
            captureStdoutTailBytes: descriptor.outputByteLimit + 1,
            captureStderrTailBytes: descriptor.outputByteLimit + 1,
            logStdinSampleBytes: 0,
            discardOutput: false
        )

        let versionResult: CursorFigmaMCPToolSurfaceProbeProcessResult
        do {
            versionResult = try await processRunner(.init(
                configuration: configuration,
                arguments: descriptor.versionArguments,
                timeout: descriptor.timeout
            ))
        } catch is CancellationError {
            return .unavailable(.cancelled)
        } catch {
            return .unavailable(.processFailed)
        }
        guard !Task.isCancelled else { return .unavailable(.cancelled) }
        guard !versionResult.timedOut else { return .unavailable(.timedOut) }
        guard versionResult.status == 0 else { return .unavailable(.nonzeroExit) }
        guard versionResult.stdout.count <= descriptor.outputByteLimit,
              versionResult.stderr.count <= descriptor.outputByteLimit
        else {
            return .unavailable(.outputTooLarge)
        }
        guard versionResult.stderr.isEmpty else { return .unavailable(.malformedVersion) }

        switch CursorFigmaMCPExecutableBuildMatcher.parse(
            stdout: versionResult.stdout,
            outputByteLimit: descriptor.outputByteLimit
        ) {
        case .accepted:
            break
        case .unsupported:
            return .unavailable(.unsupportedBuild)
        case .outputTooLarge:
            return .unavailable(.outputTooLarge)
        case .invalidUTF8:
            return .unavailable(.invalidUTF8)
        case .malformed:
            return .unavailable(.malformedVersion)
        }
        do {
            try executableIdentity.validateForTrustedPathLaunch(atPath: executablePath)
        } catch {
            return .unavailable(.executableUnavailable)
        }

        if requiresEnable {
            var enableConfiguration = configuration
            // Enable is a state transition only. Never retain or inspect its output, which must
            // not become a source of OAuth or account data.
            enableConfiguration.captureStdoutTailBytes = 0
            enableConfiguration.captureStderrTailBytes = 0
            enableConfiguration.discardOutput = true

            let enableResult: CursorFigmaMCPToolSurfaceProbeProcessResult
            do {
                enableResult = try await processRunner(.init(
                    configuration: enableConfiguration,
                    arguments: descriptor.enableArguments,
                    timeout: descriptor.timeout
                ))
            } catch is CancellationError {
                return .unavailable(.cancelled)
            } catch {
                return .unavailable(.processFailed)
            }
            guard !Task.isCancelled else { return .unavailable(.cancelled) }
            guard !enableResult.timedOut else { return .unavailable(.timedOut) }
            guard enableResult.status == 0 else { return .unavailable(.nonzeroExit) }
            do {
                try executableIdentity.validateForTrustedPathLaunch(atPath: executablePath)
            } catch {
                return .unavailable(.executableUnavailable)
            }
        }

        let toolsResult: CursorFigmaMCPToolSurfaceProbeProcessResult
        do {
            toolsResult = try await processRunner(.init(
                configuration: configuration,
                arguments: descriptor.listToolsArguments,
                timeout: descriptor.timeout
            ))
        } catch is CancellationError {
            return .unavailable(.cancelled)
        } catch {
            return .unavailable(.processFailed)
        }
        guard !Task.isCancelled else { return .unavailable(.cancelled) }
        guard !toolsResult.timedOut else { return .unavailable(.timedOut) }
        guard toolsResult.status == 0 else { return .unavailable(.nonzeroExit) }
        guard toolsResult.stdout.count <= descriptor.outputByteLimit,
              toolsResult.stderr.count <= descriptor.outputByteLimit
        else {
            return .unavailable(.outputTooLarge)
        }
        guard toolsResult.stderr.isEmpty else { return .unavailable(.malformedToolSurface) }

        switch CursorFigmaMCPToolSurfaceOutputGrammar.validate(
            toolsResult.stdout,
            outputByteLimit: descriptor.outputByteLimit
        ) {
        case .valid:
            break
        case .outputTooLarge:
            return .unavailable(.outputTooLarge)
        case .invalidUTF8:
            return .unavailable(.invalidUTF8)
        case .malformed:
            return .unavailable(.malformedToolSurface)
        case .missingRequiredTool:
            return .unavailable(.missingRequiredTool)
        case .duplicateTool:
            return .unavailable(.duplicateTool)
        }

        do {
            try executableIdentity.validateForTrustedPathLaunch(atPath: executablePath)
        } catch {
            return .unavailable(.executableUnavailable)
        }

        let observedAt = now()
        let candidate = CursorFigmaMCPToolSurfaceCandidate(
            observedAt: observedAt,
            expiresAt: observedAt.addingTimeInterval(descriptor.observationLifetime),
            executableBuild: CursorFigmaMCPToolSurfaceDescriptor.acceptedExecutableBuild,
            targetIdentifier: CursorFigmaMCPToolSurfaceDescriptor.targetIdentifier
        )
        await cache.store(candidate, for: executableIdentity)
        return .candidate(candidate)
    }

    func cachedCandidate(
        for executableIdentity: ExecutableFileIdentity,
        at date: Date
    ) async -> CursorFigmaMCPToolSurfaceCandidate? {
        await cache.candidate(for: executableIdentity, at: date)
    }
}

protocol CursorFigmaMCPToolSurfaceObserving: Sendable {
    func observe(
        launch: FigmaMCPProviderResolvedLoginLaunch,
        requiresEnable: Bool,
        cachePolicy: CursorFigmaMCPToolSurfaceCachePolicy
    ) async -> CursorFigmaMCPToolSurfaceProbeOutcome
}

/// App-lifetime Settings observer. It accepts only the exact launch retained by the login attempt;
/// it never resolves an executable or rebuilds an environment independently. Successful results
/// remain only in the probe's five-minute in-memory cache.
actor CursorFigmaMCPSettingsToolSurfaceObserver: CursorFigmaMCPToolSurfaceObserving {
    private let probe: CursorFigmaMCPToolSurfaceProbe

    init(probe: CursorFigmaMCPToolSurfaceProbe = .init()) {
        self.probe = probe
    }

    func observe(
        launch: FigmaMCPProviderResolvedLoginLaunch,
        requiresEnable: Bool,
        cachePolicy: CursorFigmaMCPToolSurfaceCachePolicy
    ) async -> CursorFigmaMCPToolSurfaceProbeOutcome {
        guard !Task.isCancelled else { return .unavailable(.cancelled) }
        let outcome = await probe.observe(
            executableIdentity: launch.executableIdentity,
            environment: launch.environment,
            requiresEnable: requiresEnable,
            cachePolicy: cachePolicy
        )
        guard !Task.isCancelled else { return .unavailable(.cancelled) }
        return outcome
    }
}

enum CursorFigmaMCPToolSurfaceOutputValidation: Equatable {
    case valid
    case outputTooLarge
    case invalidUTF8
    case malformed
    case missingRequiredTool
    case duplicateTool
}

/// Strict synthetic parser for Cursor's documented `mcp list-tools <identifier>` shape:
///
///     Tools for figma (<count>):\n
///     - get_design_context (fileKey, nodeId)\n
///     - get_variable_defs (fileKey, nodeId)\n
/// The header's count must agree with the listing, but it is deliberately not pinned to 41.
/// Tool lines expose only an ASCII tool name and its comma-space separated argument names.
private enum CursorFigmaMCPToolSurfaceOutputGrammar {
    private static let headerPrefix = "Tools for \(CursorFigmaMCPToolSurfaceDescriptor.targetIdentifier) ("

    static func validate(_ data: Data, outputByteLimit: Int) -> CursorFigmaMCPToolSurfaceOutputValidation {
        guard !data.isEmpty else { return .malformed }
        guard data.count <= outputByteLimit else { return .outputTooLarge }
        guard let output = String(data: data, encoding: .utf8) else { return .invalidUTF8 }
        guard output.hasSuffix("\n"), !output.contains("\r") else { return .malformed }

        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2,
              lines.last?.isEmpty == true,
              let header = lines.first,
              let declaredToolCount = parseHeader(String(header)),
              declaredToolCount == lines.count - 2
        else {
            return .malformed
        }

        var names = Set<String>()
        for line in lines.dropFirst().dropLast() {
            guard let name = parseToolLine(String(line)) else { return .malformed }
            guard names.insert(name).inserted else { return .duplicateTool }
        }

        guard CursorFigmaMCPToolSurfaceDescriptor.requiredToolNames.isSubset(of: names) else {
            return .missingRequiredTool
        }
        return .valid
    }

    private static func parseHeader(_ header: String) -> Int? {
        guard header.hasPrefix(headerPrefix), header.hasSuffix("):"),
              let count = Int(header.dropFirst(headerPrefix.count).dropLast(2)),
              String(count) == header.dropFirst(headerPrefix.count).dropLast(2)
        else {
            return nil
        }
        return count
    }

    private static func parseToolLine(_ line: String) -> String? {
        guard line.hasPrefix("- ") else { return nil }
        let body = line.dropFirst(2)
        guard let separator = body.firstIndex(of: " ") else { return nil }
        let name = body[..<separator]
        let parameters = body[body.index(after: separator)...]
        guard isValidIdentifier(name), isValidParameters(parameters) else { return nil }
        return String(name)
    }

    private static func isValidParameters(_ value: Substring) -> Bool {
        guard value.first == "(", value.last == ")" else { return false }
        let body = value.dropFirst().dropLast()
        guard !body.isEmpty else { return true }

        let parameters = body.split(separator: ",", omittingEmptySubsequences: false)
        for (index, parameter) in parameters.enumerated() {
            let name: Substring
            if index == 0 {
                name = parameter
            } else {
                guard parameter.first == " " else { return false }
                name = parameter.dropFirst()
            }
            guard isValidIdentifier(name) else { return false }
        }
        return true
    }

    private static func isValidIdentifier(_ value: Substring) -> Bool {
        guard let first = value.utf8.first,
              isIdentifierStart(first),
              value.utf8.dropFirst().allSatisfy(isIdentifierContinuation)
        else {
            return false
        }
        return true
    }

    private static func isIdentifierStart(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 95
    }

    private static func isIdentifierContinuation(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || (byte >= 48 && byte <= 57)
    }
}
