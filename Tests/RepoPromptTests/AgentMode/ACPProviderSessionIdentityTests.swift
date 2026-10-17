import Darwin
import Foundation
import os
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptProcess
import RepoPromptSettingsCore
import XCTest

final class ACPProviderSessionIdentityTests: XCTestCase {
    func testACPBootstrapRefusesDevinNewAndColdResumeWithoutFixtureOptIn() async throws {
        // Hydration can request a fresh controller for a persisted provider session;
        // neither that identity nor discovery is permission to start a provider in XCTest.
        for resumeID in [nil, "persisted-devin-session"] as [String?] {
            let workspace = try makeTemporaryDirectory()
            let recordURL = workspace.appendingPathComponent("requests.jsonl")
            let provider = try FakeACPProvider(
                providerID: .devin,
                commandPath: makeFakeACPServerScript().path,
                environment: ["ACP_RECORD_PATH": recordURL.path]
            )
            let request = makeRunRequest(agentKind: .devin, workspacePath: workspace.path, resumeSessionID: resumeID)
            let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
            do {
                _ = try await controller.bootstrap()
                XCTFail("Discovery and cold resume must fail closed without an explicit fixture permit")
            } catch {
                XCTAssertTrue(error is ProviderProcessLaunchPolicy.Refusal, "Unexpected refusal: \(error)")
            }
            let identity = await controller.currentProviderSessionIdentity()
            XCTAssertNil(identity.runtimeSessionID)
            XCTAssertEqual(identity.loadSessionID, resumeID)
            await controller.shutdown()
            XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path), "Refusal must precede ACP initialization")
        }
    }

    func testCancelledShutdownDrainsProviderTerminalPartBeforeClosingTransport() async throws {
        let workspace = try makeTemporaryDirectory()
        let record = workspace.appendingPathComponent("requests.jsonl")
        let part = workspace.appendingPathComponent("native-tool-part.json")
        let request = makeRunRequest(agentKind: .openCode, workspacePath: workspace.path)
        let provider = try FakeACPProvider(
            providerID: .openCode,
            commandPath: makeFakeACPServerScript().path,
            environment: ["ACP_RECORD_PATH": record.path, "ACP_CANCEL_PART_PATH": part.path]
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: request,
            allowsProviderProcessLaunchForTesting: true
        )
        _ = try await controller.bootstrap()
        let stream = await controller.currentEventsStream()
        let prompt = Task { try await controller.prompt(AgentMessage(userMessage: "cancel fixture")) }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: part.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
        await controller.cancelPrompt()
        let shutdown = Task {
            // Real stop/teardown can inherit cancellation from its owning run.
            withUnsafeCurrentTask { $0?.cancel() }
            await controller.shutdown()
        }
        await shutdown.value
        _ = try? await prompt.value
        let native = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: part)) as? [String: Any])
        XCTAssertEqual(native["status"] as? String, "error")
        XCTAssertNotNil(native["end"] as? Double)
        XCTAssertEqual(native["output"] as? String, "Tool execution aborted")
        var terminalOutputs: [String] = []
        var runningCalls = 0
        for await event in stream {
            if case let .stream(result) = event, let tool = AgentToolStreamEvent.from(result),
               case .toolCall = tool { runningCalls += 1 }

            if case let .stream(result) = event, let tool = AgentToolStreamEvent.from(result),
               case let .toolResult(result) = tool { terminalOutputs.append(result.resultJSON) }
        }
        XCTAssertEqual(runningCalls, 1)
        XCTAssertEqual(terminalOutputs.count, 1, "Late terminal content must be delivered before readers close")
        XCTAssertTrue(terminalOutputs.first?.contains("Tool execution aborted") == true)
        let requests = try String(contentsOf: record, encoding: .utf8)
        XCTAssertEqual(requests.components(separatedBy: "session/cancel").count - 1, 2)
    }

    func testUnresponsiveProviderStopUsesOneBoundedSettlementDrain() async throws {
        let workspace = try makeTemporaryDirectory()
        let part = workspace.appendingPathComponent("native-tool-part.json")
        let provider = try FakeACPProvider(
            providerID: .openCode, commandPath: makeFakeACPServerScript().path,
            environment: ["ACP_CANCEL_PART_PATH": part.path, "ACP_IGNORE_CANCEL": "1"]
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: makeRunRequest(agentKind: .openCode, workspacePath: workspace.path),
            requestTimeouts: .init(bootstrapSeconds: 5, cancellationSettlementSeconds: 0.25),
            allowsProviderProcessLaunchForTesting: true
        )
        _ = try await controller.bootstrap()
        let prompt = Task { try await controller.prompt(AgentMessage(userMessage: "unresponsive fixture")) }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: part.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
        let beforeCancel = Date()
        await controller.cancelPrompt()
        XCTAssertLessThan(Date().timeIntervalSince(beforeCancel), 0.2, "Cancellation alone must not wait on provider settlement")
        let shutdown = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await controller.shutdown()
        }
        await shutdown.value
        _ = try? await prompt.value
        XCTAssertLessThan(Date().timeIntervalSince(beforeCancel), 3, "An unresponsive provider cannot stall teardown indefinitely")
        let waiterCount = await controller.debugPromptSettlementWaiterCount()
        XCTAssertEqual(waiterCount, 0)
    }

    func testProviderExitDuringCancellationDrainReleasesShutdownPromptly() async throws {
        let workspace = try makeTemporaryDirectory()
        let part = workspace.appendingPathComponent("native-tool-part.json")
        let provider = try FakeACPProvider(
            providerID: .openCode, commandPath: makeFakeACPServerScript().path,
            environment: ["ACP_CANCEL_PART_PATH": part.path, "ACP_EXIT_ON_CANCEL": "1"]
        )
        let settlementTimeout: TimeInterval = 30
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: makeRunRequest(agentKind: .openCode, workspacePath: workspace.path),
            requestTimeouts: .init(bootstrapSeconds: 5, cancellationSettlementSeconds: settlementTimeout),
            allowsProviderProcessLaunchForTesting: true
        )
        _ = try await controller.bootstrap()
        let stream = await controller.currentEventsStream()
        let prompt = Task { try await controller.prompt(AgentMessage(userMessage: "exit on cancel fixture")) }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: part.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
        let start = Date()
        await controller.shutdown()
        // The provider dies on session/cancel, so the drain can never settle; shutdown must not
        // wait out the 30s settlement timeout for a process that is already gone.
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        do {
            try await prompt.value
            XCTFail("Provider exit must fail the pending prompt")
        } catch {
            XCTAssertEqual(error.localizedDescription, "ACP transport closed unexpectedly.")
        }
        let waiterCount = await controller.debugPromptSettlementWaiterCount()
        XCTAssertEqual(waiterCount, 0)
        for await event in stream {
            if case .terminal = event { XCTFail("Intentional shutdown must not publish a new run terminal") }
        }
    }

    func testConcurrentShutdownWaitsForInFlightTeardown() async throws {
        let workspace = try makeTemporaryDirectory()
        let part = workspace.appendingPathComponent("native-tool-part.json")
        let pidFile = workspace.appendingPathComponent("provider.pid")
        let record = workspace.appendingPathComponent("requests.jsonl")
        let release = workspace.appendingPathComponent("cancel-release.fifo")
        XCTAssertEqual(mkfifo(release.path, 0o600), 0)
        let releaseFD = open(release.path, O_RDWR | O_NONBLOCK)
        let gate = try FileHandle(fileDescriptor: XCTUnwrap(releaseFD >= 0 ? releaseFD : nil), closeOnDealloc: true)
        defer { gate.closeFile() }
        let provider = try FakeACPProvider(
            providerID: .openCode, commandPath: makeFakeACPServerScript().path,
            environment: [
                "ACP_CANCEL_PART_PATH": part.path, "ACP_PID_PATH": pidFile.path,
                "ACP_RECORD_PATH": record.path, "ACP_CANCEL_RELEASE_PATH": release.path
            ]
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: makeRunRequest(agentKind: .openCode, workspacePath: workspace.path),
            requestTimeouts: .init(bootstrapSeconds: 5, cancellationSettlementSeconds: 30),
            allowsProviderProcessLaunchForTesting: true
        )
        _ = try await controller.bootstrap()
        let stream = await controller.currentEventsStream()
        let prompt = Task { try await controller.prompt(AgentMessage(userMessage: "concurrent shutdown fixture")) }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: part.path), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
        let pid = try XCTUnwrap(pid_t(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), 0, "Provider must be alive before shutdown")

        // The fixture waits at the release gate to settle its cancelled prompt, so shutdown
        // remains draining until both callers have joined.
        let completions = BuildObserver()
        let first = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await controller.shutdown()
            completions.increment()
            return kill(pid, 0)
        }
        let drainDeadline = Date().addingTimeInterval(5)
        var waiterCount = 0
        while Date() < drainDeadline, completions.count == 0 {
            waiterCount = await controller.debugPromptSettlementWaiterCount()
            let requests = (try? String(contentsOf: record, encoding: .utf8)) ?? ""
            if waiterCount == 1, requests.contains("session/cancel") { break }
            await Task.yield()
        }
        XCTAssertEqual(waiterCount, 1)
        let second = Task {
            await controller.shutdown()
            completions.increment()
            return kill(pid, 0)
        }
        let joinDeadline = Date().addingTimeInterval(5)
        var callers = 0
        while Date() < joinDeadline, completions.count == 0 {
            callers = await controller.debugShutdownCallerCount()
            if callers == 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(callers, 2)
        second.cancel()
        XCTAssertEqual(completions.count, 0, "Neither caller may return while provider cleanup is gated")
        let beforeRelease = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: part)) as? [String: Any])
        XCTAssertEqual(beforeRelease["status"] as? String, "running")
        XCTAssertEqual(kill(pid, 0), 0)
        gate.write(Data([1]))

        let firstProbe = await first.value
        let secondProbe = await second.value
        XCTAssertEqual(firstProbe, -1, "The already-cancelled caller must await provider reaping")
        XCTAssertEqual(secondProbe, -1, "The joining caller must await provider reaping")
        XCTAssertEqual(completions.count, 2)
        try await prompt.value
        let probe = kill(pid, 0)
        let probeErrno = errno
        XCTAssertEqual(probe, -1, "Both shutdown callers must await provider reaping")
        XCTAssertEqual(probeErrno, ESRCH)
        let native = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: part)) as? [String: Any])
        XCTAssertEqual(native["status"] as? String, "error")
        XCTAssertNotNil(native["end"] as? Double)
        var terminalOutputs: [String] = []
        for await event in stream {
            if case let .stream(result) = event, let tool = AgentToolStreamEvent.from(result),
               case let .toolResult(result) = tool { terminalOutputs.append(result.resultJSON) }
        }
        XCTAssertEqual(terminalOutputs.count, 1)
        XCTAssertTrue(terminalOutputs.first?.contains("Tool execution aborted") == true)
        waiterCount = await controller.debugPromptSettlementWaiterCount()
        XCTAssertEqual(waiterCount, 0)
        await controller.shutdown()
        let requests = try String(contentsOf: record, encoding: .utf8)
        XCTAssertEqual(requests.components(separatedBy: "session/cancel").count - 1, 1)
    }

    func testProcessWaitFailureDuringCancellationDrainReleasesShutdownPromptly() async throws {
        let workspace = try makeTemporaryDirectory()
        let part = workspace.appendingPathComponent("native-tool-part.json")
        let provider = try FakeACPProvider(
            providerID: .openCode, commandPath: makeFakeACPServerScript().path,
            environment: ["ACP_CANCEL_PART_PATH": part.path, "ACP_IGNORE_CANCEL": "1"]
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: makeRunRequest(agentKind: .openCode, workspacePath: workspace.path),
            requestTimeouts: .init(bootstrapSeconds: 5, cancellationSettlementSeconds: 30),
            allowsProviderProcessLaunchForTesting: true
        )
        _ = try await controller.bootstrap()
        let stream = await controller.currentEventsStream()
        let prompt = Task { try await controller.prompt(AgentMessage(userMessage: "wait failure fixture")) }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: part.path), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
        let shutdown = Task { await controller.shutdown() }
        let drainDeadline = Date().addingTimeInterval(5)
        var waiterCount = 0
        while Date() < drainDeadline {
            waiterCount = await controller.debugPromptSettlementWaiterCount()
            if waiterCount > 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(waiterCount, 1)
        let start = Date()
        let streamFinished = await controller.debugInjectProcessWaitFailure(
            NSError(domain: "ACPProviderSessionIdentityTests", code: 1)
        )
        XCTAssertFalse(streamFinished, "The closing handler must leave event completion to shutdown")
        await shutdown.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        do {
            try await prompt.value
            XCTFail("Wait observer failure must fail the pending prompt")
        } catch {
            XCTAssertEqual(error.localizedDescription, "ACP transport closed unexpectedly.")
        }
        waiterCount = await controller.debugPromptSettlementWaiterCount()
        XCTAssertEqual(waiterCount, 0)
        for await event in stream {
            if case .terminal = event { XCTFail("Intentional shutdown must not publish a new run terminal") }
        }
    }

    func testLateFullAccessNativeShellPermissionDuringShutdownIsCancelled() async throws {
        try await assertLatePermissionIsCancelledDuringShutdown(.fullAccessNativeShell)
    }

    func testLateStrictRepoPromptPermissionDuringShutdownIsCancelled() async throws {
        try await assertLatePermissionIsCancelledDuringShutdown(.strictRepoPrompt)
    }

    /// Negative control for the shutdown fence: the same requests on an open session keep their
    /// automatic one-time grant without surfacing an approval prompt.
    func testOpenSessionPermissionStillAutoApprovesBothPaths() async throws {
        for path in PermissionAutoApprovalPath.allCases {
            let workspace = try makeTemporaryDirectory()
            let reply = workspace.appendingPathComponent("permission-reply.json")
            let provider = try FakeACPProvider(
                providerID: path.providerID, commandPath: makeFakeACPServerScript().path,
                environment: [
                    "ACP_PERMISSION_PHASE": "prompt", "ACP_PERMISSION_TOOL_CALL": path.toolCallJSON,
                    "ACP_PERMISSION_RESPONSE_PATH": reply.path
                ]
            )
            let controller = try ACPAgentSessionController(
                provider: provider,
                runRequest: makeRunRequest(
                    agentKind: path.agentKind, workspacePath: workspace.path,
                    autoApproveAllToolPermissions: path.fullAccess
                ),
                requestTimeouts: .init(bootstrapSeconds: 5, operationalSeconds: 5),
                allowsProviderProcessLaunchForTesting: true
            )
            _ = try await controller.bootstrap()
            let stream = await controller.currentEventsStream()
            // The fixture answers the prompt only after reading the permission reply.
            try await controller.prompt(AgentMessage(userMessage: "open permission fixture"))
            await controller.shutdown()

            let outcome = try permissionReplyOutcome(at: reply)
            XCTAssertEqual(outcome["outcome"] as? String, "selected", "\(path)")
            XCTAssertEqual(outcome["optionId"] as? String, "allow_once", "\(path)")
            var approvalRequests = 0
            for await event in stream {
                if case .approvalRequested = event { approvalRequests += 1 }
            }
            XCTAssertEqual(approvalRequests, 0, "\(path)")
        }
    }

    func testCursorNewSessionPublishesRuntimeIDAsVerifiedLoadID() async throws {
        let workspace = try makeTemporaryDirectory()
        let scriptURL = try makeFakeACPServerScript()
        let request = makeRunRequest(agentKind: .cursor, workspacePath: workspace.path)
        let provider = FakeACPProvider(
            providerID: .cursor,
            commandPath: scriptURL.path,
            environment: ["ACP_RUNTIME_SESSION_ID": "cursor-runtime-id"]
        )
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)
        let stream = await controller.currentEventsStream()

        let bootstrap = try await controller.bootstrap()
        XCTAssertEqual(bootstrap.sessionID, "cursor-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.runtimeSessionID, "cursor-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionID, "cursor-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionIDConfidence, .verified)

        try await controller.prompt(AgentMessage(userMessage: "Hello Cursor"), request: request)
        let messageStop = await firstMessageStop(in: stream)
        await controller.shutdown()

        XCTAssertEqual(messageStop?.providerSessionID, "cursor-runtime-id")
    }

    func testOpenCodeColdResumeUsesPersistedSessionIDForLoad() async throws {
        let workspace = try makeTemporaryDirectory()
        let scriptURL = try makeFakeACPServerScript()
        let recordURL = try makeTemporaryDirectory().appendingPathComponent("record.jsonl")
        let request = makeRunRequest(
            agentKind: .openCode,
            workspacePath: workspace.path,
            resumeSessionID: "persisted-session-id"
        )
        let provider = FakeACPProvider(
            providerID: .openCode,
            commandPath: scriptURL.path,
            environment: ["ACP_RECORD_PATH": recordURL.path]
        )
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)

        let bootstrap = try await controller.bootstrap()
        await controller.shutdown()

        XCTAssertEqual(bootstrap.sessionID, "persisted-session-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.runtimeSessionID, "persisted-session-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionID, "persisted-session-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionIDConfidence, .verified)
        XCTAssertEqual(recordedSessionLoadIDs(at: recordURL), ["persisted-session-id"])
    }

    func testGenericLoadFailureFallbackInvalidatesStaleResumeID() async throws {
        let workspace = try makeTemporaryDirectory()
        let scriptURL = try makeFakeACPServerScript()
        let recordURL = try makeTemporaryDirectory().appendingPathComponent("record.jsonl")
        let request = makeRunRequest(
            agentKind: .cursor,
            workspacePath: workspace.path,
            resumeSessionID: "stale-session-id"
        )
        let provider = FakeACPProvider(
            providerID: .cursor,
            commandPath: scriptURL.path,
            environment: [
                "ACP_RECORD_PATH": recordURL.path,
                "ACP_FAIL_LOAD": "1",
                "ACP_RUNTIME_SESSION_ID": "fresh-runtime-id"
            ]
        )
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request, allowsProviderProcessLaunchForTesting: true)

        let bootstrap = try await controller.bootstrap()
        await controller.shutdown()

        XCTAssertTrue(bootstrap.didFallbackToNewSessionAfterLoadFailure)
        XCTAssertEqual(bootstrap.invalidatedResumeSessionID, "stale-session-id")
        XCTAssertEqual(bootstrap.sessionID, "fresh-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.runtimeSessionID, "fresh-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionID, "fresh-runtime-id")
        XCTAssertEqual(bootstrap.providerSessionIdentity.loadSessionIDConfidence, .verified)
        XCTAssertEqual(recordedSessionLoadIDs(at: recordURL), ["stale-session-id"])
    }

    func testProviderSessionIdentityNormalizesEmptyIDs() {
        let identity = ACPProviderSessionIdentity(
            providerID: .cursor,
            runtimeSessionID: " cursor-runtime-id ",
            loadSessionID: "  ",
            loadSessionIDConfidence: .verified
        )

        XCTAssertEqual(identity.runtimeSessionID, "cursor-runtime-id")
        XCTAssertNil(identity.loadSessionID)
        XCTAssertEqual(identity.loadSessionIDConfidence, .unavailable)
    }

    func testNegotiatedImagesRequireLiteralTrueAndRefusalKeepsTextUsable() async throws {
        for capability in ["{\"image\":true}", "{}", "{\"image\":false}", "{\"image\":null}", "{\"image\":1}", "{\"image\":\"true\"}", "[]", "{\"image\":0}"] {
            let workspace = try makeTemporaryDirectory()
            let record = workspace.appendingPathComponent("requests.jsonl")
            let builds = BuildObserver()
            let provider = try FakeACPProvider(
                providerID: .cursor,
                commandPath: makeFakeACPServerScript().path,
                environment: ["ACP_RECORD_PATH": record.path, "ACP_PROMPT_CAPABILITIES": capability, "ACP_COMMAND": "compact"],
                builds: builds
            )
            let request = makeRunRequest(agentKind: .cursor, workspacePath: workspace.path)
            let controller = try ACPAgentSessionController(provider: provider, runRequest: request, requestTimeouts: .init(bootstrapSeconds: 5, operationalSeconds: 5), allowsProviderProcessLaunchForTesting: true)
            let bootstrap = try await controller.bootstrap()
            let image = AITransientImage(bytes: Data([1, 2, 3]), mediaType: .png, title: nil)
            let supported = capability == "{\"image\":true}"
            do {
                try await controller.prompt(AgentMessage(userMessage: "image", transientImages: [image]))
                XCTAssertTrue(supported)
            } catch {
                XCTAssertFalse(supported)
                guard case AIProviderError.invalidConfiguration = error else { XCTFail("Unexpected error: \(error)")
                    await controller.shutdown()
                    continue
                }
            }
            if !supported {
                let attachmentRequest = ACPRunRequest(
                    agentKind: .cursor,
                    modelString: nil,
                    workspacePath: workspace.path,
                    resumeSessionID: nil,
                    attachments: [AgentImageAttachment(source: .localFile(path: "/nonexistent-must-not-read.png"))],
                    taskLabelKind: nil
                )
                do {
                    try await controller.prompt(AgentMessage(userMessage: "attachment override"), request: attachmentRequest)
                    XCTFail("Effective override attachments must be gated")
                } catch {
                    guard case AIProviderError.invalidConfiguration = error else { XCTFail("Unexpected error: \(error)")
                        await controller.shutdown()
                        continue
                    }
                }
            }
            XCTAssertEqual(builds.count, supported ? 1 : 0)
            let beforeText = recordedPrompts(at: record)
            XCTAssertEqual(beforeText.count, supported ? 1 : 0)
            if supported {
                let blocks = try XCTUnwrap(beforeText.first?["prompt"] as? [[String: Any]])
                XCTAssertEqual(blocks.map { $0["type"] as? String }, ["text", "image"])
                XCTAssertEqual(blocks.last?["data"] as? String, "AQID")
                XCTAssertEqual(blocks.last?["mimeType"] as? String, "image/png")
            }
            try await controller.prompt(AgentMessage(userMessage: "next text"))
            XCTAssertEqual(recordedPrompts(at: record).count, supported ? 2 : 1)
            let deadline = Date().addingTimeInterval(5)
            while !controller.advertisesCommand("compact", inProviderSession: bootstrap.sessionID), Date() < deadline {
                await Task.yield()
            }
            XCTAssertTrue(controller.advertisesCommand("compact", inProviderSession: bootstrap.sessionID))
            let inheritedAttachments = ACPRunRequest(
                agentKind: .cursor,
                modelString: nil,
                workspacePath: workspace.path,
                resumeSessionID: nil,
                attachments: [AgentImageAttachment(source: .localFile(path: "/must-not-read.png"))],
                taskLabelKind: nil
            )
            try await controller.promptAdvertisedCommand("compact", expectedSessionID: bootstrap.sessionID, request: inheritedAttachments)
            let commandBlocks = try XCTUnwrap(recordedPrompts(at: record).last?["prompt"] as? [[String: Any]])
            XCTAssertEqual(commandBlocks.count, 1)
            XCTAssertEqual(commandBlocks.first?["text"] as? String, "/compact")
            XCTAssertEqual(builds.count, supported ? 2 : 1)
            await controller.shutdown()
        }
    }

    func testInheritedAttachmentsRejectBeforeReadingAndTextOverrideRecovers() async throws {
        let workspace = try makeTemporaryDirectory()
        let record = workspace.appendingPathComponent("requests.jsonl")
        let builds = BuildObserver()
        let provider = try FakeACPProvider(
            providerID: .cursor,
            commandPath: makeFakeACPServerScript().path,
            environment: ["ACP_RECORD_PATH": record.path],
            builds: builds
        )
        let request = ACPRunRequest(
            agentKind: .cursor,
            modelString: nil,
            workspacePath: workspace.path,
            resumeSessionID: nil,
            attachments: [AgentImageAttachment(source: .localFile(path: "/nonexistent-must-not-read.png"))],
            taskLabelKind: nil
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: request,
            requestTimeouts: .init(bootstrapSeconds: 5, operationalSeconds: 5),
            allowsProviderProcessLaunchForTesting: true
        )
        _ = try await controller.bootstrap()
        do {
            try await controller.prompt(AgentMessage(userMessage: "inherited attachment"))
            XCTFail("Expected local rejection")
        } catch {
            guard case AIProviderError.invalidConfiguration = error else { XCTFail("Unexpected error: \(error)")
                await controller.shutdown()
                return
            }
        }
        XCTAssertEqual(builds.count, 0)
        XCTAssertTrue(recordedPrompts(at: record).isEmpty)
        try await controller.prompt(
            AgentMessage(userMessage: "text override"),
            request: makeRunRequest(agentKind: .cursor, workspacePath: workspace.path)
        )
        XCTAssertEqual(builds.count, 1)
        XCTAssertEqual(recordedPrompts(at: record).count, 1)
        await controller.shutdown()
    }

    func testRealPromptRPCFailureStillRetiresController() async throws {
        let workspace = try makeTemporaryDirectory()
        let provider = try FakeACPProvider(
            providerID: .cursor,
            commandPath: makeFakeACPServerScript().path,
            environment: ["ACP_FAIL_PROMPT": "1"]
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: makeRunRequest(agentKind: .cursor, workspacePath: workspace.path),
            requestTimeouts: .init(bootstrapSeconds: 5, operationalSeconds: 5),
            allowsProviderProcessLaunchForTesting: true
        )
        _ = try await controller.bootstrap()
        do { try await controller.prompt(AgentMessage(userMessage: "transport failure"))
            XCTFail("Expected RPC failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("real RPC failure"))
        }
        do { try await controller.prompt(AgentMessage(userMessage: "must not reuse"))
            XCTFail("Failed controller must refuse")
        } catch {
            XCTAssertEqual(error.localizedDescription, "ACP controller expected sessionOpen or promptRunning, but was failed.")
        }
        await controller.shutdown()
    }

    private func recordedPrompts(at url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            guard let object = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any],
                  object["method"] as? String == "session/prompt" else { return nil }
            return object["params"] as? [String: Any]
        }
    }

    private func makeRunRequest(
        agentKind: AgentProviderKind,
        workspacePath: String,
        resumeSessionID: String? = nil,
        autoApproveAllToolPermissions: Bool = false
    ) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: agentKind,
            modelString: nil,
            workspacePath: workspacePath,
            resumeSessionID: resumeSessionID,
            attachments: [],
            taskLabelKind: nil,
            autoApproveAllToolPermissions: autoApproveAllToolPermissions
        )
    }

    /// The two automatic grant paths a closing controller must not reach.
    private enum PermissionAutoApprovalPath: CaseIterable {
        /// Cursor full access selecting an allow option for a native shell call.
        case fullAccessNativeShell
        /// Strict RepoPrompt MCP provenance auto-approval without full access.
        case strictRepoPrompt

        var providerID: ACPProviderID {
            self == .fullAccessNativeShell ? .cursor : .openCode
        }

        var agentKind: AgentProviderKind {
            self == .fullAccessNativeShell ? .cursor : .openCode
        }

        var fullAccess: Bool {
            self == .fullAccessNativeShell
        }

        var toolCallJSON: String {
            switch self {
            case .fullAccessNativeShell:
                #"{"toolCallId": "late-shell", "title": "Shell", "kind": "execute", "rawInput": {"command": "touch late-permission"}}"#
            case .strictRepoPrompt:
                #"{"toolCallId": "late-repoprompt", "title": "mcp__RepoPromptCE__read_file", "kind": "other"}"#
            }
        }
    }

    private func permissionReplyOutcome(at url: URL) throws -> [String: Any] {
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil(reply["error"])
        return try XCTUnwrap((reply["result"] as? [String: Any])?["outcome"] as? [String: Any])
    }

    /// The fixture asks for permission only after it receives shutdown's `session/cancel`, and sends
    /// the cancelled prompt's terminal tool update only after reading the client's reply.
    private func assertLatePermissionIsCancelledDuringShutdown(
        _ path: PermissionAutoApprovalPath,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let workspace = try makeTemporaryDirectory()
        let part = workspace.appendingPathComponent("native-tool-part.json")
        let reply = workspace.appendingPathComponent("permission-reply.json")
        let provider = try FakeACPProvider(
            providerID: path.providerID, commandPath: makeFakeACPServerScript().path,
            environment: [
                "ACP_CANCEL_PART_PATH": part.path, "ACP_PERMISSION_PHASE": "cancel",
                "ACP_PERMISSION_TOOL_CALL": path.toolCallJSON, "ACP_PERMISSION_RESPONSE_PATH": reply.path
            ]
        )
        let controller = try ACPAgentSessionController(
            provider: provider,
            runRequest: makeRunRequest(
                agentKind: path.agentKind, workspacePath: workspace.path,
                autoApproveAllToolPermissions: path.fullAccess
            ),
            requestTimeouts: .init(bootstrapSeconds: 5, cancellationSettlementSeconds: 30),
            allowsProviderProcessLaunchForTesting: true
        )
        _ = try await controller.bootstrap()
        let stream = await controller.currentEventsStream()
        let prompt = Task { try await controller.prompt(AgentMessage(userMessage: "late permission fixture")) }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: part.path), Date() < deadline {
            await Task.yield()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path), file: file, line: line)

        let start = Date()
        await controller.shutdown()
        // The provider settles only after the permission reply, so a prompt-and-wait answer would
        // hold teardown until the 30s settlement timeout.
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "Shutdown must complete", file: file, line: line)
        _ = try? await prompt.value
        let waiterCount = await controller.debugPromptSettlementWaiterCount()
        XCTAssertEqual(waiterCount, 0, file: file, line: line)

        let outcome = try permissionReplyOutcome(at: reply)
        XCTAssertEqual(outcome["outcome"] as? String, "cancelled", "\(path)", file: file, line: line)
        XCTAssertNil(outcome["optionId"], "\(path)", file: file, line: line)

        var approvalEvents = 0
        var terminalOutputs: [String] = []
        for await event in stream {
            switch event {
            case .approvalRequested, .approvalCancelled:
                approvalEvents += 1
            case let .stream(result):
                if let tool = AgentToolStreamEvent.from(result), case let .toolResult(result) = tool {
                    terminalOutputs.append(result.resultJSON)
                }
            case .terminal:
                break
            }
        }
        XCTAssertEqual(approvalEvents, 0, "Teardown must not surface approval state", file: file, line: line)
        XCTAssertEqual(terminalOutputs.count, 1, "The terminal update after the reply must still drain", file: file, line: line)
        XCTAssertTrue(terminalOutputs.first?.contains("Tool execution aborted") == true, file: file, line: line)
    }

    private func makeTemporaryDirectory() throws -> URL {
        try makeTestDirectory(name: "ACPProviderSessionIdentityTests")
    }

    private func makeFakeACPServerScript() throws -> URL {
        let directory = try makeTemporaryDirectory()
        let scriptURL = directory.appendingPathComponent("fake_acp_server.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import os
        import sys
        import time

        record_path = os.environ.get("ACP_RECORD_PATH")
        runtime_session_id = os.environ.get("ACP_RUNTIME_SESSION_ID", "runtime-session-id")
        fail_load = os.environ.get("ACP_FAIL_LOAD") == "1"
        load_error_code = int(os.environ.get("ACP_LOAD_ERROR_CODE", "-32602"))
        load_error_message = os.environ.get("ACP_LOAD_ERROR_MESSAGE")

        def record(method, params):
            if not record_path:
                return
            with open(record_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps({"method": method, "params": params}) + "\n")

        def respond(request_id, result=None, error=None):
            payload = {"jsonrpc": "2.0", "id": request_id}
            if error is not None:
                payload["error"] = error
            else:
                payload["result"] = result or {}
            print(json.dumps(payload), flush=True)

        permission_phase = os.environ.get("ACP_PERMISSION_PHASE")

        def request_permission(request_id):
            # Blocks until the client answers, so the fixture's next step is ordered after the reply.
            print(json.dumps({"jsonrpc":"2.0", "id":request_id, "method":"session/request_permission", "params":{"sessionId":runtime_session_id, "toolCall":json.loads(os.environ["ACP_PERMISSION_TOOL_CALL"]), "options":[{"optionId":"allow_once", "kind":"allow_once", "name":"Allow"}, {"optionId":"reject_once", "kind":"reject_once", "name":"Decline"}]}}), flush=True)
            while True:
                raw = sys.stdin.readline()
                if not raw:
                    return
                try:
                    message = json.loads(raw)
                except Exception:
                    continue
                if message.get("id") == request_id and "method" not in message:
                    with open(os.environ["ACP_PERMISSION_RESPONSE_PATH"], "w") as handle:
                        json.dump(message, handle)
                    return

        pending_prompt = None
        part_path = os.environ.get("ACP_CANCEL_PART_PATH")
        pid_path = os.environ.get("ACP_PID_PATH")
        if pid_path:
            with open(pid_path, "w") as handle:
                handle.write(str(os.getpid()))

        for line in sys.stdin:
            try:
                request = json.loads(line)
            except Exception:
                continue
            method = request.get("method")
            params = request.get("params") or {}
            record(method, params)
            if method == "initialize":
                respond(request.get("id"), {"agentCapabilities": {"loadSession": True, "promptCapabilities": json.loads(os.environ.get("ACP_PROMPT_CAPABILITIES", "{}"))}, "authMethods": []})
            elif method == "session/new":
                if os.environ.get("ACP_COMMAND"):
                    print(json.dumps({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":runtime_session_id, "update":{"sessionUpdate":"available_commands_update", "availableCommands":[{"name":os.environ["ACP_COMMAND"], "description":"command"}]}}}), flush=True)
                respond(request.get("id"), {"sessionId": runtime_session_id})
            elif method == "session/load":
                session_id = params.get("sessionId")
                if fail_load:
                    message = load_error_message or ("session not found: " + str(session_id))
                    respond(request.get("id"), error={"code": load_error_code, "message": message})
                else:
                    respond(request.get("id"), {"sessionId": session_id})
            elif method == "session/cancel" and part_path and pending_prompt is not None:
                if os.environ.get("ACP_IGNORE_CANCEL"):
                    continue
                if os.environ.get("ACP_EXIT_ON_CANCEL"):
                    sys.stdout.flush()
                    os._exit(0)
                # Provider owns its durable terminal state; the client must let cleanup finish.
                release_path = os.environ.get("ACP_CANCEL_RELEASE_PATH")
                if permission_phase == "cancel":
                    # A provider may still ask for permission while settling a cancelled prompt.
                    request_permission("late-permission")
                elif release_path:
                    with open(release_path, "rb", buffering=0) as gate:
                        gate.read(1)
                else:
                    time.sleep(0.25)
                terminal = {"status":"error", "end":time.time(), "output":"Tool execution aborted"}
                with open(part_path, "w") as handle:
                    json.dump(terminal, handle)
                print(json.dumps({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":runtime_session_id, "update":{"sessionUpdate":"tool_call_update", "toolCallId":"cancelled-oracle", "status":"failed", "rawOutput":{"error":terminal["output"]}}}}), flush=True)
                respond(pending_prompt, {"stopReason":"cancelled"})
                pending_prompt = None
            elif method == "session/prompt":
                if permission_phase == "prompt":
                    request_permission("open-permission")
                if part_path:
                    pending_prompt = request.get("id")
                    with open(part_path, "w") as handle:
                        json.dump({"status":"running", "start":time.time()}, handle)
                    print(json.dumps({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":runtime_session_id, "update":{"sessionUpdate":"tool_call", "toolCallId":"cancelled-oracle", "title":"ask_oracle", "status":"in_progress", "rawInput":{"message":"fixture"}}}}), flush=True)
                    continue
                if os.environ.get("ACP_FAIL_PROMPT"):
                    respond(request.get("id"), error={"code":-32603, "message":"real RPC failure"})
                    continue
                respond(request.get("id"), {"stopReason": "end_turn", "usage": {"inputTokens": 1, "outputTokens": 2}})
            else:
                respond(request.get("id"), {})
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func firstMessageStop(in stream: AsyncStream<NormalizedAgentRuntimeEvent>) async -> AIStreamResult? {
        for await event in stream {
            switch event {
            case let .stream(result) where result.type == "message_stop":
                return result
            case .terminal:
                return nil
            default:
                continue
            }
        }
        return nil
    }

    private func recordedSessionLoadIDs(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: { $0.isNewline }).compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["method"] as? String == "session/load",
                  let params = object["params"] as? [String: Any]
            else {
                return nil
            }
            return params["sessionId"] as? String
        }
    }
}

private struct FakeACPProvider: ACPAgentProvider {
    let providerID: ACPProviderID
    let commandPath: String
    let environment: [String: String]
    var builds: BuildObserver?

    func support(for request: ACPRunRequest) async -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: commandPath,
            arguments: [],
            environment: environment,
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        let workingDirectory = request.workspacePath ?? FileManager.default.temporaryDirectory.path
        let mode: ACPSessionConfiguration.Mode = if let resume = request.resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !resume.isEmpty {
            .load(existingSessionID: resume)
        } else {
            .new
        }
        return ACPSessionConfiguration(mode: mode, workingDirectory: workingDirectory, mcpServers: [])
    }

    func buildPromptBlocks(
        for message: AgentMessage,
        request: ACPRunRequest
    ) throws -> [[String: Any]] {
        builds?.increment()
        return try ACPPromptContentBuilder.blocks(text: message.userMessage, attachments: request.attachments, transientImages: message.transientImages)
    }

    func normalizeSessionUpdate(
        _ payload: [String: Any],
        sessionID: String
    ) -> [NormalizedAgentRuntimeEvent] {
        environment["ACP_CANCEL_PART_PATH"] == nil ? [] : ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: providerID)
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}

private final class BuildObserver: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    var count: Int {
        value.withLock { $0 }
    }

    func increment() {
        value.withLock { $0 += 1 }
    }
}
