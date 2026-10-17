import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptSettingsCore
import RepoPromptShared
import XCTest

@MainActor
final class MCPLongRunningJobToolContractParityTests: XCTestCase {
    func testAppTicketToolDiscoveryMatchesStandaloneCanonicalDefinitions() throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        defer { GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false) }
        let window = WindowState()
        let tools = try window.mcpServer.windowMCPToolCatalogService.materializeTools()
        for name in [MCPWindowToolName.askOracle, MCPWindowToolName.oracleSend, MCPWindowToolName.contextBuilder] {
            let canonical = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: name))
            let appTool = try XCTUnwrap(tools.first { $0.name == name })
            XCTAssertEqual(appTool.description, canonical.description, name)
            try assertSchemaContract(Value(appTool.inputSchema), matches: canonical)
            XCTAssertEqual(appTool.annotations.title, canonical.annotations.title, name)
            XCTAssertEqual(appTool.annotations.readOnlyHint, canonical.annotations.readOnlyHint, name)
            XCTAssertEqual(appTool.annotations.destructiveHint, canonical.annotations.destructiveHint, name)
            XCTAssertEqual(appTool.annotations.idempotentHint, canonical.annotations.idempotentHint, name)
            XCTAssertEqual(appTool.annotations.openWorldHint, canonical.annotations.openWorldHint, name)
            XCTAssertEqual(appTool.isEnabledByDefault, canonical.isEnabledByDefault, name)
            XCTAssertEqual(try appTool.domainBinding().definition, canonical, name)
        }
    }

    func testBinderPreservesLocalMetadataAndCanonicalizationPreservesExecution() async throws {
        let runtime = MCPAppToolBinder(windowID: 42) { name, freshness, args, implementation in
            guard case .providerManaged = freshness else {
                throw MCPError.internalError("Unexpected freshness policy")
            }
            return try await implementation(
                MCPAppToolInvocation(
                    toolName: name,
                    windowID: 42,
                    context: .trustedLocal(toolName: name, metadata: .init(connectionID: nil, clientName: nil, windowID: 42))
                ),
                args
            )
        }
        for name in [MCPWindowToolName.askOracle, MCPWindowToolName.oracleSend, MCPWindowToolName.contextBuilder] {
            let local = runtime.tool(
                name: name,
                freshnessPolicy: .providerManaged,
                description: "Local provider guidance",
                inputSchema: .object(properties: [
                    "op": .string(description: MCPLongRunningJobToolContract.operationDescription, enum: ["start", "poll", "wait", "cancel"]),
                    "job_id": .string(description: MCPLongRunningJobToolContract.jobIDDescription),
                    "detach": .boolean(description: MCPLongRunningJobToolContract.detachDescription),
                    "timeout": .number(description: MCPLongRunningJobToolContract.timeoutDescription)
                ], required: [])
            ) { invocation, args in
                .object([
                    "tool": .string(invocation.toolName),
                    "window_id": .int(invocation.windowID),
                    "arguments": .object(args)
                ])
            }
            XCTAssertEqual(local.description, "Local provider guidance")
            let localProperties = try XCTUnwrap(Value(local.inputSchema).objectValue?["properties"]?.objectValue)
            let canonical = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: name))
            let canonicalProperties = try XCTUnwrap(canonical.inputSchema.objectValue?["properties"]?.objectValue)
            for property in ["op", "job_id", "detach", "timeout"] {
                XCTAssertEqual(localProperties[property], canonicalProperties[property], "\(name).\(property)")
            }
            let projected = try RepoPromptApp.Tool(canonicalizing: local)
            XCTAssertEqual(projected.description, canonical.description, name)
            try assertSchemaContract(Value(projected.inputSchema), matches: canonical)
            let args: [String: Value] = ["op": .string("start"), "detach": .bool(true), "message": .string("fixture")]
            let result = try await projected(args)
            XCTAssertEqual(result, .object([
                "tool": .string(name),
                "window_id": .int(42),
                "arguments": .object(args)
            ]), name)
        }
    }

    private func assertSchemaContract(_ schema: Value, matches canonical: MCPDomainToolDefinition) throws {
        let name = canonical.name
        let appSchema = try XCTUnwrap(schema.objectValue, name)
        let canonicalSchema = try XCTUnwrap(canonical.inputSchema.objectValue, name)
        let appProperties = try XCTUnwrap(appSchema["properties"]?.objectValue, name)
        let canonicalProperties = try XCTUnwrap(canonicalSchema["properties"]?.objectValue, name)
        XCTAssertEqual(appSchema["type"], canonicalSchema["type"], name)
        XCTAssertEqual(appSchema["required"] ?? .array([]), try XCTUnwrap(canonicalSchema["required"], name), name)
        let ticketProperties: Set = ["op", "job_id", "detach", "timeout"]
        XCTAssertTrue(ticketProperties.isSubset(of: Set(canonicalProperties.keys)), "\(name): missing canonical ticket properties")
        for (property, expected) in canonicalProperties {
            XCTAssertEqual(appProperties[property], expected, "\(name).\(property)")
        }
        var allowedExtras: Set<String> = []
        #if DEBUG
            if [MCPWindowToolName.askOracle, MCPWindowToolName.oracleSend].contains(name) {
                allowedExtras = ["debug_primary_only", "debug_lane_timeout_seconds"]
            }
        #endif
        let extras = Set(appProperties.keys).subtracting(canonicalProperties.keys)
        XCTAssertTrue(extras.isSubset(of: allowedExtras), "\(name): unexpected schema properties \(extras.subtracting(allowedExtras))")
    }
}

@MainActor
final class MCPToolCatalogReadinessTests: XCTestCase {
    func testReadinessCoalescesLightweightScopeQueriesForOneTenAndOneHundredWaiters() async throws {
        #if DEBUG
            for waiterCount in [1, 10, 100] {
                let queryProbe = MCPReadinessScopePresenceProbe()
                let joinedCounter = MCPReadinessTestCounter()
                let readiness = MCPToolCatalogReadiness(
                    scopePresenceOperation: { requiredNames, scope in
                        await queryProbe.query(requiredNames: requiredNames, scope: scope)
                    },
                    windowStateOperation: { _ in
                        MCPToolCatalogReadiness.WindowRegistrationState(
                            toolsEnabled: true,
                            toolsRequested: true
                        )
                    },
                    checkJoinedOperation: { _ in
                        await joinedCounter.increment()
                    }
                )
                let waiters = (0 ..< waiterCount).map { _ in
                    Task { await readiness.awaitReady(windowID: 901, timeout: 5) }
                }

                do {
                    guard await queryProbe.waitUntilQueryEntered(1, timeout: .seconds(2)) else {
                        throw MCPReadinessTestTimeout(label: "first readiness scope query")
                    }
                    guard await joinedCounter.waitUntilAtLeast(waiterCount, timeout: .seconds(2)) else {
                        throw MCPReadinessTestTimeout(
                            label: "\(waiterCount) readiness callers joining the shared check"
                        )
                    }

                    let queryCountWhileBlocked = await queryProbe.queryCountValue()
                    XCTAssertEqual(
                        queryCountWhileBlocked,
                        1,
                        "\(waiterCount) concurrent waiters must share the initial application-scope query."
                    )

                    await queryProbe.releaseFirstQuery()
                    for waiter in waiters {
                        let ready = try await valueWithin(
                            waiter,
                            timeout: .seconds(2),
                            label: "coalesced readiness waiter"
                        )
                        XCTAssertTrue(ready)
                    }
                    let finalQueryCount = await queryProbe.queryCountValue()
                    XCTAssertEqual(
                        finalQueryCount,
                        2,
                        "Readiness should perform one application and one window scope-presence query regardless of waiter count."
                    )
                } catch {
                    waiters.forEach { $0.cancel() }
                    await queryProbe.releaseFirstQuery()
                    for waiter in waiters {
                        _ = try? await valueWithin(
                            waiter,
                            timeout: .seconds(2),
                            label: "coalescing cleanup"
                        )
                    }
                    let observedJoins = await joinedCounter.countValue()
                    let observedQueries = await queryProbe.queryCountValue()
                    XCTFail(
                        "Readiness coalescing setup failed for \(waiterCount) waiters: \(error); "
                            + "joined=\(observedJoins), queries=\(observedQueries)"
                    )
                }
            }
        #else
            throw XCTSkip("Readiness operation-count probes require DEBUG test seams.")
        #endif
    }

    func testReadinessCallerDeadlineDoesNotCancelSharedCheck() async throws {
        #if DEBUG
            let queryProbe = MCPReadinessScopePresenceProbe()
            let joinedCounter = MCPReadinessTestCounter()
            let readiness = MCPToolCatalogReadiness(
                scopePresenceOperation: { requiredNames, scope in
                    await queryProbe.query(requiredNames: requiredNames, scope: scope)
                },
                windowStateOperation: { _ in
                    MCPToolCatalogReadiness.WindowRegistrationState(
                        toolsEnabled: true,
                        toolsRequested: true
                    )
                },
                checkJoinedOperation: { _ in
                    await joinedCounter.increment()
                }
            )
            let longWaiters = (0 ..< 2).map { _ in
                Task { await readiness.awaitReady(windowID: 902, timeout: 5) }
            }
            let shortWaiter = Task {
                await readiness.awaitReady(windowID: 902, timeout: 0.05)
            }
            let survivingWaiter = longWaiters[1]
            let cancelledWaiter = longWaiters[0]
            var lateWaiter: Task<Bool, Never>?

            do {
                guard await queryProbe.waitUntilQueryEntered(1, timeout: .seconds(2)) else {
                    throw MCPReadinessTestTimeout(label: "blocked readiness scope query")
                }
                guard await joinedCounter.waitUntilAtLeast(3, timeout: .seconds(2)) else {
                    throw MCPReadinessTestTimeout(label: "initial readiness callers joining the shared check")
                }

                let shortResult = try await valueWithin(
                    shortWaiter,
                    timeout: .seconds(2),
                    label: "short readiness caller deadline",
                    cleanup: {
                        await queryProbe.releaseFirstQuery()
                    }
                )
                XCTAssertFalse(
                    shortResult,
                    "The caller-local deadline must expire while the shared query remains held."
                )
                let queryCountAfterShortDeadline = await queryProbe.queryCountValue()
                XCTAssertEqual(
                    queryCountAfterShortDeadline,
                    1,
                    "A timed-out caller must not start a replacement query or cancel shared work."
                )

                cancelledWaiter.cancel()
                let cancelledResult = try await valueWithin(
                    cancelledWaiter,
                    timeout: .seconds(2),
                    label: "explicit readiness caller cancellation",
                    cleanup: {
                        await queryProbe.releaseFirstQuery()
                    }
                )
                XCTAssertFalse(
                    cancelledResult,
                    "Cancelling one caller must resolve only that caller while the shared query remains held."
                )
                let queryCountAfterCancellation = await queryProbe.queryCountValue()
                XCTAssertEqual(
                    queryCountAfterCancellation,
                    1,
                    "A cancelled caller must not cancel or replace the shared readiness query."
                )

                let lateWaiterTask = Task {
                    await readiness.awaitReady(windowID: 902, timeout: 5)
                }
                lateWaiter = lateWaiterTask
                guard await joinedCounter.waitUntilAtLeast(4, timeout: .seconds(2)) else {
                    throw MCPReadinessTestTimeout(label: "late readiness caller joining after the short deadline")
                }
                let queryCountAfterLateJoin = await queryProbe.queryCountValue()
                XCTAssertEqual(
                    queryCountAfterLateJoin,
                    1,
                    "The shared check must remain registered for callers arriving after another caller times out."
                )

                await queryProbe.releaseFirstQuery()
                let survivingReady = try await valueWithin(
                    survivingWaiter,
                    timeout: .seconds(2),
                    label: "surviving readiness waiter"
                )
                XCTAssertTrue(survivingReady)
                let lateReady = try await valueWithin(
                    lateWaiterTask,
                    timeout: .seconds(2),
                    label: "late readiness waiter"
                )
                XCTAssertTrue(lateReady)
                let finalQueryCount = await queryProbe.queryCountValue()
                XCTAssertEqual(
                    finalQueryCount,
                    2,
                    "The surviving shared check should issue exactly one application and one window query."
                )
            } catch {
                longWaiters.forEach { $0.cancel() }
                shortWaiter.cancel()
                lateWaiter?.cancel()
                await queryProbe.releaseFirstQuery()
                for waiter in longWaiters {
                    _ = try? await valueWithin(
                        waiter,
                        timeout: .seconds(2),
                        label: "caller-deadline cleanup"
                    )
                }
                _ = try? await valueWithin(
                    shortWaiter,
                    timeout: .seconds(2),
                    label: "short caller cleanup"
                )
                if let lateWaiter {
                    _ = try? await valueWithin(
                        lateWaiter,
                        timeout: .seconds(2),
                        label: "late caller cleanup"
                    )
                }
                let observedJoins = await joinedCounter.countValue()
                let observedQueries = await queryProbe.queryCountValue()
                XCTFail(
                    "Readiness caller-deadline setup failed: \(error); "
                        + "joined=\(observedJoins), queries=\(observedQueries)"
                )
            }
        #else
            throw XCTSkip("Readiness operation-count probes require DEBUG test seams.")
        #endif
    }

    func testReadinessRetiresHungGenerationBeforeAllowingLateGeneration() async throws {
        #if DEBUG
            let ownerRetirementProbe = MCPReadinessRetirementSleepProbe()
            let joinedCounter = MCPReadinessTestCounter()
            let retiredCounter = MCPReadinessTestCounter()
            let settledCounter = MCPReadinessTestCounter()
            let queryProbe = MCPReadinessScopePresenceProbe(holdSecondQuery: true)
            // The first query intentionally ignores cancellation so late physical settlement
            // remains observable; cleanup opens its gate before draining waiter tasks.
            let releaseAllFixtures: @Sendable () async -> Void = {
                await queryProbe.releaseFirstQuery()
                await queryProbe.releaseSecondQuery()
                await ownerRetirementProbe.releaseFirst()
                await ownerRetirementProbe.releaseLater()
            }
            let readiness = MCPToolCatalogReadiness(
                scopePresenceOperation: { requiredNames, scope in
                    await queryProbe.query(requiredNames: requiredNames, scope: scope)
                },
                windowStateOperation: { _ in
                    MCPToolCatalogReadiness.WindowRegistrationState(
                        toolsEnabled: true,
                        toolsRequested: true
                    )
                },
                checkJoinedOperation: { _ in
                    await joinedCounter.increment()
                },
                sharedCheckRetirementSleep: { _ in
                    await ownerRetirementProbe.wait()
                },
                checkRetiredOperation: { _ in
                    await retiredCounter.increment()
                },
                checkSettledOperation: { _ in
                    await settledCounter.increment()
                }
            )

            let firstWaiter = Task {
                await readiness.awaitReady(windowID: 903, timeout: 0.05)
            }
            let survivingFirstWaiter = Task {
                await readiness.awaitReady(windowID: 903, timeout: 5)
            }
            var lateWaiter: Task<Bool, Never>?
            var thirdWaiter: Task<Bool, Never>?

            do {
                guard await queryProbe.waitUntilQueryEntered(1, timeout: .seconds(2)) else {
                    throw MCPReadinessTestTimeout(label: "first held readiness query")
                }
                guard await ownerRetirementProbe.waitUntilFirstEntered(timeout: .seconds(2)) else {
                    throw MCPReadinessTestTimeout(label: "first shared-check retirement owner")
                }
                guard await joinedCounter.waitUntilAtLeast(2, timeout: .seconds(2)) else {
                    throw MCPReadinessTestTimeout(label: "generation-one readiness callers joining the shared check")
                }

                let firstResult = try await valueWithin(
                    firstWaiter,
                    timeout: .seconds(2),
                    label: "first caller deadline",
                    cleanup: releaseAllFixtures
                )
                XCTAssertFalse(
                    firstResult,
                    "A caller timeout must return while the held shared attempt remains alive."
                )
                let queryCountAfterCallerTimeout = await queryProbe.queryCountValue()
                XCTAssertEqual(
                    queryCountAfterCallerTimeout,
                    1,
                    "A caller timeout must not start a replacement query."
                )

                await ownerRetirementProbe.releaseFirst()
                guard await retiredCounter.waitUntilAtLeast(1, timeout: .seconds(2)) else {
                    throw MCPReadinessTestTimeout(label: "owner retirement of the first generation")
                }
                let survivingFirstResult = try await valueWithin(
                    survivingFirstWaiter,
                    timeout: .seconds(2),
                    label: "surviving generation-one waiter retirement",
                    cleanup: releaseAllFixtures
                )
                XCTAssertFalse(
                    survivingFirstResult,
                    "Owner retirement must release a generation-one waiter that has not reached its own deadline."
                )

                let lateWaiterTask = Task {
                    await readiness.awaitReady(windowID: 903, timeout: 5)
                }
                lateWaiter = lateWaiterTask
                guard await queryProbe.waitUntilQueryEntered(2, timeout: .seconds(2)) else {
                    throw MCPReadinessTestTimeout(label: "second-generation readiness query")
                }
                guard await joinedCounter.waitUntilAtLeast(3, timeout: .seconds(2)) else {
                    throw MCPReadinessTestTimeout(label: "late readiness caller joining the second generation")
                }

                await queryProbe.releaseFirstQuery()
                guard await settledCounter.waitUntilAtLeast(1, timeout: .seconds(2)) else {
                    throw MCPReadinessTestTimeout(label: "late settlement of the retired first generation")
                }
                let queryCountAfterStaleSettlement = await queryProbe.queryCountValue()
                XCTAssertEqual(
                    queryCountAfterStaleSettlement,
                    3,
                    "The retired generation may finish late, but it must not start or remove another generation."
                )

                let thirdWaiterTask = Task {
                    await readiness.awaitReady(windowID: 903, timeout: 5)
                }
                thirdWaiter = thirdWaiterTask
                guard await joinedCounter.waitUntilAtLeast(4, timeout: .seconds(2)) else {
                    throw MCPReadinessTestTimeout(label: "third readiness caller joining the second generation")
                }
                let queryCountAfterThirdJoin = await queryProbe.queryCountValue()
                XCTAssertEqual(
                    queryCountAfterThirdJoin,
                    3,
                    "A caller arriving while generation 2 is held must join it after generation 1 settles late."
                )

                await queryProbe.releaseSecondQuery()
                let lateResult = try await valueWithin(
                    lateWaiterTask,
                    timeout: .seconds(2),
                    label: "second-generation late waiter"
                )
                let thirdResult = try await valueWithin(
                    thirdWaiterTask,
                    timeout: .seconds(2),
                    label: "second-generation third waiter"
                )
                await ownerRetirementProbe.releaseLater()

                XCTAssertTrue(lateResult)
                XCTAssertTrue(thirdResult)
                let finalQueryCount = await queryProbe.queryCountValue()
                XCTAssertEqual(
                    finalQueryCount,
                    4,
                    "Generation 2 should perform exactly one global and one window scope query."
                )
            } catch {
                firstWaiter.cancel()
                survivingFirstWaiter.cancel()
                lateWaiter?.cancel()
                thirdWaiter?.cancel()
                await queryProbe.releaseFirstQuery()
                await queryProbe.releaseSecondQuery()
                await ownerRetirementProbe.releaseFirst()
                await ownerRetirementProbe.releaseLater()
                _ = try? await valueWithin(
                    firstWaiter,
                    timeout: .seconds(2),
                    label: "retirement cleanup first waiter"
                )
                _ = try? await valueWithin(
                    survivingFirstWaiter,
                    timeout: .seconds(2),
                    label: "retirement cleanup surviving first waiter"
                )
                if let lateWaiter {
                    _ = try? await valueWithin(
                        lateWaiter,
                        timeout: .seconds(2),
                        label: "retirement cleanup late waiter"
                    )
                }
                if let thirdWaiter {
                    _ = try? await valueWithin(
                        thirdWaiter,
                        timeout: .seconds(2),
                        label: "retirement cleanup third waiter"
                    )
                }
                let observedJoins = await joinedCounter.countValue()
                let observedRetirements = await retiredCounter.countValue()
                let observedSettlements = await settledCounter.countValue()
                let observedQueries = await queryProbe.queryCountValue()
                XCTFail(
                    "Readiness retirement setup failed: \(error); "
                        + "joined=\(observedJoins), "
                        + "retired=\(observedRetirements), "
                        + "settled=\(observedSettlements), "
                        + "queries=\(observedQueries)"
                )
            }
        #else
            throw XCTSkip("Readiness retirement probes require DEBUG test seams.")
        #endif
    }
}

private struct MCPReadinessTestTimeout: Error, CustomStringConvertible {
    let label: String

    var description: String {
        "Timed out waiting for \(label)"
    }
}

private func valueWithin(
    _ task: Task<Bool, Never>,
    timeout: Duration,
    label: String,
    cleanup: @escaping @Sendable () async -> Void = {}
) async throws -> Bool {
    let resultBox = MCPReadinessTestResultBox()
    let observerTask = Task {
        let value = await task.value
        await resultBox.resolve(value)
    }
    let timeoutTask = Task {
        do {
            // This is only a finite watchdog; explicit gates establish all test ordering.
            try await ContinuousClock().sleep(for: timeout)
        } catch {
            return
        }
        await resultBox.timeout()
    }
    let result = await resultBox.wait()
    timeoutTask.cancel()
    _ = await timeoutTask.value

    // Timeout teardown owns the input: cancel it, then drain it and its observer.
    // The cleanup hook releases any cancellation-ignoring fixture gates before the input is drained.
    if result == nil {
        task.cancel()
        await cleanup()
    }
    _ = await task.value
    _ = await observerTask.value

    guard let result else {
        throw MCPReadinessTestTimeout(label: label)
    }
    return result
}

private actor MCPReadinessTestResultBox {
    private var resolved = false
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool?, Never>?

    func wait() async -> Bool? {
        if resolved {
            return result
        }
        return await withCheckedContinuation { continuation in
            if resolved {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }

    func resolve(_ result: Bool) {
        guard !resolved else { return }
        resolved = true
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    func timeout() {
        guard !resolved else { return }
        resolved = true
        continuation?.resume(returning: nil)
        continuation = nil
    }
}

private func makeReadinessWatchdog(
    timeout: Duration,
    onTimeout: @escaping @Sendable () async -> Void
) -> Task<Void, Never> {
    Task {
        do {
            try await ContinuousClock().sleep(for: timeout)
        } catch {
            return
        }
        await onTimeout()
    }
}

private func cancelAndDrainReadinessWatchdogs(_ watchdogs: [Task<Void, Never>]) async {
    watchdogs.forEach { $0.cancel() }
    for watchdog in watchdogs {
        _ = await watchdog.value
    }
}

private actor MCPReadinessTestGate {
    private struct EntryWaiter {
        let continuation: CheckedContinuation<Bool, Never>
        let watchdog: Task<Void, Never>
    }

    private var hasEntered = false
    private var isOpen = false
    private var entryWaiters: [UUID: EntryWaiter] = [:]
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        hasEntered = true
        let enteredWaiters = Array(entryWaiters.values)
        entryWaiters.removeAll()
        await cancelAndDrainReadinessWatchdogs(enteredWaiters.map(\.watchdog))
        enteredWaiters.forEach { $0.continuation.resume(returning: true) }

        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                openWaiters.append(continuation)
            }
        }
    }

    func waitUntilEntered(timeout: Duration) async -> Bool {
        if hasEntered {
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if hasEntered || Task.isCancelled {
                    continuation.resume(returning: hasEntered)
                    return
                }
                let watchdog = makeReadinessWatchdog(timeout: timeout) { [weak self] in
                    await self?.expireEntryWaiter(waiterID)
                }
                entryWaiters[waiterID] = EntryWaiter(
                    continuation: continuation,
                    watchdog: watchdog
                )
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelEntryWaiter(waiterID)
            }
        }
    }

    func release() {
        guard !isOpen else { return }
        isOpen = true
        let openWaiters = openWaiters
        self.openWaiters.removeAll()
        openWaiters.forEach { $0.resume() }
    }

    private func expireEntryWaiter(_ waiterID: UUID) {
        guard let waiter = entryWaiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(returning: false)
    }

    private func cancelEntryWaiter(_ waiterID: UUID) async {
        guard let waiter = entryWaiters.removeValue(forKey: waiterID) else { return }
        waiter.watchdog.cancel()
        _ = await waiter.watchdog.value
        waiter.continuation.resume(returning: false)
    }
}

private actor MCPReadinessTestCounter {
    private struct Waiter {
        let minimum: Int
        let continuation: CheckedContinuation<Bool, Never>
        let watchdog: Task<Void, Never>
    }

    private var count = 0
    private var waiters: [UUID: Waiter] = [:]

    func increment() async {
        count += 1
        let readyWaiters = waiters.filter { $0.value.minimum <= count }
        readyWaiters.keys.forEach { waiters.removeValue(forKey: $0) }
        await cancelAndDrainReadinessWatchdogs(readyWaiters.values.map(\.watchdog))
        readyWaiters.values.forEach { $0.continuation.resume(returning: true) }
    }

    func countValue() -> Int {
        count
    }

    func waitUntilAtLeast(_ minimum: Int, timeout: Duration) async -> Bool {
        guard count < minimum else { return true }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if count >= minimum || Task.isCancelled {
                    continuation.resume(returning: count >= minimum)
                    return
                }
                let watchdog = makeReadinessWatchdog(timeout: timeout) { [weak self] in
                    await self?.expire(waiterID)
                }
                waiters[waiterID] = Waiter(
                    minimum: minimum,
                    continuation: continuation,
                    watchdog: watchdog
                )
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelWaiter(waiterID)
            }
        }
    }

    private func expire(_ waiterID: UUID) {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(returning: false)
    }

    private func cancelWaiter(_ waiterID: UUID) async {
        guard let waiter = waiters.removeValue(forKey: waiterID) else { return }
        waiter.watchdog.cancel()
        _ = await waiter.watchdog.value
        waiter.continuation.resume(returning: false)
    }
}

private actor MCPReadinessScopePresenceProbe {
    private let holdSecondQuery: Bool
    private let firstQueryGate = MCPReadinessTestGate()
    private let secondQueryGate = MCPReadinessTestGate()
    private var queryCount = 0

    init(holdSecondQuery: Bool = false) {
        self.holdSecondQuery = holdSecondQuery
    }

    func query(
        requiredNames _: [String],
        scope _: MCPDomainToolRegistrationScope
    ) async -> MCPDomainToolScopePresence {
        queryCount += 1
        let queryNumber = queryCount
        if queryNumber == 1 {
            await firstQueryGate.arriveAndWait()
        } else if queryNumber == 2, holdSecondQuery {
            await secondQueryGate.arriveAndWait()
        }
        return MCPDomainToolScopePresence(revision: 1, isComplete: true)
    }

    func queryCountValue() -> Int {
        queryCount
    }

    func waitUntilQueryEntered(_ queryNumber: Int, timeout: Duration) async -> Bool {
        switch queryNumber {
        case 1:
            await firstQueryGate.waitUntilEntered(timeout: timeout)
        case 2:
            await secondQueryGate.waitUntilEntered(timeout: timeout)
        default:
            false
        }
    }

    func releaseFirstQuery() async {
        await firstQueryGate.release()
    }

    func releaseSecondQuery() async {
        await secondQueryGate.release()
    }
}

private actor MCPReadinessRetirementSleepProbe {
    private let firstGate = MCPReadinessTestGate()
    private let laterGate = MCPReadinessTestGate()
    private var invocationCount = 0

    func wait() async {
        invocationCount += 1
        if invocationCount == 1 {
            await firstGate.arriveAndWait()
        } else {
            await laterGate.arriveAndWait()
        }
    }

    func waitUntilFirstEntered(timeout: Duration) async -> Bool {
        await firstGate.waitUntilEntered(timeout: timeout)
    }

    func releaseFirst() async {
        await firstGate.release()
    }

    func releaseLater() async {
        await laterGate.release()
    }
}
