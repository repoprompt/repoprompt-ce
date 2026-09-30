import Foundation
@testable import RepoPromptApp
import XCTest

final class ClaudeCodeFigmaMCPLoginFactoryTests: XCTestCase {
    func testTerminalHandoffBuildsOneVisibleClaudeLoginCommand() {
        let command = ClaudeCodeFigmaTerminalHandoff.shellCommand(
            executablePath: "/opt/Claude Code/bin/claude",
            arguments: ["mcp", "login", "plugin:figma:figma"],
            resultPath: "/tmp/claude figma status"
        )

        XCTAssertEqual(
            command,
            #"'/opt/Claude Code/bin/claude' 'mcp' 'login' 'plugin:figma:figma'; rp_exit_status=$?; printf '%s\n' "$rp_exit_status" > '/tmp/claude figma status'"#
        )
    }

    func testTerminalCloseMarkerIsDistinctFromChildExitAndGenericScriptFailure() {
        let closedSession = CLIProcessRunner.Result(
            stdout: Data("REPOPROMPT_AUTHORIZATION_SESSION_CLOSED\n".utf8),
            stderr: Data(),
            status: 0,
            timedOut: false
        )
        let childExit = CLIProcessRunner.Result(
            stdout: Data("1\n".utf8),
            stderr: Data(),
            status: 0,
            timedOut: false
        )
        let scriptFailure = CLIProcessRunner.Result(
            stdout: Data("REPOPROMPT_AUTHORIZATION_SESSION_CLOSED\n".utf8),
            stderr: Data("Terminal scripting failed\n".utf8),
            status: 1,
            timedOut: false
        )

        XCTAssertTrue(FigmaMCPProviderTerminalHandoff.terminalWaitReportedClosedSession(closedSession))
        XCTAssertFalse(FigmaMCPProviderTerminalHandoff.terminalWaitReportedClosedSession(childExit))
        XCTAssertFalse(FigmaMCPProviderTerminalHandoff.terminalWaitReportedClosedSession(scriptFailure))
    }

    func testTerminalHandoffUsesLaunchWindowOrCreatesDedicatedWindow() throws {
        let script = ClaudeCodeFigmaTerminalHandoff.terminalScript
        let runningArgument = try XCTUnwrap(script.range(of: #"set terminalWasRunning to (item 3 of argv is "true")"#))
        let terminalTell = try XCTUnwrap(script.range(of: #"tell application "Terminal""#))

        XCTAssertLessThan(runningArgument.lowerBound, terminalTell.lowerBound)
        XCTAssertFalse(script.contains(#"running of application "Terminal""#))
        let normalizedLines = script.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let runningBranchIndex = try XCTUnwrap(normalizedLines.firstIndex(of: "if terminalWasRunning then"))
        XCTAssertEqual(
            Array(normalizedLines.dropFirst(runningBranchIndex).prefix(5)),
            [
                "if terminalWasRunning then",
                "set loginTab to do script loginCommand",
                "activate",
                "else",
                "activate"
            ],
            "An already-running Terminal must create the dedicated login window before activation to avoid a reopen race producing two windows."
        )
        XCTAssertEqual(script.components(separatedBy: "set loginTab to do script loginCommand").count - 1, 1)
        XCTAssertTrue(script.contains(#"if not (exists window 1) then error "Terminal did not create its launch window.""#))
        XCTAssertTrue(script.contains("set loginTab to selected tab of front window"))
        XCTAssertTrue(script.contains("do script loginCommand in loginTab"))
    }

    func testTerminalSessionControllerClosesOnlyTheVerifiedProviderSession() async {
        let recorder = TerminalSessionCloseRecorder()
        let controller = FigmaMCPProviderTerminalHandoff.SessionController { session in
            await recorder.record(session)
        }
        let claudeAttemptID = UUID()
        let firstCursorAttemptID = UUID()
        let secondCursorAttemptID = UUID()

        await controller.register(provider: .claudeCode, attemptID: claudeAttemptID, title: "Claude authorization")
        await controller.register(provider: .cursor, attemptID: firstCursorAttemptID, title: "First Cursor authorization")
        await controller.register(provider: .cursor, attemptID: secondCursorAttemptID, title: "Second Cursor authorization")
        await controller.closeOwnedSession(provider: .cursor, attemptID: firstCursorAttemptID, title: "stale title")
        await controller.closeAfterVerifiedConnection(provider: .claudeCode, attemptID: claudeAttemptID)
        await controller.closeAfterVerifiedConnection(provider: .claudeCode, attemptID: claudeAttemptID)

        let sessionsAfterClaudeVerification = await recorder.sessions
        XCTAssertEqual(sessionsAfterClaudeVerification, [
            .init(provider: .claudeCode, attemptID: claudeAttemptID, title: "Claude authorization")
        ])

        await controller.closeAfterVerifiedConnection(provider: .cursor, attemptID: firstCursorAttemptID)
        let sessionsAfterCursorVerification = await recorder.sessions
        XCTAssertEqual(sessionsAfterCursorVerification, [
            .init(provider: .claudeCode, attemptID: claudeAttemptID, title: "Claude authorization"),
            .init(provider: .cursor, attemptID: firstCursorAttemptID, title: "First Cursor authorization")
        ])

        await controller.closeAfterVerifiedConnection(provider: .cursor, attemptID: secondCursorAttemptID)
    }

    func testFactoryBuildsUnwiredClaudeLoginComponents() {
        let components = ClaudeCodeFigmaMCPLoginFactory.makeComponents(sessionController: FigmaMCPProviderTerminalHandoff.SessionController(closeRunner: { _ in }), timeout: 42)

        XCTAssertEqual(components.descriptor.provider, .claudeCode)
        XCTAssertEqual(components.descriptor.executableProfile, CLILaunchProfiles.claudeCode)
        XCTAssertEqual(components.descriptor.minimumSupportedVersion, "2.1.186")
        XCTAssertEqual(components.targetResolver.runtimeProvider, .claudeCode)
        XCTAssertEqual(components.subprocessDescriptor.provider, .claudeCode)
        XCTAssertEqual(components.subprocessDescriptor.command, "claude")
        XCTAssertEqual(components.subprocessDescriptor.timeout, 42)
        XCTAssertEqual(
            components.subprocessDescriptor.arguments("plugin:figma:figma"),
            ["mcp", "login", "plugin:figma:figma"]
        )
    }

    func testVersionParserAcceptsOnlyCompleteClaudeVersionForms() {
        let accepted = [
            "2.1.186\n",
            "claude 2.1.186\n",
            "2.1.186 (Claude Code)\n"
        ]
        for output in accepted {
            XCTAssertEqual(
                ClaudeCodeExecutableVersionParser.parse(.init(
                    stdout: Data(output.utf8),
                    stderr: Data(),
                    status: 0,
                    timedOut: false
                )),
                "2.1.186",
                "Expected to parse \(output.debugDescription)"
            )
        }

        let rejected = [
            ClaudeCodeExecutableVersionProbeResult(stdout: Data("Claude Code 2.1.186\n".utf8), stderr: Data(), status: 0, timedOut: false),
            ClaudeCodeExecutableVersionProbeResult(stdout: Data("claude 2.1.186\nextra\n".utf8), stderr: Data(), status: 0, timedOut: false),
            ClaudeCodeExecutableVersionProbeResult(stdout: Data("version=2.1.186\n".utf8), stderr: Data(), status: 0, timedOut: false),
            ClaudeCodeExecutableVersionProbeResult(stdout: Data("2.1.186\n".utf8), stderr: Data("diagnostic\n".utf8), status: 0, timedOut: false),
            ClaudeCodeExecutableVersionProbeResult(stdout: Data("2.1.186\n".utf8), stderr: Data(), status: 1, timedOut: false),
            ClaudeCodeExecutableVersionProbeResult(stdout: Data("2.1.186\n".utf8), stderr: Data(), status: 0, timedOut: true),
            ClaudeCodeExecutableVersionProbeResult(stdout: Data("2.1.186.1\n".utf8), stderr: Data(), status: 0, timedOut: false)
        ]
        for result in rejected {
            XCTAssertNil(ClaudeCodeExecutableVersionParser.parse(result))
        }
    }

    func testVersionProbeUsesCanonicalPathAndRestrictedVersionInvocationWithFakeProcess() async {
        let recorder = VersionProbeInvocationRecorder()
        let probe = ClaudeCodeExecutableVersionProbe(
            timeout: 7,
            processRunner: { invocation in
                await recorder.record(invocation)
                return .init(
                    stdout: Data("claude 2.1.186\n".utf8),
                    stderr: Data(),
                    status: 0,
                    timedOut: false
                )
            }
        )

        let environment = ["PATH": "/fake/bin", "HOME": "/fake/home"]
        let version = await probe.probe(
            executablePath: "/fake/bin/claude",
            environment: environment
        )
        let invocation = await recorder.invocation

        XCTAssertEqual(version, "2.1.186")
        XCTAssertEqual(invocation?.configuration.command, "/fake/bin/claude")
        XCTAssertEqual(invocation?.configuration.environment, environment)
        XCTAssertEqual(invocation?.configuration.launchPurpose, .figmaProviderLogin)
        XCTAssertTrue(invocation?.configuration.requiresAbsoluteExecutable == true)
        XCTAssertEqual(invocation?.configuration.shellLookupMode, .disabled)
        XCTAssertEqual(invocation?.arguments, ["--version"])
        XCTAssertEqual(invocation?.timeout, 7)
    }

    func testFactoryDriverUsesInjectedVersionProbeAndFakeLoginProcess() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("claude")
        try makeExecutable(at: executable)

        let probeRecorder = VersionProbeInvocationRecorder()
        let probe = ClaudeCodeExecutableVersionProbe(
            processRunner: { invocation in
                await probeRecorder.record(invocation)
                return .init(stdout: Data("2.1.186\n".utf8), stderr: Data(), status: 0, timedOut: false)
            }
        )
        let loginRecorder = LoginInvocationRecorder()
        let components = ClaudeCodeFigmaMCPLoginFactory.makeComponents(
            sessionController: FigmaMCPProviderTerminalHandoff.SessionController(closeRunner: { _ in }),
            timeout: 19,
            executableVersionProbe: probe
        )
        let driver = components.makeLoginDriver(
            inheritedEnvironment: ["PATH": directory.path],
            environmentBuilder: { request in
                .init(
                    environment: request.inheritedEnvironment,
                    launchContext: .detect(from: request.inheritedEnvironment),
                    shellEnvironmentSource: .inheritedRichEnvironment
                )
            },
            processRunner: { invocation in
                await loginRecorder.record(invocation)
                return .init(status: 0, timedOut: false)
            }
        )
        let canonicalPath = try XCTUnwrap(FileSystemService.realpathString(executable.path))
        let context = FigmaMCPProviderLoginAttemptContext(
            provider: .claudeCode,
            target: .figma,
            providerTargetIdentifier: ClaudeCodeFigmaMCPLoginDescriptor.targetIdentifier,
            credentialContext: .providerDefaultUserProfile,
            evidenceID: ClaudeCodeFigmaMCPLoginDescriptor.evidenceID,
            capabilityRevision: ClaudeCodeFigmaMCPLoginDescriptor.capabilityRevision,
            executableIdentity: canonicalPath,
            executableVersion: "2.1.186"
        )

        let availability = await driver.evaluateAvailability(provider: .claudeCode, target: .figma)
        let settlement = await driver.beginLogin(provider: .claudeCode, target: .figma, attemptContext: context)
        let versionInvocation = await probeRecorder.invocation
        let loginInvocation = await loginRecorder.invocation

        XCTAssertEqual(availability, .available)
        XCTAssertEqual(settlement, .exited(status: 0))
        XCTAssertEqual(versionInvocation?.configuration.command, canonicalPath)
        XCTAssertEqual(versionInvocation?.arguments, ["--version"])
        XCTAssertEqual(loginInvocation?.configuration.command, canonicalPath)
        XCTAssertEqual(loginInvocation?.arguments, ["mcp", "login", "plugin:figma:figma"])
        XCTAssertEqual(loginInvocation?.timeout, 19)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeExecutable(at url: URL) throws {
        let contents = "#!/bin/sh\nexit 0\n"
        guard FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8)) else {
            throw NSError(domain: "ClaudeCodeFigmaMCPLoginFactoryTests", code: 1)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private actor VersionProbeInvocationRecorder {
    private(set) var invocation: ClaudeCodeExecutableVersionProbe.Invocation?

    func record(_ invocation: ClaudeCodeExecutableVersionProbe.Invocation) {
        self.invocation = invocation
    }
}

private actor LoginInvocationRecorder {
    private(set) var invocation: FigmaMCPProviderLoginProcessInvocation?

    func record(_ invocation: FigmaMCPProviderLoginProcessInvocation) {
        self.invocation = invocation
    }
}

private actor TerminalSessionCloseRecorder {
    private(set) var sessions: [FigmaMCPProviderTerminalHandoff.Session] = []

    func record(_ session: FigmaMCPProviderTerminalHandoff.Session) {
        sessions.append(session)
    }
}
