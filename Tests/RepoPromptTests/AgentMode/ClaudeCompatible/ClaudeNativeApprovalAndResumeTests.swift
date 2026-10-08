import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptProviderQuota
import XCTest

final class ClaudeNativeApprovalAndResumeTests: XCTestCase {
    func testCLIUsageConfigurationDoesNotDisableItsOwnStatusLine() throws {
        let data = try ClaudeCLIUsageSource.collectionSettings(collector: "/fixture/collector --private-output")
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(settings["disableAllHooks"], "This flag suppresses the status-line collector too; managed policy must not be overridden with false")
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        XCTAssertTrue(hooks.isEmpty)
        let statusLine = try XCTUnwrap(settings["statusLine"] as? [String: String])
        XCTAssertEqual(statusLine["type"], "command")
        XCTAssertEqual(statusLine["command"], "/fixture/collector --private-output")
    }

    func testCLIUsageSetupIsExplicitAndDoesNotPinDefaultCredentialsOrSendInput() {
        let root = URL(fileURLWithPath: "/fixture/helper's folder")
        let profile = ClaudeUsageCredentialProfile(directory: URL(fileURLWithPath: "/fixture/.claude"), isDefault: true)
        let script = ClaudeCLIUsageSource.setupScript(command: "/fixture/claude", profile: profile, workdir: root, settings: root.appendingPathComponent("settings.json"), mcp: root.appendingPathComponent("mcp.json"))
        XCTAssertTrue(script.contains("helper'\\''s folder"), "shell-quote paths containing apostrophes")
        XCTAssertTrue(script.contains("'-u' 'CLAUDE_CONFIG_DIR'"))
        XCTAssertFalse(script.contains("CLAUDE_CONFIG_DIR="), "default profile must retain Claude's normal Keychain/config identity")
        XCTAssertTrue(script.contains("'--setting-sources' ''"))
        XCTAssertTrue(script.contains("'--tools' ''"))
        XCTAssertTrue(script.contains("'--strict-mcp-config'"))
        XCTAssertFalse(script.contains("--dangerously-skip-permissions"))
        XCTAssertFalse(script.contains("--print"))
        XCTAssertTrue(script.contains("/exit or Ctrl-C twice"))
        XCTAssertTrue(script.contains("Check usage after setup"))
        XCTAssertFalse(script.contains("osascript"))
        let custom = ClaudeUsageCredentialProfile(directory: root, isDefault: false)
        let customScript = ClaudeCLIUsageSource.setupScript(command: "/fixture/claude", profile: custom, workdir: root, settings: root.appendingPathComponent("settings.json"), mcp: root.appendingPathComponent("mcp.json"))
        XCTAssertTrue(customScript.contains("CLAUDE_CONFIG_DIR=/fixture/helper'\\''s folder"))
    }

    func testCLIUsageCommandAdmissionRequiresReadinessAndKeepsDeadlineAndFreshReceipt() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let ready = try XCTUnwrap(ClaudeCLIUsageRecord.extract(Data("{}".utf8), now: date))
        let reading = try XCTUnwrap(ClaudeCLIUsageRecord.extract(Data(#"{"rate_limits":{"five_hour":{"used_percentage":4}}}"#.utf8), now: date.addingTimeInterval(1)))
        var state = ClaudeCLIUsageCollectionState()
        XCTAssertEqual(state.next(record: nil, elapsed: 5, now: date), .wait, "never type into trust/login setup")
        XCTAssertEqual(state.next(record: ready, elapsed: 6, now: date), .usage)
        XCTAssertEqual(state.next(record: ready, elapsed: 7, now: date), .wait, "do not submit /usage twice")
        XCTAssertEqual(state.next(record: ready, elapsed: 15, now: date), .wait, "slow usage fetch is not dismissed at 3 seconds")
        XCTAssertEqual(state.next(record: ready, elapsed: 16, now: date), .escape)
        XCTAssertEqual(state.next(record: ready, elapsed: 17, now: date), .wait, "escape is one-shot")
        XCTAssertEqual(state.next(record: reading, elapsed: 18, now: date), .complete(reading))
        var startup = ClaudeCLIUsageCollectionState()
        XCTAssertEqual(startup.next(record: nil, elapsed: 30, now: date), .failed(.cliUnavailable))
        var empty = ClaudeCLIUsageCollectionState()
        XCTAssertEqual(empty.next(record: ready, elapsed: 0, now: date), .usage)
        XCTAssertEqual(empty.next(record: ready, elapsed: 30, now: date), .failed(.invalidResponse))
        var early = ClaudeCLIUsageCollectionState()
        XCTAssertEqual(early.next(record: ready, elapsed: 0, now: date), .usage)
        XCTAssertEqual(early.next(record: reading, elapsed: 1, now: date), .complete(reading), "accept JSON before Escape if CLI already reported it")
        var stale = ClaudeCLIUsageCollectionState()
        XCTAssertEqual(stale.next(record: reading, elapsed: 0, now: date.addingTimeInterval(2)), .usage)
        XCTAssertEqual(stale.next(record: reading, elapsed: 1, now: date.addingTimeInterval(3)), .wait, "startup retained JSON is not a refreshed reading")
    }

    func testOnlyFirstPartyAgentsHaveAUsageTarget() {
        XCTAssertEqual(ProviderQuotaSettingsTarget(agent: .codexExec), .codex)
        XCTAssertEqual(ProviderQuotaSettingsTarget(agent: .claudeCode), .claude)
        for agent in AgentProviderKind.allCases where agent != .codexExec && agent != .claudeCode {
            XCTAssertNil(ProviderQuotaSettingsTarget(agent: agent), agent.rawValue)
        }
    }

    func testCLIUsageRequiresConsentBeforeCollection() async {
        let profile = ClaudeUsageCredentialProfile(directory: URL(fileURLWithPath: "/fixture/profile"), isDefault: false)
        let source = ClaudeCLIUsageSource(profileProvider: { profile }, collect: { _, _ in
            XCTFail("Collection without consent")
            throw ProviderQuotaReadError.transport
        }, consentProvider: { nil })
        do {
            _ = try await source.read(.init(userInitiated: true))
            XCTFail("Read without consent")
        } catch { XCTAssertEqual(error as? ProviderQuotaReadError, .needsConsent) }
    }

    func testCLIUsageWhitelistsStatisticsAndKeepsPercentUnitsAndUnknownAccount() throws {
        let payload = Data(#"{"session_id":"secret-session","token":"secret-token","rate_limits":{"five_hour":{"used_percentage":1,"resets_at":1900000300},"seven_day":{"used_percentage":23},"unexpected":{"used_percentage":99}}}"#.utf8)
        let record = try XCTUnwrap(ClaudeCLIUsageRecord.extract(payload))
        XCTAssertEqual(record.windows["five_hour"]?.used, 1)
        XCTAssertEqual(record.windows.count, 2)
        let encoded = try JSONEncoder().encode(record)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret"))
        let snapshot = record.snapshot(profileID: "profile")
        XCTAssertFalse(snapshot.accountKey.isIdentified)
        XCTAssertEqual(snapshot.source, .claudeCLIUsage)
        XCTAssertEqual(snapshot.coverage, .accountWideAggregateOnly)
        XCTAssertNil(snapshot.buckets.first?.planType)
    }

    func testCLIUsageRejectsInvalidOrMissingNumbersRatherThanShowingZero() throws {
        for raw in [
            #"{"rate_limits":{"five_hour":{"used_percentage":true}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":-1}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":101}}}"#,
            #"{"rate_limits":{"five_hour":{"resets_at":1900000300}}}"#
        ] {
            XCTAssertTrue(try XCTUnwrap(ClaudeCLIUsageRecord.extract(Data(raw.utf8))).windows.isEmpty)
        }
        XCTAssertNil(ClaudeCLIUsageRecord.extract(Data(repeating: 32, count: 65537)))
        XCTAssertNil(ClaudeCLIUsageRecord.extract(Data("invalid".utf8)))
    }

    func testCLIUsageCacheIsPrivateProfileScopedAndRetainsObservationDate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ClaudeCLIUsageCache(root: root)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let record = try XCTUnwrap(ClaudeCLIUsageRecord.extract(Data(#"{"rate_limits":{"five_hour":{"used_percentage":4}}}"#.utf8), now: date))
        try cache.save(record, profileID: "profile-a")
        XCTAssertEqual(cache.load(profileID: "profile-a")?.receivedAt, date)
        XCTAssertNil(cache.load(profileID: "profile-b"))
        let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("cache.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: root.appendingPathComponent("cache.json").path)
        XCTAssertNil(cache.load(profileID: "profile-a"))
    }

    func testCLIUsageProfileChangeOrCancellationNeverCachesReading() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ClaudeUsageCredentialProfile(directory: URL(fileURLWithPath: "/fixture/profile-a"), isDefault: false)
        let profiles = UsageProfileFixture(profile)
        let record = try XCTUnwrap(ClaudeCLIUsageRecord.extract(Data(#"{"rate_limits":{"five_hour":{"used_percentage":4}}}"#.utf8)))
        let source = ClaudeCLIUsageSource(root: root, profileProvider: { profiles.current() }, collect: { _, _ in
            profiles.replace(.init(directory: URL(fileURLWithPath: "/fixture/profile-b"), isDefault: false))
            return record
        }, consentProvider: { profile.id })
        do { _ = try await source.read(.init(userInitiated: true))
            XCTFail("Adopted changed profile")
        } catch { XCTAssertEqual(error as? ProviderQuotaReadError, .needsConsent) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache.json").path))
        let cancelled = ClaudeCLIUsageSource(root: root, profileProvider: { profile }, collect: { _, _ in throw CancellationError() }, consentProvider: { profile.id })
        do { _ = try await cancelled.read(.init(userInitiated: true))
            XCTFail("Ignored cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cache.json").path))
    }

    func testCLIUsagePersistsAndHydratesWithoutAnotherCollection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ClaudeUsageCredentialProfile(directory: URL(fileURLWithPath: "/fixture/profile"), isDefault: false)
        let record = try XCTUnwrap(ClaudeCLIUsageRecord.extract(Data(#"{"rate_limits":{"five_hour":{"used_percentage":4}}}"#.utf8)))
        let first = ClaudeCLIUsageSource(root: root, profileProvider: { profile }, collect: { _, _ in record }, consentProvider: { profile.id })
        let value = try await first.read(.init(userInitiated: true))
        let restarted = ClaudeCLIUsageSource(root: root, profileProvider: { profile }, collect: { _, _ in XCTFail("Hydration launches CLI")
            return record
        }, consentProvider: { profile.id })
        let cached = await restarted.cachedSnapshot()
        XCTAssertEqual(cached, value)
        await restarted.clearCache()
        let cleared = await restarted.cachedSnapshot()
        XCTAssertNil(cleared)
    }

    func testCLIUsageDisclosureExplainsMethodAndUncertaintyWithoutCredentialAccess() {
        let copy = ProviderUsageSectionConfiguration.claudeConsent.message
        XCTAssertTrue(copy.contains("/usage"))
        XCTAssertTrue(copy.contains("does not read login tokens"))
        XCTAssertTrue(copy.contains("One-time setup opens Claude Code in Terminal"))
        XCTAssertTrue(copy.contains("Check usage after setup"))
        XCTAssertTrue(ProviderUsageSectionConfiguration.claudeConsent.confirmTitle.contains("open setup"))
        XCTAssertTrue(copy.contains("has not explicitly approved automated usage monitoring"))
        XCTAssertFalse(copy.lowercased().contains("ban"))
    }

    private final class UsageProfileFixture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ClaudeUsageCredentialProfile
        init(_ value: ClaudeUsageCredentialProfile) {
            self.value = value
        }

        func current() -> ClaudeUsageCredentialProfile {
            lock.withLock { value }
        }

        func replace(_ value: ClaudeUsageCredentialProfile) {
            lock.withLock { self.value = value }
        }
    }

    func testNativeControllerPreservesAllowedTelemetryOutsideTranscript() async {
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(), tabID: UUID(), windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false")
        )
        await controller.ensureEventsStreamReady()
        let stream = await controller.events
        let wire = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour","resetsAt":1900000300}}"# + "\n"
        await controller.test_handleConfigurationStdoutChunk(Data(wire.utf8))
        await controller.shutdown()
        var received: [ClaudeCompatiblePluginRateLimitInfo] = []
        for await event in stream {
            switch event {
            case let .rateLimit(info): received.append(info)
            case .stream: XCTFail("Routine allowed telemetry must not clutter the transcript")
            default: break
            }
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.status, .allowed)
        XCTAssertNil(received.first?.utilization)
        if let info = received.first {
            let observation = ClaudeCompatibleProviderRuntimeBridge.quotaObservation(from: info)
            XCTAssertEqual(observation.status, .allowed)
            XCTAssertEqual(observation.resetsAt, 1_900_000_300)
            XCTAssertNil(observation.utilization)
        }
    }

    enum ResolverError: Error {
        case unsupportedModel
    }

    actor RecordingLaunchEnvironmentResolver: ClaudeCodeLaunchEnvironmentResolving {
        private(set) var requestedModels: [String?] = []

        func resolve(
            variant _: ClaudeCodeRuntimeVariant,
            requestedModel: String?
        ) async throws -> ClaudeCodeLaunchEnvironment {
            requestedModels.append(requestedModel)
            guard requestedModel != "glm-5-turbo:xhigh" else {
                throw ResolverError.unsupportedModel
            }
            return ClaudeCodeLaunchEnvironment(
                effectiveModel: "sonnet",
                environmentOverrides: [:],
                backend: .compatible(.glmZAI)
            )
        }
    }

    func testNativeFlagResolutionPassesEncodedGLMModelToResolver() async throws {
        let resolver = RecordingLaunchEnvironmentResolver()
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(
                commandName: "/usr/bin/false",
                runtimeVariant: .glm
            ),
            environmentResolver: resolver
        )

        do {
            _ = try await controller.test_resolveApplyFlagSettingsRequest(model: "glm-5-turbo:xhigh")
            XCTFail("Expected encoded unsupported GLM XHigh model to be rejected by the resolver")
        } catch ResolverError.unsupportedModel {
            // Expected.
        }

        let requestedModels = await resolver.requestedModels
        XCTAssertEqual(requestedModels, ["glm-5-turbo:xhigh"])
    }

    func testNativeLiveModelSwitchRequiresRestartWhenLaunchEnvironmentChanges() async {
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(
                commandName: "/usr/bin/false",
                runtimeVariant: .glm
            )
        )
        let directGLM = ClaudeCodeLaunchEnvironment(
            effectiveModel: "sonnet",
            environmentOverrides: [
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5-turbo",
                "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5-turbo"
            ],
            backend: .compatible(.glmZAI),
            suppressesEffortSettings: true
        )
        let slotGLM = ClaudeCodeLaunchEnvironment(
            effectiveModel: "sonnet",
            environmentOverrides: [
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-4.7",
                "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-4.7"
            ],
            backend: .compatible(.glmZAI),
            suppressesEffortSettings: true
        )
        let sameEnvironmentDifferentFlagModel = ClaudeCodeLaunchEnvironment(
            effectiveModel: "opus",
            environmentOverrides: directGLM.environmentOverrides,
            backend: .compatible(.glmZAI),
            suppressesEffortSettings: true
        )

        let directToSlotRequiresRestart = await controller.test_liveFlagSettingsRequiresProcessRestart(
            activeLaunchEnvironment: directGLM,
            nextLaunchEnvironment: slotGLM
        )
        let sameEnvironmentRequiresRestart = await controller.test_liveFlagSettingsRequiresProcessRestart(
            activeLaunchEnvironment: directGLM,
            nextLaunchEnvironment: sameEnvironmentDifferentFlagModel
        )

        XCTAssertTrue(directToSlotRequiresRestart)
        XCTAssertFalse(sameEnvironmentRequiresRestart)
    }

    private actor ApplicationGate {
        private let fence = TestReleaseFence(name: "native configuration application")
        private var hold = true

        func waitUntilEntered() async throws {
            guard await fence.waitUntilEntered(timeout: 3) else {
                fence.release()
                throw CancellationError()
            }
        }

        func respond() async -> [String: Any] {
            if hold {
                hold = false
                await fence.enterAndWait()
            }
            return [:]
        }

        nonisolated func resume() {
            fence.release()
        }
    }

    private final class WrittenLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [Data] = []
        func append(_ line: Data) {
            lock.lock()
            defer { lock.unlock() }
            lines.append(line)
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return lines.count
        }

        func line(at index: Int) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return lines.indices.contains(index) ? lines[index] : nil
        }
    }

    private actor PassthroughResolver: ClaudeCodeLaunchEnvironmentResolving {
        func resolve(variant _: ClaudeCodeRuntimeVariant, requestedModel: String?) async throws -> ClaudeCodeLaunchEnvironment {
            ClaudeCodeLaunchEnvironment(effectiveModel: requestedModel, environmentOverrides: [:], backend: .defaultClaude)
        }
    }

    private func applicationController() -> ClaudeNativeProcessSessionController {
        ClaudeNativeProcessSessionController(
            runID: UUID(), tabID: UUID(), windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            environmentResolver: PassthroughResolver()
        )
    }

    func testApplicationProofRequiresReadyTransportIncludingNilSettings() async throws {
        let controller = applicationController()
        let absent = try await controller.applyModelAndEffortWithProof(model: nil, effortLevel: nil)
        XCTAssertEqual(absent, .notReady)
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(initialized: true, write: { writes.append($0) })
        let ready = try await controller.applyModelAndEffortWithProof(model: nil, effortLevel: nil)
        guard case let .applied(proof) = ready else { return XCTFail("Ready no-override policy must be proven") }
        _ = try await controller.sendUserMessage("ordinary", configuration: proof)
        XCTAssertEqual(writes.count, 1)
    }

    func testUnchangedConfigurationReusesProofWithoutProviderIO() async throws {
        let controller = applicationController()
        let controls = WrittenLines()
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(initialized: true, controlRequest: { _ in
            controls.append(Data())
            return [:]
        }, write: { writes.append($0) })
        let first = try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high)
        let repeated = try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high)
        XCTAssertEqual(repeated, first, "Unchanged desired configuration must reuse its current proof")
        XCTAssertEqual(controls.count, 1, "No provider round trip for an unchanged ordinary turn")
        _ = try await controller.applyModelAndEffortWithProof(model: "B", effortLevel: .high)
        _ = try await controller.applyModelAndEffortWithProof(model: "B", effortLevel: .low)
        XCTAssertEqual(controls.count, 3, "Changed model and Auto effort each require application")
        XCTAssertEqual(writes.count, 0)
    }

    @MainActor
    func testFirstOrdinarySendWaitsForColdInitializationAndReusesLaunchProof() async throws {
        let controller = applicationController()
        let gate = ApplicationGate()
        let controls = WrittenLines()
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(initialized: false, controlRequest: { request in
            if request["subtype"] as? String == "initialize" { return await gate.respond() }
            if request["subtype"] as? String == "apply_flag_settings" { controls.append(Data()) }
            return [:]
        }, write: { writes.append($0) })
        let (coordinator, session, intent) = ordinaryTurnFixture(controller: controller)
        let send = Task {
            await coordinator.sendClaudeNativeMessage(
                session: session, text: "first ordinary turn", attachments: [], intent: intent,
                allowsCatalogRouteControllerRecovery: false
            )
        }
        defer { send.cancel()
            gate.resume()
        }
        // The ordinary send has entered production startOrResume, but initialize is still pending.
        try await gate.waitUntilEntered()
        XCTAssertEqual(writes.count, 0)
        XCTAssertEqual(controls.count, 0)
        gate.resume()
        let outcome = await send.value
        XCTAssertEqual(outcome, .sent, "The first turn must deliver without retry after initialization")
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(controls.count, 1, "Reuse launch-time application; do not add a live-update round trip")
    }

    func testApplicationACKSupersessionCannotReleasePromptEvenForSameValueOrABA() async throws {
        for interveningModels in [["A"], ["B", "A"]] {
            let controller = applicationController()
            let gate = ApplicationGate()
            let writes = WrittenLines()
            await controller.test_installConfigurationTransport(
                initialized: true, controlRequest: { _ in await gate.respond() }, write: { writes.append($0) }
            )
            let first = Task { try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high) }
            defer { first.cancel()
                gate.resume()
            }
            try await gate.waitUntilEntered()
            var latest: NativeAgentRuntimeConfigurationApplication = .notReady
            for model in interveningModels {
                latest = try await controller.applyModelAndEffortWithProof(model: model, effortLevel: .high)
            }
            gate.resume()
            let superseded = try await first.value
            XCTAssertEqual(superseded, .appliedButSuperseded)
            XCTAssertEqual(writes.count, 0)
            guard case let .applied(proof) = latest else { return XCTFail("Latest application must be current") }
            do {
                _ = try await controller.sendUserMessage("tainted", configuration: proof)
                XCTFail("A landed stale write must invalidate even the newer proof")
            } catch NativeAgentRuntimeControllerError.configurationNotCurrent {}
            XCTAssertEqual(writes.count, 0)
            guard case let .applied(restored) = try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high)
            else { return XCTFail("The next turn must re-establish its configuration") }
            _ = try await controller.sendUserMessage("current", configuration: restored)
            XCTAssertEqual(writes.count, 1)
        }
    }

    func testPhysicalWriteRejectsProofAfterChangedIntentAndProcessReplacement() async throws {
        let controller = applicationController()
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(initialized: true, write: { writes.append($0) })
        guard case let .applied(first) = try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high)
        else { return XCTFail("Missing initial proof") }
        guard case let .applied(second) = try await controller.applyModelAndEffortWithProof(model: "B", effortLevel: .high)
        else { return XCTFail("Missing replacement proof") }
        do {
            _ = try await controller.sendUserMessage("stale", configuration: first)
            XCTFail("Changed configuration must invalidate an older proof")
        } catch NativeAgentRuntimeControllerError.configurationNotCurrent {}
        await controller.test_installConfigurationTransport(initialized: true, write: { writes.append($0) })
        _ = try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high)
        _ = try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high)
        do {
            _ = try await controller.sendUserMessage("old process", configuration: second)
            XCTFail("A prior transport proof must not survive generation reset")
        } catch NativeAgentRuntimeControllerError.configurationNotCurrent {}
        XCTAssertEqual(writes.count, 0)
    }

    private actor GatedResolver: ClaudeCodeLaunchEnvironmentResolving {
        let gate: ApplicationGate
        let rejectFirst: Bool
        private var calls = 0
        init(gate: ApplicationGate, rejectFirst: Bool = false) {
            self.gate = gate
            self.rejectFirst = rejectFirst
        }

        func resolve(variant _: ClaudeCodeRuntimeVariant, requestedModel: String?) async throws -> ClaudeCodeLaunchEnvironment {
            calls += 1
            let reject = rejectFirst && calls == 1
            _ = await gate.respond()
            if reject { throw ResolverError.unsupportedModel }
            return ClaudeCodeLaunchEnvironment(effectiveModel: requestedModel, environmentOverrides: [:], backend: .defaultClaude)
        }
    }

    func testSupersessionDuringResolutionNeverWritesStaleSettings() async throws {
        let gate = ApplicationGate()
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(), tabID: UUID(), windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            environmentResolver: GatedResolver(gate: gate)
        )
        let writes = WrittenLines()
        let controls = WrittenLines()
        await controller.test_installConfigurationTransport(
            initialized: true,
            controlRequest: { _ in controls.append(Data())
                return [:]
            },
            write: { writes.append($0) }
        )
        let first = Task { try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high) }
        defer { first.cancel()
            gate.resume()
        }
        try await gate.waitUntilEntered()
        _ = try await controller.applyModelAndEffortWithProof(model: "B", effortLevel: .high)
        let latest = try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high)
        gate.resume()
        let stale = try await first.value
        XCTAssertEqual(stale, .superseded)
        XCTAssertEqual(controls.count, 2, "The delayed A intent must not write settings after B→A")
        XCTAssertEqual(writes.count, 0)
        guard case let .applied(proof) = latest else { return XCTFail("Missing latest proof") }
        _ = try await controller.sendUserMessage("current", configuration: proof)
        XCTAssertEqual(writes.count, 1)
    }

    func testSupersededResolutionErrorReturnsSuperseded() async throws {
        let gate = ApplicationGate()
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(), tabID: UUID(), windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false", runtimeVariant: .standard),
            environmentResolver: GatedResolver(gate: gate, rejectFirst: true)
        )
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(initialized: true, write: { writes.append($0) })
        let first = Task { try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .low) }
        defer { first.cancel()
            gate.resume()
        }
        try await gate.waitUntilEntered()
        _ = try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .low)
        gate.resume()
        let result = try await first.value
        XCTAssertEqual(result, .superseded, "Resolution failures must be generation-fenced too")
        XCTAssertEqual(writes.count, 0)
    }

    func testRejectedApplicationInvalidatesEarlierProofWithoutChangingSessionIdentity() async throws {
        let controller = applicationController()
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(initialized: true, write: { writes.append($0) })
        guard case let .applied(proof) = try await controller.applyModelAndEffortWithProof(model: "A", effortLevel: .high)
        else { return XCTFail("Missing proof") }
        await controller.test_setConfigurationControlRequest { _ in throw ResolverError.unsupportedModel }
        do {
            _ = try await controller.applyModelAndEffortWithProof(model: "B", effortLevel: .high)
            XCTFail("Expected rejection")
        } catch let failure as NativeAgentRuntimeConfigurationFailure {
            guard case ResolverError.unsupportedModel = failure.underlyingError else {
                return XCTFail("Unexpected underlying application error: \(failure.underlyingError)")
            }
        }
        do {
            try await controller.applyModelAndEffort(model: "B", effortLevel: .high)
            XCTFail("Legacy updates must still expose their original error")
        } catch ResolverError.unsupportedModel {}
        do {
            _ = try await controller.sendUserMessage("stale after rejection", configuration: proof)
            XCTFail("Rejected intent still invalidates prior application")
        } catch NativeAgentRuntimeControllerError.configurationNotCurrent {}
        let identity = await controller.currentSessionRef()
        XCTAssertEqual(identity.sessionID, "application-proof-session")
        XCTAssertEqual(writes.count, 0)
    }

    @MainActor
    private func ordinaryTurnFixture(
        controller: ClaudeNativeProcessSessionController,
        replacement: ClaudeNativeProcessSessionController? = nil
    ) -> (ClaudeAgentModeCoordinator, AgentTabSession, ClaudeAgentModeCoordinator.NativeSessionIntent) {
        var creations = 0
        let coordinator = ClaudeAgentModeCoordinator(
            windowID: 1,
            workspacePathProvider: { _ in nil },
            claudeControllerFactory: { _, _, _, _ in
                creations += 1
                return creations == 1 ? controller : (replacement ?? controller)
            },
            autoEffortEnabledProvider: { true }
        )
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = "claude-opus-5-5:high"
        session.hasLoadedPersistedState = true
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        let runID = UUID()
        session.installRunID(runID)
        session.runState = .running
        let ownership = session.beginRunAttempt(source: "test.native-application-proof")
        return (coordinator, session, .runAttempt(ownership: ownership, runID: runID))
    }

    @MainActor
    func testOrdinarySendWaitsForModelAndEffortACKAndRejectsChangedModelWithSameEffort() async throws {
        for changeModel in [false, true] {
            let controller = applicationController()
            let gate = ApplicationGate()
            let writes = WrittenLines()
            await controller.test_installConfigurationTransport(
                initialized: true, controlRequest: { _ in await gate.respond() }, write: { writes.append($0) }
            )
            let (coordinator, session, intent) = ordinaryTurnFixture(controller: controller)
            let send = Task {
                await coordinator.sendClaudeNativeMessage(
                    session: session, text: "ordinary", attachments: [], intent: intent,
                    allowsCatalogRouteControllerRecovery: false
                )
            }
            defer { send.cancel()
                gate.resume()
            }
            try await gate.waitUntilEntered()
            XCTAssertEqual(writes.count, 0, "An ordinary turn must await application even without Auto")
            if changeModel { session.selectedModelRaw = "claude-sonnet-4-6:high" }
            gate.resume()
            let outcome = await send.value
            XCTAssertEqual(outcome, changeModel ? .superseded : .sent)
            XCTAssertEqual(writes.count, changeModel ? 0 : 1)
            XCTAssertEqual(session.providerSessionID, "application-proof-session")
            XCTAssertTrue(session.claudeController === controller)
        }
    }

    @MainActor
    func testOrdinarySendRejectsSameValueSupersessionDuringACK() async throws {
        let controller = applicationController()
        let gate = ApplicationGate()
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(
            initialized: true, controlRequest: { _ in await gate.respond() }, write: { writes.append($0) }
        )
        let (coordinator, session, intent) = ordinaryTurnFixture(controller: controller)
        let send = Task {
            await coordinator.sendClaudeNativeMessage(
                session: session, text: "ordinary", attachments: [], intent: intent,
                allowsCatalogRouteControllerRecovery: false
            )
        }
        defer { send.cancel()
            gate.resume()
        }
        try await gate.waitUntilEntered()
        _ = try await controller.applyModelAndEffortWithProof(model: session.selectedModelRaw, effortLevel: .high)
        gate.resume()
        let outcome = await send.value
        guard case .failed = outcome else { return XCTFail("Superseded application cannot release the prompt") }
        XCTAssertEqual(writes.count, 0)
        XCTAssertEqual(session.providerSessionID, "application-proof-session")
    }

    @MainActor
    func testOrdinaryApplicationFailurePreservesIdentityAndDoesNotPrompt() async {
        for failure in [NativeAgentRuntimeControllerError.invalidControlResponse("rejected")] {
            let controller = applicationController()
            let writes = WrittenLines()
            await controller.test_installConfigurationTransport(
                initialized: true, controlRequest: { _ in throw failure }, write: { writes.append($0) }
            )
            let (coordinator, session, intent) = ordinaryTurnFixture(controller: controller)
            let outcome = await coordinator.sendClaudeNativeMessage(
                session: session, text: "ordinary", attachments: [], intent: intent,
                allowsCatalogRouteControllerRecovery: false
            )
            guard case .failed = outcome else { return XCTFail("Expected pre-prompt failure, got \(outcome)") }
            XCTAssertEqual(writes.count, 0)
            XCTAssertEqual(session.providerSessionID, "application-proof-session")
            XCTAssertTrue(session.claudeController === controller)
        }
    }

    @MainActor
    func testComposerModelSwitchRequiringRestartDeliversWithoutRetry() async {
        let controller = applicationController()
        let replacement = applicationController()
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(initialized: true, controlRequest: { _ in
            throw NativeAgentRuntimeControllerError.liveModelSwitchRequiresRestart
        }, write: { writes.append($0) })
        await replacement.test_installConfigurationTransport(initialized: true, write: { writes.append($0) })
        let (coordinator, session, intent) = ordinaryTurnFixture(controller: controller, replacement: replacement)
        let ready = await coordinator.ensureClaudeNativeSession(session: session, intent: intent)
        XCTAssertEqual(ready, .ready)
        session.selectedModelRaw = "claude-sonnet-4-6:high"
        let outcome = await coordinator.sendClaudeNativeMessage(
            session: session, text: "ordinary after model switch", attachments: [], intent: intent,
            allowsCatalogRouteControllerRecovery: false
        )
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(session.claudeController === replacement)
        XCTAssertEqual(session.providerSessionID, "application-proof-session")
    }

    private actor EffortRequests {
        private(set) var models: [String?] = []
        private(set) var efforts: [String?] = []
        func respond(_ request: [String: Any]) throws -> [String: Any] {
            let settings = request["settings"] as? [String: Any]
            models.append(settings?["model"] as? String)
            efforts.append(settings?["effortLevel"] as? String)
            if efforts.count == 1 { throw ResolverError.unsupportedModel }
            return [:]
        }
    }

    @MainActor
    func testOptionalAutoFailureReestablishesSameModelManualProofBeforePrompt() async {
        let controller = applicationController()
        let requests = EffortRequests()
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(
            initialized: true, controlRequest: { try await requests.respond($0) }, write: { writes.append($0) }
        )
        let (coordinator, session, intent) = ordinaryTurnFixture(controller: controller)
        let outcome = await coordinator.sendClaudeNativeMessage(
            session: session, text: "ordinary", attachments: [], intent: intent,
            allowsCatalogRouteControllerRecovery: false,
            autoEffortSelection: .init(
                provider: .claudeCode, selectedModelRaw: session.selectedModelRaw,
                manualEffortRaw: "high", effortRaw: "low"
            )
        )
        XCTAssertEqual(outcome, .sent)
        let models = await requests.models
        let efforts = await requests.efforts
        XCTAssertEqual(models, ["claude-opus-5-5:high", "claude-opus-5-5:high"])
        XCTAssertEqual(efforts, ["low", "high"])
        XCTAssertEqual(writes.count, 1)
        XCTAssertFalse(session.isMCPOriginated)
        XCTAssertEqual(session.providerSessionID, "application-proof-session")
    }

    @MainActor
    func testParkedNoteProofRefusalIsUnattemptedAndRetryableButWriteFailureIsUnknown() async throws {
        // Only the typed entry refusal is definitely unsent; a writer's CancellationError is not.
        for (invalidateProof, cancelBeforeWrite, writerThrowsCancellation) in [
            (true, false, false), (false, true, false), (false, false, false), (false, false, true)
        ] {
            let isPreWriteRefusal = invalidateProof || cancelBeforeWrite
            let controller = applicationController()
            let gate = ApplicationGate()
            let writes = WrittenLines()
            await controller.test_installConfigurationTransport(initialized: true, write: {
                writes.append($0)
                if writerThrowsCancellation { throw CancellationError() }
                if !isPreWriteRefusal { throw NativeAgentRuntimeControllerError.inputWriteFailed("uncertain write") }
            })
            await controller.test_setBeforeConfigurationSend { _ = await gate.respond() }
            let (coordinator, session, intent) = ordinaryTurnFixture(controller: controller)
            var notAttempted = 0
            var failed = 0
            var accepted = 0
            coordinator.installHostCapabilities(.init(
                isSessionCurrent: { $0 === session }, requestUIRefresh: { _, _ in }, scheduleSave: { _ in },
                stageClaudeResumeRecoveryHandoff: { _ in }, prependPendingHandoff: { text, _ in text },
                decorateAgentSessionLinkPrompt: { text, _, _ in .init(text: text, claim: nil, mustAbortDispatch: false) },
                acquireAgentSessionLinkPhysicalDispatch: { _, _ in true },
                recordAgentSessionLinkPhysicalDispatchNotAttempted: { _, _ in notAttempted += 1 },
                recordAgentSessionLinkPhysicalDispatchFailure: { _, _ in failed += 1 },
                acceptAgentSessionLinkPromptClaim: { _, _, _ in accepted += 1 }
            ), providerBindingService: AgentModeProviderBindingService())
            var state = session.selfCompactState
            guard case let .scheduled(noteAttempt) = state.reserve(note: "keep this exact note", idempotencyKey: "proof-race")
            else { return XCTFail("Expected parked note reservation") }
            let noteID = noteAttempt.id
            state.active?.phase = .parked
            state.active?.compactTurnSucceeded = true
            session.selfCompactState = state
            let auditID = UUID()
            session.pendingTurnRuntimeAnchors.append(.init(userItemID: auditID, userSequenceIndex: 0, startedAt: Date()))
            let disabled = AgentAutomationTurnAudit.Feature(configured: false, eligible: false, judgmentRequested: false, decision: .disabled)
            session.appendAutomationAudit(.init(turnID: auditID, createdAt: Date(), router: disabled, autoEffort: disabled))
            let send = Task {
                await coordinator.sendClaudeNativeMessage(
                    session: session, text: "ordinary", attachments: [], intent: intent,
                    allowsCatalogRouteControllerRecovery: false
                )
            }
            defer { send.cancel()
                gate.resume()
            }
            try await gate.waitUntilEntered()
            XCTAssertEqual(session.selfCompactState.active?.noteDispatchStarted, true)
            XCTAssertEqual(writes.count, 0)
            if invalidateProof {
                _ = try await controller.applyModelAndEffortWithProof(model: "claude-sonnet-4-6:high", effortLevel: .high)
            }
            if cancelBeforeWrite { send.cancel() }
            gate.resume()
            let outcome = await send.value
            guard case .failed = outcome else { return XCTFail("Expected send refusal/failure") }
            XCTAssertEqual(accepted, 0)
            XCTAssertEqual(notAttempted, isPreWriteRefusal ? 1 : 0)
            XCTAssertEqual(failed, isPreWriteRefusal ? 0 : 1)
            XCTAssertEqual(writes.count, isPreWriteRefusal ? 0 : 1)
            XCTAssertEqual(session.automationTurnAudit.last?.providerDispatchAttempted, !isPreWriteRefusal)
            XCTAssertEqual(session.automationTurnAudit.last?.providerTurnAccepted, false)
            if isPreWriteRefusal {
                XCTAssertEqual(session.selfCompactState.parkedNote?.dispatchID.requestID, noteID)
                XCTAssertEqual(session.selfCompactState.active?.noteDispatchStarted, false)
                XCTAssertEqual(session.selfCompactState.active?.note, "keep this exact note")
                XCTAssertNil(session.selfCompactState.latest)
                let retry = await coordinator.sendClaudeNativeMessage(
                    session: session, text: "retry", attachments: [], intent: intent,
                    allowsCatalogRouteControllerRecovery: false
                )
                XCTAssertEqual(retry, .sent)
                XCTAssertEqual(writes.count, 1)
                XCTAssertEqual(accepted, 1)
                XCTAssertEqual(session.selfCompactState.latest?.requestID, noteID)
                XCTAssertEqual(session.selfCompactState.latest?.noteDelivery, .prepended)
            } else {
                XCTAssertNil(session.selfCompactState.parkedNote)
                XCTAssertEqual(session.selfCompactState.latest?.outcome, .deliveryUnknown)
                XCTAssertEqual(session.selfCompactState.latest?.recoveryNote, "keep this exact note")
            }
        }
    }

    @MainActor
    func testSupersededAutoErrorDoesNotFallbackForIdenticalOrABAConfiguration() async throws {
        for interveningModels in [["claude-opus-5-5:high"], ["claude-sonnet-4-6:high", "claude-opus-5-5:high"]] {
            let controller = applicationController()
            let gate = ApplicationGate()
            let controls = WrittenLines()
            let writes = WrittenLines()
            await controller.test_installConfigurationTransport(initialized: true, controlRequest: { request in
                controls.append(Data())
                if (request["settings"] as? [String: Any])?["effortLevel"] as? String == "low" {
                    _ = await gate.respond()
                    throw NativeAgentRuntimeControllerError.invalidControlResponse("late Auto rejection")
                }
                return [:]
            }, write: { writes.append($0) })
            let (coordinator, session, intent) = ordinaryTurnFixture(controller: controller)
            let send = Task {
                await coordinator.sendClaudeNativeMessage(
                    session: session, text: "ordinary", attachments: [], intent: intent,
                    allowsCatalogRouteControllerRecovery: false,
                    autoEffortSelection: .init(
                        provider: .claudeCode,
                        selectedModelRaw: session.selectedModelRaw,
                        manualEffortRaw: "high",
                        effortRaw: "low"
                    )
                )
            }
            defer { send.cancel()
                gate.resume()
            }
            try await gate.waitUntilEntered()
            for model in interveningModels {
                _ = try await controller.applyModelAndEffortWithProof(model: model, effortLevel: .high)
            }
            gate.resume()
            let outcome = await send.value
            guard case .failed = outcome else { return XCTFail("Stale Auto error must refuse, not fall back and send") }
            XCTAssertEqual(controls.count, 1 + interveningModels.count, "No manual fallback from a superseded application")
            XCTAssertEqual(writes.count, 0)
            XCTAssertEqual(session.providerSessionID, "application-proof-session")
        }
    }

    @MainActor
    func testLaunchSettingsChangeDuringApplicationRelaunchesAndDelivers() async throws {
        let controller = applicationController()
        let gate = ApplicationGate()
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(
            initialized: true, controlRequest: { _ in await gate.respond() }, write: { writes.append($0) }
        )
        let replacement = applicationController()
        await replacement.test_installConfigurationTransport(initialized: true, write: { writes.append($0) })
        let (coordinator, session, intent) = ordinaryTurnFixture(controller: controller, replacement: replacement)
        let send = Task {
            await coordinator.sendClaudeNativeMessage(
                session: session, text: "ordinary", attachments: [], intent: intent,
                allowsCatalogRouteControllerRecovery: false
            )
        }
        defer {
            send.cancel()
            gate.resume()
        }
        try await gate.waitUntilEntered()
        let launch = try XCTUnwrap(coordinator.test_controllerLaunchSettings(for: session))
        coordinator.test_setControllerLaunchSettings(.init(
            runtimeVariant: launch.runtimeVariant, workspacePath: "/changed-during-application",
            permissionMode: launch.permissionMode, allowNativeBashTool: launch.allowNativeBashTool,
            mcpStrictMode: launch.mcpStrictMode
        ), for: session)
        gate.resume()
        let outcome = await send.value
        XCTAssertEqual(outcome, .sent, "A launch mismatch must relaunch and deliver without a user retry")
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(session.claudeController === replacement)
        XCTAssertEqual(session.providerSessionID, "application-proof-session")
    }

    @MainActor
    func testProductionFactoryAdapterAndControlResponseGateConfigurationProof() async throws {
        let runtime = ClaudeAgentModeCoordinator.test_makeDefaultController(
            runID: UUID(), tabID: UUID(), windowID: 1,
            launchSettings: .init(
                runtimeVariant: .standard, workspacePath: nil, permissionMode: nil,
                allowNativeBashTool: nil, mcpStrictMode: nil
            )
        )
        let adapter = try XCTUnwrap(runtime as? ClaudeCompatibleNativeSessionAdapter)
        let underlying = await adapter.test_processController()
        let controller = try XCTUnwrap(underlying, "The production factory must wrap the proof-capable process controller")
        addTeardownBlock { await runtime.shutdown() }
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(initialized: true, controlRequest: nil, write: { writes.append($0) })
        for (index, reject) in [true, false].enumerated() {
            let application = Task {
                try await runtime.applyModelAndEffortWithProof(model: "claude-opus-5-5:high", effortLevel: .low)
            }
            defer { application.cancel() }
            try await AsyncTestWait.waitUntil("configuration request \(index) on production adapter wire") {
                writes.count > index
            }
            let frame = try XCTUnwrap(writes.line(at: index))
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
            XCTAssertEqual(request["type"] as? String, "control_request")
            let body = try XCTUnwrap(request["request"] as? [String: Any])
            XCTAssertEqual(body["subtype"] as? String, "apply_flag_settings")
            let settings = try XCTUnwrap(body["settings"] as? [String: Any])
            XCTAssertEqual(settings["model"] as? String, "claude-opus-5-5")
            XCTAssertEqual(settings["effortLevel"] as? String, "low")
            let requestID = try XCTUnwrap(request["request_id"] as? String)
            let response = try (
                reject
                    ? ClaudeSDKProtocolCodec.encodeControlResponseError(requestID: requestID, error: "rejected")
                    : ClaudeSDKProtocolCodec.encodeControlResponseSuccess(requestID: requestID)
            )
            await controller.test_receiveConfigurationResponseLine(response)
            if reject {
                do {
                    _ = try await application.value
                    XCTFail("A production error response cannot certify application")
                } catch let failure as NativeAgentRuntimeConfigurationFailure {
                    guard case NativeAgentRuntimeControllerError.invalidControlResponse = failure.underlyingError else {
                        return XCTFail("Unexpected underlying ACK error: \(failure.underlyingError)")
                    }
                }
                XCTAssertEqual(writes.count, 1, "Only the settings request was written")
            } else {
                guard case let .applied(proof) = try await application.value else { return XCTFail("Missing ACK proof") }
                _ = try await runtime.sendUserMessage("ordinary", configuration: proof)
                try await AsyncTestWait.waitUntil("user message on production adapter wire") { writes.count == 3 }
                let userFrame = try XCTUnwrap(writes.line(at: 2))
                let user = try XCTUnwrap(JSONSerialization.jsonObject(with: userFrame) as? [String: Any])
                XCTAssertEqual(user["type"] as? String, "user")
                XCTAssertEqual(writes.count, 3, "Two settings requests followed by one user write")
            }
        }
    }

    func testRepoPromptPermissionAutoApprovalAndAllowPayloadPreserveToolUseID() throws {
        let repoPromptPayload: [String: Any] = [
            "tool_name": "mcp__RepoPromptCE__read_file",
            "tool_use_id": "toolu_read_1",
            "input": ["path": "Sources/App.swift"],
            "permission_suggestions": [["type": "tool", "name": "mcp__RepoPromptCE__read_file"]]
        ]

        let match = try XCTUnwrap(ClaudeNativeProcessSessionController.repoPromptPermissionAutoApprovalMatch(
            toolName: "mcp__RepoPromptCE__read_file",
            requestPayload: repoPromptPayload
        ))
        XCTAssertEqual(match.source, .topLevelToolName)
        XCTAssertEqual(match.normalizedToolName, "read_file")

        let allowOnce = ClaudeNativeProcessSessionController.allowPermissionResponsePayload(
            pendingRequest: repoPromptPayload,
            includeUpdatedPermissions: false
        )
        XCTAssertEqual(allowOnce["behavior"] as? String, "allow")
        XCTAssertEqual(allowOnce["toolUseID"] as? String, "toolu_read_1")
        XCTAssertNil(allowOnce["updatedPermissions"])
        XCTAssertEqual((allowOnce["updatedInput"] as? [String: Any])?["path"] as? String, "Sources/App.swift")

        let allowForSession = ClaudeNativeProcessSessionController.allowPermissionResponsePayload(
            pendingRequest: repoPromptPayload,
            includeUpdatedPermissions: true
        )
        XCTAssertEqual((allowForSession["updatedPermissions"] as? [[String: Any]])?.first?["name"] as? String, "mcp__RepoPromptCE__read_file")

        // A RepoPrompt permission suggestion must not authorize a different actual invocation.
        XCTAssertNil(ClaudeNativeProcessSessionController.repoPromptPermissionAutoApprovalMatch(
            toolName: "Bash",
            requestPayload: [
                "permission_suggestions": [["rules": [["toolName": "mcp__RepoPromptCE__read_file"]]]]
            ]
        ))

        for (tool, operation) in [
            ("agent_session_link", "list"),
            ("self_compact", "context"),
            ("manage_worktree", "list")
        ] {
            let toolUseID = "toolu_\(tool)"
            let qualifiedTool = "mcp__RepoPromptCE__\(tool)"
            let payload: [String: Any] = [
                "tool_name": qualifiedTool,
                "tool_use_id": toolUseID,
                "input": ["op": operation]
            ]
            XCTAssertNil(ClaudeNativeProcessSessionController.repoPromptPermissionAutoApprovalMatch(
                toolName: tool,
                requestPayload: ["tool_name": tool, "input": ["op": operation]]
            ), "bare top-level name without provenance: \(tool)")
            let match = ClaudeNativeProcessSessionController.repoPromptPermissionAutoApprovalMatch(
                toolName: qualifiedTool,
                requestPayload: payload
            )
            XCTAssertEqual(match?.source, .topLevelToolName, tool)
            XCTAssertEqual(match?.normalizedToolName, tool, tool)

            let response = ClaudeNativeProcessSessionController.allowPermissionResponsePayload(
                pendingRequest: payload,
                includeUpdatedPermissions: false
            )
            XCTAssertEqual(response["behavior"] as? String, "allow", tool)
            XCTAssertEqual(response["toolUseID"] as? String, toolUseID, tool)
            XCTAssertEqual((response["updatedInput"] as? [String: Any])?["op"] as? String, operation, tool)
            XCTAssertNil(response["updatedPermissions"], tool)
        }

        let metadataMatch = ClaudeNativeProcessSessionController.repoPromptPermissionAutoApprovalMatch(
            toolName: "",
            requestPayload: ["server_name": "RepoPromptCE"]
        )
        XCTAssertEqual(metadataMatch?.source, .serverIdentifier)
        XCTAssertEqual(metadataMatch?.serverIdentifier, "RepoPromptCE")
        XCTAssertNil(metadataMatch?.normalizedToolName)

        XCTAssertNil(ClaudeNativeProcessSessionController.repoPromptPermissionAutoApprovalMatch(
            toolName: "Bash",
            requestPayload: ["input": ["command": "rm -rf /tmp/example"]]
        ))
    }

    /// Issue #1243: a bare RepoPrompt tool name in request metadata must not auto-approve a
    /// request that another MCP server owns. Codex elicitation/permission auto-accept uses the
    /// same matcher with `requestToolName: nil`, so a nil match means Codex does not auto-accept.
    func testRepoPromptPermissionAutoApprovalRequiresRepoPromptProvenance() {
        let toolNames = MCPDomainToolCatalog.orderedToolNames
        XCTAssertTrue(toolNames.contains("manage_worktree"))
        XCTAssertTrue(toolNames.contains("agent_session_link"))
        XCTAssertTrue(toolNames.contains("self_compact"))

        for tool in toolNames {
            let foreignPayloads: [[String: Any]] = [
                ["serverName": "OtherServer", "request": ["_meta": ["tool_title": tool]]],
                ["server_name": "OtherServer", "name": tool],
                ["request": ["_meta": ["connector_name": "OtherServer", "tool_title": tool]]],
                ["serverName": "OtherServer", "request": ["_meta": ["tool_title": "mcp__RepoPromptCE__\(tool)"]]],
                ["serverName": "OtherServer", "tool_name": tool]
            ]
            for payload in foreignPayloads {
                XCTAssertNil(
                    MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(requestToolName: nil, requestPayload: payload),
                    "foreign server payload must not match: \(tool) \(payload)"
                )
                XCTAssertNil(
                    MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(requestToolName: tool, requestPayload: payload),
                    "foreign server payload must not match with top-level name: \(tool)"
                )
            }

            // Bare nested names without any server provenance do not auto-approve.
            XCTAssertNil(MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
                requestToolName: nil,
                requestPayload: ["request": ["_meta": ["tool_title": tool]]]
            ), tool)
            // Free-text descriptions are not tool-name candidates.
            XCTAssertNil(MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
                requestToolName: nil,
                requestPayload: ["request": ["_meta": ["tool_description": "mcp__RepoPromptCE__\(tool)"]]]
            ), tool)

            // Positive controls: RepoPrompt server identifier or a server-prefixed name.
            let serverMatch = MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
                requestToolName: nil,
                requestPayload: ["serverName": "RepoPromptCE", "request": ["_meta": ["tool_title": tool]]]
            )
            XCTAssertEqual(serverMatch?.source, .nestedToolName, tool)
            XCTAssertEqual(serverMatch?.normalizedToolName, tool, tool)

            let connectorMatch = MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
                requestToolName: nil,
                requestPayload: ["request": ["_meta": ["connector_name": "RepoPromptCE", "tool_title": tool]]]
            )
            XCTAssertEqual(connectorMatch?.normalizedToolName, tool, tool)

            let prefixedMatch = MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
                requestToolName: nil,
                requestPayload: ["request": ["_meta": ["tool_title": "mcp__RepoPromptCE__\(tool)"]]]
            )
            XCTAssertEqual(prefixedMatch?.source, .nestedToolName, tool)

            let grokMatch = MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
                requestToolName: nil,
                requestPayload: ["serverName": "RepoPromptCEGrokRuntime", "name": tool]
            )
            XCTAssertNotNil(grokMatch, tool)

            // Look-alike server names that merely contain the RepoPrompt server name are foreign.
            for lookAlike in ["NotRepoPromptCE", "RepoPromptCE-evil", "evil.repopromptce", "RepoPromptCEX"] {
                XCTAssertNil(MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
                    requestToolName: nil,
                    requestPayload: ["serverName": lookAlike, "request": ["_meta": ["tool_title": tool]]]
                ), "\(lookAlike) \(tool)")
            }
        }

        XCTAssertTrue(MCPIntegrationHelper.isRepoPromptServerIdentifier(" repopromptce "))
        XCTAssertTrue(MCPIntegrationHelper.isRepoPromptServerIdentifier("RepoPromptCEGrokRuntime"))
        XCTAssertFalse(MCPIntegrationHelper.isRepoPromptServerIdentifier("NotRepoPromptCE"))
        XCTAssertFalse(MCPIntegrationHelper.isRepoPromptServerIdentifier("RepoPromptCE MCP Server"))
    }

    /// Issue #1243 review follow-ups: display labels, permission suggestions, foreign qualified
    /// actual tool names, and server-field aliases must not grant RepoPrompt provenance.
    func testRepoPromptPermissionAutoApprovalRejectsLabelAndSuggestionProvenance() {
        func match(_ toolName: String?, _ payload: [String: Any]) -> MCPIntegrationHelper.RepoPromptPermissionAutoApprovalMatch? {
            MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(requestToolName: toolName, requestPayload: payload)
        }

        // Unanchored / look-alike labels.
        for title in [
            "RepoPromptCE-evil: git",
            "RepoPromptCE anything: manage_worktree",
            "Other RepoPromptCE MCP Server: git",
            "Unrelated operation (RepoPromptCE MCP Server)",
            "printf '(RepoPromptCE MCP Server)'"
        ] {
            XCTAssertNil(match(title, ["toolCall": ["title": title, "kind": "execute"], "title": title]), title)
        }

        // Anchored labels naming a catalog tool still match.
        XCTAssertEqual(match("read_file (RepoPromptCE MCP Server)", [:])?.normalizedToolName, "read_file")
        XCTAssertEqual(match("RepoPromptCE: git", [:])?.normalizedToolName, "git")
        XCTAssertEqual(match("RepoPromptCE MCP Server: git", [:])?.normalizedToolName, "git")

        // Foreign qualified actual tool cannot borrow a RepoPrompt suggestion or nested name.
        XCTAssertNil(match("mcp__OtherServer__delete_files", [
            "tool_name": "mcp__OtherServer__delete_files",
            "permission_suggestions": [["rules": [["toolName": "mcp__RepoPromptCE__git"]]]]
        ]))
        XCTAssertNil(match("mcp__OtherServer__delete_files", [
            "request": ["_meta": ["tool_title": "mcp__RepoPromptCE__git"]]
        ]))
        XCTAssertNil(match(nil, [
            "name": "mcp__OtherServer__git",
            "request": ["_meta": ["tool_title": "mcp__RepoPromptCE__git"]]
        ]))

        // Server-field aliases recognized by the Codex parser also veto.
        for key in ["mcpServerName", "mcp_server_name"] {
            XCTAssertNil(match(nil, [key: "OtherServer", "request": ["_meta": ["tool_title": "mcp__RepoPromptCE__git"]]]), key)
            XCTAssertNil(match(nil, ["request": [key: "OtherServer", "_meta": ["tool_title": "mcp__RepoPromptCE__git"]]]), key)
            XCTAssertNotNil(match(nil, [key: "RepoPromptCE", "request": ["_meta": ["tool_title": "git"]]]), key)
        }
    }

    func testCodexMCPElicitationAutoAcceptRequiresRepoPromptProvenance() {
        // Reported shape and flattened upstream shape from a foreign server.
        XCTAssertFalse(CodexNativeSessionController.isRepoPromptMCPElicitationRequest(params: [
            "serverName": "OtherServer",
            "request": ["_meta": ["tool_title": "manage_worktree"]]
        ]))
        XCTAssertFalse(CodexNativeSessionController.isRepoPromptMCPElicitationRequest(params: [
            "serverName": "OtherServer",
            "_meta": ["tool_title": "git"],
            "message": "Allow git?"
        ]))
        XCTAssertFalse(CodexNativeSessionController.isRepoPromptMCPElicitationRequest(params: [
            "request": ["_meta": ["tool_title": "git"]]
        ]))
        // Genuine RepoPrompt elicitation still auto-accepts.
        XCTAssertTrue(CodexNativeSessionController.isRepoPromptMCPElicitationRequest(params: [
            "serverName": "RepoPromptCE",
            "request": ["_meta": ["tool_title": "manage_worktree"]]
        ]))
        XCTAssertTrue(CodexNativeSessionController.isRepoPromptMCPElicitationRequest(params: [
            "serverName": "RepoPromptCE",
            "message": "Approve?"
        ]))
    }
}
