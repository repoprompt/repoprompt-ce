import AppKit
import Foundation

/// Runs one provider-owned Figma login command in a dedicated, visible Terminal window.
///
/// If Terminal is not running, the command uses Terminal's single launch-created window. If it is
/// already running, the command always gets a new window and never reuses the user's active tab.
enum FigmaMCPProviderTerminalHandoff {
    struct Session: Equatable {
        let provider: ExternalMCPRuntimeProvider
        let attemptID: UUID
        let title: String
    }

    actor SessionController {
        typealias CloseRunner = @Sendable (Session) async -> Void

        private let closeRunner: CloseRunner
        private var sessions: [UUID: Session] = [:]
        private var creationPermitIsHeld = false
        private var creationPermitWaiters: [CheckedContinuation<Void, Never>] = []

        init(closeRunner: @escaping CloseRunner = { session in
            await FigmaMCPProviderTerminalHandoff.closeTerminalSession(named: session.title)
        }) {
            self.closeRunner = closeRunner
        }

        func acquireCreationPermit() async {
            guard creationPermitIsHeld else {
                creationPermitIsHeld = true
                return
            }
            await withCheckedContinuation { continuation in
                creationPermitWaiters.append(continuation)
            }
        }

        func releaseCreationPermit() {
            guard !creationPermitWaiters.isEmpty else {
                creationPermitIsHeld = false
                return
            }
            creationPermitWaiters.removeFirst().resume()
        }

        func register(provider: ExternalMCPRuntimeProvider, attemptID: UUID, title: String) {
            sessions[attemptID] = .init(provider: provider, attemptID: attemptID, title: title)
        }

        func closeAfterVerifiedConnection(provider: ExternalMCPRuntimeProvider, attemptID: UUID) async {
            guard let session = sessions[attemptID], session.provider == provider else { return }
            sessions.removeValue(forKey: attemptID)
            await closeRunner(session)
        }

        func closeOwnedSession(provider: ExternalMCPRuntimeProvider, attemptID: UUID, title: String) async {
            guard let session = sessions[attemptID], session.provider == provider, session.title == title else { return }
            sessions.removeValue(forKey: attemptID)
            await closeRunner(session)
        }

        func forgetOwnedSession(provider: ExternalMCPRuntimeProvider, attemptID: UUID) {
            guard sessions[attemptID]?.provider == provider else { return }
            sessions.removeValue(forKey: attemptID)
        }
    }

    private static let osascriptPath = "/usr/bin/osascript"
    private static let authorizationSessionClosedMarker = "REPOPROMPT_AUTHORIZATION_SESSION_CLOSED"

    static func makeProcessRunner(
        provider: ExternalMCPRuntimeProvider,
        resultFilePrefix: String,
        sessionTitlePrefix: String,
        sessionController: SessionController
    ) -> FigmaMCPProviderSubprocessLoginDriver.ProcessRunner {
        { invocation in
            let resultURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(resultFilePrefix)-\(UUID().uuidString)")
            let sessionTitle = "\(sessionTitlePrefix) \(UUID().uuidString)"
            defer { try? FileManager.default.removeItem(at: resultURL) }
            let command = shellCommand(
                executablePath: invocation.configuration.command,
                arguments: invocation.arguments,
                resultPath: resultURL.path
            )
            let configuration = osascriptConfiguration(environment: invocation.configuration.environment)

            return try await withTaskCancellationHandler {
                await sessionController.acquireCreationPermit()
                guard !Task.isCancelled else {
                    await sessionController.releaseCreationPermit()
                    throw CancellationError()
                }

                let launchResult: CLIProcessRunner.Result
                do {
                    // Capture this while holding the creation permit and before osascript can load
                    // Terminal's scripting interface. The permit is released as soon as this tab is
                    // uniquely titled; authorization processes still run concurrently.
                    let terminalWasRunning = isTerminalRunning
                    await sessionController.register(
                        provider: provider,
                        attemptID: invocation.attemptID,
                        title: sessionTitle
                    )
                    launchResult = try await CLIProcessRunner(config: configuration).run(
                        args: [
                            "-e",
                            terminalScript,
                            command,
                            sessionTitle,
                            terminalWasRunning ? "true" : "false"
                        ],
                        stdin: nil,
                        outputMode: .none,
                        timeout: 10,
                        cancelChildOnTaskCancellation: true
                    )
                } catch {
                    await sessionController.releaseCreationPermit()
                    await sessionController.forgetOwnedSession(provider: provider, attemptID: invocation.attemptID)
                    throw error
                }
                await sessionController.releaseCreationPermit()

                guard launchResult.status == 0, !launchResult.timedOut else {
                    if launchResult.timedOut {
                        await sessionController.closeOwnedSession(
                            provider: provider,
                            attemptID: invocation.attemptID,
                            title: sessionTitle
                        )
                    } else {
                        await sessionController.forgetOwnedSession(provider: provider, attemptID: invocation.attemptID)
                    }
                    return .init(status: launchResult.status, timedOut: launchResult.timedOut)
                }

                let result = try await CLIProcessRunner(config: configuration).run(
                    args: ["-e", terminalWaitScript, resultURL.path, sessionTitle],
                    stdin: nil,
                    outputMode: .none,
                    timeout: invocation.timeout,
                    cancelChildOnTaskCancellation: true
                )
                if result.timedOut {
                    await sessionController.closeOwnedSession(
                        provider: provider,
                        attemptID: invocation.attemptID,
                        title: sessionTitle
                    )
                    return .init(status: result.status, timedOut: true)
                }
                if terminalWaitReportedClosedSession(result) {
                    // The wait script reports this marker only when the uniquely titled Terminal
                    // tab no longer exists. Provider exit status remains a separate result-file value.
                    await sessionController.forgetOwnedSession(
                        provider: provider,
                        attemptID: invocation.attemptID
                    )
                    return .init(
                        status: result.status,
                        timedOut: false,
                        interruption: .authorizationSessionClosed
                    )
                }
                if result.status != 0 {
                    await sessionController.forgetOwnedSession(
                        provider: provider,
                        attemptID: invocation.attemptID
                    )
                }
                return .init(status: terminalExitStatus(from: result), timedOut: false)
            } onCancel: {
                Task {
                    await sessionController.closeOwnedSession(
                        provider: provider,
                        attemptID: invocation.attemptID,
                        title: sessionTitle
                    )
                }
            }
        }
    }

    static func closeAfterVerifiedConnection(
        provider: ExternalMCPRuntimeProvider,
        attemptID: UUID,
        sessionController: SessionController
    ) async {
        await sessionController.closeAfterVerifiedConnection(provider: provider, attemptID: attemptID)
    }

    static func shellCommand(
        executablePath: String,
        arguments: [String],
        resultPath: String
    ) -> String {
        ([shellQuote(executablePath)] + arguments.map(shellQuote)).joined(separator: " ")
            + "; rp_exit_status=$?; printf '%s\\n' \"$rp_exit_status\" > \(shellQuote(resultPath))"
    }

    static let terminalScript = """
    on run argv
        set loginCommand to item 1 of argv
        set sessionTitle to item 2 of argv
        set terminalWasRunning to (item 3 of argv is "true")
        tell application "Terminal"
            if terminalWasRunning then
                set loginTab to do script loginCommand
                activate
            else
                activate
                repeat 100 times
                    if exists window 1 then exit repeat
                    delay 0.05
                end repeat
                if not (exists window 1) then error "Terminal did not create its launch window."
                set loginTab to selected tab of front window
                do script loginCommand in loginTab
            end if
            set custom title of loginTab to sessionTitle
        end tell
        return sessionTitle
    end run
    """

    private static let terminalWaitScript = """
    on run argv
        set resultPath to item 1 of argv
        set sessionTitle to item 2 of argv
        repeat
            tell application "Terminal"
                set loginTab to missing value
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        if custom title of aTab is sessionTitle then set loginTab to aTab
                    end repeat
                end repeat
                if loginTab is missing value then return "\(authorizationSessionClosedMarker)"
                if not busy of loginTab then exit repeat
            end tell
            delay 0.2
        end repeat
        return do shell script "/bin/cat " & quoted form of resultPath
    end run
    """

    private static let closeTerminalSessionScript = """
    on run argv
        set sessionTitle to item 1 of argv
        tell application "Terminal"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    if custom title of aTab is sessionTitle then close aTab
                end repeat
            end repeat
        end tell
    end run
    """

    static func terminalWaitReportedClosedSession(_ result: CLIProcessRunner.Result) -> Bool {
        guard result.status == 0 else { return false }
        return String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == authorizationSessionClosedMarker
    }

    private static func terminalExitStatus(from result: CLIProcessRunner.Result) -> Int32 {
        guard result.status == 0,
              let output = String(data: result.stdout, encoding: .utf8)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              let status = Int32(output)
        else { return result.status == 0 ? 1 : result.status }
        return status
    }

    private static func closeTerminalSession(named title: String) async {
        guard isTerminalRunning else { return }
        let runner = CLIProcessRunner(config: osascriptConfiguration(environment: ProcessInfo.processInfo.environment))
        _ = try? await runner.run(
            args: ["-e", closeTerminalSessionScript, title],
            stdin: nil,
            outputMode: .none,
            timeout: 5,
            cancelChildOnTaskCancellation: true
        )
    }

    private static func osascriptConfiguration(environment: [String: String]) -> CLIProcessConfiguration {
        CLIProcessConfiguration(
            command: osascriptPath,
            environment: environment,
            additionalPaths: [],
            launchPurpose: .figmaProviderLogin,
            requiresAbsoluteExecutable: true,
            shellLookupMode: .disabled,
            captureStdoutTailBytes: 1024,
            captureStderrTailBytes: 1024,
            discardOutput: false
        )
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'"
    }

    private static var isTerminalRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty
    }
}
