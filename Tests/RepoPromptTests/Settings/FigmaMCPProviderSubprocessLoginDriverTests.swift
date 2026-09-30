import Darwin
import Foundation
@testable import RepoPromptApp
import XCTest

final class FigmaMCPProviderSubprocessLoginDriverTests: XCTestCase {
    func testAvailabilityRequiresAbsoluteExecutableAndUsesNoShell() async {
        let driver = makeDriver(command: "/bin/sh")

        let availability = await driver.evaluateAvailability(provider: .claudeCode, target: .figma)

        XCTAssertEqual(availability, .available)
        let executableIdentity = await driver.executableIdentity()
        XCTAssertEqual(executableIdentity, FileSystemService.realpathString("/bin/sh"))
        let mismatchedAvailability = await driver.evaluateAvailability(provider: .openCode, target: .figma)
        XCTAssertEqual(
            mismatchedAvailability,
            .unavailable("The provider login descriptor does not match this Figma target.")
        )
    }

    func testAvailabilityFailsClosedForAbsentAndUnparsableOpenCodeAndCursorVersions() async {
        for provider in [ExternalMCPRuntimeProvider.openCode, .cursor] {
            for version in [String?(nil), String?("not-a-version"), String?("1.0.0")] {
                let resolvedVersion = version
                let driver = FigmaMCPProviderSubprocessLoginDriver(
                    descriptor: .init(
                        provider: provider,
                        command: "/bin/sh",
                        executableVersion: resolvedVersion,
                        arguments: { _ in [] }
                    ),
                    executableVersionResolver: { [resolvedVersion] in resolvedVersion }
                )

                let availability = await driver.evaluateAvailability(provider: provider, target: .figma)

                if version == "1.0.0" {
                    XCTAssertEqual(availability, .available, "\(provider) should accept a known parseable version")
                } else {
                    XCTAssertEqual(
                        availability,
                        .unavailable("The provider executable is unavailable or unsupported."),
                        "\(provider) should reject version \(version ?? "nil")"
                    )
                }
            }
        }
    }

    func testAvailabilityEnforcesDescriptorMinimumExecutableVersion() async {
        let unsupported = FigmaMCPProviderSubprocessLoginDriver(
            descriptor: .init(
                provider: .claudeCode,
                command: "/bin/sh",
                minimumSupportedVersion: "2.1.186",
                executableVersion: "2.1.185",
                arguments: { _ in [] }
            )
        )
        let unsupportedAvailability = await unsupported.evaluateAvailability(provider: .claudeCode, target: .figma)
        XCTAssertEqual(unsupportedAvailability, .unavailable("The provider executable is unavailable or unsupported."))

        let supported = FigmaMCPProviderSubprocessLoginDriver(
            descriptor: .init(
                provider: .claudeCode,
                command: "/bin/sh",
                minimumSupportedVersion: "2.1.186",
                executableVersion: "2.1.186",
                arguments: { _ in [] }
            )
        )
        let supportedAvailability = await supported.evaluateAvailability(provider: .claudeCode, target: .figma)
        XCTAssertEqual(supportedAvailability, .available)
    }

    func testComposedEnvironmentForFigmaLoginForcesCanonicalDefaultHome() async {
        let inheritedHome = "/tmp/figma-custom-inherited-home"
        let inherited = [
            "TERM": "xterm-256color",
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "HOME": inheritedHome
        ]
        let canonicalHome = FileManager.default.homeDirectoryForCurrentUser.path

        let result = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(
                purpose: .figmaProviderLogin,
                inheritedEnvironment: inherited
            )
        )

        XCTAssertEqual(ProcessEnvironmentBuilder.canonicalDefaultUserHome, canonicalHome)
        XCTAssertNotEqual(inheritedHome, canonicalHome)
        XCTAssertEqual(result.environment["HOME"], canonicalHome)
        XCTAssertEqual(result.shellEnvironmentSource, .inheritedRichEnvironment)
    }

    func testNonFigmaPurposePreservesCustomInheritedHome() async {
        let inheritedHome = "/tmp/non-figma-custom-home"
        let inherited = [
            "TERM": "xterm-256color",
            "PATH": "/opt/custom/bin:/usr/bin:/bin",
            "HOME": inheritedHome
        ]
        let result = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(
                purpose: .cliRunner,
                inheritedEnvironment: inherited
            ),
            shellEnvironmentProvider: { _, _ in
                CLIEnvironmentSnapshot(
                    environment: ["HOME": "/tmp/should-not-be-used"],
                    source: .capturedLoginShell
                )
            }
        )

        XCTAssertEqual(result.environment["HOME"], inheritedHome)
        XCTAssertEqual(result.shellEnvironmentSource, .inheritedRichEnvironment)
    }

    func testSymlinkedExecutableIsCanonicalizedForIdentityAndLaunch() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let symlink = directory.appendingPathComponent("figma-login")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: URL(fileURLWithPath: "/bin/sh")
        )
        let canonicalPath = try XCTUnwrap(FileSystemService.realpathString("/bin/sh"))
        let recorder = LoginInvocationRecorder()
        let driver = makeDriver(command: symlink.path, recorder: recorder)

        let availability = await driver.evaluateAvailability(provider: .claudeCode, target: .figma)
        let identity = await driver.executableIdentity()
        let settlement = await driver.beginLogin(
            provider: .claudeCode,
            target: .figma,
            attemptContext: makeContext(executableIdentity: symlink.path)
        )
        let invocation = await recorder.invocation

        XCTAssertEqual(availability, .available)
        XCTAssertEqual(identity, canonicalPath)
        XCTAssertEqual(settlement, .exited(status: 0))
        XCTAssertEqual(invocation?.configuration.command, canonicalPath)
    }

    func testExecutableReplacementAfterCaptureFailsClosedBeforeSpawn() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try makeExecutable(named: "figma-login", in: directory)
        let replacement = ExecutableReplacement(path: executable.path)
        let recorder = LoginInvocationRecorder()
        let driver = FigmaMCPProviderSubprocessLoginDriver(
            descriptor: .init(
                provider: .claudeCode,
                command: executable.path,
                executableVersion: "1.0.0",
                arguments: { _ in [] }
            ),
            inheritedEnvironment: ["PATH": "/bin"],
            environmentBuilder: { request in
                .init(
                    environment: request.inheritedEnvironment,
                    launchContext: .detect(from: request.inheritedEnvironment),
                    shellEnvironmentSource: .inheritedRichEnvironment
                )
            },
            executableVersionResolver: {
                await replacement.replace()
                return "1.0.0"
            },
            processRunner: { invocation in
                await recorder.record(invocation)
                return .init(status: 0, timedOut: false)
            }
        )

        let settlement = await driver.beginLogin(
            provider: .claudeCode,
            target: .figma,
            attemptContext: makeContext(executableIdentity: executable.path)
        )

        let invocation = await recorder.invocation
        XCTAssertEqual(settlement, .launchFailed)
        XCTAssertNil(invocation)
    }

    func testSymlinkRetargetAfterCaptureFailsClosedBeforeSpawn() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initialExecutable = try makeExecutable(named: "initial-login", in: directory)
        let symlink = directory.appendingPathComponent("figma-login")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: initialExecutable)
        let replacement = ExecutableReplacement(path: symlink.path)
        let recorder = LoginInvocationRecorder()
        let driver = FigmaMCPProviderSubprocessLoginDriver(
            descriptor: .init(
                provider: .claudeCode,
                command: symlink.path,
                executableVersion: "1.0.0",
                arguments: { _ in [] }
            ),
            inheritedEnvironment: ["PATH": "/bin"],
            environmentBuilder: { request in
                .init(
                    environment: request.inheritedEnvironment,
                    launchContext: .detect(from: request.inheritedEnvironment),
                    shellEnvironmentSource: .inheritedRichEnvironment
                )
            },
            executableVersionResolver: {
                await replacement.retarget(to: "/bin/sh")
                return "1.0.0"
            },
            processRunner: { invocation in
                await recorder.record(invocation)
                return .init(status: 0, timedOut: false)
            }
        )

        let settlement = await driver.beginLogin(
            provider: .claudeCode,
            target: .figma,
            attemptContext: makeContext(executableIdentity: symlink.path)
        )

        let invocation = await recorder.invocation
        XCTAssertEqual(settlement, .launchFailed)
        XCTAssertNil(invocation)
    }

    func testLoginInvocationIsOpaqueAndUsesRestrictedConfiguration() async {
        let recorder = LoginInvocationRecorder()
        let driver = makeDriver(command: "/bin/sh", recorder: recorder) { target in
            ["mcp", "login", target]
        }
        let context = makeContext(executableIdentity: "/bin/sh")

        let settlement = await driver.beginLogin(provider: .claudeCode, target: .figma, attemptContext: context)
        let invocation = await recorder.invocation

        XCTAssertEqual(settlement, .exited(status: 0))
        XCTAssertEqual(invocation?.configuration.command, FileSystemService.realpathString("/bin/sh"))
        XCTAssertEqual(invocation?.configuration.additionalPaths, [])
        XCTAssertEqual(invocation?.configuration.shellLookupMode, .disabled)
        XCTAssertEqual(invocation?.configuration.launchPurpose, .figmaProviderLogin)
        XCTAssertTrue(invocation?.configuration.requiresAbsoluteExecutable == true)
        XCTAssertTrue(invocation?.configuration.discardOutput == true)
        XCTAssertEqual(invocation?.configuration.captureStdoutTailBytes, 0)
        XCTAssertEqual(invocation?.configuration.captureStderrTailBytes, 0)
        XCTAssertEqual(invocation?.configuration.logStdinSampleBytes, 0)
        XCTAssertNil(invocation?.configuration.logCollector)
        XCTAssertEqual(invocation?.arguments, ["mcp", "login", "figma-server"])
        XCTAssertEqual(invocation?.timeout, 300)
    }

    func testLoginInvocationForcesCanonicalHomeForDefaultCredentialContext() async {
        let recorder = LoginInvocationRecorder()
        let canonicalHome = FileManager.default.homeDirectoryForCurrentUser.path
        let driver = makeDriver(
            command: "/bin/sh",
            recorder: recorder,
            inheritedEnvironment: [
                "TERM": "xterm-256color",
                "PATH": "/usr/bin:/bin:/usr/local/bin",
                "HOME": "/tmp/custom-figma-profile-home"
            ]
        ) { target in
            ["mcp", "login", target]
        }

        let settlement = await driver.beginLogin(provider: .claudeCode, target: .figma, attemptContext: makeContext(executableIdentity: "/bin/sh"))
        let invocation = await recorder.invocation

        XCTAssertEqual(settlement, .exited(status: 0))
        XCTAssertEqual(invocation?.configuration.environment["HOME"], canonicalHome)
        XCTAssertNotEqual(invocation?.configuration.environment["HOME"], "/tmp/custom-figma-profile-home")
    }

    func testRealChildDoesNotReceiveForbiddenEnvironmentSentinels() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let reportURL = directory.appendingPathComponent("environment.txt")
        let forbidden = ProcessEnvironmentSanitizer.figmaProviderLoginRemovedKeys
        var inherited = Dictionary(uniqueKeysWithValues: forbidden.map { ($0, "forbidden-sentinel-\($0)") })
        inherited["PATH"] = "/bin:/usr/bin"
        inherited["TERM"] = "xterm-256color"

        let driver = makeRealDriver(
            timeout: 5,
            arguments: { _ in ["-c", "env > \"\(reportURL.path)\""] },
            inheritedEnvironment: inherited
        )

        let settlement = await driver.beginLogin(
            provider: .claudeCode,
            target: .figma,
            attemptContext: makeContext(executableIdentity: "/bin/sh")
        )

        XCTAssertEqual(settlement, .exited(status: 0))
        let report = try String(contentsOf: reportURL, encoding: .utf8)
        for key in forbidden {
            XCTAssertFalse(
                report.contains("\(key)=forbidden-sentinel-\(key)"),
                "Forbidden key leaked to the real child: \(key)"
            )
        }
    }

    func testAuthorizationSessionCloseIsPreservedAsTypedSettlement() async {
        let driver = FigmaMCPProviderSubprocessLoginDriver(
            descriptor: .init(
                provider: .claudeCode,
                command: "/bin/sh",
                executableVersion: "1.0.0",
                arguments: { _ in [] }
            ),
            processRunner: { _ in
                .init(
                    status: 1,
                    timedOut: false,
                    interruption: .authorizationSessionClosed
                )
            }
        )

        let settlement = await driver.beginLogin(
            provider: .claudeCode,
            target: .figma,
            attemptContext: makeContext(executableIdentity: "/bin/sh")
        )

        XCTAssertEqual(settlement, .authorizationSessionClosed)
    }

    func testRealChildReportsNonzeroAndSignalSettlements() async {
        let nonzero = makeRealDriver(arguments: { _ in ["-c", "exit 7"] })
        let nonzeroSettlement = await nonzero.beginLogin(
            provider: .claudeCode,
            target: .figma,
            attemptContext: makeContext(executableIdentity: "/bin/sh")
        )
        XCTAssertEqual(nonzeroSettlement, .exited(status: 7))

        let signaled = makeRealDriver(arguments: { _ in ["-c", "kill -KILL $$"] })
        let signaledSettlement = await signaled.beginLogin(
            provider: .claudeCode,
            target: .figma,
            attemptContext: makeContext(executableIdentity: "/bin/sh")
        )
        XCTAssertEqual(signaledSettlement, .exited(status: 128 + SIGKILL))
    }

    func testRealChildTimeoutAndCancellationSettleWithoutRetainingOutput() async throws {
        let timedOut = makeRealDriver(timeout: 0.05, arguments: { _ in ["-c", "sleep 60"] })
        let timeoutSettlement = await timedOut.beginLogin(
            provider: .claudeCode,
            target: .figma,
            attemptContext: makeContext(executableIdentity: "/bin/sh")
        )
        XCTAssertEqual(timeoutSettlement, .timedOut)

        let cancelled = makeRealDriver(timeout: 60, arguments: { _ in ["-c", "sleep 60"] })
        let context = makeContext(executableIdentity: "/bin/sh")
        let loginTask = Task {
            await cancelled.beginLogin(provider: .claudeCode, target: .figma, attemptContext: context)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        await cancelled.cancelLogin(provider: .claudeCode, attemptID: context.attemptID)
        let cancellationSettlement = await loginTask.value
        XCTAssertEqual(cancellationSettlement, .cancelled)
    }

    func testReservedAttemptCanBeCancelledBeforeBegin() async {
        let recorder = LoginInvocationRecorder()
        let driver = makeDriver(command: "/bin/sh", recorder: recorder)
        let context = makeContext(executableIdentity: "/bin/sh")

        await driver.reserveAttempt(context.attemptID)
        await driver.cancelLogin(provider: .claudeCode, attemptID: context.attemptID)

        let settlement = await driver.beginLogin(
            provider: .claudeCode,
            target: .figma,
            attemptContext: context
        )

        XCTAssertEqual(settlement, .cancelled)
        let invocation = await recorder.invocation
        XCTAssertNil(invocation)
    }

    func testCursorFigmaMCPCancellationBeforeReservationLeavesTombstoneAndNeverLaunches() async {
        let recorder = LoginInvocationRecorder()
        let driver = FigmaMCPProviderSubprocessLoginDriver(
            descriptor: .init(
                provider: .cursor,
                command: "/bin/sh",
                executableVersion: "1.0.0",
                arguments: { _ in [] }
            ),
            processRunner: { invocation in
                await recorder.record(invocation)
                return .init(status: 0, timedOut: false)
            }
        )
        let context = FigmaMCPProviderLoginAttemptContext(
            provider: .cursor,
            target: .figma,
            providerTargetIdentifier: "figma",
            credentialContext: .providerDefaultUserProfile,
            evidenceID: "cursor-test-evidence",
            capabilityRevision: "cursor-test-revision",
            executableIdentity: FileSystemService.realpathString("/bin/sh") ?? "/bin/sh",
            executableVersion: "1.0.0"
        )

        await driver.cancelLogin(provider: .cursor, attemptID: context.attemptID)
        let reservation = await driver.reserveAttempt(context.attemptID)
        let settlement = await driver.beginLogin(
            provider: .cursor,
            target: .figma,
            attemptContext: context
        )

        XCTAssertEqual(reservation, .cancelled)
        XCTAssertEqual(settlement, .cancelled)
        let invocation = await recorder.invocation
        XCTAssertNil(invocation)
    }

    func testCursorFigmaMCPSharedProviderLeaseAllowsOnlyOneLoginAcrossDriverInstances() async {
        let descriptor = FigmaMCPProviderSubprocessLoginDescriptor(
            provider: .cursor,
            command: "/bin/sh",
            executableVersion: "1.0.0",
            arguments: { _ in [] }
        )
        let first = FigmaMCPProviderSubprocessLoginDriver(descriptor: descriptor)
        let second = FigmaMCPProviderSubprocessLoginDriver(descriptor: descriptor)
        let firstAttempt = UUID()
        let secondAttempt = UUID()

        let firstReservation = await first.reserveAttempt(firstAttempt)
        let busyReservation = await second.reserveAttempt(secondAttempt)
        XCTAssertEqual(firstReservation, .reserved)
        XCTAssertEqual(busyReservation, .busy)

        await first.cancelLogin(provider: .cursor, attemptID: firstAttempt)
        let secondReservation = await second.reserveAttempt(secondAttempt)
        XCTAssertEqual(secondReservation, .reserved)
        await second.cancelLogin(provider: .cursor, attemptID: secondAttempt)
    }

    func testCredentialLikeChildOutputIsNotRetained() async {
        let driver = makeRealDriver(arguments: { _ in
            [
                "-c",
                "printf '%s\\n' 'FIGMA_PAT=credential-like-secret' >&1; printf '%s\\n' 'authorization=credential-like-secret' >&2"
            ]
        })

        let settlement = await driver.beginLogin(
            provider: .claudeCode,
            target: .figma,
            attemptContext: makeContext(executableIdentity: "/bin/sh")
        )

        XCTAssertEqual(settlement, .exited(status: 0))
    }

    func testRealChildUsesCanonicalHomeDespiteCustomInheritedHome() async {
        let canonicalHome = FileManager.default.homeDirectoryForCurrentUser.path

        let realChild = makeRealDriver(
            arguments: { _ in ["-c", "test \"$HOME\" = \"$1\"", "figma-login", canonicalHome] },
            inheritedEnvironment: [
                "PATH": "/bin:/usr/bin",
                "HOME": "/tmp/custom-figma-inherited-home",
                "TERM": "xterm-256color"
            ]
        )

        let settlement = await realChild.beginLogin(
            provider: .claudeCode,
            target: .figma,
            attemptContext: makeContext(executableIdentity: "/bin/sh")
        )

        XCTAssertEqual(settlement, .exited(status: 0))
    }

    func testSanitizedEnvironmentIsPassedAsTheRunnerEnvironment() async {
        let recorder = LoginInvocationRecorder()
        let inherited = [
            "PATH": "/bin",
            "FIGMA_PAT": "forbidden-sentinel",
            "DYLD_INSERT_LIBRARIES": "/tmp/forbidden.dylib"
        ]
        let sanitized = ProcessEnvironmentSanitizer.sanitizedForChildLaunch(
            inherited,
            additionalRemovedKeys: ProcessEnvironmentSanitizer.figmaProviderLoginRemovedKeys
        )
        let canonicalHome = ProcessEnvironmentBuilder.canonicalDefaultUserHome
        XCTAssertNotNil(canonicalHome)
        var expected = sanitized
        if let canonicalHome {
            expected["HOME"] = canonicalHome
        }
        let driver = FigmaMCPProviderSubprocessLoginDriver(
            descriptor: .init(
                provider: .claudeCode,
                command: "/bin/sh",
                executableVersion: "1.0.0",
                arguments: { _ in ["-c", "exit 0"] }
            ),
            inheritedEnvironment: inherited,
            environmentBuilder: { _ in
                .init(
                    environment: sanitized,
                    launchContext: .detect(from: sanitized),
                    shellEnvironmentSource: .inheritedRichEnvironment
                )
            },
            processRunner: { invocation in
                await recorder.record(invocation)
                return .init(status: 0, timedOut: false)
            }
        )

        let settlement = await driver.beginLogin(
            provider: .claudeCode,
            target: .figma,
            attemptContext: makeContext(executableIdentity: "/bin/sh")
        )
        let invocation = await recorder.invocation

        XCTAssertEqual(settlement, .exited(status: 0))
        XCTAssertEqual(invocation?.configuration.environment, expected)
        XCTAssertNil(invocation?.configuration.environment["FIGMA_PAT"])
        XCTAssertNil(invocation?.configuration.environment["DYLD_INSERT_LIBRARIES"])
        XCTAssertEqual(invocation?.configuration.environment["HOME"], canonicalHome)
    }

    func testExitStatusIsOnlyAProcessSettlement() async {
        let driver = makeDriver(command: "/bin/sh")
        let context = makeContext(executableIdentity: "/bin/sh")

        let settlement = await driver.beginLogin(provider: .claudeCode, target: .figma, attemptContext: context)

        XCTAssertEqual(settlement, .exited(status: 0))
    }

    func testImmediateCancellationTerminatesChildGrandchildAndReapsRoot() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rootMarker = directory.appendingPathComponent("root.pid")
        let grandchildMarker = directory.appendingPathComponent("grandchild.pid")
        let script = """
        #!/bin/sh
        # This script is the real provider CLI child. It creates a real
        # grandchild in the same process group before waiting indefinitely.
        printf '%s\\n' "$$" > "$1"
        (/bin/sh -c 'printf "%s\\n" "$$" > "$1"; trap "" TERM; while :; do sleep 1; done' grandchild "$2" &)
        while :; do sleep 1; done
        """
        let scriptURL = directory.appendingPathComponent("figma-login.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let driver = makeRealDriver(
            timeout: 30,
            arguments: { _ in [scriptURL.path, rootMarker.path, grandchildMarker.path] }
        )
        let context = makeContext(executableIdentity: "/bin/sh")
        let loginTask = Task {
            await driver.beginLogin(provider: .claudeCode, target: .figma, attemptContext: context)
        }

        let rootPID: pid_t
        let grandchildPID: pid_t
        do {
            rootPID = try await Self.waitForPIDFile(rootMarker)
            grandchildPID = try await Self.waitForPIDFile(grandchildMarker)
        } catch {
            await driver.cancelLogin(provider: .claudeCode, attemptID: context.attemptID)
            _ = await loginTask.value
            throw error
        }

        // Cancel as soon as the real child has created its grandchild. The driver must
        // terminate the whole group and reap the root process before returning.
        await driver.cancelLogin(provider: .claudeCode, attemptID: context.attemptID)
        let settlement = await loginTask.value

        XCTAssertEqual(settlement, .cancelled)
        let grandchildExited = await Self.waitUntilProcessGone(grandchildPID)
        XCTAssertTrue(grandchildExited)
        var waitStatus: Int32 = 0
        let waitResult = Darwin.waitpid(rootPID, &waitStatus, WNOHANG)
        let waitError = errno
        XCTAssertEqual(waitResult, -1)
        XCTAssertEqual(waitError, ECHILD)
    }

    func testCancellationCancelsOnlyMatchingDriverAttempt() async {
        let recorder = LoginInvocationRecorder()
        let descriptor = FigmaMCPProviderSubprocessLoginDescriptor(
            provider: .claudeCode,
            command: "/bin/sh",
            executableVersion: "1.0.0",
            arguments: { _ in ["mcp", "login", "figma-server"] }
        )
        let driver = FigmaMCPProviderSubprocessLoginDriver(
            descriptor: descriptor,
            inheritedEnvironment: ["PATH": "/bin"],
            environmentBuilder: { request in
                .init(
                    environment: request.inheritedEnvironment,
                    launchContext: .detect(from: request.inheritedEnvironment),
                    shellEnvironmentSource: .inheritedRichEnvironment
                )
            },
            processRunner: { invocation in
                await recorder.record(invocation)
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                return .init(status: 0, timedOut: false)
            }
        )
        let context = makeContext(executableIdentity: "/bin/sh")
        let loginTask = Task {
            await driver.beginLogin(provider: .claudeCode, target: .figma, attemptContext: context)
        }
        _ = await recorder.waitForInvocation()

        await driver.cancelLogin(provider: .claudeCode, attemptID: UUID())
        await driver.cancelLogin(provider: .openCode, attemptID: context.attemptID)
        await driver.cancelLogin(provider: .claudeCode, attemptID: context.attemptID)

        let settlement = await loginTask.value
        XCTAssertEqual(settlement, .cancelled)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FigmaMCPProviderSubprocessLoginDriverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func makeExecutable(named name: String, in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        let contents = "#!/bin/sh\nexit 0\n"
        guard FileManager.default.createFile(atPath: executable.path, contents: contents.data(using: .utf8)) else {
            throw NSError(domain: "FigmaMCPProviderSubprocessLoginDriverTests", code: 1)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }

    private func makeRealDriver(
        timeout: TimeInterval = 5,
        arguments: @escaping @Sendable (String) -> [String],
        inheritedEnvironment: [String: String] = ["PATH": "/bin:/usr/bin", "TERM": "xterm-256color"]
    ) -> FigmaMCPProviderSubprocessLoginDriver {
        FigmaMCPProviderSubprocessLoginDriver(
            descriptor: .init(
                provider: .claudeCode,
                command: "/bin/sh",
                timeout: timeout,
                executableVersion: "1.0.0",
                arguments: arguments
            ),
            inheritedEnvironment: inheritedEnvironment
        )
    }

    private func makeDriver(
        command: String,
        recorder: LoginInvocationRecorder? = nil,
        inheritedEnvironment: [String: String] = ["PATH": "/bin", "SHELL": "/bin/sh", "TERM": "xterm-256color"],
        arguments: @escaping @Sendable (String) -> [String] = { _ in ["mcp", "login", "figma-server"] }
    ) -> FigmaMCPProviderSubprocessLoginDriver {
        let descriptor = FigmaMCPProviderSubprocessLoginDescriptor(
            provider: .claudeCode,
            command: command,
            executableVersion: "1.0.0",
            arguments: arguments
        )
        return FigmaMCPProviderSubprocessLoginDriver(
            descriptor: descriptor,
            inheritedEnvironment: inheritedEnvironment,
            environmentBuilder: { request in
                .init(
                    environment: request.inheritedEnvironment,
                    launchContext: .detect(from: request.inheritedEnvironment),
                    shellEnvironmentSource: .inheritedRichEnvironment
                )
            },
            processRunner: { invocation in
                await recorder?.record(invocation)
                return .init(status: 0, timedOut: false)
            }
        )
    }

    private static func waitForPIDFile(_ url: URL, timeout: TimeInterval = 3) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return value
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "FigmaMCPProviderSubprocessLoginDriverTests", code: 2)
    }

    private static func waitUntilProcessGone(_ pid: pid_t, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Darwin.kill(pid, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return Darwin.kill(pid, 0) == -1 && errno == ESRCH
    }

    private func makeContext(executableIdentity: String) -> FigmaMCPProviderLoginAttemptContext {
        .init(
            provider: .claudeCode,
            target: .figma,
            providerTargetIdentifier: "figma-server",
            credentialContext: .providerDefaultUserProfile,
            evidenceID: "test-evidence",
            capabilityRevision: "test-revision",
            executableIdentity: FileSystemService.realpathString(executableIdentity) ?? executableIdentity
        )
    }
}

private actor ExecutableReplacement {
    let path: String

    init(path: String) {
        self.path = path
    }

    func replace() {
        try? FileManager.default.removeItem(atPath: path)
        _ = FileManager.default.createFile(
            atPath: path,
            contents: Data("#!/bin/sh\nexit 999\n".utf8)
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    func retarget(to destination: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: destination)
    }
}

private actor LoginInvocationRecorder {
    private(set) var invocation: FigmaMCPProviderLoginProcessInvocation?
    private var waiter: CheckedContinuation<FigmaMCPProviderLoginProcessInvocation?, Never>?

    func record(_ invocation: FigmaMCPProviderLoginProcessInvocation) {
        self.invocation = invocation
        waiter?.resume(returning: invocation)
        waiter = nil
    }

    func waitForInvocation() async -> FigmaMCPProviderLoginProcessInvocation? {
        if let invocation { return invocation }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}
