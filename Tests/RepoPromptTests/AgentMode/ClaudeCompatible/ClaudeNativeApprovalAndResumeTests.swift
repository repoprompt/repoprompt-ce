import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptProviderQuota
import RepoPromptSettingsCore
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

    private func cliPlanUsageSnapshot(observedAt date: Date) throws -> ProviderQuotaSnapshot {
        let payload = Data(#"{"rate_limits":{"five_hour":{"used_percentage":6,"resets_at":1900010000},"seven_day":{"used_percentage":5,"resets_at":1900300000}}}"#.utf8)
        return try XCTUnwrap(ClaudeCLIUsageRecord.extract(payload, now: date)).snapshot(profileID: "profile")
    }

    func testCLIUsageSnapshotDeclaresPlanWindowDurationsAndFriendlyTitles() throws {
        let snapshot = try cliPlanUsageSnapshot(observedAt: Date(timeIntervalSince1970: 1_900_000_000))
        let windows = try XCTUnwrap(snapshot.buckets.first?.windows)
        XCTAssertEqual(windows.map(\.nativeRole), ["five_hour", "seven_day"])
        XCTAssertEqual(windows.map(\.windowDuration), [18000, 604_800])
        XCTAssertEqual(windows.map(ProviderQuotaPresenter.windowTitle(for:)), ["5-hour limit", "Weekly limit"], "raw role names must not leak into Settings rows")
    }

    func testCLIUsageIndicatorStaysVisibleBeyondDefaultStaleHorizon() throws {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshot = try cliPlanUsageSnapshot(observedAt: date)
        let hourOld = try XCTUnwrap(ProviderQuotaIndicatorState.project(snapshot, now: date.addingTimeInterval(60 * 60)), "an hour-old 5-hour reading is within 25% of its window")
        XCTAssertEqual(hourOld.usedPercent, 5, "the weekly window remains the primary figure")
        XCTAssertEqual(hourOld.shortWindowPercent, 6, "the hour-old 5-hour reading remains visible as the secondary figure")
        let pastFiveHourHorizon = try XCTUnwrap(ProviderQuotaIndicatorState.project(snapshot, now: date.addingTimeInterval(76 * 60)))
        XCTAssertEqual(pastFiveHourHorizon.usedPercent, 5, "only the weekly reading remains fresh")
        XCTAssertEqual(pastFiveHourHorizon.freshness, .fresh)
        let everythingAged = try XCTUnwrap(ProviderQuotaIndicatorState.project(snapshot, now: date.addingTimeInterval(43 * 3600)), "aged readings stay visible")
        XCTAssertEqual(everythingAged.usedPercent, 5, "the aged weekly reading stays primary")
        XCTAssertEqual(everythingAged.shortWindowPercent, 6, "the aged 5-hour reading also stays visible")
        XCTAssertEqual(everythingAged.freshness, .resetPassed, "the 5-hour reset has passed with nothing newer")
    }

    func testCLIUsageWeeklyReadingInformsBalancingWithinSixHours() throws {
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshot = try cliPlanUsageSnapshot(observedAt: date)
        let recent = ProviderUsageBalancePolicy.reading(snapshot, now: date.addingTimeInterval(40 * 60))
        XCTAssertTrue(recent.known)
        XCTAssertNotNil(recent.weeklySparePace)
        XCTAssertEqual(recent.weeklyHeadroom, 95)
        XCTAssertFalse(ProviderUsageBalancePolicy.reading(snapshot, now: date.addingTimeInterval(6 * 3600 + 1)).known, "weekly routing evidence is capped at six hours")
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
        let (coordinator, session, intent) = try ordinaryTurnFixture(controller: controller)
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
    ) throws -> (ClaudeAgentModeCoordinator, AgentTabSession, ClaudeAgentModeCoordinator.NativeSessionIntent) {
        var creations = 0
        let coordinator = ClaudeAgentModeCoordinator(
            windowID: 1,
            workspacePathProvider: { _ in nil },
            claudeControllerFactory: { _, _, _, _ in
                creations += 1
                return creations == 1 ? controller : (replacement ?? controller)
            },
            autoEffortConfigurationProvider: { .init(enabled: true, selectedBackendRawValue: nil, revision: 0) }
        )
        let session = AgentTabSession(tabID: UUID())
        session.selectedAgent = .claudeCode
        session.selectedModelRaw = "claude-opus-5-5:high"
        session.hasLoadedPersistedState = true
        session.testInstallPersistentSessionBinding(sessionID: UUID())
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        _ = try XCTUnwrap(
            session.permitsBoundOperationAndSave ? session.currentRestorationBindingToken : nil,
            "The restored conversation must be ready before exercising native configuration."
        )
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
            let (coordinator, session, intent) = try ordinaryTurnFixture(controller: controller)
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
        let (coordinator, session, intent) = try ordinaryTurnFixture(controller: controller)
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
    func testOrdinaryApplicationFailurePreservesIdentityAndDoesNotPrompt() async throws {
        for failure in [NativeAgentRuntimeControllerError.invalidControlResponse("rejected")] {
            let controller = applicationController()
            let writes = WrittenLines()
            await controller.test_installConfigurationTransport(
                initialized: true, controlRequest: { _ in throw failure }, write: { writes.append($0) }
            )
            let (coordinator, session, intent) = try ordinaryTurnFixture(controller: controller)
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
    func testComposerModelSwitchRequiringRestartDeliversWithoutRetry() async throws {
        let controller = applicationController()
        let replacement = applicationController()
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(initialized: true, controlRequest: { _ in
            throw NativeAgentRuntimeControllerError.liveModelSwitchRequiresRestart
        }, write: { writes.append($0) })
        await replacement.test_installConfigurationTransport(initialized: true, write: { writes.append($0) })
        let (coordinator, session, intent) = try ordinaryTurnFixture(controller: controller, replacement: replacement)
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
    func testOptionalAutoFailureReestablishesSameModelManualProofBeforePrompt() async throws {
        let controller = applicationController()
        let requests = EffortRequests()
        let writes = WrittenLines()
        await controller.test_installConfigurationTransport(
            initialized: true, controlRequest: { try await requests.respond($0) }, write: { writes.append($0) }
        )
        let (coordinator, session, intent) = try ordinaryTurnFixture(controller: controller)
        let outcome = await coordinator.sendClaudeNativeMessage(
            session: session, text: "ordinary", attachments: [], intent: intent,
            allowsCatalogRouteControllerRecovery: false,
            autoEffortSelection: .init(
                provider: .claudeCode, selectedModelRaw: session.selectedModelRaw,
                manualEffortRaw: "high", effortRaw: "low", backendID: .jev, autoEffortRevision: 0
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
            let (coordinator, session, intent) = try ordinaryTurnFixture(controller: controller)
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
            guard case let .scheduled(noteAttempt) = state.reserve(note: "keep this exact note", idempotencyKey: "proof-race", maximumNoteUTF8Bytes: AgentSessionSelfCompactNotePolicy.fallbackMaximumUTF8Bytes)
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
            let (coordinator, session, intent) = try ordinaryTurnFixture(controller: controller)
            let send = Task {
                await coordinator.sendClaudeNativeMessage(
                    session: session, text: "ordinary", attachments: [], intent: intent,
                    allowsCatalogRouteControllerRecovery: false,
                    autoEffortSelection: .init(
                        provider: .claudeCode,
                        selectedModelRaw: session.selectedModelRaw,
                        manualEffortRaw: "high",
                        effortRaw: "low", backendID: .jev, autoEffortRevision: 0
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
        let (coordinator, session, intent) = try ordinaryTurnFixture(controller: controller, replacement: replacement)
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

@MainActor
final class ClaudeUsageSetupTests: XCTestCase {
    func testProductionConnectAndSetupActionAcceptPendingConsentButCollectionDoesNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ClaudeUsageSetupTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = GlobalSettingsStore(defaults: defaults, fileStore: GlobalSettingsFileStore(fileURL: root.appendingPathComponent("settings.json")))
        var source: ClaudeCLIUsageSource?
        let runtime = ProviderQuotaRuntime(
            accountIDProvider: { nil },
            managedAuthTransitions: { AsyncStream { $0.finish() } },
            settingsStore: settings,
            claudeSourceFactory: { readConsent, setupConsent in
                let value = ClaudeCLIUsageSource(root: root.appendingPathComponent("usage"), collect: { _, _ in
                    try XCTUnwrap(ClaudeCLIUsageRecord.extract(Data(#"{"rate_limits":{"five_hour":{"used_percentage":4}}}"#.utf8)))
                }, consentProvider: readConsent, setupConsentProvider: setupConsent, setupCommandProvider: { "/usr/bin/false" })
                source = value
                return value
            }
        )
        let action = ClaudeUsageSetupAction()
        // These are the production Connect confirmation and Open Terminal action, not a
        // hand-built ready grant. Before this fix the latter failed with needsConsent.
        runtime.connectClaudeUsage(startReading: false)
        let grant = try XCTUnwrap(settings.claudeCLIUsageGrant())
        XCTAssertFalse(grant.isReady)
        var launched: URL?
        await action.open(prepare: { try await runtime.prepareClaudeUsageSetup() }, launch: { launched = $0 })
        XCTAssertNil(action.error)
        let script = try XCTUnwrap(launched)
        XCTAssertEqual(action.script, script)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path))
        XCTAssertTrue(try String(contentsOf: script, encoding: .utf8).contains("'--tools' ''"))
        XCTAssertEqual(settings.claudeCLIUsageGrant(), grant, "Opening setup cannot mark consent ready")
        let connectedSource = try XCTUnwrap(source)
        do {
            _ = try await connectedSource.read(.init(userInitiated: true))
            XCTFail("Pending setup authorized collection")
        } catch { XCTAssertEqual(error as? ProviderQuotaReadError, .needsConsent) }
        try await runtime.completeClaudeUsageSetup()
        XCTAssertEqual(settings.claudeCLIUsageGrant()?.grantedAt, grant.grantedAt)
        XCTAssertEqual(settings.claudeCLIUsageGrant()?.isReady, true)
        let reading = try await connectedSource.read(.init(userInitiated: true))
        XCTAssertFalse(reading.buckets.isEmpty)
        runtime.disconnectClaudeUsage()
        await action.open(prepare: { try await runtime.prepareClaudeUsageSetup() }, launch: { _ in XCTFail("Revoked consent opened Terminal") })
        XCTAssertNotNil(action.error)
        XCTAssertNil(action.manualCommand, "Do not retain a runnable command after revocation")
    }

    func testTerminalFailureRetainsCopyableQuotedManualCommandAndSuccessClearsError() async throws {
        let action = ClaudeUsageSetupAction()
        let script = URL(fileURLWithPath: "/fixture/helper's folder/Set up Claude usage.command")
        await action.open(prepare: { script }, launch: { _ in throw NSError(domain: "Terminal", code: 42, userInfo: [NSLocalizedDescriptionKey: "Automation denied"]) })
        XCTAssertTrue(try XCTUnwrap(action.error).contains("Automation denied"))
        XCTAssertEqual(action.manualCommand, "/bin/zsh '/fixture/helper'\\''s folder/Set up Claude usage.command'")
        await action.open(prepare: { script }, launch: { XCTAssertEqual($0, script) })
        XCTAssertNil(action.error)
        XCTAssertFalse(action.isOpening)
    }

    func testPreparationFailureNeverLaunchesOrOffersStaleCommand() async {
        let action = ClaudeUsageSetupAction()
        action.script = URL(fileURLWithPath: "/stale/setup.command")
        await action.open(prepare: { throw ProviderQuotaReadError.needsConsent }, launch: { _ in XCTFail("No authorized setup script") })
        XCTAssertNil(action.manualCommand)
        XCTAssertEqual(action.error, ProviderQuotaReadError.needsConsent.message)
        XCTAssertFalse(action.isOpening)
    }

    func testMissingCLIProvidesPreparationFailureWithoutLaunching() async {
        let profile = ClaudeUsageCredentialProfile.current()
        let source = ClaudeCLIUsageSource(consentProvider: { nil }, setupConsentProvider: { profile.id }, setupCommandProvider: { "not-an-executable" })
        do {
            _ = try await source.prepareSetup()
            XCTFail("Missing CLI accepted")
        } catch { XCTAssertEqual(error as? ProviderQuotaReadError, .cliUnavailable) }
    }

    func testSetupRevalidatesConsentAfterPreparingFiles() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = ClaudeUsageCredentialProfile.current()
        let consent = OneUseSetupConsent(profileID: profile.id)
        let source = ClaudeCLIUsageSource(root: root, consentProvider: { nil }, setupConsentProvider: { await consent.next() }, setupCommandProvider: { "/usr/bin/false" })
        let action = ClaudeUsageSetupAction()
        await action.open(prepare: { try await source.prepareSetup() }, launch: { _ in XCTFail("Revoked consent launched setup") })
        XCTAssertEqual(action.error, ProviderQuotaReadError.needsConsent.message)
        XCTAssertNil(action.manualCommand)
    }

    private actor OneUseSetupConsent {
        let profileID: String
        var calls = 0
        init(profileID: String) {
            self.profileID = profileID
        }

        func next() -> String? {
            calls += 1
            return calls == 1 ? profileID : nil
        }
    }
}

final class ClaudeNativeTurnCorrelationTests: XCTestCase {
    private func controller(fallback: TimeInterval = 1) async -> ClaudeNativeProcessSessionController {
        let controller = ClaudeNativeProcessSessionController(
            runID: UUID(), tabID: UUID(), windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false"),
            authoritativeTurnIdleFallbackSeconds: fallback
        )
        await controller.test_installConfigurationTransport(write: { _ in })
        return controller
    }

    private let initFrame: [String: Any] = [
        "type": "system", "subtype": "init", "claude_code_version": "2.1.292",
        "capabilities": ["msg_lifecycle_v1"]
    ]

    private func feed(_ payload: [String: Any], to controller: ClaudeNativeProcessSessionController) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        await controller.test_receiveConfigurationResponseLine(data)
    }

    private func result(_ ids: [UUID]? = nil, text: String = "answer") -> [String: Any] {
        var frame: [String: Any] = ["type": "result", "subtype": "success", "num_turns": 0, "result": text]
        if let ids {
            frame["user_message_uuids"] = ids.map(\.uuidString)
            frame["user_message_uuid"] = ids.last?.uuidString
        }
        return frame
    }

    private func assistant(_ id: UUID? = nil, text: String = "") -> [String: Any] {
        var frame: [String: Any] = [
            "type": "assistant", "message": ["id": "synthetic-message", "role": "assistant", "content": [["type": "text", "text": text]]]
        ]
        if let id { frame["user_message_uuid"] = id.uuidString }
        return frame
    }

    private func completions(_ events: [ClaudeNativeProcessSessionController.Event]) -> [([UUID], ClaudeNativeProcessSessionController.TurnStatus)] {
        events.compactMap {
            switch $0 {
            case let .turnCompleted(id, status): ([id], status)
            case let .turnsCompleted(ids, status): (ids, status)
            default: nil
            }
        }
    }

    private func finish(_ controller: ClaudeNativeProcessSessionController) async -> [ClaudeNativeProcessSessionController.Event] {
        await controller.shutdown()
        var events: [ClaudeNativeProcessSessionController.Event] = []
        for await event in await controller.events {
            events.append(event)
        }
        return events
    }

    private func failureEvents(_ controller: ClaudeNativeProcessSessionController) async -> [ClaudeNativeProcessSessionController.Event] {
        let stream = await controller.events
        let finished = expectation(description: "Protocol failure closes its event stream")
        let reader = Task {
            var events: [ClaudeNativeProcessSessionController.Event] = []
            for await event in stream {
                events.append(event)
            }
            finished.fulfill()
            return events
        }
        await fulfillment(of: [finished], timeout: 2)
        await controller.shutdown()
        return await reader.value
    }

    func testFirstInputAndZeroTurnCommandsUseExactEchoWithoutAnEchoLatch() async throws {
        let controller = await controller()
        let first = try await controller.sendUserMessage("baseline")
        try await feed(initFrame, to: controller)
        try await feed(result([first]), to: controller)
        let cost = try await controller.sendUserMessage("/cost")
        let compact = try await controller.sendUserMessage("/compact")
        try await feed(result([compact]), to: controller)
        try await feed(result([cost]), to: controller)
        let pending = await controller.hasTurnInFlight
        XCTAssertFalse(pending)
        let events = await finish(controller)
        XCTAssertEqual(completions(events).map(\.0), [[first], [compact], [cost]])
    }

    func testUnsolicitedResultCannotStealNewHostInputOrItsOutputAndApprovalsStillFlow() async throws {
        let controller = await controller()
        try await feed(initFrame, to: controller)
        try await feed(assistant(text: "unowned text"), to: controller)
        let host = try await controller.sendUserMessage("B")
        try await feed([
            "type": "control_request", "request_id": "approval-U",
            "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "echo synthetic"]]
        ], to: controller)
        await controller.test_receiveConfigurationResponseLine(Data("Unsolicited background work completed while another input waited for service.".utf8))
        try await feed(result(text: "unowned final"), to: controller)
        let pending = await controller.hasTurnInFlight
        XCTAssertTrue(pending)
        var subagent = assistant(host, text: "child answer")
        subagent["parent_tool_use_id"] = "synthetic-parent-tool"
        try await feed(subagent, to: controller)
        try await feed(assistant(text: "subagent ownership probe"), to: controller)
        try await feed(assistant(host, text: "owned text"), to: controller)
        try await feed(assistant(UUID(), text: "stale answer"), to: controller)
        try await feed(result([host], text: "owned final"), to: controller)
        try await feed(result([host], text: "duplicate"), to: controller)
        let events = await finish(controller)
        XCTAssertEqual(completions(events).map(\.0), [[host]])
        let text = events.compactMap { event -> String? in
            if case let .stream(result) = event { return result.text }
            return nil
        }.joined()
        XCTAssertFalse(text.contains("unowned"))
        XCTAssertFalse(text.contains("duplicate"))
        XCTAssertFalse(text.contains("stale answer"))
        XCTAssertFalse(text.contains("child answer"))
        XCTAssertFalse(text.contains("subagent ownership probe"))
        XCTAssertFalse(text.contains("Unsolicited background"))
        XCTAssertTrue(text.contains("owned text"))
        XCTAssertTrue(events.contains { if case .approvalRequest = $0 { return true }
            return false
        })
    }

    private func streamEvent(_ event: [String: Any], inputID: UUID? = nil, parentKey: String? = nil) -> [String: Any] {
        var frame: [String: Any] = ["type": "stream_event", "event": event]
        if let inputID { frame["user_message_uuid"] = inputID.uuidString }
        if let parentKey { frame[parentKey] = "synthetic-parent-tool" }
        return frame
    }

    func testForeignMessageRejectionPersistsAcrossDeltasWithoutRetiringHostInput() async throws {
        let controller = await controller()
        try await feed(initFrame, to: controller)
        let retired = try await controller.sendUserMessage("previous input")
        try await feed(result([retired]), to: controller)
        let host = try await controller.sendUserMessage("host input")
        try await feed(assistant(host), to: controller)
        for foreign in [retired, UUID()] {
            try await feed(streamEvent([
                "type": "message_start", "message": ["id": host.uuidString, "role": "assistant"]
            ], inputID: host), to: controller)
            try await feed(streamEvent([
                "type": "content_block_delta", "delta": ["type": "text_delta", "text": "accepted host delta"]
            ]), to: controller)
            try await feed(streamEvent([
                "type": "message_start", "message": ["id": foreign.uuidString, "role": "assistant"]
            ], inputID: foreign), to: controller)
            try await feed(streamEvent([
                "type": "content_block_delta", "delta": ["type": "text_delta", "text": "rejected foreign text"]
            ]), to: controller)
            try await feed(streamEvent([
                "type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "rejected foreign reasoning"]
            ]), to: controller)
            try await feed(streamEvent(["type": "message_stop"]), to: controller)
            let pending = await controller.hasTurnInFlight
            XCTAssertTrue(pending, "Rejecting a message must not retire the host execution")
        }
        // A keyed result still settles A even while the latest message is rejected.
        try await feed(result([host], text: "host final"), to: controller)
        let pending = await controller.hasTurnInFlight
        XCTAssertFalse(pending)
        let events = await finish(controller)
        XCTAssertEqual(completions(events).map(\.0), [[retired], [host]])
        let output = events.compactMap { event -> String? in
            guard case let .stream(value) = event, ["content", "final_content", "reasoning"].contains(value.type) else { return nil }
            return value.text ?? value.reasoning
        }
        XCTAssertFalse(output.joined().contains("rejected foreign"))
        XCTAssertEqual(output.count(where: { $0 == "accepted host delta" }), 2)
        XCTAssertTrue(output.joined().contains("host final"))
    }

    func testSubagentDeltasCannotBorrowOrReplaceMainThreadOutputOwnership() async throws {
        let controller = await controller()
        try await feed(initFrame, to: controller)
        let host = try await controller.sendUserMessage("host input")
        try await feed(streamEvent([
            "type": "message_start", "message": ["id": host.uuidString, "role": "assistant"]
        ], inputID: host), to: controller)
        for parentKey in ["parent_tool_use_id", "parentToolUseId"] {
            try await feed(streamEvent([
                "type": "message_start", "message": ["id": "child-message", "role": "assistant"]
            ], inputID: UUID(), parentKey: parentKey), to: controller)
            try await feed(streamEvent([
                "type": "content_block_delta", "delta": ["type": "text_delta", "text": "rejected child text"]
            ], parentKey: parentKey), to: controller)
            try await feed(streamEvent([
                "type": "content_block_delta", "delta": ["type": "thinking_delta", "thinking": "rejected child reasoning"]
            ], parentKey: parentKey), to: controller)
            try await feed(streamEvent(["type": "message_stop"], parentKey: parentKey), to: controller)
            // The main stream resumes without a new message_start; child frames must
            // neither inherit its output owner nor overwrite it with their own.
            try await feed(streamEvent([
                "type": "content_block_delta", "delta": ["type": "text_delta", "text": "resumed host delta"]
            ]), to: controller)
        }
        let pending = await controller.hasTurnInFlight
        XCTAssertTrue(pending)
        try await feed(result([host]), to: controller)
        let events = await finish(controller)
        XCTAssertEqual(completions(events).map(\.0), [[host]])
        let output = events.compactMap { event -> String? in
            guard case let .stream(value) = event, ["content", "final_content", "reasoning"].contains(value.type) else { return nil }
            return value.text ?? value.reasoning
        }
        XCTAssertFalse(output.joined().contains("rejected child"))
        XCTAssertEqual(output.count(where: { $0 == "resumed host delta" }), 2)
    }

    func testGroupedPickupAndForeignIDsDoNotConsumeOtherPendingInputs() async throws {
        let controller = await controller()
        try await feed(initFrame, to: controller)
        try await feed(assistant(), to: controller)
        let b = try await controller.sendUserMessage("B")
        let c = try await controller.sendUserMessage("C")
        let d = try await controller.sendUserMessage("D")
        try await feed(result([UUID()]), to: controller)
        var grouped = result([b, c])
        grouped["origin"] = ["type": "task-notification"]
        try await feed(grouped, to: controller)
        let pending = await controller.hasTurnInFlight
        XCTAssertTrue(pending)
        try await feed(result([d]), to: controller)
        let events = await finish(controller)
        XCTAssertEqual(completions(events).map(\.0), [[b, c], [d]])
    }

    func testResolvedDeferredTargetsSurviveNewSendAndEOFDrainsOnlyUnresolved() async throws {
        let controller = await controller()
        try await feed(initFrame, to: controller)
        try await feed(["type": "system", "subtype": "session_state_changed", "state": "busy"], to: controller)
        let a = try await controller.sendUserMessage("A")
        let b = try await controller.sendUserMessage("B")
        try await feed(result([b]), to: controller)
        await controller.test_handleStdoutEOF()
        await controller.test_handleStdoutEOF()
        let events = await finish(controller)
        let completed = completions(events)
        XCTAssertEqual(completed.map(\.0), [[b], [a]])
        guard completed.count == 2 else { return }
        if case .completed = completed[0].1 {} else { XCTFail("Preserve resolved status") }
        if case .failed = completed[1].1 {} else { XCTFail("Fail only unresolved A") }
    }

    func testIdleAndFallbackUseResolvedTargetsRatherThanLaterSend() async throws {
        for useIdle in [true, false] {
            let controller = await controller(fallback: useIdle ? 10 : 0.01)
            let stream = await controller.events
            let completed = expectation(description: "Resolved A completes via idle or fallback")
            let a = try await controller.sendUserMessage("A")
            let b = try await controller.sendUserMessage("B")
            let reader = Task {
                var events: [ClaudeNativeProcessSessionController.Event] = []
                for await event in stream {
                    events.append(event)
                    if case let .turnsCompleted(ids, _) = event, ids == [b] { completed.fulfill() }
                }
                return events
            }
            try await feed(initFrame, to: controller)
            try await feed(["type": "system", "subtype": "session_state_changed", "state": "busy"], to: controller)
            try await feed(result([b]), to: controller)
            try await feed(result(), to: controller) // U's result cannot steal A or alter B's resolved status.
            if useIdle {
                try await feed(["type": "system", "subtype": "session_state_changed", "state": "idle"], to: controller)
            }
            await fulfillment(of: [completed], timeout: 2)
            let pending = await controller.hasTurnInFlight
            XCTAssertTrue(pending, "B's completion must leave A pending")
            try await feed(result([a]), to: controller)
            await controller.test_handleStdoutEOF()
            let events = await reader.value
            XCTAssertEqual(completions(events).map(\.0), [[b], [a]])
            await controller.shutdown()
        }
    }

    func testUnsupportedVersionRetainsLegacySettlement() async throws {
        let controller = await controller()
        var old = initFrame
        old["claude_code_version"] = "2.1.291"
        try await feed(old, to: controller)
        let host = try await controller.sendUserMessage("B")
        try await feed(result(), to: controller)
        let events = await finish(controller)
        XCTAssertEqual(completions(events).map(\.0), [[host]])
    }

    func testMalformedGroupsFailAtomicallyAndInterruptBindingCannotMoveToLaterInput() throws {
        let a = UUID(), b = UUID()
        var state = ClaudeNativeTurnCorrelation()
        state.observeInit(initFrame)
        state.register(a)
        try state.observeActivity(assistant(a))
        let target = state.beginInterrupt()
        state.register(b)
        let resolved = try state.resolve(result([a]))
        XCTAssertTrue(resolved.interrupted, "Result-before-ACK is cancelled at the captured target")
        XCTAssertFalse(state.isInterruptPending(target), "A later ACK/failure is safe even with B outstanding")
        state.abandonInterrupt(target) // A late failure/timeout cannot modify B; success needs no mutation.
        XCTAssertFalse(try state.resolve(result([b])).interrupted)

        state.register(a)
        try state.observeActivity(assistant(a))
        let failedTarget = state.beginInterrupt()
        state.abandonInterrupt(failedTarget) // failed/timed-out interrupt before result
        XCTAssertFalse(try state.resolve(result([a])).interrupted)
        state.register(b)
        for malformed: [String: Any] in [
            ["user_message_uuids": [b.uuidString, "invalid"]],
            ["user_message_uuids": Array(repeating: b.uuidString, count: 65)],
            ["user_message_uuids": [b.uuidString], "user_message_uuid": a.uuidString]
        ] {
            XCTAssertThrowsError(try state.resolve(malformed))
            XCTAssertTrue(state.hasOutstanding)
        }
        XCTAssertEqual(try state.resolve(result([b])).inputIDs, [b])
    }

    func testPreEvidenceInterruptDoesNotAssignQueuedInputToUnsolicitedExecution() throws {
        var state = ClaudeNativeTurnCorrelation()
        state.observeInit(initFrame)
        let b = UUID()
        state.register(b)
        let token = state.beginInterrupt()
        XCTAssertFalse(try state.observeActivity(assistant(text: "U")))
        XCTAssertFalse(state.ownsOutput)
        var interruptedResult = result()
        interruptedResult["is_error"] = true
        let completion = try state.resolve(interruptedResult)
        XCTAssertTrue(completion.inputIDs.isEmpty)
        XCTAssertTrue(completion.interrupted)
        XCTAssertFalse(state.isInterruptPending(token))
        XCTAssertEqual(try state.resolve(result([b])).inputIDs, [b])
        let c = UUID()
        state.register(c)
        let noEvidence = state.beginInterrupt()
        state.acknowledgeInterrupt(noEvidence)
        try state.observeActivity(assistant(c))
        XCTAssertFalse(try state.resolve(result([c])).interrupted, "A no-op ACK must not cancel a future execution")
    }

    func testSilentAbortDoesNotRetireQueuedHostInEitherACKOrdering() throws {
        for response in ["ack", "result-first", "timeout"] {
            var state = ClaudeNativeTurnCorrelation()
            state.observeInit(initFrame)
            let b = UUID()
            state.register(b)
            let token = state.beginInterrupt()
            if response == "ack" { state.acknowledgeInterrupt(token) }
            if response == "timeout" { state.abandonInterrupt(token) }
            var aborted = result()
            aborted["subtype"] = "error_during_execution"
            aborted["is_error"] = true
            XCTAssertTrue(try state.resolve(aborted).inputIDs.isEmpty)
            XCTAssertTrue(state.hasOutstanding)
            XCTAssertEqual(try state.resolve(result([b])).inputIDs, [b])
        }
    }

    func testProtocolFailureFencesFollowingSuccessInSameRecoveredBurst() async throws {
        let controller = await controller()
        try await feed(initFrame, to: controller)
        let b = try await controller.sendUserMessage("B")
        var malformed = result([b])
        malformed["user_message_uuids"] = [b.uuidString, "invalid"]
        var burst = try JSONSerialization.data(withJSONObject: malformed)
        try burst.append(JSONSerialization.data(withJSONObject: result([b], text: "must not appear")))
        await controller.test_receiveConfigurationResponseLine(burst)
        let events = await failureEvents(controller)
        let answers = completions(events)
        XCTAssertEqual(answers.map(\.0), [[b]])
        guard let answer = answers.first else { return }
        if case .failed = answer.1 {} else { XCTFail("Protocol failure cannot later become success") }
        XCTAssertFalse(events.contains { if case let .stream(value) = $0 { return value.text == "must not appear" }
            return false
        })
    }

    func testMissingAnswerIdentityFailsKnownCommandAndSessionErrorWithoutHanging() async throws {
        for knownCommand in [true, false] {
            let controller = await controller()
            try await feed(initFrame, to: controller)
            let b = try await controller.sendUserMessage("synthetic input")
            if knownCommand {
                try await feed(["type": "command_lifecycle", "state": "started", "command_uuid": b.uuidString], to: controller)
            }
            var missing = result()
            missing["is_error"] = !knownCommand
            try await feed(missing, to: controller)
            let events = await failureEvents(controller)
            XCTAssertEqual(completions(events).map(\.0), [[b]])
            if case .failed = completions(events).first?.1 {} else { XCTFail("Missing answer identity is finite protocol failure") }
        }
    }

    func testAbsentIdentityFormsAndTransportResetDoNotCreateAHostOwner() async throws {
        for payload: [String: Any] in [
            ["user_message_uuid": NSNull()], ["user_message_uuids": NSNull()], ["user_message_uuids": []]
        ] {
            XCTAssertNil(try ClaudeNativeTurnCorrelation.inputIDs(payload))
        }
        let controller = await controller()
        try await feed(initFrame, to: controller)
        _ = await finish(controller)
        await controller.test_installConfigurationTransport(write: { _ in })
        await controller.ensureEventsStreamReady()
        var prooflessInit = initFrame
        prooflessInit.removeValue(forKey: "capabilities")
        try await feed(prooflessInit, to: controller)
        let b = try await controller.sendUserMessage("resumed input")
        try await feed(result(), to: controller)
        let events = await finish(controller)
        XCTAssertEqual(completions(events).map(\.0), [[b]], "A new transport without capability proof stays legacy")
    }

    private actor InterruptGate {
        private let entered: XCTestExpectation
        private var response: CheckedContinuation<[String: Any], Error>?
        private var releasedFailure: Bool?
        private(set) var didEnter = false

        init(entered: XCTestExpectation) {
            self.entered = entered
        }

        func request() async throws -> [String: Any] {
            didEnter = true
            entered.fulfill()
            // Cleanup can release the gate before a delayed request reaches it.
            if let failed = releasedFailure {
                if failed {
                    throw ClaudeNativeProcessSessionController.ControllerError.controlRequestTimedOut(requestID: "test-interrupt")
                }
                return [:]
            }
            return try await withCheckedThrowingContinuation { continuation in
                response = continuation
            }
        }

        func release(failed: Bool = false) {
            releasedFailure = failed
            if failed {
                response?.resume(throwing: ClaudeNativeProcessSessionController.ControllerError.controlRequestTimedOut(requestID: "test-interrupt"))
            } else { response?.resume(returning: [:]) }
            response = nil
        }
    }

    func testControllerInterruptGlueBindsResultAcrossACKAndEOFOrderings() async throws {
        // Two ACK orderings, timeout after settlement, and EOF while ACK is held.
        for ordering in ["result-before-ack", "ack-before-result", "timeout-after-result", "eof"] {
            let controller = await controller()
            try await feed(initFrame, to: controller)
            let a = try await controller.sendUserMessage("A")
            try await feed(assistant(a), to: controller)
            let b = try await controller.sendUserMessage("B")
            let entered = expectation(description: "Interrupt request enters gate: \(ordering)")
            let gate = InterruptGate(entered: entered)
            await controller.test_setConfigurationControlRequest { _ in try await gate.request() }
            let interrupt = Task { await controller.test_interruptRunningTurn(reason: "synthetic steer") }
            await fulfillment(of: [entered], timeout: 2)
            guard await gate.didEnter else {
                await gate.release(failed: true)
                await controller.shutdown()
                interrupt.cancel()
                _ = await interrupt.value
                continue
            }
            if ordering == "ack-before-result" {
                await gate.release()
                let outcome = await interrupt.value
                XCTAssertEqual(outcome, .acknowledged)
                try await feed(result([a]), to: controller)
            } else {
                if ordering == "eof" { await controller.test_handleStdoutEOF() }
                else { try await feed(result([a]), to: controller) }
                await gate.release(failed: ordering == "timeout-after-result")
                let outcome = await interrupt.value
                XCTAssertEqual(outcome, ordering == "eof" ? .failed : .noTurnInFlight)
            }
            if ordering != "eof" { try await feed(result([b]), to: controller) }
            let events = await finish(controller)
            let answers = completions(events)
            XCTAssertEqual(answers.map(\.0), [[a], [b]], ordering)
            guard answers.count == 2 else { continue }
            if ordering != "eof" {
                if case .cancelled = answers[0].1 {} else { XCTFail("Target A must be cancelled") }
                if case .completed = answers[1].1 {} else { XCTFail("B must not inherit A's interrupt") }
            }
        }
    }

    func testUnownedStampedResultRetiresInterruptWithoutCancellingQueuedHostInputs() async throws {
        for ackFirst in [true, false] {
            for grouped in [false, true] {
                let controller = await controller()
                try await feed(initFrame, to: controller)
                let unowned = UUID()
                try await feed(assistant(), to: controller)
                try await feed(assistant(unowned, text: "unowned activity"), to: controller)
                let b = try await controller.sendUserMessage("B")
                var hostIDs = [b]
                if grouped { try await hostIDs.append(controller.sendUserMessage("C")) }
                let entered = expectation(description: "Interrupt unowned execution: ackFirst=\(ackFirst), grouped=\(grouped)")
                let gate = InterruptGate(entered: entered)
                await controller.test_setConfigurationControlRequest { _ in try await gate.request() }
                let interrupt = Task { await controller.test_interruptRunningTurn(reason: "interrupt provider-owned work") }
                await fulfillment(of: [entered], timeout: 2)
                guard await gate.didEnter else {
                    await gate.release(failed: true)
                    await controller.shutdown()
                    interrupt.cancel()
                    _ = await interrupt.value
                    continue
                }
                if ackFirst {
                    await gate.release()
                    let outcome = await interrupt.value
                    XCTAssertEqual(outcome, .acknowledged)
                }
                try await feed(result([unowned], text: "unowned final"), to: controller)
                let queued = await controller.hasTurnInFlight
                XCTAssertTrue(queued, "U's result cannot settle B or C")
                for id in hostIDs {
                    try await feed(assistant(id), to: controller)
                }
                if !ackFirst {
                    // Even a new host pickup before the old ACK must not inherit U's interrupt.
                    await gate.release()
                    let outcome = await interrupt.value
                    XCTAssertEqual(outcome, .noTurnInFlight)
                }
                try await feed(result(hostIDs, text: "host final"), to: controller)
                try await feed(result([unowned], text: "late unowned final"), to: controller)
                try await feed(result(hostIDs, text: "duplicate host final"), to: controller)
                let pending = await controller.hasTurnInFlight
                XCTAssertFalse(pending)
                let events = await finish(controller)
                let answers = completions(events)
                XCTAssertEqual(answers.map(\.0), [hostIDs], "Only B or the B/C group completes, exactly once")
                if case .completed = answers.first?.1 {} else { XCTFail("Queued host work must not inherit U's cancellation") }
                let output = events.compactMap { event -> String? in
                    if case let .stream(value) = event { return value.text ?? value.reasoning }
                    return nil
                }.joined()
                XCTAssertFalse(output.contains("unowned"))
                XCTAssertFalse(output.contains("duplicate host final"))
                XCTAssertTrue(output.contains("host final"))
            }
        }
    }

    func testLateForeignResultCannotClearInterruptForExecutingHostInput() async throws {
        for ackFirst in [true, false] {
            let controller = await controller()
            try await feed(initFrame, to: controller)
            let retiredUnowned = UUID()
            try await feed(assistant(), to: controller)
            try await feed(assistant(retiredUnowned), to: controller)
            try await feed(result([retiredUnowned]), to: controller)
            let a = try await controller.sendUserMessage("A")
            try await feed(assistant(a), to: controller)
            let b = try await controller.sendUserMessage("B")
            let entered = expectation(description: "Interrupt host A: ackFirst=\(ackFirst)")
            let gate = InterruptGate(entered: entered)
            await controller.test_setConfigurationControlRequest { _ in try await gate.request() }
            let interrupt = Task { await controller.test_interruptRunningTurn(reason: "interrupt host A") }
            await fulfillment(of: [entered], timeout: 2)
            guard await gate.didEnter else {
                await gate.release(failed: true)
                await controller.shutdown()
                interrupt.cancel()
                _ = await interrupt.value
                continue
            }
            if ackFirst {
                await gate.release()
                let outcome = await interrupt.value
                XCTAssertEqual(outcome, .acknowledged)
            }
            // Even foreign activity cannot reidentify an already host-owned execution.
            try await feed(assistant(retiredUnowned), to: controller)
            try await feed(result([retiredUnowned]), to: controller)
            try await feed(result([UUID()]), to: controller)
            try await feed(result([a]), to: controller)
            if !ackFirst {
                await gate.release()
                let outcome = await interrupt.value
                XCTAssertEqual(outcome, .noTurnInFlight)
            }
            try await feed(assistant(b), to: controller)
            try await feed(result([b]), to: controller)
            let events = await finish(controller)
            let answers = completions(events)
            XCTAssertEqual(answers.map(\.0), [[a], [b]])
            guard answers.count == 2 else { continue }
            if case .cancelled = answers[0].1 {} else { XCTFail("Late foreign results cannot clear A's interrupt") }
            if case .completed = answers[1].1 {} else { XCTFail("B must not inherit A's interrupt") }
        }
    }

    @MainActor
    func testGroupedCompletionTraversesRealRunnerConsumer() async throws {
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
        let session = harness.makeSession(agent: .claudeCode)
        harness.host.test_installLiveSession(session)
        let runID = UUID()
        session.installRunID(runID)
        session.runState = .running
        let owner = session.beginRunAttempt(source: "correlation-consumer-test")
        let b = UUID(), c = UUID(), d = UUID()
        session.claudeExpectedTurnIDs = [b, c, d]
        let runner = try ClaudeIntegratedAgentModeRunner(claudeCoordinator: harness.host.claudeCoordinator, hooks: XCTUnwrap(harness.hooks), terminalCommitBarrier: AgentRunTerminalCommitBarrier())
        let partial = await runner.testConsumeQuietEvents([.turnsCompleted(turnIDs: [b, c], status: .completed)], session: session, runID: runID, owner: owner)
        XCTAssertFalse(partial)
        XCTAssertEqual(session.claudeExpectedTurnIDs, [d])
        let terminal = await runner.testConsumeQuietEvents([.turnsCompleted(turnIDs: [d], status: .completed)], session: session, runID: runID, owner: owner)
        XCTAssertTrue(terminal)
    }

    @MainActor
    func testRunnerRetainsStrongestUnprotectedOutcomeAcrossCompletionOrders() async throws {
        typealias Status = ClaudeNativeProcessSessionController.TurnStatus
        let cases: [(Status, Status, Status)] = [
            (.failed, .completed, .failed), (.completed, .failed, .failed),
            (.cancelled, .completed, .cancelled), (.completed, .cancelled, .cancelled),
            (.failed, .cancelled, .failed), (.cancelled, .failed, .failed)
        ]
        for (first, second, expected) in cases {
            let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
            let session = harness.makeSession(agent: .claudeCode)
            harness.host.test_installLiveSession(session)
            let runID = UUID()
            session.installRunID(runID)
            session.runState = .running
            let owner = session.beginRunAttempt(source: "mixed-outcome-consumer-test")
            let b = UUID(), c = UUID()
            session.claudeExpectedTurnIDs = [b, c]
            let runner = try ClaudeIntegratedAgentModeRunner(claudeCoordinator: harness.host.claudeCoordinator, hooks: XCTUnwrap(harness.hooks), terminalCommitBarrier: AgentRunTerminalCommitBarrier())
            let actual = await runner.testConsumeTurnStatus([
                .turnsCompleted(turnIDs: [b], status: first),
                .turnsCompleted(turnIDs: [c], status: second)
            ], session: session, runID: runID, owner: owner)
            switch (actual, expected) {
            case (.failed, .failed), (.cancelled, .cancelled): break
            default: XCTFail("Outcomes \(first), \(second) must settle as \(expected), not \(actual)")
            }
            XCTAssertTrue(session.claudeExpectedTurnIDs.isEmpty, "One consumer invocation must settle both inputs")
        }
    }

    @MainActor
    func testRunnerExcludesProtectedPredecessorOutcomesFromAggregate() async throws {
        let predecessorStatuses: [ClaudeNativeProcessSessionController.TurnStatus] = [.failed, .cancelled]
        for explicitlyProtected in [true, false] {
            for predecessorStatus in predecessorStatuses {
                let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
                let session = harness.makeSession(agent: .claudeCode)
                harness.host.test_installLiveSession(session)
                let runID = UUID()
                session.installRunID(runID)
                session.runState = .running
                let owner = session.beginRunAttempt(source: "protected-outcome-consumer-test")
                let predecessor = UUID(), b = UUID(), c = UUID()
                session.claudeExpectedTurnIDs = [predecessor, b, c]
                if explicitlyProtected { session.claudeSupersedingProtectedTurnIDs = [predecessor] }
                session.pendingSupersedingTurnCompletions = 1
                let runner = try ClaudeIntegratedAgentModeRunner(claudeCoordinator: harness.host.claudeCoordinator, hooks: XCTUnwrap(harness.hooks), terminalCommitBarrier: AgentRunTerminalCommitBarrier())
                let actual = await runner.testConsumeTurnStatus([
                    .turnsCompleted(turnIDs: [predecessor], status: predecessorStatus),
                    .turnsCompleted(turnIDs: [b], status: .completed),
                    .turnsCompleted(turnIDs: [c], status: .completed)
                ], session: session, runID: runID, owner: owner)
                if case .completed = actual {} else {
                    XCTFail("Protected predecessor \(predecessorStatus) must not poison successful replacements")
                }
                XCTAssertTrue(session.claudeExpectedTurnIDs.isEmpty)
                XCTAssertTrue(session.claudeSupersedingProtectedTurnIDs.isEmpty)
                XCTAssertEqual(session.pendingSupersedingTurnCompletions, 0)
            }
        }
    }

    @MainActor
    func testRunnerSettlesGroupBeforeTerminalDecision() {
        let b = UUID(), c = UUID(), d = UUID()
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.claudeExpectedTurnIDs = [b, c, d]
        XCTAssertEqual(ClaudeIntegratedAgentModeRunner.settleCompletedTurnIDs([b, c], session: session), false)
        XCTAssertEqual(session.claudeExpectedTurnIDs, [d])
        XCTAssertEqual(ClaudeIntegratedAgentModeRunner.settleCompletedTurnIDs([c, d], session: session), true)
        session.claudeExpectedTurnIDs = [b, c]
        session.claudeSupersedingProtectedTurnIDs = [b]
        session.pendingSupersedingTurnCompletions = 1
        XCTAssertEqual(ClaudeIntegratedAgentModeRunner.settleCompletedTurnIDs([b, c], session: session), true)
        XCTAssertEqual(session.pendingSupersedingTurnCompletions, 0)
        XCTAssertTrue(session.claudeExpectedTurnIDs.isEmpty)
        XCTAssertNil(ClaudeIntegratedAgentModeRunner.settleCompletedTurnIDs([b], session: session))
        session.claudeExpectedTurnIDs = [b, c]
        XCTAssertEqual(ClaudeIntegratedAgentModeRunner.settleCompletedTurnIDs([b], session: session, waitForAllUnprotected: false), true, "Legacy settlement keeps its prior first-unprotected boundary")
    }
}
