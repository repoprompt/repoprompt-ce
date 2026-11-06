import Foundation
import RepoPromptAIContracts
@testable import RepoPromptDomainRuntime
import XCTest

private typealias TestCatalogRuntime = ModelCatalogRuntime<CatalogTestRegistry, CatalogTestRegistry, Bool>

private final class CatalogTestRegistry {
    func resolvedSnapshot(for _: AgentProviderKind) -> String? { nil }
    func currentLiveModels() -> [String] { [] }
}

private extension ModelCatalogRuntime where ACPRegistry == CatalogTestRegistry,
    CodexRegistry == CatalogTestRegistry, Availability == Bool
{
    convenience init(registerBackendChanges: @escaping (@escaping @Sendable () -> Void) -> Void) {
        self.init(
            dependencies: Dependencies(
                makeACPRegistry: { _ in CatalogTestRegistry() },
                makeCodexRegistry: { _ in CatalogTestRegistry() },
                isAgentAvailable: { _, available in available },
                reasoningEffortRaw: { _, _ in nil }
            ),
            registerBackendChanges: registerBackendChanges
        )
    }
}

final class AgentModelCatalogRuntimeOwnershipTests: XCTestCase {
    func testColdAdmissionDoesNotConstructRegistriesAndRegistryReadsDoNotSubscribe() {
        let recorder = CatalogRuntimeRegistrationRecorder()
        let admission = TestCatalogRuntime(registerBackendChanges: recorder.install)
        XCTAssertFalse(admission.test_initializedSlots.acp)
        XCTAssertFalse(admission.test_initializedSlots.codex)
        XCTAssertThrowsError(try admission.selection("cursor:auto", availability: true))
        XCTAssertEqual(recorder.installCount, 1)
        XCTAssertFalse(admission.test_initializedSlots.acp)
        XCTAssertFalse(admission.test_initializedSlots.codex)

        let other = CatalogRuntimeRegistrationRecorder()
        let runtime = TestCatalogRuntime(registerBackendChanges: other.install)
        XCTAssertNil(runtime.acpRegistry.resolvedSnapshot(for: .cursor))
        XCTAssertTrue(runtime.test_initializedSlots.acp)
        XCTAssertFalse(runtime.test_initializedSlots.codex)
        _ = runtime.codexRegistry.currentLiveModels()
        XCTAssertTrue(runtime.test_initializedSlots.codex)
        XCTAssertEqual(other.installCount, 0)
    }

    func testConcurrentRegistryAccessConstructsOneInstancePerSlotWithoutSubscription() {
        let recorder = CatalogRuntimeRegistrationRecorder()
        let runtime = TestCatalogRuntime(registerBackendChanges: recorder.install)
        let identities = CatalogRuntimeIdentities()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            identities.append(acp: ObjectIdentifier(runtime.acpRegistry), codex: ObjectIdentifier(runtime.codexRegistry))
        }
        XCTAssertEqual(identities.acp.count, 1)
        XCTAssertEqual(identities.codex.count, 1)
        XCTAssertEqual(recorder.installCount, 0)
    }

    func testConcurrentActivationWaitsForRegistrationWithoutHoldingRuntimeLocks() {
        let entered = expectation(description: "registration entered")
        let firstCompleted = expectation(description: "first caller completed")
        let secondCompleted = expectation(description: "second caller completed")
        let notificationCompleted = expectation(description: "notification completed")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let recorder = CatalogRuntimeRegistrationRecorder()
        var runtime: TestCatalogRuntime!
        runtime = TestCatalogRuntime(registerBackendChanges: { handler in
            // Registration can consult a registry: no slot or index lock is held across this call.
            _ = runtime.acpRegistry.resolvedSnapshot(for: .cursor)
            recorder.install(handler)
            entered.fulfill()
            release.wait()
        })
        // These synchronous calls deliberately block. Keep them off Swift's cooperative pool,
        // and let only the test release registration rather than a wall-clock escape hatch.
        DispatchQueue(label: "catalog-test.first").async { [runtime = runtime!] in
            XCTAssertEqual(runtime.productionGeneration(for: .cursor), 0)
            firstCompleted.fulfill()
        }
        wait(for: [entered], timeout: 5)
        let secondDone = DispatchSemaphore(value: 0)
        let notificationDone = DispatchSemaphore(value: 0)
        DispatchQueue(label: "catalog-test.second").async { [runtime = runtime!] in
            XCTAssertEqual(runtime.productionGeneration(for: .cursor), 0)
            secondDone.signal()
            secondCompleted.fulfill()
        }
        DispatchQueue(label: "catalog-test.notification").async {
            recorder.notify()
            notificationDone.signal()
            notificationCompleted.fulfill()
        }
        let bothWaiting = runtime.test_waitForActivationWaiter() && runtime.test_waitForActivationWaiter()
        XCTAssertTrue(bothWaiting, "Both callers must reach the activation wait before registration completes")
        XCTAssertEqual(secondDone.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(notificationDone.wait(timeout: .now()), .timedOut)
        release.signal()
        wait(for: [firstCompleted, secondCompleted, notificationCompleted], timeout: 5)
        XCTAssertEqual(runtime.productionGeneration(for: .claudeCodeGLM), 1)
        XCTAssertEqual(recorder.installCount, 1)
    }

    func testAdmissionRetainsExactOptionMetadataAndNeverReevaluatesProducerPolicy() throws {
        var decompositionCount = 0
        let runtime = TestCatalogRuntime(
            dependencies: .init(
                makeACPRegistry: { _ in XCTFail("Admission must not construct ACP"); return CatalogTestRegistry() },
                makeCodexRegistry: { _ in XCTFail("Admission must not construct Codex"); return CatalogTestRegistry() },
                isAgentAvailable: { _, available in available },
                reasoningEffortRaw: { _, _ in decompositionCount += 1; return "future-effort" }
            ),
            registerBackendChanges: { _ in }
        )
        let option = AgentModelOption(
            rawValue: "Exact:Model-high", displayName: "Exact", description: "Metadata",
            isPlaceholderDefault: false, isProviderDefault: true,
            supportedReasoningEffortRawValues: ["future-effort"],
            defaultReasoningEffortRawValue: "future-effort", contextWindowTokens: 12345
        )
        let id = AgentModelSelectionID(agentRaw: "codexExec", modelRaw: option.rawValue).rawValue
        XCTAssertThrowsError(try runtime.selection(id, availability: true))
        XCTAssertTrue(runtime.record([option], for: .codexExec, generation: runtime.productionGeneration(for: .codexExec)))
        let selection = try runtime.selection(id, availability: true)
        XCTAssertEqual(selection.option, option)
        XCTAssertEqual(selection.id.rawValue, id)
        XCTAssertEqual(selection.storedModelRaw, option.rawValue)
        XCTAssertEqual(selection.reasoningEffortRaw, "future-effort")
        XCTAssertEqual(decompositionCount, 1)
        XCTAssertThrowsError(try runtime.selection(id.lowercased(), availability: true))
        XCTAssertThrowsError(try runtime.selection(id, availability: false))
        XCTAssertEqual(runtime.modelIDs(for: .codexExec, availability: true), [id])
        XCTAssertEqual(runtime.modelIDs(for: .codexExec, availability: false), [])
        XCTAssertEqual(decompositionCount, 1)
    }

    func testRecoveryHintsStaySortedBoundedAndMemoryOnlyAfterInvalidation() {
        let runtime = TestCatalogRuntime(registerBackendChanges: { _ in })
        let options = (0 ..< 12).reversed().map {
            AgentModelOption(rawValue: String(format: "model-%02d", $0), displayName: "Model", description: nil,
                             isPlaceholderDefault: false, isProviderDefault: false)
        }
        let generation = runtime.productionGeneration(for: .cursor)
        XCTAssertTrue(runtime.record(options, for: .cursor, generation: generation))
        XCTAssertEqual(runtime.modelIDs(for: .cursor, availability: true), (0 ..< 8).map { String(format: "cursor:model-%02d", $0) })
        runtime.invalidate(.cursor)
        XCTAssertEqual(runtime.modelIDs(for: .cursor, availability: true), [])
        XCTAssertFalse(runtime.record(options, for: .cursor, generation: generation))
        XCTAssertFalse(runtime.test_initializedSlots.acp)
        XCTAssertFalse(runtime.test_initializedSlots.codex)
    }

    func testBackendHandlerInstallsOnceAndInvalidatesCapturedGeneration() {
        let recorder = CatalogRuntimeRegistrationRecorder()
        let runtime = TestCatalogRuntime(registerBackendChanges: recorder.install)
        let agent = AgentProviderKind.claudeCodeGLM
        let generation = runtime.productionGeneration(for: agent)
        let option = AgentModelOption(rawValue: "runtime-test", displayName: "Runtime", description: nil, isPlaceholderDefault: false, isProviderDefault: false)
        XCTAssertTrue(runtime.record([option], for: agent, generation: generation))
        recorder.notify()
        XCTAssertFalse(runtime.record([option], for: agent, generation: generation))
        XCTAssertEqual(runtime.productionGeneration(for: agent), generation + 1)
        XCTAssertEqual(recorder.installCount, 1)
    }
}

private final class CatalogRuntimeRegistrationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var count = 0

    var installCount: Int {
        lock.withLock { count }
    }

    func install(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock {
            count += 1
            self.handler = handler
        }
    }

    func notify() {
        let installedHandler = lock.withLock { handler }
        installedHandler?()
    }
}

private final class CatalogRuntimeIdentities: @unchecked Sendable {
    private let lock = NSLock()
    private var acpValues: Set<ObjectIdentifier> = []
    private var codexValues: Set<ObjectIdentifier> = []
    var acp: Set<ObjectIdentifier> {
        lock.withLock { acpValues }
    }

    var codex: Set<ObjectIdentifier> {
        lock.withLock { codexValues }
    }

    func append(acp: ObjectIdentifier, codex: ObjectIdentifier) {
        lock.withLock {
            acpValues.insert(acp)
            codexValues.insert(codex)
        }
    }
}
