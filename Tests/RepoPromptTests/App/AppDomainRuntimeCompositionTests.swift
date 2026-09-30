import Foundation
import JSONSchema
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

@MainActor
final class AppDomainRuntimeCompositionTests: XCTestCase {
    func testCollectLegacyRuntimeDefaultsSerializesBooleanScalarFragments() throws {
        for value in [true, false] {
            let (defaults, suiteName) = try makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(value, forKey: "agentModeAutoEditEnabled")

            let collected = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)
            let data = try XCTUnwrap(collected["agentModeAutoEditEnabled"])

            XCTAssertEqual(try JSONDecoder().decode(Bool.self, from: data), value)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), value ? "true" : "false")
        }
    }

    func testCollectLegacyRuntimeDefaultsPreservesRawDataAlongsideBoolean() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let approvalBytes = Data([0x00, 0xFF, 0x7B, 0x01])
        defaults.set(approvalBytes, forKey: "workspace.approvalSettings")
        defaults.set(false, forKey: "agentModeAutoEditEnabled")

        let collected = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)

        XCTAssertEqual(collected["workspace.approvalSettings"], approvalBytes)
        let booleanData = try XCTUnwrap(collected["agentModeAutoEditEnabled"])
        XCTAssertFalse(try JSONDecoder().decode(Bool.self, from: booleanData))
    }

    func testCollectLegacyRuntimeDefaultsSkipsInvalidValueWithoutMutationAndIsRepeatable() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let invalidDate = Date(timeIntervalSince1970: 1_725_000_000)
        defaults.set(invalidDate, forKey: "workspace.approvalSettings")
        defaults.set(true, forKey: "agentModeAutoEditEnabled")

        let first = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)
        let second = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)

        XCTAssertEqual(first, second)
        XCTAssertNil(first["workspace.approvalSettings"])
        let booleanData = try XCTUnwrap(first["agentModeAutoEditEnabled"])
        XCTAssertTrue(try JSONDecoder().decode(Bool.self, from: booleanData))
        XCTAssertEqual(defaults.object(forKey: "workspace.approvalSettings") as? Date, invalidDate)
        XCTAssertEqual(defaults.object(forKey: "agentModeAutoEditEnabled") as? Bool, true)
    }

    func testAppDomainBindingPreparationPassesAskUserThroughLongRunningInteractionAdapter() async throws {
        let (runtime, root) = try makeRuntime()
        addTeardownBlock {
            _ = await runtime.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        try await runtime.start()

        let probe = AppDomainInteractionProbe()
        let tool = Tool(
            name: MCPWindowToolName.askUser,
            description: "ask-user wrapper fixture",
            inputSchema: .object(properties: [:]),
            returnsValue: { _ in
                await probe.recordPresentation()
                return .string("presented")
            }
        )
        let adapter = DomainLongRunningInteractionAdapter(
            isAvailable: { _ in
                await probe.recordAvailability()
                return true
            },
            resolveDefaultTimeoutSeconds: { _ in 1 },
            cancel: { _ in await probe.recordCancellation() }
        )

        let bindings = try runtime.prepareAppDomainBindings(
            tools: [tool],
            interactionAdapter: adapter
        )
        let binding = try XCTUnwrap(bindings.first)
        let result = try await binding(["timeout_seconds": .int(1)])

        let availabilityCount = await probe.availabilityCount
        let presentationCount = await probe.presentationCount
        let cancellationCount = await probe.cancellationCount
        XCTAssertEqual(result.stringValue, "presented")
        XCTAssertEqual(availabilityCount, 1)
        XCTAssertEqual(presentationCount, 1)
        XCTAssertEqual(cancellationCount, 0)
    }

    func testAtomicApplicationRegistrationPublishesProtectedWindowRoutingBindings() async throws {
        let (runtime, root) = try makeRuntime()
        let composition = AppGlobalMCPServiceComposition(
            runtime: runtime,
            windowStates: .shared,
            networkManager: .shared
        )
        addTeardownBlock {
            _ = await runtime.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        try await composition.ensureRegistered()

        let snapshot = await runtime.toolRegistry.snapshot()
        XCTAssertTrue(
            snapshot.activeScopesByToolName[MCPGlobalToolName.bindContext]?.contains(.application) == true
        )
        let resolvedBinding = await runtime.toolRegistry.resolve(
            toolName: MCPGlobalToolName.bindContext,
            scope: .application
        )
        let resolved = try XCTUnwrap(resolvedBinding)

        do {
            _ = try await resolved.binding(["op": .string("bind")])
            XCTFail("Expected atomic app-domain registration to publish the protected binding")
        } catch let error as DomainMutationPolicyError {
            XCTAssertEqual(error, .principalMissing)
        }
    }

    func testAppDomainBindingPreparationAppliesProtectedMutationWrapper() async throws {
        let (runtime, root) = try makeRuntime()
        addTeardownBlock {
            _ = await runtime.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        try await runtime.start()

        let probe = AppDomainInvocationProbe()
        let tool = Tool(
            name: MCPWindowToolName.manageSelection,
            description: "protected wrapper fixture",
            inputSchema: .object(properties: [:]),
            returnsValue: { _ in
                await probe.recordInvocation()
                return .string("raw")
            }
        )
        let bindings = try runtime.prepareAppDomainBindings(
            tools: [tool],
            interactionAdapter: nil
        )
        let binding = try XCTUnwrap(bindings.first)

        do {
            _ = try await binding(["op": .string("set")])
            XCTFail("Expected protected mutation without an invocation principal to be denied")
        } catch let error as DomainMutationPolicyError {
            XCTAssertEqual(error, .principalMissing)
        }
        let invocationCount = await probe.invocationCount
        XCTAssertEqual(invocationCount, 0)
    }

    private func makeIsolatedDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "AppDomainRuntimeCompositionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private func makeRuntime() throws -> (runtime: MCPDomainRuntime, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDomainRuntimeCompositionTests-\(UUID().uuidString)", isDirectory: true)
        let runtime = try MCPDomainRuntime(
            configuration: .init(
                mode: .app,
                profileIdentifier: "app-domain-registration-test",
                storageDirectory: root,
                eventDirectory: root.appendingPathComponent("Events", isDirectory: true),
                temporaryDirectory: root.appendingPathComponent("Temporary", isDirectory: true),
                externalReloadInterval: nil
            ),
            registryID: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000021"))
        )
        return (runtime, root)
    }
}

private actor AppDomainInteractionProbe {
    private(set) var availabilityCount = 0
    private(set) var presentationCount = 0
    private(set) var cancellationCount = 0

    func recordAvailability() {
        availabilityCount += 1
    }

    func recordPresentation() {
        presentationCount += 1
    }

    func recordCancellation() {
        cancellationCount += 1
    }
}

private actor AppDomainInvocationProbe {
    private(set) var invocationCount = 0

    func recordInvocation() {
        invocationCount += 1
    }
}
