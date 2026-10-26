import CryptoKit
import Foundation
import MCP
import RepoPromptSettingsCore
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class AntigravityHeadlessBoundaryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    private let availability = AgentModelCatalog.AvailabilityContext(
        claudeCodeAvailable: true,
        codexAvailable: true,
        openCodeAvailable: true,
        cursorAvailable: true,
        grokBuildAvailable: true,
        antigravityAvailable: true
    )

    func testGeneralCatalogIncludesAntigravityButHeadlessExcludesIt() {
        XCTAssertTrue(AgentModelCatalog.selectableAgents(availability: availability).contains(.antigravity))
        XCTAssertFalse(AgentModelCatalog.selectableAgents(availability: availability, surface: .headless).contains(.antigravity))
        XCTAssertTrue(AgentModelCatalog.discoveryAgents(availability: availability).contains { $0.agent == .antigravity })
        XCTAssertFalse(AgentModelCatalog.discoveryAgents(availability: availability, surface: .headless).contains { $0.agent == .antigravity })
    }

    @MainActor
    func testExplicitSelectionAllowsGeneralButRejectsHeadlessAntigravity() throws {
        let registry = AgentACPModelRegistry.shared
        registry.test_reset(providerID: .antigravity)
        defer { registry.test_reset(providerID: .antigravity) }
        let model = "gemini-test-model"
        _ = registry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(rawValue: model, displayName: model, description: nil, isDefault: true)],
                currentModelRaw: model
            ),
            for: .antigravity
        )

        let general = try AgentMCPSelectionResolver.resolve(
            modelID: "antigravity:\(model)", availability: availability, surface: .general
        )
        XCTAssertEqual(general.agentRaw, AgentProviderKind.antigravity.rawValue)
        XCTAssertThrowsError(try AgentMCPSelectionResolver.resolve(
            modelID: "antigravity:\(model)", availability: availability, surface: .headless
        ))
    }

    @MainActor
    func testStoredExploreOverridePreservesGeneralPinButFailsClosedHeadlessly() throws {
        let registry = AgentACPModelRegistry.shared
        registry.test_reset(providerID: .antigravity)
        let settings = GlobalSettingsStore.shared
        let previousOverrides = settings.mcpAgentRoleOverrides(scope: .global)
        defer {
            settings.updateMCPAgentRoleOverrides(previousOverrides, scope: .global, commit: true)
            registry.test_reset(providerID: .antigravity)
        }
        let model = "gemini-test-model"
        _ = registry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(rawValue: model, displayName: model, description: nil, isDefault: true)],
                currentModelRaw: model
            ),
            for: .antigravity
        )
        MCPAgentRoleDefaultsService.setSelection(
            .init(agent: .antigravity, modelRaw: model), for: .explore, scope: .global
        )

        let effective = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(for: .explore, availability: availability))
        XCTAssertTrue(effective.hasStoredOverride)
        XCTAssertFalse(effective.overrideUnavailable)
        XCTAssertEqual(effective.effective.agent, .antigravity)

        let general = try AgentMCPSelectionResolver.resolve(
            modelID: "explore", availability: availability, surface: .general
        )
        XCTAssertEqual(general.agentRaw, AgentProviderKind.antigravity.rawValue)
        XCTAssertThrowsError(try AgentMCPSelectionResolver.resolve(
            modelID: "explore", availability: availability, surface: .headless
        ))
    }

    func testHeadlessFactoryRejectsAntigravity() {
        let provider = AgentRuntimeProviderService.shared.makeProvider(for: .antigravity, modelString: nil)
        XCTAssertTrue(provider is UnsupportedHeadlessAgentProvider)
    }
}

final class AgentMCPSelectionResolverTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        _ = try WorkspaceTestProcessSandbox.validate()
        GlobalSettingsStore.installApplicationModelIdentityPolicy()
    }

    private let openCodeOnly = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.openCode)
    private let globalModel = "rolepin/global"
    private let workspaceModel = "rolepin/workspace"
    private let interactiveModel = "rolepin-interactive"

    @MainActor
    func testRecommendationlessPinsUseEffectiveWorkspaceProfileAndParameters() throws {
        try withFixture { settings in
            let workspaceID = UUID()
            let globalProfile = profile(settings, model: globalModel, effort: "high")
            let workspaceProfile = profile(settings, model: workspaceModel, effort: "low")
            settings.setGlobalAgentModelsProfile(globalProfile, contextBuilderWriteIntent: .preserveExistingOwnership)
            settings.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: workspaceProfile)
            settings.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)

            for label in ["global", "workspace", "inherited"] {
                let targetID: UUID? = label == "global" ? nil : workspaceID
                let expectedModel = label == "workspace" ? workspaceModel : globalModel
                let surface: AgentModelCatalog.AgentSelectionSurface = label == "inherited" ? .headless : .general
                if label == "inherited" {
                    settings.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useGlobalSettings)
                    XCTAssertEqual(settings.workspaceAgentModelsProfile(for: workspaceID)?.mcpAgentRoleOverrides?["pair"], "openCode:\(workspaceModel)")
                }
                let effectiveProfile = settings.effectiveAgentModelsProfile(workspaceID: targetID)
                let parameters = try XCTUnwrap(effectiveProfile.mcpAgentRoleModelParameters?["pair"], label)
                XCTAssertEqual(parameters, [parameter(model: expectedModel, effort: label == "workspace" ? "low" : "high")], label)
                let pin = try XCTUnwrap(MCPAgentRoleDefaultsService.executableStoredSelection(
                    for: .pair, overrides: effectiveProfile.mcpAgentRoleOverrides,
                    roleModelParameters: effectiveProfile.mcpAgentRoleModelParameters, availability: openCodeOnly
                ), label)
                XCTAssertEqual(pin.selection.agent, .openCode, label)
                XCTAssertEqual(pin.selection.modelRaw, expectedModel, label)
                XCTAssertEqual(pin.modelParameters, parameters, label)
                XCTAssertNil(MCPAgentRoleDefaultsService.effectiveSelection(for: .pair, availability: openCodeOnly, workspaceID: targetID), label)

                for modelID: String? in ["pair", nil] {
                    do {
                        let result = try AgentMCPSelectionResolver.resolve(
                            modelID: modelID, defaultTaskLabel: .pair, availability: openCodeOnly,
                            workspaceID: targetID, surface: surface
                        )
                        assertSelection(result, agent: .openCode, model: expectedModel, role: .pair, parameters: parameters, label: "\(label), modelID=\(modelID ?? "omitted")")
                    } catch {
                        XCTFail("\(label), modelID=\(modelID ?? "omitted"): executable pin was rejected: \(error)")
                    }
                }
            }
        }
    }

    @MainActor
    func testIneligiblePinOnlyCandidatesPreserveExistingFallback() throws {
        try withFixture { settings in
            let globalProfile = profile(settings, model: globalModel, effort: "high")
            settings.setGlobalAgentModelsProfile(globalProfile, contextBuilderWriteIntent: .preserveExistingOwnership)
            let workspaceID = UUID()
            let cases: [(String, String?, AgentModelCatalog.AvailabilityContext, AgentModelCatalog.AgentSelectionSurface)] = [
                ("missing workspace role", nil, openCodeOnly, .general),
                ("malformed pin", "not-a-compound-id", openCodeOnly, .general),
                ("unavailable provider", "openCode:\(globalModel)", .none, .general),
                ("missing catalog model", "openCode:rolepin/missing", openCodeOnly, .general),
                ("interactive-only candidate", "antigravity:\(interactiveModel)", .none.assumingAvailable(.antigravity), .headless)
            ]
            for (label, override, availability, surface) in cases {
                var candidate = globalProfile
                candidate.mcpAgentRoleOverrides = override.map { ["pair": $0] } ?? [:]
                settings.setWorkspaceAgentModelsProfile(workspaceID: workspaceID, profile: candidate)
                settings.setWorkspaceAgentModelsInheritanceMode(workspaceID: workspaceID, mode: .useWorkspaceOverrides)
                XCTAssertEqual(settings.globalAgentModelsProfile().mcpAgentRoleOverrides?["pair"], "openCode:\(globalModel)", label)
                XCTAssertNil(MCPAgentRoleDefaultsService.effectiveSelection(for: .pair, availability: availability, workspaceID: workspaceID), label)
                let effectiveProfile = settings.effectiveAgentModelsProfile(workspaceID: workspaceID)
                let pin = MCPAgentRoleDefaultsService.executableStoredSelection(
                    for: .pair, overrides: effectiveProfile.mcpAgentRoleOverrides,
                    roleModelParameters: effectiveProfile.mcpAgentRoleModelParameters, availability: availability
                )
                if label == "interactive-only candidate" {
                    let executable = try XCTUnwrap(pin, label)
                    XCTAssertEqual(executable.selection.agent, .antigravity)
                    XCTAssertFalse(surface.allows(executable.selection.agent))
                } else {
                    XCTAssertNil(pin, label)
                }
                let omitted = try AgentMCPSelectionResolver.resolve(
                    modelID: nil, defaultTaskLabel: .pair, availability: availability,
                    workspaceID: workspaceID, surface: surface
                )
                assertSelection(omitted, agent: nil, model: nil, role: nil, label: label)
                XCTAssertThrowsError(try AgentMCPSelectionResolver.resolve(
                    modelID: "pair", availability: availability, workspaceID: workspaceID, surface: surface
                ), label) { error in
                    switch error {
                    case let MCPError.invalidParams(message):
                        XCTAssertEqual(message, "No available agent/model for task label 'pair'.", label)
                    default:
                        XCTFail("\(label): unexpected error \(error)")
                    }
                }
            }
            // Same valid interactive pin is eligible on general; only headless must retain nil.
            let general = try AgentMCPSelectionResolver.resolve(
                modelID: nil, defaultTaskLabel: .pair, availability: .none.assumingAvailable(.antigravity),
                workspaceID: workspaceID, surface: .general
            )
            assertSelection(general, agent: .antigravity, model: interactiveModel, role: .pair, label: "eligible general control")
        }
    }

    @MainActor
    func testExistingSelectionPrecedenceAndNonRoleBehaviorRemainUnchanged() throws {
        try withFixture { settings in
            settings.setGlobalAgentModelsProfile(profile(settings, model: globalModel, effort: "high"), contextBuilderWriteIntent: .preserveExistingOwnership)
            let provided = try AgentMCPSelectionResolver.resolve(
                modelID: "pair", availability: openCodeOnly,
                roleSelectionProvider: { _, _ in .init(agent: .openCode, modelRaw: self.workspaceModel) }
            )
            assertSelection(provided, agent: .openCode, model: workspaceModel, role: .pair, label: "provider precedence")

            let noDefault = try AgentMCPSelectionResolver.resolve(modelID: nil, availability: openCodeOnly)
            assertSelection(noDefault, agent: nil, model: nil, role: nil, label: "no default")
            let compound = try AgentMCPSelectionResolver.resolve(modelID: "openCode:\(workspaceModel)", availability: openCodeOnly)
            assertSelection(compound, agent: .openCode, model: workspaceModel, role: nil, label: "compound ID")

            let recommendedAvailability = AgentModelCatalog.AvailabilityContext.none.assumingAvailable(.codexExec)
            let effective = try XCTUnwrap(MCPAgentRoleDefaultsService.effectiveSelection(for: .pair, availability: recommendedAvailability))
            XCTAssertTrue(effective.hasStoredOverride)
            XCTAssertTrue(effective.overrideUnavailable)
            XCTAssertEqual(effective.effective.agent, .codexExec)
            XCTAssertEqual(effective.modelParameters, [])
            let fallback = try AgentMCPSelectionResolver.resolve(modelID: "pair", availability: recommendedAvailability)
            assertSelection(fallback, agent: effective.effective.agent, model: effective.effective.modelRaw, role: .pair, label: "existing unavailable-pin recommendation")
        }
    }

    @MainActor
    private func withFixture(_ body: (GlobalSettingsStore) throws -> Void) throws {
        let settings = GlobalSettingsStore.shared
        let originalProfile = settings.globalAgentModelsProfile()
        let registry = AgentACPModelRegistry.shared
        defer {
            settings.setGlobalAgentModelsProfile(originalProfile, contextBuilderWriteIntent: .preserveExistingOwnership)
            registry.test_reset(providerID: .openCode)
            registry.test_reset(providerID: .antigravity)
        }
        registry.test_reset(providerID: .openCode)
        registry.test_reset(providerID: .antigravity)
        _ = registry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [globalModel, workspaceModel].map {
                    AgentModelOption(rawValue: $0, displayName: $0, description: nil, isDefault: $0 == globalModel)
                },
                currentModelRaw: globalModel
            ), for: .openCode
        )
        _ = registry.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(rawValue: interactiveModel, displayName: interactiveModel, description: nil, isDefault: true)],
                currentModelRaw: interactiveModel
            ), for: .antigravity
        )
        try body(settings)
    }

    @MainActor
    private func profile(_ settings: GlobalSettingsStore, model: String, effort: String) -> AgentModelsSettingsProfile {
        var result = settings.globalAgentModelsProfile()
        result.mcpAgentRoleOverrides = ["pair": "openCode:\(model)"]
        result.mcpAgentRoleModelParameters = ["pair": [parameter(model: model, effort: effort)]]
        return result
    }

    private func parameter(model: String, effort: String) -> ACPModelParameterSelection {
        ACPModelParameterSelection(providerID: .openCode, baseModelRaw: model, kind: .thinking, configID: "effort", valueRaw: effort)
    }

    private func assertSelection(
        _ result: AgentMCPSelectionResolver.ResolvedSelection,
        agent: AgentProviderKind?, model: String?, role: AgentModelCatalog.TaskLabelKind?,
        parameters: [ACPModelParameterSelection] = [], label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(result.agentRaw, agent?.rawValue, label, file: file, line: line)
        XCTAssertEqual(result.modelRaw, model, label, file: file, line: line)
        XCTAssertEqual(result.taskLabelKind, role, label, file: file, line: line)
        XCTAssertEqual(result.modelParameterSelections, parameters, label, file: file, line: line)
        XCTAssertFalse(result.usageBalancingEligible, label, file: file, line: line)
    }
}

@MainActor
final class AntigravityRuntimeManagerTests: XCTestCase {
    private static let archiveData = Data(base64Encoded: "UEsDBBQAAAAAAAAAIVzihkXDEQAAABEAAAASAAAAYWd5X2FjcF9zZXJ2ZXIucGFyIyEvYmluL3NoCmV4aXQgMApQSwMEFAAAAAAAAAAhXOKGRcMRAAAAEQAAABUAAABsb2NhbGhhcm5lc3NfZXh0ZXJuYWwjIS9iaW4vc2gKZXhpdCAwClBLAQIUAxQAAAAAAAAAIVzihkXDEQAAABEAAAASAAAAAAAAAAAAAADtgQAAAABhZ3lfYWNwX3NlcnZlci5wYXJQSwECFAMUAAAAAAAAACFc4oZFwxEAAAARAAAAFQAAAAAAAAAAAAAA7YFBAAAAbG9jYWxoYXJuZXNzX2V4dGVybmFsUEsFBgAAAAACAAIAgwAAAIUAAAAAAA==")!

    func testRequestedReleaseUsesAsyncExtractionAndReplacesOnlyIncompleteInstallation() async throws {
        let root = try makeRoot()
        let data = Self.archiveData
        let release = Self.release(data: data)
        let current = root.appendingPathComponent(AntigravityRuntimeRelease.current.version, isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Self.writeExecutable("existing current runtime", at: current.appendingPathComponent(release.executable))
        try Self.writeExecutable("existing current harness", at: current.appendingPathComponent(release.harness))
        let incomplete = root.appendingPathComponent(release.version, isDirectory: true)
        try FileManager.default.createDirectory(at: incomplete, withIntermediateDirectories: true)
        try Self.writeExecutable("old partial runtime", at: incomplete.appendingPathComponent(release.executable))
        let manager = AntigravityRuntimeManager(root: root, download: { url in
            await Task.yield()
            return Self.response(data: data, url: url)
        })

        let installed = try await manager.install(release)
        XCTAssertEqual(installed.command, incomplete.appendingPathComponent(release.executable).path)
        XCTAssertEqual(installed.harness, incomplete.appendingPathComponent(release.harness).path)
        XCTAssertEqual(try String(contentsOfFile: installed.command, encoding: .utf8), "#!/bin/sh\nexit 0\n")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.harness))
        let requested = await manager.installedRuntime(release)
        let stillCurrent = await manager.installedRuntime()
        XCTAssertEqual(requested?.command, installed.command)
        XCTAssertEqual(stillCurrent?.command, current.appendingPathComponent(release.executable).path)
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent(release.executable), encoding: .utf8), "existing current runtime")
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: root.path)), [release.version, AntigravityRuntimeRelease.current.version])
    }

    func testConcurrentAttemptsNeverPublishPartialRuntimeOrRemoveTheWinner() async throws {
        for completion in [LateCompletion.success, .failure, .cancelled] {
            let root = try makeRoot()
            let data = Self.archiveData
            let release = Self.release(data: data)
            let firstEntered = expectation(description: "first extraction held: \(completion)")
            let secondEntered = expectation(description: "second extraction held: \(completion)")
            let extraction = AntigravityControlledExtraction(
                release: release, entered: [firstEntered, secondEntered], failFirst: completion == .failure
            )
            let manager = AntigravityRuntimeManager(
                root: root, download: { Self.response(data: data, url: $0) },
                extractArchive: { try await extraction.run(archive: $0, payload: $1) }
            )
            let late = Task { try await manager.install(release) }
            addTeardownBlock {
                late.cancel()
                await extraction.releaseAll()
                _ = await late.result
            }
            await fulfillment(of: [firstEntered], timeout: 5)
            let winner = Task { try await manager.install(release) }
            addTeardownBlock {
                winner.cancel()
                await extraction.releaseAll()
                _ = await winner.result
            }
            await fulfillment(of: [secondEntered], timeout: 5)
            let attempts = await extraction.attempts
            XCTAssertEqual(Set(attempts.map(\.archive)).count, 2)
            XCTAssertEqual(Set(attempts.map(\.payload)).count, 2)
            for attempt in attempts {
                XCTAssertEqual(try Data(contentsOf: attempt.archive), data)
            }
            let whileExtracting = await manager.installedRuntime(release)
            XCTAssertNil(whileExtracting)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(release.version).path))

            await extraction.release(1)
            let published = try await winner.value
            XCTAssertEqual(try String(contentsOfFile: published.command, encoding: .utf8), "attempt-1")
            if completion == .cancelled { late.cancel() }
            await extraction.release(0)
            do {
                let result = try await late.value
                XCTAssertEqual(completion, .success)
                XCTAssertEqual(result.command, published.command)
            } catch is CancellationError {
                XCTAssertEqual(completion, .cancelled)
            } catch AntigravityRuntimeError.invalidArchive {
                XCTAssertEqual(completion, .failure)
            }
            XCTAssertEqual(try String(contentsOfFile: published.command, encoding: .utf8), "attempt-1")
            XCTAssertEqual(try String(contentsOfFile: published.harness, encoding: .utf8), "harness-1")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [release.version])
        }
    }

    func testInvalidHarnessCannotPublishAnInstallation() async throws {
        for invalidHarness in ["missing", "directory", "not executable"] {
            let root = try makeRoot()
            let data = Self.archiveData
            let release = Self.release(data: data)
            let manager = AntigravityRuntimeManager(
                root: root, download: { Self.response(data: data, url: $0) },
                extractArchive: { _, payload in
                    try Self.writeExecutable("partial executable", at: payload.appendingPathComponent(release.executable))
                    let harness = payload.appendingPathComponent(release.harness)
                    if invalidHarness == "directory" {
                        try FileManager.default.createDirectory(at: harness, withIntermediateDirectories: false)
                    } else if invalidHarness == "not executable" {
                        try Data("harness".utf8).write(to: harness)
                        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: harness.path)
                    }
                }
            )
            do {
                _ = try await manager.install(release)
                XCTFail("accepted \(invalidHarness) harness")
            } catch AntigravityRuntimeError.invalidArchive {}
            let installed = await manager.installedRuntime(release)
            XCTAssertNil(installed)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    func testChecksumAndHTTPFailuresNeverReachExtraction() async throws {
        for invalidChecksum in [false, true] {
            let root = try makeRoot()
            let data = Self.archiveData
            let release = Self.release(data: invalidChecksum ? Data("different bytes".utf8) : data)
            let manager = AntigravityRuntimeManager(
                root: root,
                download: { Self.response(data: data, url: $0, status: invalidChecksum ? 200 : 503) },
                extractArchive: { _, _ in XCTFail("unverified download reached extraction") }
            )
            do {
                _ = try await manager.install(release)
                XCTFail("accepted invalid download")
            } catch AntigravityRuntimeError.checksumMismatch {
                XCTAssertTrue(invalidChecksum)
            } catch AntigravityRuntimeError.unavailable {
                XCTAssertFalse(invalidChecksum)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        }
    }

    private func makeRoot() throws -> URL {
        let sandbox = try WorkspaceTestProcessSandbox.validate()
        let root = sandbox.appendingPathComponent("antigravity-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private nonisolated static func release(data: Data) -> AntigravityRuntimeRelease {
        AntigravityRuntimeRelease(
            version: "fixture-runtime", url: URL(string: "https://example.invalid/runtime.zip")!,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            executable: AntigravityRuntimeRelease.current.executable, harness: AntigravityRuntimeRelease.current.harness
        )
    }

    private nonisolated static func response(data: Data, url: URL, status: Int = 200) -> (Data, URLResponse) {
        (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    fileprivate nonisolated static func writeExecutable(_ contents: String, at url: URL) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private enum LateCompletion {
        case success, failure, cancelled
    }
}

private actor AntigravityControlledExtraction {
    struct Attempt {
        let archive: URL
        let payload: URL
    }

    private let release: AntigravityRuntimeRelease
    private let entered: [XCTestExpectation]
    private let failFirst: Bool
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private(set) var attempts: [Attempt] = []

    init(release: AntigravityRuntimeRelease, entered: [XCTestExpectation], failFirst: Bool) {
        self.release = release
        self.entered = entered
        self.failFirst = failFirst
    }

    func run(archive: URL, payload: URL) async throws {
        let index = attempts.count
        attempts.append(Attempt(archive: archive, payload: payload))
        try AntigravityRuntimeManagerTests.writeExecutable("attempt-\(index)", at: payload.appendingPathComponent(release.executable))
        entered[index].fulfill()
        if !released.contains(index) {
            await withCheckedContinuation { continuations[index] = $0 }
        }
        if index == 0, failFirst { throw AntigravityRuntimeError.invalidArchive }
        try AntigravityRuntimeManagerTests.writeExecutable("harness-\(index)", at: payload.appendingPathComponent(release.harness))
    }

    func release(_ index: Int) {
        released.insert(index)
        continuations.removeValue(forKey: index)?.resume()
    }

    func releaseAll() {
        for index in entered.indices {
            release(index)
        }
    }
}
