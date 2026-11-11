import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
@testable import RepoPromptApp
import RepoPromptClaudeProvider
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
            host: ClaudeNativeSessionAppHost(),
            runID: UUID(), tabID: UUID(), windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false")
        )
        await controller.ensureEventsStreamReady()
        let stream = await controller.events
        let wire = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour","resetsAt":1900000300}}"# + "\n"
        await controller.test_handleConfigurationStdoutChunk(Data(wire.utf8))
        await controller.shutdown()
        var received: [ClaudeProviderQuotaObservation] = []
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
        if let observation = received.first {
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
        ) async throws -> ClaudeCompatiblePluginLaunchEnvironment {
            requestedModels.append(requestedModel)
            guard requestedModel != "glm-5-turbo:xhigh" else {
                throw ResolverError.unsupportedModel
            }
            return ClaudeCompatiblePluginLaunchEnvironment(
                effectiveModel: "sonnet",
                environmentOverrides: [:],
                backendID: .glmZAI
            )
        }
    }

    func testNativeFlagResolutionPassesEncodedGLMModelToResolver() async throws {
        let resolver = RecordingLaunchEnvironmentResolver()
        let controller = ClaudeNativeProcessSessionController(
            host: ClaudeNativeSessionAppHost(),
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
            host: ClaudeNativeSessionAppHost(),
            runID: UUID(),
            tabID: UUID(),
            windowID: 1,
            workspacePath: nil,
            config: .discovery(
                commandName: "/usr/bin/false",
                runtimeVariant: .glm
            )
        )
        let directGLM = ClaudeCompatiblePluginLaunchEnvironment(
            effectiveModel: "sonnet",
            environmentOverrides: [
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5-turbo",
                "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5-turbo"
            ],
            backendID: .glmZAI,
            suppressesEffortSettings: true
        )
        let slotGLM = ClaudeCompatiblePluginLaunchEnvironment(
            effectiveModel: "sonnet",
            environmentOverrides: [
                "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-4.7",
                "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-4.7"
            ],
            backendID: .glmZAI,
            suppressesEffortSettings: true
        )
        let sameEnvironmentDifferentFlagModel = ClaudeCompatiblePluginLaunchEnvironment(
            effectiveModel: "opus",
            environmentOverrides: directGLM.environmentOverrides,
            backendID: .glmZAI,
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

        for backendID: ClaudeCompatiblePluginBackendID? in [nil, .kimi, .custom] {
            let otherBackend = ClaudeCompatiblePluginLaunchEnvironment(
                effectiveModel: directGLM.effectiveModel,
                environmentOverrides: directGLM.environmentOverrides,
                backendID: backendID,
                suppressesEffortSettings: directGLM.suppressesEffortSettings
            )
            let requiresRestart = await controller.test_liveFlagSettingsRequiresProcessRestart(
                activeLaunchEnvironment: directGLM,
                nextLaunchEnvironment: otherBackend
            )
            XCTAssertTrue(requiresRestart, "Backend identity changes must require a restart")
        }
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

    fileprivate final class WrittenLines: @unchecked Sendable {
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
        func resolve(variant _: ClaudeCodeRuntimeVariant, requestedModel: String?) async throws -> ClaudeCompatiblePluginLaunchEnvironment {
            ClaudeCompatiblePluginLaunchEnvironment(effectiveModel: requestedModel, environmentOverrides: [:], backendID: nil)
        }
    }

    private func applicationController() -> ClaudeNativeProcessSessionController {
        ClaudeNativeProcessSessionController(
            host: ClaudeNativeSessionAppHost(),
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

        func resolve(variant _: ClaudeCodeRuntimeVariant, requestedModel: String?) async throws -> ClaudeCompatiblePluginLaunchEnvironment {
            calls += 1
            let reject = rejectFirst && calls == 1
            _ = await gate.respond()
            if reject { throw ResolverError.unsupportedModel }
            return ClaudeCompatiblePluginLaunchEnvironment(effectiveModel: requestedModel, environmentOverrides: [:], backendID: nil)
        }
    }

    func testSupersessionDuringResolutionNeverWritesStaleSettings() async throws {
        let gate = ApplicationGate()
        let controller = ClaudeNativeProcessSessionController(
            host: ClaudeNativeSessionAppHost(),
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
            host: ClaudeNativeSessionAppHost(),
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
                stageClaudeResumeRecoveryHandoff: { _ in true }, prependPendingHandoff: { text, _ in text },
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

        let match = try XCTUnwrap(ClaudeNativeSessionAppHost().repoPromptPermissionMatch(
            toolName: "mcp__RepoPromptCE__read_file",
            requestPayload: repoPromptPayload
        ))
        XCTAssertEqual(match.source, MCPIntegrationHelper.RepoPromptPermissionAutoApprovalMatch.Source.topLevelToolName.rawValue)
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
        XCTAssertNil(ClaudeNativeSessionAppHost().repoPromptPermissionMatch(
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
            XCTAssertNil(ClaudeNativeSessionAppHost().repoPromptPermissionMatch(
                toolName: tool,
                requestPayload: ["tool_name": tool, "input": ["op": operation]]
            ), "bare top-level name without provenance: \(tool)")
            let match = ClaudeNativeSessionAppHost().repoPromptPermissionMatch(
                toolName: qualifiedTool,
                requestPayload: payload
            )
            XCTAssertEqual(match?.source, MCPIntegrationHelper.RepoPromptPermissionAutoApprovalMatch.Source.topLevelToolName.rawValue, tool)
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

        let metadataMatch = ClaudeNativeSessionAppHost().repoPromptPermissionMatch(
            toolName: "",
            requestPayload: ["server_name": "RepoPromptCE"]
        )
        XCTAssertEqual(metadataMatch?.source, MCPIntegrationHelper.RepoPromptPermissionAutoApprovalMatch.Source.serverIdentifier.rawValue)
        XCTAssertEqual(metadataMatch?.serverIdentifier, "RepoPromptCE")
        XCTAssertNil(metadataMatch?.normalizedToolName)

        XCTAssertNil(ClaudeNativeSessionAppHost().repoPromptPermissionMatch(
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

final class ClaudeNativeRunnerSettlementTests: XCTestCase {
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
        typealias Status = NativeAgentRuntimeTurnStatus
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
        let predecessorStatuses: [NativeAgentRuntimeTurnStatus] = [.failed, .cancelled]
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

@MainActor
final class ClaudeNativeProviderTurnLifecycleTests: XCTestCase {
    private struct Fixture {
        let harness: AgentSessionLinkRunnerHarness
        let session: AgentTabSession
        let controller: ClaudeNativeProcessSessionController
        let listener: ClaudeControllerEventListener
    }

    private func fixture(mcp: Bool = false, write: @escaping @Sendable (Data) throws -> Void = { _ in }) async throws -> Fixture {
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() })
        let session = harness.host.session(for: UUID())
        // A live provider conversation already has a persistent runtime writer, whether or
        // not its turn is MCP-controlled. Unbound local creation is covered separately.
        let persistentSessionID = UUID()
        XCTAssertNil(harness.host.runtimeSessionStore.bindingRejection(persistentSessionID, on: session))
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: persistentSessionID, workspaceID: UUID()))
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        XCTAssertNotNil(try harness.host.runtimeCommand(sessionID: persistentSessionID))
        let controlledSessionID = mcp ? persistentSessionID : nil
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        session.runState = .completed
        let runID = UUID()
        session.installRunID(runID)
        let controller = ClaudeNativeProcessSessionController(
            host: ClaudeNativeSessionAppHost(),
            runID: runID, tabID: session.tabID, windowID: 1, workspacePath: nil,
            config: .discovery(commandName: "/usr/bin/false")
        )
        await controller.test_installConfigurationTransport(write: write)
        session.claudeController = controller
        if let id = controlledSessionID {
            let registration = await AgentRunSessionStore.register(sessionID: id)
            session.mcpControlContext = try .init(
                sessionID: id,
                activationID: UUID(),
                writerIdentity: controlWriterIdentity(for: session),
                registration: registration,
                currentEpoch: nil,
                preparedEpoch: nil,
                pendingEpochTransition: nil,
                originatingConnectionID: nil,
                interactionTransport: .mcp(sessionID: id, originatingConnectionID: nil),
                suppressUserNotifications: true,
                forceAutoEditEnabled: false,
                autoEditEnabledBeforeOverride: false,
                taskLabelKind: .pair, autoEditOverride: nil
            )
        }
        let installed = await harness.host.claudeCoordinator.test_installEventListener(for: session)
        let listener = try XCTUnwrap(installed)
        try await feed(["type": "system", "subtype": "init", "claude_code_version": "2.1.292", "capabilities": ["msg_lifecycle_v1"]], controller)
        return Fixture(harness: harness, session: session, controller: controller, listener: listener)
    }

    private func cleanup(_ fixture: Fixture) async {
        await fixture.harness.host.claudeCoordinator.shutdownClaudeSession(fixture.session)
        if let context = fixture.session.mcpControlContext { await AgentRunSessionStore.cleanup(registration: context.registration) }
        fixture.harness.host.mcpRuntime.test_afterEpochBegan = nil
    }

    private func feed(_ payload: [String: Any], _ controller: ClaudeNativeProcessSessionController) async throws {
        try await controller.test_receiveConfigurationResponseLine(JSONSerialization.data(withJSONObject: payload))
    }

    private func assistant(_ text: String) -> [String: Any] {
        ["type": "assistant", "message": ["id": UUID().uuidString, "role": "assistant", "content": [["type": "text", "text": text]]]]
    }

    private func result(_ text: String = "done") -> [String: Any] {
        ["type": "result", "subtype": "success", "result": text, "usage": ["input_tokens": 5, "output_tokens": 7]]
    }

    private func until(_ message: String, timeout: Duration = .seconds(5), _ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !predicate(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(predicate(), message)
    }

    func testTwoProviderAttemptsKeepProcessAndPublishRelatedEpochsWithoutUserRows() async throws {
        let f = try await fixture(mcp: true)
        let runID = f.session.runID
        var epochs: [AgentRunTurnEpoch] = []
        for index in 0 ..< 2 {
            try await feed(assistant("provider-\(index)"), f.controller)
            await until("provider work adopts") { f.session.runState == .running }
            let owner = try XCTUnwrap(f.session.activeRunOwnership)
            try epochs.append(XCTUnwrap(owner.turnEpoch))
            XCTAssertEqual(f.session.runID, runID)
            XCTAssertEqual(f.session.activeNonCodexTurnTokenAccumulator?.estimatedUserInputTokens, 0)
            XCTAssertFalse(f.session.items.contains { $0.kind == .user })
            if case .none = f.session.terminalAnchor(for: owner) {} else { XCTFail("Pure provider attempt has no user anchor") }
            try await feed(result("provider-final-\(index)"), f.controller)
            await until("terminal publication completes") { f.session.runState == .completed && !f.session.runLifecycle.terminalCommitInProgress }
            guard case .accepted = f.session.runLifecycle.lastTerminalPublicationResult else { XCTFail("Epoch must accept exactly one terminal")
                break
            }
            XCTAssertNil(f.session.agentTask)
            XCTAssertTrue(f.session.pendingTurnRuntimeAnchors.isEmpty)
        }
        XCTAssertEqual(epochs.count, 2)
        XCTAssertNotEqual(epochs.first?.id, epochs.last?.id)
        XCTAssertEqual(epochs.map(\.transitionKind), [.relatedFollowUp, .relatedFollowUp])
        XCTAssertEqual(epochs.first?.continuityGeneration, epochs.last?.continuityGeneration)
        XCTAssertTrue(f.session.items.contains { $0.text.contains("provider-final-0") })
        XCTAssertTrue(f.session.items.contains { $0.text.contains("provider-final-1") })
        XCTAssertFalse(f.listener.isBusy)
        await cleanup(f)
    }

    func testFinalOnlyProviderReplyDoesNotReplaceCompletedAssistant() async throws {
        let f = try await fixture()
        f.session.appendItem(.user("earlier question", sequenceIndex: f.session.nextSequenceIndex))
        let previous = AgentChatItem.assistant("earlier answer", sequenceIndex: f.session.nextSequenceIndex)
        f.session.appendItem(previous)
        let providerInput = UUID()
        try await feed(["type": "command_lifecycle", "state": "started", "command_uuid": providerInput.uuidString], f.controller)
        await until("provider turn is adopted") { f.session.runState == .running }
        try await feed([
            "type": "result", "subtype": "success", "result": "new provider answer",
            "user_message_uuid": providerInput.uuidString
        ], f.controller)
        await until("provider attempt completes") { f.session.runState == .completed && f.session.agentTask == nil }
        XCTAssertEqual(f.session.items.first(where: { $0.id == previous.id })?.text, previous.text)
        XCTAssertEqual(f.session.items.count(where: { $0.kind == .user }), 1)
        let answers = f.session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(answers.count, 2)
        XCTAssertNotEqual(answers.last?.id, previous.id)
        XCTAssertEqual(answers.last?.text, "new provider answer")
        await cleanup(f)
    }

    func testApprovalFirstAdoptsBeforePermissionAndStopRetiresListener() async throws {
        let f = try await fixture()
        try await feed(["type": "control_request", "request_id": "permission-first", "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "echo fixture"]]], f.controller)
        await until("Approval-first cannot hang invisibly") { f.session.runState == .waitingForApproval }
        if case let .claudeControl(receipt) = f.session.pendingApproval?.requestID {
            XCTAssertNotNil(UUID(uuidString: receipt))
        } else { XCTFail("Expected an opaque Claude approval response receipt") }
        XCTAssertEqual(f.session.pendingApproval?.itemID, "permission-first")
        XCTAssertNotNil(f.session.activeRunOwnership)
        await f.harness.host.cancelAgentRun(tabID: f.session.tabID, completion: .terminalTeardownCompleted)
        XCTAssertEqual(f.session.runState, .cancelled)
        XCTAssertNil(f.session.claudeController)
        XCTAssertNil(f.listener.subscription)
        XCTAssertFalse(f.listener.isBusy)
        try await feed(assistant("late"), f.controller)
        XCTAssertEqual(f.session.runState, .cancelled)
        await cleanup(f)
    }

    func testNoiseSubagentsAndReconnectWithoutReplayDoNotCreateAttempts() async throws {
        let f = try await fixture()
        let historical = AgentChatItem.error("persisted history", sequenceIndex: f.session.nextSequenceIndex)
        f.session.appendItem(historical)
        var child = assistant("child")
        child["parent_tool_use_id"] = "parent-tool"
        for frame in [child, ["type": "system", "subtype": "task_notification"], ["type": "system", "subtype": "task_progress"], ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "orphan", "content": "tool output"]]]]] {
            try await feed(frame, f.controller)
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertNil(f.session.activeRunOwnership)
        XCTAssertEqual(f.session.items.map(\.id), [historical.id])
        let repeated = await f.harness.host.claudeCoordinator.test_installEventListener(for: f.session)
        XCTAssertTrue(repeated === f.listener)
        await f.controller.resetEventsStreamForNewRun()
        let replacement = await f.harness.host.claudeCoordinator.test_installEventListener(for: f.session)
        XCTAssertTrue(replacement === f.listener)
        XCTAssertEqual(f.session.items.map(\.id), [historical.id])
        try await feed(assistant("new live work"), f.controller)
        try await feed(result("new live work final"), f.controller)
        await until("Only live work is admitted") { f.session.lastTerminalCommitRevision != nil }
        XCTAssertEqual(f.session.items.count(where: { $0.text.contains("new live work") }), 1)
        await cleanup(f)
    }

    func testSameChunkTailSurvivesTerminalAndAttemptCancellationDoesNotKillReader() async throws {
        let f = try await fixture()
        try await feed(assistant("one"), f.controller)
        await until("first starts") { f.session.runState == .running }
        let first = f.session.activeRunOwnership
        // A single controller ingress hop leaves no runner scheduling opportunity between frames.
        let frames = try [result("one-final"), assistant("two"), result("two-final")].map { try JSONSerialization.data(withJSONObject: $0) + Data([10]) }.reduce(Data(), +)
        await f.controller.test_handleConfigurationStdoutChunk(frames)
        await until("next execution survives unread-tail handback") { f.session.lastTerminalCommitRevision?.ownership != first && f.session.lastTerminalCommitRevision != nil && f.session.runState == .completed }
        XCTAssertTrue(f.session.items.contains { $0.text.contains("one") })
        XCTAssertTrue(f.session.items.contains { $0.text.contains("two") })
        XCTAssertNil(f.listener.subscription)
        await cleanup(f)
    }

    func testConsumedProviderStartKeepsHostAttemptAliveThroughDeferredCompletion() async throws {
        let (h, session, controller, listener) = try await spyFixture()
        let row = AgentChatItem.user("host A", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(row)
        let service = h.host.test_initializeRunService(expectedPIDPolicyArmer: { _ in true })
        await h.host.test_composeRunService(service).startRun(
            tabID: session.tabID, session: session, initialUserMessage: row.text,
            initialMessageForRun: row.text, attachments: [], initialUserItemID: row.id
        )
        await until("host input is registered") { !session.claudeExpectedTurnIDs.isEmpty }
        let hostID = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
        let providerID = UUID()
        var deliveredStart = false
        listener.test_onDelivery = { event in
            if case .providerTurnStarted = event { deliveredStart = true }
        }
        // The controller has already resolved A, but its completion is deferred until idle/fallback.
        await controller.emit(.stream(.init(type: "final_content", text: "host answer")))
        await controller.emit(.providerTurnStarted(turnID: providerID))
        await until("U's start was consumed by A's inbox") { deliveredStart }
        await controller.emit(.turnsCompleted(turnIDs: [hostID], status: .completed))
        await until("A's completion is consumed") { !session.claudeExpectedTurnIDs.contains(hostID) }
        XCTAssertTrue(session.runState.isActive, "U must retain an owner after A completes")
        await controller.emit(.approvalRequest(.init(
            requestID: .claudeControl("provider-approval"), method: "control/can_use_tool",
            kind: .commandExecution, threadID: "fixture", turnID: providerID.uuidString, itemID: "tool"
        )))
        await until("U's approval is presented") { session.runState == .waitingForApproval }
        XCTAssertEqual(session.pendingApproval?.requestID, .claudeControl("provider-approval"))
        await controller.emit(.stream(.init(type: "final_content", text: "provider output")))
        await controller.emit(.turnsCompleted(turnIDs: [providerID], status: .completed))
        await until("provider work settles once") { session.runState == .completed && session.agentTask == nil }
        XCTAssertTrue(session.items.contains { $0.kind == .assistant && $0.text == "host answer" })
        XCTAssertEqual(session.items.count(where: { $0.text.contains("provider output") }), 1)
        XCTAssertEqual(session.items.count(where: { $0.kind == .assistant }), 2)
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testChainedConsumedProviderStartsKeepTheSameOwner() async throws {
        let (h, session, controller, _) = try await spyFixture()
        let row = AgentChatItem.user("host A", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(row)
        let service = h.host.test_initializeRunService(expectedPIDPolicyArmer: { _ in true })
        await h.host.test_composeRunService(service).startRun(
            tabID: session.tabID, session: session, initialUserMessage: row.text,
            initialMessageForRun: row.text, attachments: [], initialUserItemID: row.id
        )
        await until("host input is registered") { !session.claudeExpectedTurnIDs.isEmpty }
        let hostID = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
        let firstProviderID = UUID()
        let secondProviderID = UUID()
        await controller.emit(.providerTurnStarted(turnID: firstProviderID))
        await until("first provider start is consumed") { session.claudeExpectedTurnIDs.contains(firstProviderID) }
        await controller.emit(.turnsCompleted(turnIDs: [hostID], status: .completed))
        await until("host result is retained for provider work") { !session.claudeExpectedTurnIDs.contains(hostID) }
        XCTAssertTrue(session.runState.isActive)
        await controller.emit(.providerTurnStarted(turnID: secondProviderID))
        await until("second provider start is consumed") { session.claudeExpectedTurnIDs.contains(secondProviderID) }
        await controller.emit(.turnsCompleted(turnIDs: [firstProviderID], status: .completed))
        await until("first provider completion is consumed") { !session.claudeExpectedTurnIDs.contains(firstProviderID) }
        XCTAssertTrue(session.runState.isActive)
        await controller.emit(.stream(.init(type: "final_content", text: "second provider answer")))
        await controller.emit(.turnsCompleted(turnIDs: [secondProviderID], status: .completed))
        await until("second provider work settles") { session.runState == .completed && session.agentTask == nil }
        XCTAssertEqual(session.items.count(where: { $0.kind == .assistant && $0.text == "second provider answer" }), 1)
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testSteeringRetainedProviderSuccessorDoesNotCancelReplacement() async throws {
        for successorFinishesBeforeSend in [true, false] {
            let (h, session, controller, _) = try await spyFixture()
            let row = AgentChatItem.user("host A", sequenceIndex: session.nextSequenceIndex)
            session.appendItem(row)
            let service = h.host.test_initializeRunService(expectedPIDPolicyArmer: { _ in true })
            await h.host.test_composeRunService(service).startRun(
                tabID: session.tabID, session: session, initialUserMessage: row.text,
                initialMessageForRun: row.text, attachments: [], initialUserItemID: row.id
            )
            await until("host input is registered") { !session.claudeExpectedTurnIDs.isEmpty }
            let hostID = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
            let providerID = UUID()
            await controller.emit(.providerTurnStarted(turnID: providerID))
            await controller.emit(.turnsCompleted(turnIDs: [hostID], status: .completed))
            await until("host completion is retained") { !session.claudeExpectedTurnIDs.contains(hostID) }
            XCTAssertTrue(session.runState.isActive)
            await controller.setTurnInFlight(true)
            await controller.setInterruptedTurnID(providerID)
            let gate = Gate()
            await controller.setSendSuspension { await gate.wait() }
            try queueSteer("replacement B", in: session, service: h.service)
            let accepted = await h.service.submitQueuedClaudeSteeringIfSupported(session: session)
            XCTAssertTrue(accepted)
            await until("replacement write is held") { gate.isWaiting }
            if successorFinishesBeforeSend {
                await controller.emit(.turnsCompleted(turnIDs: [providerID], status: .cancelled))
                await until("interrupted provider completes") { !session.claudeExpectedTurnIDs.contains(providerID) }
                XCTAssertTrue(session.runState.isActive)
            }
            gate.open()
            await until("replacement input is registered") { !session.claudeExpectedTurnIDs.isEmpty }
            if !successorFinishesBeforeSend {
                await controller.emit(.turnsCompleted(turnIDs: [providerID], status: .cancelled))
                await until("interrupted provider completes") { !session.claudeExpectedTurnIDs.contains(providerID) }
                XCTAssertTrue(session.runState.isActive)
            }
            await controller.completeLastTurn(status: .completed)
            await until("replacement completes") { session.runState == .completed && session.agentTask == nil }
            XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .completed)
            await h.host.claudeCoordinator.shutdownClaudeSession(session)
        }
    }

    func testAcceptedReplacementSurvivesQueuedNoWriteSteerAfterProviderCancellation() async throws {
        let (h, session, controller, _) = try await spyFixture()
        let row = AgentChatItem.user("host A", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(row)
        let service = h.host.test_initializeRunService(expectedPIDPolicyArmer: { _ in true })
        await h.host.test_composeRunService(service).startRun(
            tabID: session.tabID, session: session, initialUserMessage: row.text,
            initialMessageForRun: row.text, attachments: [], initialUserItemID: row.id
        )
        await until("A registers") { !session.claudeExpectedTurnIDs.isEmpty }
        let hostID = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
        let providerID = UUID()
        await controller.emit(.providerTurnStarted(turnID: providerID))
        await until("U starts inside A's inbox") { session.claudeExpectedTurnIDs.contains(providerID) }
        await controller.emit(.turnsCompleted(turnIDs: [hostID], status: .completed))
        await until("A completes while U remains") { !session.claudeExpectedTurnIDs.contains(hostID) }
        XCTAssertTrue(session.runState.isActive)
        XCTAssertTrue(session.claudeExpectedTurnIDs.contains(providerID))
        await controller.setTurnInFlight(true)
        await controller.setInterruptedTurnID(providerID)
        try queueSteer("replacement B", in: session, service: h.service)
        let acceptedB = await h.service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(acceptedB)
        await until("B registers") { !session.claudeExpectedTurnIDs.subtracting([providerID]).isEmpty }
        let replacementID = try XCTUnwrap(session.claudeExpectedTurnIDs.subtracting([providerID]).first)
        let gate = Gate()
        h.host.claudeCoordinator.installHostCapabilities(.init(
            isSessionCurrent: { $0 === session }, requestUIRefresh: { _, _ in }, scheduleSave: { _ in },
            stageClaudeResumeRecoveryHandoff: { _ in true }, prependPendingHandoff: { text, _ in text },
            qualifyAgentSessionLinkProviderInputRoute: { _, _ in await gate.wait()
                return .unavailable
            },
            hasCurrentAgentSessionLinkProviderInputRoute: { _, _ in false },
            decorateAgentSessionLinkPrompt: { text, _, _ in .init(text: text, claim: nil, mustAbortDispatch: false) },
            acquireAgentSessionLinkPhysicalDispatch: { _, _ in true }, recordAgentSessionLinkPhysicalDispatchNotAttempted: { _, _ in },
            recordAgentSessionLinkPhysicalDispatchFailure: { _, _ in }, acceptAgentSessionLinkPromptClaim: { _, _, _ in }
        ), providerBindingService: h.host.providerBindingService)
        try queueSteer("refused C", in: session, service: h.service)
        let acceptedC = await h.service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(acceptedC)
        await until("C protects B while waiting on route") {
            gate.isWaiting && session.claudeSupersedingProtectedTurnIDs.contains(replacementID)
        }
        await controller.emit(.turnsCompleted(turnIDs: [providerID], status: .cancelled))
        await controller.emit(.turnsCompleted(turnIDs: [replacementID], status: .completed))
        await until("B result is consumed") { !session.claudeExpectedTurnIDs.contains(replacementID) }
        XCTAssertTrue(session.runState.isActive)
        gate.open()
        await until("refused C releases B") { session.runState == .completed && session.agentTask == nil }
        XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .completed)
        let sentCount = await controller.sentCount
        XCTAssertEqual(sentCount, 2, "Only A and B were written")
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testQueuedSteerBeforeReplacementRegistrationCannotRestoreProviderCancellation() async throws {
        let (h, session, controller, _) = try await spyFixture()
        let row = AgentChatItem.user("host A", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(row)
        let service = h.host.test_initializeRunService(expectedPIDPolicyArmer: { _ in true })
        await h.host.test_composeRunService(service).startRun(
            tabID: session.tabID, session: session, initialUserMessage: row.text,
            initialMessageForRun: row.text, attachments: [], initialUserItemID: row.id
        )
        await until("A registers") { !session.claudeExpectedTurnIDs.isEmpty }
        let hostID = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
        let providerID = UUID()
        await controller.emit(.providerTurnStarted(turnID: providerID))
        await until("U starts inside A's inbox") { session.claudeExpectedTurnIDs.contains(providerID) }
        await controller.emit(.turnsCompleted(turnIDs: [hostID], status: .completed))
        await until("A completes while U remains") { !session.claudeExpectedTurnIDs.contains(hostID) }
        await controller.setTurnInFlight(true)
        let sendGate = Gate()
        await controller.setSendSuspension { await sendGate.wait() }
        try queueSteer("replacement B", in: session, service: service)
        let acceptedB = await service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(acceptedB)
        await until("B send is held before registration") { sendGate.isWaiting }
        let preparationGate = Gate()
        h.host.test_beforeACPToolIdleWait = { await preparationGate.wait() }
        defer { h.host.test_beforeACPToolIdleWait = nil }
        h.host.claudeCoordinator.installHostCapabilities(.init(
            isSessionCurrent: { $0 === session }, requestUIRefresh: { _, _ in }, scheduleSave: { _ in },
            stageClaudeResumeRecoveryHandoff: { _ in true }, prependPendingHandoff: { text, _ in text },
            qualifyAgentSessionLinkProviderInputRoute: { _, _ in .unavailable },
            hasCurrentAgentSessionLinkProviderInputRoute: { _, _ in false },
            decorateAgentSessionLinkPrompt: { text, _, _ in .init(text: text, claim: nil, mustAbortDispatch: false) },
            acquireAgentSessionLinkPhysicalDispatch: { _, _ in true }, recordAgentSessionLinkPhysicalDispatchNotAttempted: { _, _ in },
            recordAgentSessionLinkPhysicalDispatchFailure: { _, _ in }, acceptAgentSessionLinkPromptClaim: { _, _, _ in }
        ), providerBindingService: h.host.providerBindingService)
        try queueSteer("refused C", in: session, service: service)
        let acceptedC = await service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(acceptedC)
        XCTAssertTrue(
            session.pendingClaudeSteeringInstructions.last?.supersedingProtectedTurnIDs.contains(providerID) == true,
            "C claims U before B is accepted"
        )
        sendGate.open()
        await until("B registers and C waits before interrupt") {
            preparationGate.isWaiting && !session.claudeExpectedTurnIDs.subtracting([providerID]).isEmpty
        }
        let replacementID = try XCTUnwrap(session.claudeExpectedTurnIDs.subtracting([providerID]).first)
        XCTAssertTrue(session.claudeSupersedingProtectedTurnIDs.contains(replacementID))
        await controller.emit(.turnsCompleted(turnIDs: [providerID], status: .cancelled))
        await controller.emit(.turnsCompleted(turnIDs: [replacementID], status: .completed))
        await until("U and B results are consumed") { session.claudeExpectedTurnIDs.isEmpty }
        await controller.setTurnInFlight(false)
        preparationGate.open()
        await until("refused C releases only B") { session.runState == .completed && session.agentTask == nil }
        XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .completed)
        let sentCount = await controller.sentCount
        XCTAssertEqual(sentCount, 2, "Only A and B were written")
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testProviderStartAfterReplacementWriteSurvivesDeferredCompletion() async throws {
        let (h, session, controller, _) = try await spyFixture()
        let row = AgentChatItem.user("host A", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(row)
        let service = h.host.test_initializeRunService(expectedPIDPolicyArmer: { _ in true })
        await h.host.test_composeRunService(service).startRun(
            tabID: session.tabID, session: session, initialUserMessage: row.text,
            initialMessageForRun: row.text, attachments: [], initialUserItemID: row.id
        )
        await until("host input is registered") { !session.claudeExpectedTurnIDs.isEmpty }
        let hostID = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
        let firstProviderID = UUID()
        let secondProviderID = UUID()
        await controller.emit(.providerTurnStarted(turnID: firstProviderID))
        await controller.emit(.turnsCompleted(turnIDs: [hostID], status: .completed))
        await until("host result is retained") { !session.claudeExpectedTurnIDs.contains(hostID) }
        await controller.setTurnInFlight(true)
        await controller.setInterruptedTurnID(firstProviderID)
        try queueSteer("replacement B", in: session, service: h.service)
        let accepted = await h.service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(accepted)
        await until("replacement input is registered") {
            !session.claudeExpectedTurnIDs.subtracting(session.claudeSupersedingProtectedTurnIDs).isEmpty
        }
        let replacementID = try XCTUnwrap(session.claudeExpectedTurnIDs.subtracting(session.claudeSupersedingProtectedTurnIDs).first)
        await controller.emit(.turnsCompleted(turnIDs: [firstProviderID], status: .cancelled))
        await until("interrupted provider result is consumed") { !session.claudeExpectedTurnIDs.contains(firstProviderID) }
        await controller.emit(.stream(.init(type: "final_content", text: "replacement answer")))
        await controller.emit(.providerTurnStarted(turnID: secondProviderID))
        await controller.emit(.turnsCompleted(turnIDs: [replacementID], status: .completed))
        await until("replacement completion is retained for later provider work") {
            !session.claudeExpectedTurnIDs.contains(replacementID)
        }
        XCTAssertTrue(session.runState.isActive)
        XCTAssertTrue(session.claudeExpectedTurnIDs.contains(secondProviderID))
        await controller.emit(.stream(.init(type: "final_content", text: "later provider answer")))
        await controller.emit(.turnsCompleted(turnIDs: [secondProviderID], status: .completed))
        await until("later provider work settles") { session.runState == .completed && session.agentTask == nil }
        XCTAssertEqual(session.items.filter { $0.kind == .assistant }.map(\.text), ["replacement answer", "later provider answer"])
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testAdoptedProviderFinalOnlySuccessorKeepsBothAnswers() async throws {
        let (h, session, controller, _) = try await spyFixture()
        let firstProviderID = UUID()
        let secondProviderID = UUID()
        await controller.emit(.providerTurnStarted(turnID: firstProviderID))
        await until("first provider turn is adopted") { session.runState == .running }
        await controller.emit(.stream(.init(type: "final_content", text: "first provider answer")))
        await controller.emit(.providerTurnStarted(turnID: secondProviderID))
        await until("second provider start is consumed") { session.claudeExpectedTurnIDs.contains(secondProviderID) }
        await controller.emit(.turnsCompleted(turnIDs: [firstProviderID], status: .completed))
        await until("first provider result is consumed") { !session.claudeExpectedTurnIDs.contains(firstProviderID) }
        XCTAssertTrue(session.runState.isActive)
        await controller.emit(.stream(.init(type: "final_content", text: "second provider answer")))
        await controller.emit(.turnsCompleted(turnIDs: [secondProviderID], status: .completed))
        await until("second provider work settles") { session.runState == .completed && session.agentTask == nil }
        XCTAssertEqual(session.items.filter { $0.kind == .assistant }.map(\.text), ["first provider answer", "second provider answer"])
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testQueuedSteerDoesNotMergeAdoptedProviderFinalOnlyAnswers() async throws {
        let (h, session, controller, _) = try await spyFixture()
        let firstProviderID = UUID()
        let secondProviderID = UUID()
        await controller.emit(.providerTurnStarted(turnID: firstProviderID))
        await until("first provider turn is adopted") { session.runState == .running }
        try queueSteer("queued replacement", in: session, service: h.service)
        XCTAssertTrue(session.claudeSupersedingProtectedTurnIDs.contains(firstProviderID))
        await controller.emit(.stream(.init(type: "final_content", text: "first provider answer")))
        await controller.emit(.providerTurnStarted(turnID: secondProviderID))
        await controller.emit(.stream(.init(type: "final_content", text: "second provider answer")))
        await until("both final-only answers are visible") {
            session.items.count(where: { $0.kind == .assistant }) == 2
        }
        XCTAssertEqual(session.items.filter { $0.kind == .assistant }.map(\.text), ["first provider answer", "second provider answer"])
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testLaterProviderFailureOrCancellationOutranksDeferredHostSuccess() async throws {
        for status: NativeAgentRuntimeTurnStatus in [.failed, .cancelled] {
            let (h, session, controller, _) = try await spyFixture()
            let row = AgentChatItem.user("host A", sequenceIndex: session.nextSequenceIndex)
            session.appendItem(row)
            let service = h.host.test_initializeRunService(expectedPIDPolicyArmer: { _ in true })
            await h.host.test_composeRunService(service).startRun(
                tabID: session.tabID, session: session, initialUserMessage: row.text,
                initialMessageForRun: row.text, attachments: [], initialUserItemID: row.id
            )
            await until("host input is registered") { !session.claudeExpectedTurnIDs.isEmpty }
            let hostID = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
            let providerID = UUID()
            await controller.emit(.stream(.init(type: "final_content", text: "host answer")))
            await controller.emit(.providerTurnStarted(turnID: providerID))
            await controller.emit(.turnsCompleted(turnIDs: [hostID], status: .completed))
            await until("host result is retained for later provider work") { !session.claudeExpectedTurnIDs.contains(hostID) }
            XCTAssertTrue(session.runState.isActive)
            await controller.emit(.turnsCompleted(turnIDs: [providerID], status: status))
            await until("later provider result publishes") { session.agentTask == nil }
            XCTAssertEqual(session.runState, status == .failed ? .failed : .cancelled)
            await h.host.claudeCoordinator.shutdownClaudeSession(session)
        }
    }

    func testDeferredEmptyHostResultSeparatesLaterProviderDelta() async throws {
        let (h, session, controller, _) = try await spyFixture()
        let row = AgentChatItem.user("host A", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(row)
        let service = h.host.test_initializeRunService(expectedPIDPolicyArmer: { _ in true })
        await h.host.test_composeRunService(service).startRun(
            tabID: session.tabID, session: session, initialUserMessage: row.text,
            initialMessageForRun: row.text, attachments: [], initialUserItemID: row.id
        )
        await until("host input is registered") { !session.claudeExpectedTurnIDs.isEmpty }
        let hostID = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
        let providerID = UUID()
        await controller.emit(.stream(.init(type: "content", text: "host partial")))
        await controller.emit(.providerTurnStarted(turnID: providerID))
        await controller.emit(.turnsCompleted(turnIDs: [hostID], status: .completed))
        await until("deferred A is consumed") { !session.claudeExpectedTurnIDs.contains(hostID) }
        await controller.emit(.stream(.init(type: "content", text: "provider continuation")))
        await controller.emit(.turnsCompleted(turnIDs: [providerID], status: .completed))
        await until("later provider settles") { session.agentTask == nil }
        let answers = session.items.filter { $0.kind == .assistant }
        XCTAssertEqual(answers.map(\.text), ["host partial", "provider continuation"])
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testRefusedEpochDeniesPendingApprovalAndRecordsOnce() async throws {
        let writes = ClaudeNativeApprovalAndResumeTests.WrittenLines()
        let f = try await fixture(mcp: true, write: { writes.append($0) })
        let context = try XCTUnwrap(f.session.mcpControlContext)
        // Replace the store registration without replacing the captured control activation.
        let successor = await AgentRunSessionStore.register(sessionID: context.sessionID)
        try await feed(["type": "control_request", "request_id": "refused-permission", "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "echo fixture"]]], f.controller)
        await until("failed preparation cancels exact provider work") { f.session.claudeController == nil }
        XCTAssertNil(f.session.activeRunOwnership)
        XCTAssertFalse(f.session.mcpFollowUpRunPending)
        XCTAssertNil(f.session.mcpControlContext?.pendingEpochTransition)
        await until("refused permission is explicitly denied") { writes.count == 1 }
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(writes.line(at: 0))) as? [String: Any])
        XCTAssertEqual(frame["type"] as? String, "control_response")
        let response = try XCTUnwrap(frame["response"] as? [String: Any])
        XCTAssertEqual(response["request_id"] as? String, "refused-permission")
        let decision = try XCTUnwrap(response["response"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertEqual(decision["interrupt"] as? Bool, true)
        XCTAssertEqual(f.session.items.count(where: { $0.text == "RepoPrompt stopped Claude work because it could not attach it to this session." }), 1)
        await AgentRunSessionStore.cleanup(registration: successor)
        await cleanup(f)
    }

    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        var isWaiting: Bool {
            continuation != nil
        }

        func wait() async {
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func spyFixture(replacement: MonitorFakeNativeController? = nil, mcp: Bool = false) async throws -> (AgentSessionLinkRunnerHarness, AgentTabSession, MonitorFakeNativeController, ClaudeControllerEventListener) {
        let controller = MonitorFakeNativeController()
        var creations = 0
        let harness = AgentSessionLinkRunnerHarness(headlessProviderFactory: { _, _ in AgentSessionLinkCapturingHeadlessProvider() }, claudeControllerFactory: { _, _, _, _ in
            creations += 1
            return creations > 1 ? replacement ?? controller : controller
        })
        let session = harness.host.session(for: UUID())
        // A live provider conversation already has a persistent runtime writer, whether or
        // not its turn is MCP-controlled. Unbound local creation is covered separately.
        let persistentSessionID = UUID()
        XCTAssertNil(harness.host.runtimeSessionStore.bindingRejection(persistentSessionID, on: session))
        session.installPersistentSessionBinding(.init(tabID: session.tabID, sessionID: persistentSessionID, workspaceID: UUID()))
        session.recordRestorationAuthoritative(.persistedPayloadApplied)
        XCTAssertNotNil(try harness.host.runtimeCommand(sessionID: persistentSessionID))
        let controlledSessionID = mcp ? persistentSessionID : nil
        session.selectedAgent = .claudeCode
        session.hasLoadedPersistedState = true
        session.runState = .completed
        let runID = UUID()
        session.installRunID(runID)
        session.providerSessionID = "monitor-native-session"
        let outcome = await harness.host.claudeCoordinator.ensureClaudeNativeSession(session: session, intent: .reconnect(runID: runID, providerSessionID: "monitor-native-session", currency: session.persistentBindingTransitionToken()))
        XCTAssertEqual(outcome, .ready)
        let installed = await harness.host.claudeCoordinator.test_installEventListener(for: session)
        if let id = controlledSessionID {
            let registration = await AgentRunSessionStore.register(sessionID: id)
            session.mcpControlContext = try .init(
                sessionID: id, activationID: UUID(), writerIdentity: controlWriterIdentity(for: session), registration: registration,
                currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil,
                originatingConnectionID: nil, interactionTransport: .mcp(sessionID: id, originatingConnectionID: nil),
                suppressUserNotifications: true, forceAutoEditEnabled: false, autoEditEnabledBeforeOverride: false, taskLabelKind: .pair, autoEditOverride: nil
            )
        }
        return try (harness, session, controller, XCTUnwrap(installed))
    }

    private func queueSteer(_ text: String, in session: AgentTabSession, service: AgentModeRunService) throws {
        let owner = try XCTUnwrap(session.activeRunOwnership)
        let row = AgentChatItem.user(text, sequenceIndex: session.nextSequenceIndex)
        session.appendItem(row)
        let id = UUID()
        session.pendingClaudeSteeringInstructions.append(.init(
            id: id,
            targetRunID: session.runID,
            targetRunAttemptID: owner.attemptID,
            providerText: text,
            attachments: [],
            taggedFileAttachments: [],
            draftText: text,
            optimisticUserItemID: row.id,
            createdAt: Date()
        ))
        service.protectCurrentClaudeTurnForAcceptedSteeringIfNeeded(session: session, steeringID: id)
    }

    func testViewModelAdoptionRaceAugmentsLocalAttachmentOnceAndDoesNotConvertLaneWake() async throws {
        let (h, session, controller, _) = try await spyFixture(mcp: true)
        let gate = Gate()
        h.host.mcpRuntime.test_afterEpochBegan = { await gate.wait() }
        let providerID = UUID()
        await controller.setTurnInFlight(true)
        await controller.emit(.providerTurnStarted(turnID: providerID))
        await until("provider epoch preparation is held") { gate.isWaiting }
        let row = AgentChatItem.user("local race input", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(row)
        let candidate = session.registerLocalComposerCandidate(itemID: row.id, at: session.items.count - 1)
        let attachmentURL = "https://example.invalid/synthesized-attachment.png"
        let attachment = AgentFileAttachment(source: .url(attachmentURL), title: "synthetic attachment")
        let localOutcome = AgentRunStartOutcomeRecorder()
        let local = Task { @MainActor in
            await h.host.startAgentRun(
                tabID: session.tabID, initialMessage: row.text, attachments: [attachment],
                directStartOptions: .init(localComposerCandidate: candidate, initialUserItemID: row.id),
                startOutcome: localOutcome
            )
        }
        let laneOutcome = AgentRunStartOutcomeRecorder()
        let lane = Task { @MainActor in
            await h.host.startAgentRun(tabID: session.tabID, initialMessage: "", directStartOptions: .laneUpdate(wakeID: UUID()), startOutcome: laneOutcome)
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await controller.setInterruptedTurnID(providerID)
        await controller.setImmediateReplyDuringSend(true)
        gate.open()
        _ = await local.value
        _ = await lane.value
        await until("one local steer completes the adopted owner") { session.runState == .completed && session.agentTask == nil }
        let messages = await controller.sentMessages
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.components(separatedBy: attachmentURL).count, 2, "The attachment is rendered exactly once")
        XCTAssertTrue(messages.first?.contains(row.text) == true)
        XCTAssertEqual(localOutcome.outcome, .accepted)
        XCTAssertFalse(laneOutcome.outcome.didStart)
        XCTAssertEqual(session.items.count { $0.kind == .user }, 1, "The lane wake must not create a synthetic input")
        let owner = try XCTUnwrap(session.lastTerminalCommitRevision?.ownership)
        if case let .exact(id) = session.terminalAnchor(for: owner) { XCTAssertEqual(id, row.id) } else { XCTFail("The transferred real user row owns the terminal anchor") }
        h.host.mcpRuntime.test_afterEpochBegan = nil
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
        if let context = session.mcpControlContext { await AgentRunSessionStore.cleanup(registration: context.registration) }
    }

    func testAlreadyAdoptedLocalSendSteersAndCompetingStartupCannotClaimAcceptance() async throws {
        let (h, session, controller, listener) = try await spyFixture()
        let providerID = UUID()
        await controller.setTurnInFlight(true)
        await controller.emit(.providerTurnStarted(turnID: providerID))
        await until("provider adoption has already finished") { session.runState == .running && listener.adoptionTask == nil }
        let owner = try XCTUnwrap(session.activeRunOwnership)
        let refused = AgentRunStartOutcomeRecorder()
        await h.host.test_composeRunService(h.service).startRun(tabID: session.tabID, session: session, initialUserMessage: "contending startup", initialMessageForRun: "contending startup", attachments: [], startOutcome: refused)
        XCTAssertFalse(refused.outcome.didStart, "Another active owner must not overwrite a startup refusal as accepted")
        XCTAssertEqual(session.activeRunOwnership, owner)
        let row = AgentChatItem.user("local after adoption", sequenceIndex: session.nextSequenceIndex)
        session.appendItem(row)
        let candidate = session.registerLocalComposerCandidate(itemID: row.id, at: session.items.count - 1)
        await controller.setInterruptedTurnID(providerID)
        await controller.setImmediateReplyDuringSend(true)
        let accepted = AgentRunStartOutcomeRecorder()
        _ = await h.host.startAgentRun(tabID: session.tabID, initialMessage: row.text, directStartOptions: .init(localComposerCandidate: candidate, initialUserItemID: row.id), startOutcome: accepted)
        await until("late local send completes the adopted owner") { session.runState == .completed && session.agentTask == nil }
        XCTAssertTrue(accepted.outcome.didStart)
        XCTAssertEqual(session.lastTerminalCommitRevision?.ownership, owner)
        let messages = await controller.sentMessages
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains(row.text))
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testProviderAdoptionCannotCrossWriterIncarnationsDuringEpochPreparation() async throws {
        for change in ["reacquire", "replaceController", "retire"] {
            let retires = change == "retire"
            let replacement = change == "replaceController" ? MonitorFakeNativeController() : nil
            let f = try await fixture(mcp: true)
            let command = try XCTUnwrap(f.harness.host.runtimeCommand(sessionID: XCTUnwrap(f.session.activeAgentSessionID)))
            let writer = command.writer
            let binding = f.session.currentRestorationBindingToken
            let gate = Gate()
            f.harness.host.mcpRuntime.test_afterEpochBegan = { await gate.wait() }
            defer { gate.open()
                f.harness.host.mcpRuntime.test_afterEpochBegan = nil
            }
            try await feed(assistant("provider work held at epoch acknowledgement"), f.controller)
            await until("provider epoch preparation is held") { gate.isWaiting }
            let adoption = try XCTUnwrap(f.listener.adoptionTask)
            XCTAssertTrue(f.session.mcpFollowUpRunPending)
            if retires {
                writer.scope.beginRetirement()
            } else {
                let sessions = writer.scope.sessions
                writer.scope.replaceSessions([:])
                writer.scope.replaceSessions(sessions)
                let successor = try XCTUnwrap(f.harness.host.runtimeCommand(sessionID: writer.identity.sessionID))
                XCTAssertNotEqual(successor.writer.identity, writer.identity)
                // This now belongs to the successor, even with copied binding/context values.
                f.session.mcpFollowUpRunPending = true
                if let replacement { f.session.claudeController = replacement }
            }
            XCTAssertFalse(command.isCurrent)
            XCTAssertEqual(f.session.currentRestorationBindingToken, binding)
            gate.open()
            await adoption.value
            XCTAssertNil(f.session.activeRunOwnership)
            XCTAssertNil(f.listener.subscription)
            XCTAssertNil(f.session.agentTask)
            XCTAssertEqual(
                f.session.runState,
                retires ? .failed : .completed,
                "The still-current retiring writer may refuse; a successor must not receive its failure"
            )
            if retires { XCTAssertNil(f.session.claudeController) }
            else if let replacement {
                XCTAssertTrue(f.session.claudeController === replacement)
                let shutdowns = await replacement.shutdownCount
                XCTAssertEqual(shutdowns, 0, "Old adoption cleanup must never cancel the replacement controller")
            } else { XCTAssertTrue(f.session.claudeController === f.controller) }
            XCTAssertNil(f.listener.pendingProviderTurnID)
            XCTAssertFalse(f.listener.isBusy)
            XCTAssertFalse(f.harness.host.claudeCoordinator.hasPendingProviderWork(for: f.session))
            if !retires {
                let hasTurn = await f.controller.hasTurnInFlight
                XCTAssertFalse(hasTurn, "The exact unadopted controller must not strand provider work")
                XCTAssertFalse(f.session.items.contains { $0.kind == .error })
            }
            XCTAssertEqual(f.session.mcpFollowUpRunPending, !retires)
            XCTAssertEqual(
                f.session.mcpControlContext?.preparedEpoch != nil,
                retires,
                "Only the still-current retiring writer may acknowledge the accepted epoch"
            )
            let epoch = try await AgentRunSessionStore.currentEpoch(for: XCTUnwrap(f.session.mcpControlContext).registration)
            XCTAssertNotNil(epoch, "Domain acceptance is not dispatch permission")
            await cleanup(f)
        }
    }

    func testProviderAdmissionRefusalRetiresPendingPermissionsInsteadOfStrandingThem() async throws {
        for retires in [false, true] {
            let f = try await fixture(mcp: true)
            let command = try XCTUnwrap(f.harness.host.runtimeCommand(sessionID: XCTUnwrap(f.session.activeAgentSessionID)))
            if retires { command.writer.scope.beginRetirement() }
            else { f.session.recordRestorationTerminal(.loadFailed) }
            XCTAssertTrue(command.writer.isCurrent)
            XCTAssertFalse(command.isCurrent)
            try await feed(["type": "control_request", "request_id": "inadmissible-provider", "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "echo fixture"]]], f.controller)
            await until("inadmissible provider permissions are retired") { f.session.claudeController == nil }
            XCTAssertFalse(f.session.mcpFollowUpRunPending)
            XCTAssertEqual(f.session.runState, .failed)
            XCTAssertNil(f.session.activeRunOwnership)
            XCTAssertNil(f.listener.pendingProviderTurnID)
            XCTAssertFalse(f.listener.isBusy)
            let epoch = try await AgentRunSessionStore.currentEpoch(for: XCTUnwrap(f.session.mcpControlContext).registration)
            XCTAssertNil(epoch)
            await cleanup(f)
        }
    }

    func testProviderEpochKeepsControlContextAmbiguityVetoWithoutPresentation() async throws {
        let f = try await fixture(mcp: true)
        let command = try XCTUnwrap(f.harness.host.runtimeCommand(sessionID: XCTUnwrap(f.session.activeAgentSessionID)))
        let writer = command.writer
        let other = writer.scope.makeSession(tabID: UUID())
        other.mcpControlContext = f.session.mcpControlContext
        var sessions = writer.scope.sessions
        sessions[other.tabID] = other
        writer.scope.replaceSessions(sessions)
        XCTAssertTrue(command.isCurrent, "An unbound control-context copy is not a competing persistent writer")
        let refused = await writer.scope.mcp.prepareClaudeProviderEpoch(command: command, fence: .init(session: f.session))
        XCTAssertFalse(refused)
        XCTAssertFalse(f.session.mcpFollowUpRunPending, "A control-context veto must not advertise an admitted follow-up")
        let registration = try XCTUnwrap(f.session.mcpControlContext).registration
        let before = await AgentRunSessionStore.currentEpoch(for: registration)
        XCTAssertNil(before)
        sessions.removeValue(forKey: other.tabID)
        writer.scope.replaceSessions(sessions)
        let attachment = writer.scope.presentation.attach(f.session, sink: .init(activityChanged: { _, _ in }, refresh: { _, _, _ in }, turnComplete: { _ in }, turnFailed: { _, _ in }))
        writer.scope.presentation.detach(attachment)
        let prepared = await writer.scope.mcp.prepareClaudeProviderEpoch(command: command, fence: .init(session: f.session))
        XCTAssertTrue(prepared, "Runtime epoch preparation does not require a presentation sink")
        XCTAssertEqual(f.session.mcpControlContext?.preparedEpoch, f.session.mcpControlContext?.currentEpoch)
        await cleanup(f)
    }

    func testInternalCancellationDuringPendingAdoptionPreservesQueuedLocalWork() async throws {
        let f = try await fixture(mcp: true)
        let gate = Gate()
        f.harness.host.mcpRuntime.test_afterEpochBegan = { await gate.wait() }
        try await feed(assistant("pending provider"), f.controller)
        await until("provider epoch preparation is held") { gate.isWaiting }
        f.session.pendingInstructions.append("queued local input")
        let adoption = f.listener.adoptionTask
        await f.harness.host.cancelAgentRun(tabID: f.session.tabID, origin: .internalLifecycle)
        gate.open()
        await adoption?.value
        XCTAssertEqual(f.session.pendingInstructions.map(\.providerText), ["queued local input"])
        XCTAssertNil(f.session.claudeController)
        XCTAssertFalse(f.listener.isBusy)
        await cleanup(f)
    }

    func testRetiredPreparationInboxCannotLoseFreshProcessAnswer() async throws {
        let replacement = MonitorFakeNativeController()
        let (h, session, _, oldListener) = try await spyFixture(replacement: replacement)
        let oldRunID = session.runID
        let reservation = try XCTUnwrap(h.host.claudeCoordinator.reserveEventsForHostPreparation(for: session))
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
        await replacement.setImmediateReplyDuringSend(true)
        let service = h.host.test_initializeRunService(expectedPIDPolicyArmer: { _ in true })
        await h.host.test_composeRunService(service).startRun(
            tabID: session.tabID, session: session, initialUserMessage: "fresh replacement input",
            initialMessageForRun: "fresh replacement input", attachments: [], preparedClaudeEvents: reservation
        )
        await until("fresh process answer reaches its replacement reservation") { session.runState == .completed && session.agentTask == nil }
        XCTAssertNotEqual(session.runID, oldRunID)
        XCTAssertFalse(oldListener.isCurrent())
        XCTAssertTrue(reservation.subscription.isClosed)
        XCTAssertEqual(session.claudeController.map { ObjectIdentifier($0) }, ObjectIdentifier(replacement))
        XCTAssertTrue(session.items.contains { $0.text.contains("immediate-steer-reply") })
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testHostPreparationReservationOwnsProviderStartBeforeRunnerDispatch() async throws {
        let (h, session, controller, listener) = try await spyFixture()
        let reservation = try XCTUnwrap(h.host.claudeCoordinator.reserveEventsForHostPreparation(for: session))
        var presentedDeniedApproval = false
        listener.test_onDelivery = { event in
            if case .approvalRequest = event { presentedDeniedApproval = true }
        }
        XCTAssertNil(h.host.claudeCoordinator.reserveEventsForHostPreparation(for: session), "A competing startup fails closed without replacing the inbox")
        let providerID = UUID()
        await controller.setTurnInFlight(true)
        await controller.setInterruptedTurnID(providerID)
        await controller.emit(.providerTurnStarted(turnID: providerID))
        await controller.emit(.approvalRequest(.init(requestID: .claudeControl("parked-host-start"), method: "control/can_use_tool", kind: .commandExecution, threadID: "fixture", turnID: providerID.uuidString, itemID: "tool")))
        await until("host-preparation approval is parked") { listener.pendingApprovalIDs == ["parked-host-start"] }
        XCTAssertNil(session.activeRunOwnership, "Async host preparation retains admission; provider work cannot adopt over it")
        XCTAssertNil(listener.adoptionTask)
        XCTAssertTrue(listener.subscription === reservation.subscription)
        await controller.setImmediateReplyDuringSend(true)
        let service = h.host.test_initializeRunService(expectedPIDPolicyArmer: { _ in true })
        await h.host.test_composeRunService(service).startRun(
            tabID: session.tabID, session: session, initialUserMessage: "host start",
            initialMessageForRun: "host start", attachments: [], preparedClaudeEvents: reservation
        )
        await until("host answer completes its sole attempt") { session.runState == .completed && session.agentTask == nil }
        let calls = await controller.inputBoundaryCalls
        XCTAssertEqual(calls, ["permission:parked-host-start:cancel", "interrupt:interrupt", "send"])
        XCTAssertFalse(presentedDeniedApproval)
        XCTAssertNil(session.pendingApproval)
        XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .completed)
        XCTAssertNil(listener.subscription)
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testApprovalSteerProtectsProviderWorkAndImmediateAnswerWaitsForHostIDRegistration() async throws {
        let (h, session, controller, _) = try await spyFixture()
        let providerID = UUID()
        await controller.setTurnInFlight(true)
        await controller.emit(.providerTurnStarted(turnID: providerID))
        await controller.emit(.approvalRequest(.init(requestID: .claudeControl("steer-permission"), method: "control/can_use_tool", kind: .commandExecution, threadID: "fixture", turnID: providerID.uuidString, itemID: "tool")))
        await until("provider approval is visible") { session.runState == .waitingForApproval }
        let owner = try XCTUnwrap(session.activeRunOwnership)
        try queueSteer("replacement instruction", in: session, service: h.service)
        XCTAssertTrue(session.claudeSupersedingProtectedTurnIDs.contains(providerID))
        let gate = Gate()
        await controller.setInterruptedTurnID(providerID)
        await controller.setImmediateReplyDuringSend(true)
        await controller.setSendSuspension { await gate.wait() }
        let accepted = await h.service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(accepted)
        await until("write receipt is held after immediate reply") { gate.isWaiting }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertEqual(session.activeRunOwnership, owner, "An immediate reply cannot outrun expected-ID registration")
        XCTAssertNil(session.pendingApproval)
        XCTAssertEqual(session.runState, .running, "The replacement must not wait on a cancelled approval")
        let calls = await controller.inputBoundaryCalls
        XCTAssertEqual(calls, ["permission:steer-permission:cancel", "interrupt:interrupt", "send"])
        gate.open()
        await until("host result finishes the same attempt") { session.runState == .completed && session.agentTask == nil }
        XCTAssertTrue(session.claudeExpectedTurnIDs.isEmpty)
        XCTAssertEqual(session.lastTerminalCommitRevision?.ownership, owner)
        if case .exact = session.terminalAnchor(for: owner) {} else { XCTFail("A real steer supplies its exact user anchor") }
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testLateApprovalCancellationDoesNotReopenWaitingStateAfterSteer() async throws {
        let (h, session, controller, listener) = try await spyFixture()
        let providerID = UUID()
        await controller.setTurnInFlight(true)
        await controller.emit(.providerTurnStarted(turnID: providerID))
        await controller.emit(.approvalRequest(.init(
            requestID: .claudeControl("late-steer-permission"), method: "control/can_use_tool",
            kind: .commandExecution, threadID: "fixture", turnID: providerID.uuidString, itemID: "tool"
        )))
        await until("provider approval is visible") { session.runState == .waitingForApproval }
        try queueSteer("replacement instruction", in: session, service: h.service)
        await controller.setInterruptedTurnID(providerID)
        let accepted = await h.service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(accepted)
        await until("replacement send is registered") {
            !session.claudeExpectedTurnIDs.subtracting(session.claudeSupersedingProtectedTurnIDs).isEmpty
                && session.pendingApproval == nil
        }
        XCTAssertEqual(session.runState, .running)
        var deliveredLateCancellation = false
        listener.test_onDelivery = { event in
            if case .approvalCancelled = event { deliveredLateCancellation = true }
        }
        await controller.emit(.approvalCancelled(requestID: "late-steer-permission"))
        await until("late cancellation is delivered") { deliveredLateCancellation }
        XCTAssertNil(session.pendingApproval)
        XCTAssertEqual(session.runState, .running)
        await controller.completeLastTurn(status: .completed)
        await until("replacement completes") { session.runState == .completed && session.agentTask == nil }
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testDefinitivelyUnsentSteerReleasesCompletedProviderWork() async throws {
        let (h, session, controller, _) = try await spyFixture()
        let providerID = UUID()
        await controller.setTurnInFlight(true)
        await controller.emit(.providerTurnStarted(turnID: providerID))
        await until("provider starts") { session.runState == .running }
        let gate = Gate()
        // Refuse the real coordinator's route gate, before its physical input boundary.
        h.host.claudeCoordinator.installHostCapabilities(.init(
            isSessionCurrent: { $0 === session }, requestUIRefresh: { _, _ in }, scheduleSave: { _ in },
            stageClaudeResumeRecoveryHandoff: { _ in true }, prependPendingHandoff: { text, _ in text },
            qualifyAgentSessionLinkProviderInputRoute: { _, _ in await gate.wait()
                return .unavailable
            },
            hasCurrentAgentSessionLinkProviderInputRoute: { _, _ in false },
            decorateAgentSessionLinkPrompt: { text, _, _ in .init(text: text, claim: nil, mustAbortDispatch: false) },
            acquireAgentSessionLinkPhysicalDispatch: { _, _ in true }, recordAgentSessionLinkPhysicalDispatchNotAttempted: { _, _ in },
            recordAgentSessionLinkPhysicalDispatchFailure: { _, _ in }, acceptAgentSessionLinkPromptClaim: { _, _, _ in }
        ), providerBindingService: h.host.providerBindingService)
        try queueSteer("never sent", in: session, service: h.service)
        _ = await h.service.submitQueuedClaudeSteeringIfSupported(session: session)
        await until("route qualification is held") { gate.isWaiting }
        await controller.emit(.turnsCompleted(turnIDs: [providerID], status: .completed))
        await until("protected answer is consumed") { session.claudeExpectedTurnIDs.isEmpty }
        XCTAssertEqual(session.runState, .running)
        gate.open()
        await until("definite refusal releases retained answer") { session.runState == .completed && session.agentTask == nil }
        let count = await controller.sentCount
        XCTAssertEqual(count, 0)
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testNoWriteSteerReleasesChainedProviderWorkWithoutHidingHostFailure() async throws {
        for secondCompletesBeforeRefusal in [true, false] {
            let (h, session, controller, _) = try await spyFixture()
            let row = AgentChatItem.user("host A", sequenceIndex: session.nextSequenceIndex)
            session.appendItem(row)
            let service = h.host.test_initializeRunService(expectedPIDPolicyArmer: { _ in true })
            await h.host.test_composeRunService(service).startRun(
                tabID: session.tabID, session: session, initialUserMessage: row.text,
                initialMessageForRun: row.text, attachments: [], initialUserItemID: row.id
            )
            await until("host input is registered") { !session.claudeExpectedTurnIDs.isEmpty }
            let hostID = try XCTUnwrap(session.claudeExpectedTurnIDs.first)
            let firstProviderID = UUID()
            let secondProviderID = UUID()
            await controller.emit(.providerTurnStarted(turnID: firstProviderID))
            await controller.emit(.turnsCompleted(turnIDs: [hostID], status: .failed))
            await until("failed host answer is retained") { !session.claudeExpectedTurnIDs.contains(hostID) }
            XCTAssertTrue(session.runState.isActive)
            let gate = Gate()
            h.host.claudeCoordinator.installHostCapabilities(.init(
                isSessionCurrent: { $0 === session }, requestUIRefresh: { _, _ in }, scheduleSave: { _ in },
                stageClaudeResumeRecoveryHandoff: { _ in true }, prependPendingHandoff: { text, _ in text },
                qualifyAgentSessionLinkProviderInputRoute: { _, _ in await gate.wait()
                    return .unavailable
                },
                hasCurrentAgentSessionLinkProviderInputRoute: { _, _ in false },
                decorateAgentSessionLinkPrompt: { text, _, _ in .init(text: text, claim: nil, mustAbortDispatch: false) },
                acquireAgentSessionLinkPhysicalDispatch: { _, _ in true }, recordAgentSessionLinkPhysicalDispatchNotAttempted: { _, _ in },
                recordAgentSessionLinkPhysicalDispatchFailure: { _, _ in }, acceptAgentSessionLinkPromptClaim: { _, _, _ in }
            ), providerBindingService: h.host.providerBindingService)
            try queueSteer("never sent", in: session, service: h.service)
            let accepted = await h.service.submitQueuedClaudeSteeringIfSupported(session: session)
            XCTAssertTrue(accepted)
            await until("route qualification is held") { gate.isWaiting }
            await controller.emit(.providerTurnStarted(turnID: secondProviderID))
            await controller.emit(.turnsCompleted(turnIDs: [firstProviderID], status: .completed))
            await until("first provider result is consumed") { !session.claudeExpectedTurnIDs.contains(firstProviderID) }
            if secondCompletesBeforeRefusal {
                await controller.emit(.turnsCompleted(turnIDs: [secondProviderID], status: .completed))
                await until("second provider result is consumed") { !session.claudeExpectedTurnIDs.contains(secondProviderID) }
            }
            gate.open()
            if !secondCompletesBeforeRefusal {
                await until("definite refusal releases second provider") {
                    !session.claudeSupersedingProtectedTurnIDs.contains(secondProviderID)
                        && session.claudeSteeringFlushTask == nil
                }
                await controller.emit(.turnsCompleted(turnIDs: [secondProviderID], status: .completed))
            }
            await until("host failure remains authoritative") { session.runState == .failed && session.agentTask == nil }
            let sentCount = await controller.sentCount
            XCTAssertEqual(sentCount, 1, "Only the original host input reached the controller")
            await h.host.claudeCoordinator.shutdownClaudeSession(session)
        }
    }

    func testTypedZeroWriteSteerRefusalReleasesCompletedProviderWork() async throws {
        let (h, session, controller, _) = try await spyFixture()
        let providerID = UUID()
        await controller.setTurnInFlight(true)
        await controller.emit(.providerTurnStarted(turnID: providerID))
        await until("provider starts") { session.runState == .running }
        let gate = Gate()
        await controller.setRejectBeforeWrite(true)
        await controller.setSendSuspension { await gate.wait() }
        try queueSteer("never written", in: session, service: h.service)
        _ = await h.service.submitQueuedClaudeSteeringIfSupported(session: session)
        await until("controller validation is held") { gate.isWaiting }
        await controller.emit(.turnsCompleted(turnIDs: [providerID], status: .completed))
        gate.open()
        await until("typed zero-write refusal releases provider success") { session.runState == .completed && session.agentTask == nil }
        let count = await controller.sentCount
        XCTAssertEqual(count, 0)
        XCTAssertNotNil(session.claudeController)
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testStopWithdrawsProviderApprovalParkedInHostPreparationReservation() async throws {
        let writes = ClaudeNativeApprovalAndResumeTests.WrittenLines()
        let f = try await fixture(write: { writes.append($0) })
        let reservation = try XCTUnwrap(f.harness.host.claudeCoordinator.reserveEventsForHostPreparation(for: f.session))
        try await feed(["type": "control_request", "request_id": "parked-permission", "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "echo fixture"]]], f.controller)
        await until("unowned provider work and its approval reach the reserved inbox") {
            f.session.mcpFollowUpRunPending && f.listener.pendingApprovalIDs.count == 1
        }
        XCTAssertNil(f.session.activeRunOwnership)
        XCTAssertTrue(f.harness.host.claudeCoordinator.hasPendingProviderAdoption(for: f.session))
        let receipt = try XCTUnwrap(f.listener.pendingApprovalIDs.first)
        XCTAssertNotNil(UUID(uuidString: receipt))
        XCTAssertNotEqual(receipt, "parked-permission", "The reserved inbox retains opaque response authority, not a wire ID")
        await f.harness.host.cancelAgentRun(tabID: f.session.tabID)
        await until("parked approval is denied") { writes.count == 1 }
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(writes.line(at: 0))) as? [String: Any])
        let response = try XCTUnwrap(frame["response"] as? [String: Any])
        XCTAssertEqual(response["request_id"] as? String, "parked-permission")
        let decision = try XCTUnwrap(response["response"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertEqual(decision["interrupt"] as? Bool, true)
        XCTAssertFalse(f.listener.isBusy)
        XCTAssertNil(f.session.claudeController)
        XCTAssertFalse(f.session.mcpFollowUpRunPending)
        XCTAssertTrue(reservation.subscription.isClosed)
        await cleanup(f)
    }

    func testPendingProviderCancellationWaitsForWithdrawnControllerTeardown() async throws {
        for (hasSettledPredecessor, explicitStop) in [(false, false), (true, false), (false, true), (true, true)] {
            let (h, session, controller, listener) = try await spyFixture()
            if hasSettledPredecessor {
                let predecessorID = UUID()
                await controller.emit(.providerTurnStarted(turnID: predecessorID))
                await until("predecessor starts") { session.activeRunOwnership != nil }
                await controller.emit(.turnsCompleted(turnIDs: [predecessorID], status: .completed))
                await until("predecessor settles") {
                    session.runState == .completed && !session.runLifecycle.terminalCommitInProgress && session.activeRunOwnership == nil
                }
                XCTAssertNotNil(session.lastTerminalCommitRevision)
            } else {
                XCTAssertNil(session.lastTerminalCommitRevision)
            }
            let reservation = try XCTUnwrap(h.host.claudeCoordinator.reserveEventsForHostPreparation(for: session))
            let providerID = UUID()
            await controller.emit(.providerTurnStarted(turnID: providerID))
            await controller.emit(.approvalRequest(.init(
                requestID: .claudeControl("parked-teardown-approval"), method: "control/can_use_tool",
                kind: .commandExecution, threadID: "fixture", turnID: providerID.uuidString, itemID: "tool"
            )))
            await until("provider approval is parked in host preparation") {
                listener.pendingApprovalIDs == ["parked-teardown-approval"] && listener.isBusy
            }
            XCTAssertTrue(listener.subscription === reservation.subscription)
            XCTAssertNil(session.activeRunOwnership)
            let predecessorOwnership = session.lastTerminalCommitRevision?.ownership
            let shutdownGate = Gate()
            await controller.setShutdownSuspension { await shutdownGate.wait() }
            let service = h.host.test_initializeRunService(expectedPIDPolicyArmer: { _ in true })
            // A retained settled Oracle drain must not bypass pending provider-adoption teardown.
            if explicitStop { session.oracleBackgroundDrain = Task {} }
            var returned = false
            let cancellation = Task { @MainActor in
                await service.cancelRun(
                    tabID: session.tabID, session: session, intent: explicitStop ? .userStop : .runtimeShutdown,
                    completion: .terminalTeardownCompleted, origin: explicitStop ? .explicitStop : .internalLifecycle
                )
                returned = true
            }
            await until("withdrawn controller shutdown is held") { shutdownGate.isWaiting }
            XCTAssertNil(session.claudeController)
            XCTAssertNil(session.activeRunOwnership, "Withdrawal must not invent a provider attempt")
            XCTAssertEqual(session.lastTerminalCommitRevision?.ownership, predecessorOwnership)
            XCTAssertFalse(returned, "Teardown-completed cancellation must join this provider, not just the predecessor")
            let shutdownsBeforeRelease = await controller.shutdownCount
            XCTAssertEqual(shutdownsBeforeRelease, 0)
            let calls = await controller.inputBoundaryCalls
            XCTAssertTrue(calls.contains("permission:parked-teardown-approval:cancel"))
            shutdownGate.open()
            await cancellation.value
            XCTAssertTrue(returned)
            let shutdownsAfterRelease = await controller.shutdownCount
            XCTAssertEqual(shutdownsAfterRelease, 1)
            XCTAssertTrue(reservation.subscription.isClosed)
            await h.host.claudeCoordinator.shutdownClaudeSession(session)
        }
    }

    func testRevisionlessSecondCancellationJoinsWithdrawnProviderWithoutSyntheticAttempt() async throws {
        let (h, session, controller, listener) = try await spyFixture()
        XCTAssertNil(session.lastTerminalCommitRevision)
        let reservation = try XCTUnwrap(h.host.claudeCoordinator.reserveEventsForHostPreparation(for: session))
        let providerID = UUID()
        await controller.emit(.providerTurnStarted(turnID: providerID))
        await controller.emit(.approvalRequest(.init(
            requestID: .claudeControl("revisionless-teardown-approval"), method: "control/can_use_tool",
            kind: .commandExecution, threadID: "fixture", turnID: providerID.uuidString, itemID: "tool"
        )))
        await until("provider approval is parked in host preparation") {
            listener.pendingApprovalIDs == ["revisionless-teardown-approval"] && listener.isBusy
        }
        let shutdownGate = Gate()
        await controller.setShutdownSuspension { await shutdownGate.wait() }
        let service = h.host.test_initializeRunService(expectedPIDPolicyArmer: { _ in true })

        await service.cancelRun(
            tabID: session.tabID, session: session, intent: .runtimeShutdown,
            completion: .terminalPublished
        )
        await until("withdrawn controller shutdown is held") { shutdownGate.isWaiting }
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNil(session.lastTerminalCommitRevision)
        XCTAssertTrue(reservation.subscription.isClosed)

        var returned = false
        let teardown = Task { @MainActor in
            await service.cancelRun(
                tabID: session.tabID, session: session, intent: .runtimeShutdown,
                completion: .terminalTeardownCompleted
            )
            returned = true
        }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertFalse(returned, "The second cancellation must join the held withdrawn provider")
        XCTAssertNil(session.activeRunOwnership, "No attempt should be active while retirement is held")
        XCTAssertNil(session.lastTerminalCommitRevision, "The second cancellation must not commit a synthetic attempt")

        shutdownGate.open()
        await teardown.value
        XCTAssertTrue(returned)
        XCTAssertNil(session.activeRunOwnership)
        XCTAssertNil(session.lastTerminalCommitRevision, "The second cancellation must not commit after retirement")
        let shutdownCount = await controller.shutdownCount
        XCTAssertEqual(shutdownCount, 1)
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testSecondCancellationJoinsPreviouslyWithdrawnPendingProviderShutdown() async throws {
        let (h, session, controller, listener) = try await spyFixture()
        let predecessorID = UUID()
        await controller.emit(.providerTurnStarted(turnID: predecessorID))
        await until("predecessor starts") { session.activeRunOwnership != nil }
        await controller.emit(.turnsCompleted(turnIDs: [predecessorID], status: .completed))
        await until("predecessor settles") {
            session.runState == .completed && !session.runLifecycle.terminalCommitInProgress && session.activeRunOwnership == nil
        }
        let predecessorOwnership = try XCTUnwrap(session.lastTerminalCommitRevision?.ownership)
        let reservation = try XCTUnwrap(h.host.claudeCoordinator.reserveEventsForHostPreparation(for: session))
        let providerID = UUID()
        await controller.emit(.providerTurnStarted(turnID: providerID))
        await controller.emit(.approvalRequest(.init(
            requestID: .claudeControl("repeated-teardown-approval"), method: "control/can_use_tool",
            kind: .commandExecution, threadID: "fixture", turnID: providerID.uuidString, itemID: "tool"
        )))
        await until("provider approval is parked in host preparation") {
            listener.pendingApprovalIDs == ["repeated-teardown-approval"] && listener.isBusy
        }
        let shutdownGate = Gate()
        await controller.setShutdownSuspension { await shutdownGate.wait() }
        let service = h.host.test_initializeRunService(expectedPIDPolicyArmer: { _ in true })

        // Publication-only cancellation withdraws the provider and detaches its listener
        // without waiting for retirement.
        await service.cancelRun(
            tabID: session.tabID, session: session, intent: .runtimeShutdown,
            completion: .terminalPublished
        )
        await until("withdrawn controller shutdown is held") { shutdownGate.isWaiting }
        XCTAssertFalse(h.host.claudeCoordinator.hasPendingProviderAdoption(for: session))

        var returned = false
        let teardown = Task { @MainActor in
            await service.cancelRun(
                tabID: session.tabID, session: session, intent: .runtimeShutdown,
                completion: .terminalTeardownCompleted
            )
            returned = true
        }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertFalse(returned, "A later teardown-completed cancellation must still join the withdrawn provider")
        let shutdownsBeforeRelease = await controller.shutdownCount
        XCTAssertEqual(shutdownsBeforeRelease, 0)
        XCTAssertNil(session.activeRunOwnership, "Withdrawal must not invent a provider attempt")
        XCTAssertEqual(session.lastTerminalCommitRevision?.ownership, predecessorOwnership)
        let calls = await controller.inputBoundaryCalls
        XCTAssertEqual(calls.count(where: { $0 == "permission:repeated-teardown-approval:cancel" }), 1)

        shutdownGate.open()
        await teardown.value
        XCTAssertTrue(returned)
        let shutdownsAfterRelease = await controller.shutdownCount
        XCTAssertEqual(shutdownsAfterRelease, 1)
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    func testReplacementTransportReopensTheExistingAttemptInboxAfterEOF() async throws {
        let f = try await fixture()
        let inbox = try XCTUnwrap(f.listener.reserve())
        inbox.finish()
        f.listener.detachTransport()
        await f.controller.resetEventsStreamForNewRun()
        _ = await f.harness.host.claudeCoordinator.test_installEventListener(for: f.session)
        XCTAssertTrue(f.listener.subscription === inbox)
        var returned = false
        let waiter = Task { @MainActor in
            let event = await inbox.next()
            returned = true
            return event
        }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertFalse(returned, "An old transport EOF must not end the replacement reservation")
        inbox.append(.settlementRecheck)
        let event = await waiter.value
        if case .settlementRecheck = event {} else { XCTFail("Replacement event must reach the retained reservation") }
        f.listener.close(inbox, returningTail: false)
        await cleanup(f)
    }

    func testUncertainSteerWriteCannotReplayProtectedProviderSuccess() async throws {
        let (h, session, controller, _) = try await spyFixture()
        let providerID = UUID()
        await controller.setTurnInFlight(true)
        await controller.emit(.providerTurnStarted(turnID: providerID))
        await until("provider starts") { session.runState == .running }
        let owner = try XCTUnwrap(session.activeRunOwnership)
        try queueSteer("replacement instruction", in: session, service: h.service)
        let gate = Gate()
        await controller.setFailSendAfterRecord(true)
        await controller.setSendSuspension { await gate.wait() }
        let accepted = await h.service.submitQueuedClaudeSteeringIfSupported(session: session)
        XCTAssertTrue(accepted)
        await until("physical write receipt is held") { gate.isWaiting }
        await controller.emit(.turnsCompleted(turnIDs: [providerID], status: .completed))
        XCTAssertEqual(session.activeRunOwnership, owner)
        gate.open()
        await until("uncertain write fails and retires instead of replaying success") { session.runState == .failed && session.claudeController == nil && session.agentTask == nil }
        XCTAssertEqual(session.lastTerminalCommitRevision?.ownership, owner)
        XCTAssertEqual(session.lastTerminalCommitRevision?.terminalState, .failed)
        try await AsyncTestWait.waitUntil("retired controller cleanup finishes", timeout: 2) { await controller.shutdownCount == 1 }
        let shutdowns = await controller.shutdownCount
        XCTAssertEqual(shutdowns, 1)
    }

    private func seedHydratedHistory(_ history: AgentTranscript, harness: AgentSessionLinkRunnerHarness, session: AgentTabSession, pendingUser: AgentChatItem? = nil) {
        // Mirror preparePersistedHydration's structured branch and hydrateSession: normalize
        // frozen caps, derive canonical working rows, install cold presentation and cursor.
        var saved = history
        if let pendingUser {
            saved.turns += AgentTranscriptIO.buildTranscript(from: [pendingUser], terminalState: .running, nextSequenceIndex: pendingUser.sequenceIndex + 1, policy: .liveSession(hidePendingQuestionToolCall: false)).turns
            saved.nextSequenceIndex = pendingUser.sequenceIndex + 1
            saved = AgentTranscriptCompactor.compact(saved, mode: .preserveDurableFrontier)
        }
        let transcript = AgentTranscriptProjectionBuilder.normalizedFrozenDetailedToolTailLimits(in: saved)
        let canonicalItems = AgentTranscriptIO.workingSourceItems(from: transcript)
        session.setItemsSilently(canonicalItems, reason: .persistedSessionHydration)
        AgentSessionTranscriptRefreshRuntime.applyTranscriptPresentation(transcript, sourceItems: canonicalItems, to: session, isColdLoad: true)
        session.nextSequenceIndex = transcript.nextSequenceIndex
        session.hasSentFirstMessage = transcript.turns.contains { $0.request != nil }
        XCTAssertEqual(session.transcript, transcript)
    }

    private func measureOrdinaryTerminalCommit(history: AgentTranscript) async throws {
        let (h, session, controller, listener) = try await spyFixture()
        h.host.test_setAllowsScheduledDerivedTranscriptRefreshWithoutPromptManager(true)
        // Ordinary input admission precedes dispatch, as on the composer path.
        let row = AgentChatItem.user("ordinary live input", sequenceIndex: history.nextSequenceIndex)
        seedHydratedHistory(history, harness: h, session: session, pendingUser: row)
        let baseline = session.transcriptPerformanceSnapshot
        var terminalStarted: ContinuousClock.Instant?
        listener.test_onDelivery = { event in
            if case .turnsCompleted = event {
                terminalStarted = .now
            }
        }
        await controller.setImmediateReplyDuringSend(true)
        let service = h.host.test_initializeRunService(expectedPIDPolicyArmer: { _ in true })
        await h.host.test_composeRunService(service).startRun(
            tabID: session.tabID, session: session, initialUserMessage: row.text,
            initialMessageForRun: row.text, attachments: [], initialUserItemID: row.id
        )
        await until("ordinary saved-history attempt publishes", timeout: .seconds(120)) { terminalStarted != nil && session.agentTask == nil && session.runState == .completed && !session.runLifecycle.terminalCommitInProgress }
        let elapsed = try XCTUnwrap(terminalStarted).duration(to: .now)
        let metrics = session.transcriptPerformanceSnapshot
        print("C2 hydrated ordinary terminal=\(elapsed) incrementalAttempts=\(metrics.incrementalImportAttemptCount - baseline.incrementalImportAttemptCount) successes=\(metrics.incrementalImportSuccessCount - baseline.incrementalImportSuccessCount) fallbacks=\(metrics.incrementalImportFallbackCount - baseline.incrementalImportFallbackCount) importMS=\(String(describing: metrics.lastImportDurationMS))")
        await h.host.claudeCoordinator.shutdownClaudeSession(session)
    }

    /// The large-transcript settlement predicate's inputs, captured together so a failed wait reports every value.
    private struct LargeTranscriptSettlement: CustomStringConvertible {
        let preparationCount: Int
        let uniqueDeliveries: Int
        let runState: AgentSessionRunState
        let terminalCommitInProgress: Bool
        let listenerBusy: Bool

        var isSettled: Bool {
            preparationCount == 2 && uniqueDeliveries == 1996 && runState == .completed && !terminalCommitInProgress && !listenerBusy
        }

        var description: String {
            "settled=\(isSettled) preparationCount=\(preparationCount) uniqueDeliveries=\(uniqueDeliveries) runState=\(runState.rawValue) terminalCommitInProgress=\(terminalCommitInProgress) listenerBusy=\(listenerBusy)"
        }
    }

    func testLargeSavedTranscriptDoesNotMultiplyLiveRoutingWork() async throws {
        // Seed the retention tiers left by live compaction, then let the real compactor
        // trim and normalize once. Replaying every intermediate compaction is quadratic.
        let setupStarted = ContinuousClock.now
        var history = AgentTranscript.empty
        for index in stride(from: 0, to: 20000, by: 2) {
            history.turns += AgentTranscriptIO.buildTranscript(
                from: [.user("saved-user-\(index)", sequenceIndex: index), .assistant("saved-answer-\(index + 1)", sequenceIndex: index + 1)],
                terminalState: .completed, nextSequenceIndex: index + 2,
                policy: .liveSession(hidePendingQuestionToolCall: false)
            ).turns
            history.nextSequenceIndex = index + 2
        }
        // Keep 34 summary turns plus the final full turn, matching the measured live
        // fixture's 9,999 frozen turns, 2 working rows, and 70 working units.
        for index in history.turns.indices.dropLast() {
            history.turns[index].retentionTier = index < 9965 ? .archived : .summary
        }
        history = AgentTranscriptCompactor.compact(history, mode: .recomputeAll)
        XCTAssertEqual(history.nextSequenceIndex, 20000)
        XCTAssertEqual(history.turns.count, 10000)
        XCTAssertEqual(AgentTranscriptIO.workingSourceItems(from: history).count, 2)
        XCTAssertEqual(history.compactionFrontier?.frozenPrefixTurnCount, 9999)
        XCTAssertEqual(AgentTranscriptCompactor.estimatedWorkingUnitCount(for: history), 70)
        print("C2 compacted setup=\(setupStarted.duration(to: .now)) seededItems=20000 turns=\(history.turns.count) workingRows=\(AgentTranscriptIO.workingSourceItems(from: history).count) frozenPrefix=\(history.compactionFrontier?.frozenPrefixTurnCount ?? 0) workingUnits=\(AgentTranscriptCompactor.estimatedWorkingUnitCount(for: history))")
        AgentTranscriptDebugInstrumentation.configure(.init(refreshAttemptHandler: { metrics in
            print("C2 refresh tab=\(metrics.tabID) state=\(metrics.runState) path=\(metrics.incrementalPath)")
        }))
        defer { AgentTranscriptDebugInstrumentation.reset() }
        var counts: [Int] = []
        for seedCount in [0, 20000] {
            let setupStarted = ContinuousClock.now
            print("C2 routing fixture begin seed=\(seedCount)")
            let f = try await fixture(mcp: true)
            f.harness.host.test_setAllowsScheduledDerivedTranscriptRefreshWithoutPromptManager(true)
            seedHydratedHistory(seedCount == 0 ? .empty : history, harness: f.harness, session: f.session)
            let baseline = f.session.transcriptPerformanceSnapshot
            var terminalStarted: ContinuousClock.Instant?
            var terminalDurations: [Duration] = []
            print("C2 routing fixture ready seed=\(seedCount) setup=\(setupStarted.duration(to: .now))")
            var resume: CheckedContinuation<Void, Never>?
            var preparationCount = 0
            f.harness.host.mcpRuntime.test_afterEpochBegan = {
                preparationCount += 1
                if preparationCount == 2, let terminalStarted { terminalDurations.append(terminalStarted.duration(to: .now)) }
                if preparationCount == 1 { await withCheckedContinuation { resume = $0 } }
            }
            var receivedCompletions = 0
            f.listener.test_onReceive = { event in
                if case .turnsCompleted = event { receivedCompletions += 1 }
            }
            var deliveries: [String: Int] = [:]
            f.listener.test_onDelivery = { event in
                if case .turnsCompleted = event {
                    terminalStarted = .now
                }
                if case let .stream(value) = event, value.type == "task_progress", let text = value.text {
                    deliveries[text, default: 0] += 1
                }
            }
            var frames: [[String: Any]] = []
            for i in 0 ..< 998 {
                frames.append(["type": "system", "subtype": "task_progress", "description": "progress-\(i)"])
            }
            frames += [result("first-terminal"), assistant("second-live")]
            for i in 998 ..< 1996 {
                frames.append(["type": "system", "subtype": "task_progress", "description": "progress-\(i)"])
            }
            frames.append(result("second-terminal"))
            XCTAssertEqual(frames.count + 1, 2000)
            var bytes = Data()
            for frame in frames {
                try bytes.append(JSONSerialization.data(withJSONObject: frame))
                bytes.append(10)
            }
            let started = ContinuousClock.now
            try await feed(assistant("first-live"), f.controller)
            await until("hold the adoption gap", timeout: .seconds(120)) { resume != nil }
            let busy = await f.harness.host.preparedOversightRuntimeIsBusy()
            XCTAssertTrue(busy)
            await f.controller.test_handleConfigurationStdoutChunk(bytes)
            await until("the whole burst is parked", timeout: .seconds(120)) { receivedCompletions == 2 }
            XCTAssertGreaterThan(f.listener.test_handoffCount, 1996, "One input burst is retained losslessly, not count-capped")
            resume?.resume()
            resume = nil
            func settlement() -> LargeTranscriptSettlement {
                LargeTranscriptSettlement(
                    preparationCount: preparationCount,
                    uniqueDeliveries: deliveries.count,
                    runState: f.session.runState,
                    terminalCommitInProgress: f.session.runLifecycle.terminalCommitInProgress,
                    listenerBusy: f.listener.isBusy
                )
            }
            // A generous watchdog detects hangs without treating CI performance as a correctness requirement.
            await until("both bursts settle", timeout: .seconds(120)) { settlement().isSettled }
            let elapsed = started.duration(to: .now)
            // No suspension separates this from the wait's final evaluation, so these are the values it judged.
            let settlementAtDeadline = settlement()
            print("C2 settlement seed=\(seedCount) phase=deadline elapsed=\(elapsed) \(settlementAtDeadline)")
            try terminalDurations.append(XCTUnwrap(terminalStarted).duration(to: .now))
            XCTAssertEqual(terminalDurations.count, 2)
            XCTAssertEqual(deliveries.count, 1996)
            XCTAssertTrue(deliveries.values.allSatisfy { $0 == 1 })
            counts.append(deliveries.values.reduce(0, +))
            XCTAssertNil(f.listener.subscription)
            XCTAssertEqual(f.listener.test_handoffCount, 0)
            XCTAssertFalse(f.listener.isBusy)
            let metrics = f.session.transcriptPerformanceSnapshot
            print("C2 routing seed=\(seedCount) frames=2000 deliveredProgress=\(counts.last!) elapsed=\(elapsed) terminals=\(terminalDurations) incrementalAttempts=\(metrics.incrementalImportAttemptCount - baseline.incrementalImportAttemptCount) successes=\(metrics.incrementalImportSuccessCount - baseline.incrementalImportSuccessCount) fallbacks=\(metrics.incrementalImportFallbackCount - baseline.incrementalImportFallbackCount) importMS=\(String(describing: metrics.lastImportDurationMS))")
            print("C2 refresh cost seed=\(seedCount) requests=\(metrics.refreshRequestCount - baseline.refreshRequestCount) immediate=\(metrics.refreshImmediateCount - baseline.refreshImmediateCount) coalesced=\(metrics.refreshCoalescedCount - baseline.refreshCoalescedCount) lastTotalMS=\(String(describing: metrics.lastRefreshTotalDurationMS)) maxTotalMS=\(String(describing: metrics.maxRefreshTotalDurationMS))")
            await cleanup(f)
        }
        XCTAssertEqual(counts, [1996, 1996])
        try await measureOrdinaryTerminalCommit(history: history)
    }

    func testAdoptedTurnsKeepRealMCPRouteUntilStopAndLateCleanupCannotRevokeSuccessor() async throws {
        try await MCPSharedServerTestLease.shared.withLease { _ in
            try await AppGlobalMCPServiceComposition.shared.ensureRegistered()
            let manager = ServerNetworkManager.shared
            let window = WindowState(domainRuntime: AppDomainRuntimeComposition.shared.runtime)
            WindowStatesManager.shared.registerWindowState(window)
            let registration = try await AppDomainRuntimeComposition.shared.register(window.mcpServer.windowMCPToolCatalogService)
            let vm = window.agentModeViewModel
            var connections: [PersistentMCPTestEndpoint] = []
            var runIDs: [UUID] = []
            var session: AgentTabSession?
            var storeRegistration: AgentRunSessionStore.Registration?
            let cleanup: @MainActor () async -> Void = {
                if let session { await vm.claudeCoordinator.shutdownClaudeSession(session) }
                if let storeRegistration { await AgentRunSessionStore.cleanup(registration: storeRegistration) }
                for connection in connections {
                    connection.client.close()
                    await connection.connectionManager.stop()
                    await manager.debugRemoveConnection(connection.connectionID)
                }
                for runID in runIDs {
                    await manager.clearClientConnectionPolicy(for: AgentProviderKind.claudeMCPClientID, windowID: window.windowID, runID: runID)
                    await manager.cleanupRunRoutingState(for: runID, windowID: window.windowID)
                }
                await window.tearDown()
                await AppDomainRuntimeComposition.shared.unregister(registration.handle)
                WindowStatesManager.shared.unregisterWindowState(window)
            }
            do {
                await window.workspaceManager.awaitInitialized()
                let tabID = UUID(), sessionID = UUID()
                var workspace = WorkspaceModel(name: "Claude adopted route fixture", repoPaths: [])
                workspace.isEphemeral = true
                workspace.composeTabs = [ComposeTabState(id: tabID, name: "Claude route", activeAgentSessionID: sessionID)]
                workspace.activeComposeTabID = tabID
                let persisted = AgentSession(id: sessionID, workspaceID: workspace.id, composeTabID: tabID, name: "Claude route", agentKind: AgentProviderKind.claudeCode.rawValue)
                _ = try await AgentSessionDataService.shared.saveAgentSession(persisted, for: workspace)
                window.workspaceManager.workspaces.append(workspace)
                let switched = await window.workspaceManager.switchWorkspace(to: workspace, saveState: false)
                XCTAssertTrue(switched.didSwitch)
                window.promptManager.loadComposeTabsFromWorkspace(workspace, syncPromptText: true)
                let live = await vm.ensureSessionReady(tabID: tabID, reconnectActiveProviders: false)
                session = live
                let registered = await AgentRunSessionStore.register(sessionID: sessionID)
                storeRegistration = registered
                live.mcpControlContext = try .init(sessionID: sessionID, activationID: UUID(), writerIdentity: controlWriterIdentity(for: live), registration: registered, currentEpoch: nil, preparedEpoch: nil, pendingEpochTransition: nil, originatingConnectionID: nil, interactionTransport: .mcp(sessionID: sessionID, originatingConnectionID: nil), suppressUserNotifications: true, forceAutoEditEnabled: false, autoEditEnabledBeforeOverride: false, taskLabelKind: .pair, autoEditOverride: nil)
                let controller = MonitorFakeNativeController()
                let runID = UUID()
                runIDs.append(runID)
                live.installRunID(runID)
                live.claudeController = controller
                _ = await vm.claudeCoordinator.test_installEventListener(for: live)
                @MainActor func connect(_ runID: UUID) async throws -> PersistentMCPTestEndpoint {
                    await manager.installClientConnectionPolicy(for: AgentProviderKind.claudeMCPClientID, windowID: window.windowID, restrictedTools: AgentModeMCPToolPolicy.restrictedTools, oneShot: true, reason: "Claude adoption route regression", ttl: 60, tabID: tabID, runID: runID, additionalTools: [MCPWindowToolName.getFileTree], purpose: .agentModeRun, taskLabelKind: .pair, allowsAgentExternalControlTools: false)
                    await manager.setEnabled(true)
                    let endpoint = try await PersistentMCPTestEndpoint.make(label: "claude-adoption-route", networkManager: manager, clientName: AgentProviderKind.claudeMCPClientID, requiredToolNames: [MCPWindowToolName.getFileTree])
                    connections.append(endpoint)
                    return endpoint
                }
                @MainActor func callTree(_ connection: PersistentMCPTestEndpoint, runID: UUID) async throws {
                    let response = try await connection.callTool(name: MCPWindowToolName.getFileTree, arguments: ["type": "roots"], timeoutSeconds: 3)
                    let object = try MCPExportWatchdogIntegrationTests.responseObject(from: response)
                    XCTAssertNil(object["error"])
                    let result = try XCTUnwrap(object["result"] as? [String: Any])
                    XCTAssertNotEqual(result["isError"] as? Bool, true)
                    let routed = await manager.debugCachedRunID(for: connection.connectionID)
                    XCTAssertEqual(routed, runID)
                    XCTAssertEqual(window.mcpServer.connectionID(forRunID: runID), connection.connectionID)
                }
                let connection = try await connect(runID)
                var epochs: [AgentRunTurnEpoch] = []
                for index in 0 ..< 2 {
                    let turnID = UUID()
                    await controller.emit(.providerTurnStarted(turnID: turnID))
                    await until("real-route provider turn adopts") { live.runState == .running }
                    try epochs.append(XCTUnwrap(live.activeRunOwnership?.turnEpoch))
                    XCTAssertEqual(live.runID, runID)
                    try await callTree(connection, runID: runID)
                    await controller.emit(.stream(.init(type: "content", text: "route answer \(index)")))
                    await controller.emit(.turnsCompleted(turnIDs: [turnID], status: .completed))
                    await until("real-route terminal publishes") { live.runState == .completed && !live.runLifecycle.terminalCommitInProgress }
                    XCTAssertEqual(window.mcpServer.connectionID(forRunID: runID), connection.connectionID)
                }
                XCTAssertNotEqual(epochs[0], epochs[1])
                let preparation = Gate()
                vm.mcpRuntime.test_afterEpochBegan = { await preparation.wait() }
                defer { preparation.open()
                    vm.mcpRuntime.test_afterEpochBegan = nil
                }
                let installedListener = await vm.claudeCoordinator.test_installEventListener(for: live)
                let listener = try XCTUnwrap(installedListener)
                await controller.emit(.providerTurnStarted(turnID: UUID()))
                await until("third turn waits in fresh epoch preparation") { preparation.isWaiting }
                XCTAssertEqual(vm.mcpRuntime.mcpSnapshot(for: live)?.status, .running)
                let adoption = listener.adoptionTask
                let candidate = try XCTUnwrap(vm.agentSessionLinkCandidate(tabID: tabID, sessionID: sessionID, tabName: "Claude route", isWindowClosing: false))
                let observer = DomainAgentSessionLinkEndpointIdentity(windowID: 2, workspaceID: UUID(), tabID: UUID(), sessionID: UUID(), persistentBindingGeneration: UUID(), bindingTransitionGeneration: 1)
                let stop = await vm.linkExecutionRuntime.agentSessionLinkPerformStop(
                    to: candidate,
                    request: .init(requestID: UUID(), linkID: UUID(), linkGeneration: 1, observerEndpoint: observer, observerDisplayName: "Overseer"),
                    liveness: { .init(observerEndpointIsLive: true, targetEndpointIsLive: true, targetWindowIsClosing: false) },
                    queueHasCommittedDrain: { false }, withdrawInbound: { true }, commitAuthorization: { .committed }
                )
                if case let .settled(receipt) = stop {
                    XCTAssertEqual(receipt.result, .stopped)
                    XCTAssertEqual(receipt.stopRequested, true)
                    XCTAssertEqual(receipt.resultingRunState, "pending_start_withdrawn")
                } else { XCTFail("Pending adoption must produce an attributed managed Stop receipt") }
                preparation.open()
                await adoption?.value
                XCTAssertNil(live.activeRunOwnership)
                XCTAssertFalse(live.mcpFollowUpRunPending)
                try await AsyncTestWait.waitUntil("Stop retires the process route", timeout: 3) {
                    await manager.debugCachedRunID(for: connection.connectionID) == nil
                }
                XCTAssertNil(window.mcpServer.connectionID(forRunID: runID))
                let successorID = UUID()
                runIDs.append(successorID)
                live.installRunID(successorID)
                let successor = try await connect(successorID)
                await vm.cleanupMCPRunRoutingForDiscardedSession(boundSessionID: sessionID, liveSession: live, explicitRunID: runID, reason: "late retired Claude cleanup fixture")
                try await callTree(successor, runID: successorID)
            } catch {
                await cleanup()
                throw error
            }
            await cleanup()
        }
    }

    func testNextProviderAttemptWaitsForPriorTerminalPublication() async throws {
        let f = try await fixture(mcp: true)
        let gate = Gate()
        f.harness.host.test_setTerminalPublicationOverride { revision, successor, session in
            await gate.wait()
            f.harness.host.test_setTerminalPublicationOverride(nil)
            return await f.harness.host.test_publishTerminalCommit(revision, successorKind: successor, for: session)
        }
        try await feed(assistant("first"), f.controller)
        await until("first attempt starts") { f.session.runState == .running }
        let first = try XCTUnwrap(f.session.activeRunOwnership)
        let epochPreparation = Gate()
        f.harness.host.mcpRuntime.test_afterEpochBegan = { await epochPreparation.wait() }
        let bytes = try [result("first-final"), assistant("second")].map { try JSONSerialization.data(withJSONObject: $0) + Data([10]) }.reduce(Data(), +)
        await f.controller.test_handleConfigurationStdoutChunk(bytes)
        await until("prior publication is held") { gate.isWaiting && f.listener.pendingProviderTurnID != nil }
        XCTAssertTrue(f.session.runLifecycle.terminalCommitInProgress)
        XCTAssertEqual(f.session.mcpControlContext?.currentEpoch, first.turnEpoch)
        XCTAssertNil(f.session.activeRunOwnership)
        gate.open()
        await until("handed-back turn is preparing its fresh epoch") { epochPreparation.isWaiting }
        XCTAssertTrue(f.session.mcpFollowUpRunPending)
        XCTAssertEqual(f.harness.host.mcpRuntime.mcpSnapshot(for: f.session)?.status, .running)
        epochPreparation.open()
        await until("second starts after publication") { f.session.runState == .running && f.session.activeRunOwnership?.attemptID != first.attemptID }
        XCTAssertNotEqual(f.session.activeRunOwnership?.turnEpoch, first.turnEpoch)
        try await feed(result("second-final"), f.controller)
        await until("second publishes") { f.session.runState == .completed && !f.session.runLifecycle.terminalCommitInProgress }
        await cleanup(f)
    }

    func testQueuedFollowUpIsRetainedWhenHandedBackProviderWorkWinsAdmission() async throws {
        let f = try await fixture(mcp: true)
        let publication = Gate()
        f.harness.host.test_setTerminalPublicationOverride { revision, successor, session in
            await publication.wait()
            f.harness.host.test_setTerminalPublicationOverride(nil)
            return await f.harness.host.test_publishTerminalCommit(revision, successorKind: successor, for: session)
        }
        try await feed(assistant("first"), f.controller)
        await until("first provider attempt starts") { f.session.runState == .running }
        let first = try XCTUnwrap(f.session.activeRunOwnership)
        let queued = AgentTabSession.PendingInstruction(providerText: "queued follow-up M", localDraftText: "local draft M", stopFence: .init(session: f.session), skipsSlashExpansion: true)
        f.session.pendingInstructions.append(queued)
        let bytes = try [result("first-final"), assistant("second")].map { try JSONSerialization.data(withJSONObject: $0) + Data([10]) }.reduce(Data(), +)
        await f.controller.test_handleConfigurationStdoutChunk(bytes)
        await until("prior publication and provider handback are held") { publication.isWaiting && f.listener.pendingProviderTurnID != nil }
        publication.open()
        await until("provider adoption wins and the refused follow-up remains owed") {
            f.session.runState == .running && f.session.activeRunOwnership?.attemptID != first.attemptID && f.session.pendingInstructions == [queued]
        }
        XCTAssertEqual(f.session.pendingInstructions, [queued], "Provider text, local draft, original Stop fence and expansion policy must survive together")
        await f.harness.host.cancelAgentRun(tabID: f.session.tabID)
        XCTAssertTrue(f.session.pendingInstructions.isEmpty, "Only explicit Stop withdraws the retained follow-up")
        await cleanup(f)
    }

    func testStopWithdrawsHandedBackWorkWithoutBypassingPriorTerminalPublication() async throws {
        let f = try await fixture(mcp: true)
        let publication = Gate()
        f.harness.host.test_setTerminalPublicationOverride { revision, successor, session in
            await publication.wait()
            f.harness.host.test_setTerminalPublicationOverride(nil)
            return await f.harness.host.test_publishTerminalCommit(revision, successorKind: successor, for: session)
        }
        try await feed(assistant("first"), f.controller)
        await until("first provider attempt starts") { f.session.runState == .running }
        let first = try XCTUnwrap(f.session.activeRunOwnership)
        let bytes = try [result("first-final"), assistant("second")].map { try JSONSerialization.data(withJSONObject: $0) + Data([10]) }.reduce(Data(), +)
        await f.controller.test_handleConfigurationStdoutChunk(bytes)
        await until("prior publication and next adoption are held") { publication.isWaiting && f.listener.pendingProviderTurnID != nil }
        var stopReturned = false
        let stop = Task { @MainActor in
            await f.harness.host.cancelAgentRun(tabID: f.session.tabID, completion: .terminalTeardownCompleted)
            stopReturned = true
        }
        await until("pending provider work is detached") { f.session.claudeController == nil }
        XCTAssertFalse(stopReturned)
        XCTAssertEqual(f.session.runState, .completed, "Stop of unadopted work must not rewrite its predecessor's terminal outcome")
        publication.open()
        await stop.value
        XCTAssertFalse(f.session.runLifecycle.terminalCommitInProgress)
        XCTAssertEqual(f.session.lastTerminalCommitRevision?.ownership, first)
        if case .accepted = f.session.runLifecycle.lastTerminalPublicationResult {} else { XCTFail("The predecessor still publishes its one accepted terminal result") }
        XCTAssertFalse(f.listener.isBusy)
        XCTAssertNil(f.session.activeRunOwnership)
        await cleanup(f)
    }

    func testUnexpectedStreamEndFailsOwnedProviderAttempt() async throws {
        let f = try await fixture()
        try await feed(assistant("unfinished"), f.controller)
        await until("provider attempt starts") { f.session.runState == .running }
        let owner = f.session.activeRunOwnership
        await f.controller.test_handleStdoutEOF()
        await until("EOF fails rather than silently idling or restarting") { f.session.runState == .failed && f.session.claudeController == nil }
        XCTAssertEqual(f.session.lastTerminalCommitRevision?.ownership, owner)
        XCTAssertNil(f.listener.subscription)
        await cleanup(f)
    }

    func testPreparedSuccessorIsConsumedWithoutAnotherEpochTransition() async throws {
        let f = try await fixture(mcp: true)
        await f.harness.host.mcpRuntime.prepareWaitTrackingForRunStart(session: f.session, stopFence: .init(session: f.session))
        let prepared = try XCTUnwrap(f.session.mcpControlContext?.preparedEpoch)
        var preparations = 0
        f.harness.host.mcpRuntime.test_afterEpochBegan = { preparations += 1 }
        try await feed(assistant("prepared successor"), f.controller)
        await until("successor is adopted") { f.session.runState == .running }
        XCTAssertEqual(f.session.activeRunOwnership?.turnEpoch, prepared)
        XCTAssertNil(f.session.mcpControlContext?.preparedEpoch)
        XCTAssertNil(f.session.mcpControlContext?.pendingEpochTransition)
        XCTAssertEqual(preparations, 0)
        try await feed(result(), f.controller)
        await until("successor terminal is published") { f.session.runState == .completed && !f.session.runLifecycle.terminalCommitInProgress }
        await cleanup(f)
    }

    func testRebindRetiresPendingOwnerWithoutWritingIntoReplacementOrSecondWindow() async throws {
        let f = try await fixture(mcp: true)
        let other = try await fixture()
        let gate = Gate()
        f.harness.host.mcpRuntime.test_afterEpochBegan = { await gate.wait() }
        try await feed(assistant("old binding"), f.controller)
        await until("old epoch preparation is held") { gate.isWaiting }
        let adoption = f.listener.adoptionTask
        _ = f.harness.host.test_installPersistentSessionBinding(sessionID: UUID(), on: f.session)
        gate.open()
        await adoption?.value
        try await feed(assistant("stale work"), f.controller)
        try await feed(assistant("other window"), other.controller)
        try await feed(result("other-window-final"), other.controller)
        await until("other window independently settles") { other.session.runState == .completed && other.session.lastTerminalCommitRevision != nil }
        XCTAssertNil(f.session.claudeController)
        XCTAssertNil(f.session.activeRunOwnership)
        XCTAssertTrue(f.session.items.isEmpty, "No refusal or stale output may write into the replacement binding")
        XCTAssertFalse(f.listener.isCurrent())
        XCTAssertTrue(other.session.items.contains { $0.text.contains("other-window-final") })
        await cleanup(f)
        await cleanup(other)
    }

    func testStopDuringEpochPreparationCannotReadoptOrRetainRunningMask() async throws {
        let f = try await fixture(mcp: true)
        var resume: CheckedContinuation<Void, Never>?
        f.harness.host.mcpRuntime.test_afterEpochBegan = {
            await withCheckedContinuation { resume = $0 }
        }
        try await feed(assistant("pending adoption"), f.controller)
        await until("epoch preparation is suspended") { resume != nil }
        XCTAssertTrue(f.listener.isBusy)
        XCTAssertTrue(f.session.mcpFollowUpRunPending)
        XCTAssertEqual(f.harness.host.mcpRuntime.mcpSnapshot(for: f.session)?.status, .running)
        let busy = await f.harness.host.preparedOversightRuntimeIsBusy()
        XCTAssertTrue(busy)
        let adoption = f.listener.adoptionTask
        await f.harness.host.cancelAgentRun(tabID: f.session.tabID)
        resume?.resume()
        resume = nil
        await adoption?.value
        await until("pending owner is retired") { !f.listener.isBusy && f.session.claudeController == nil }
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        XCTAssertNil(f.session.activeRunOwnership)
        XCTAssertNil(f.session.agentTask)
        XCTAssertFalse(f.session.mcpFollowUpRunPending)
        XCTAssertNil(f.session.mcpControlContext?.pendingEpochTransition)
        XCTAssertEqual(f.session.runState, .cancelled)
        XCTAssertNil(f.session.lastTerminalCommitRevision, "Withdrawing preparation must not synthesize a terminal attempt under the old epoch")
        if let context = f.session.mcpControlContext {
            let epoch = await AgentRunSessionStore.currentEpoch(for: context.registration)
            XCTAssertEqual(context.currentEpoch, epoch, "Accepted-but-cancelled preparation cannot strand the store ahead of its owner")
            XCTAssertEqual(context.preparedEpoch, epoch)
        }
        await cleanup(f)
    }
}
