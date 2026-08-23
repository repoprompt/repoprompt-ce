import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class MCPDomainReadToolProviderTests: XCTestCase {
    func testDefinitionsCoverM3FamiliesExactlyOnce() throws {
        let definitions = MCPDomainReadToolDefinitions.definitions
        XCTAssertEqual(definitions.map(\.name), MCPDomainReadToolDefinitions.toolNames)
        XCTAssertEqual(Set(definitions.map(\.name)).count, definitions.count)
        XCTAssertTrue(definitions.allSatisfy { $0.inputSchema.objectValue?["type"]?.stringValue == "object" })
        XCTAssertEqual(definitions.first { $0.name == "prompt" }?.annotations.readOnlyHint, false)
        XCTAssertTrue(definitions.filter { $0.name != "prompt" }.allSatisfy { $0.annotations.readOnlyHint == true })
    }

    func testProviderUsesDomainHandleAndSharedBackendForEveryFamily() async throws {
        let identity = makeIdentity()
        let coordinator = DomainReadSideEffectCoordinator(identity: identity)
        let recorder = InvocationRecorder()
        let handle = makeHandle(identity: identity)
        let provider = MCPDomainReadToolProvider(
            resolveContext: { _, _ in DomainReadInvocationContext(handle: handle, connectionID: handle.connectionID) },
            backend: MCPDomainReadToolBackend { name, received, arguments, _ in
                await recorder.record(name: name, context: received, arguments: arguments)
                return .object(["tool": .string(name)])
            },
            sideEffects: coordinator
        )

        for binding in provider.bindings {
            let arguments: [String: Value] = switch binding.definition.name {
            case "read_file": ["path": .string("file.swift")]
            case "file_search": ["pattern": .string("needle")]
            case "history": ["op": .string("list_sessions")]
            case "git": ["op": .string("status")]
            default: [:]
            }
            let value = try await binding(arguments)
            XCTAssertEqual(value.objectValue?["tool"]?.stringValue, binding.definition.name)
        }

        let invocations = await recorder.snapshot()
        XCTAssertEqual(invocations.map(\.name), MCPDomainReadToolDefinitions.toolNames)
        XCTAssertTrue(invocations.allSatisfy { $0.context.handle == handle })
    }

    func testIndependentReadBackendsDoNotContendOnSideEffectCoordinator() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let barrier = ConcurrentEntryBarrier(target: 2)
        let provider = MCPDomainReadToolProvider(
            resolveContext: { _, _ in DomainReadInvocationContext(handle: handle, connectionID: handle.connectionID) },
            backend: MCPDomainReadToolBackend { name, _, _, _ in
                await barrier.arriveAndWait()
                return .string(name)
            },
            sideEffects: DomainReadSideEffectCoordinator(identity: identity)
        )
        let tree = try XCTUnwrap(provider.binding(named: "get_file_tree"))
        let search = try XCTUnwrap(provider.binding(named: "file_search"))

        async let treeValue = tree([:])
        async let searchValue = search(["pattern": .string("needle")])
        let values = try await [treeValue, searchValue]

        XCTAssertEqual(Set(values.compactMap(\.stringValue)), ["get_file_tree", "file_search"])
        let maximumConcurrency = await barrier.maximumConcurrency()
        XCTAssertEqual(maximumConcurrency, 2)
    }

    func testContextRequirementsPreserveUnscopedAndOptionalFamilies() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let resolutions = ContextResolutionRecorder()
        let provider = MCPDomainReadToolProvider(
            resolveContext: { toolName, requirement in
                await resolutions.record(toolName, requirement: requirement)
                return if requirement == .workspaceRequired {
                    DomainReadInvocationContext(handle: handle, connectionID: handle.connectionID)
                } else {
                    DomainReadInvocationContext(handle: nil, connectionID: nil)
                }
            },
            refreshContext: { received in
                await resolutions.recordRefresh()
                return received
            },
            backend: MCPDomainReadToolBackend { name, _, _, _ in .string(name) },
            sideEffects: DomainReadSideEffectCoordinator(identity: identity)
        )

        _ = try await XCTUnwrap(provider.binding(named: "history"))(["op": .string("list_sessions")])
        _ = try await XCTUnwrap(provider.binding(named: "get_file_tree"))([:])
        _ = try await XCTUnwrap(provider.binding(named: "git"))(["op": .string("status")])
        _ = try await XCTUnwrap(provider.binding(named: "read_file"))(["path": .string("file.swift")])

        let recorded = await resolutions.snapshot()
        XCTAssertEqual(recorded.map(\.toolName), ["history", "get_file_tree", "git", "read_file"])
        XCTAssertEqual(
            recorded.map(\.requirement),
            [.workspaceIndependent, .workspaceOptional, .workspaceOptional, .workspaceRequired]
        )
        let refreshCount = await resolutions.refreshCount()
        XCTAssertEqual(refreshCount, 1)
    }

    func testRequiredContextCannotExecuteUnfencedAndReleasesInvocation() async throws {
        let identity = makeIdentity()
        let backendInvocations = InvocationRecorder()
        let releases = StringRecorder()
        let provider = MCPDomainReadToolProvider(
            resolveContext: { _, _ in
                DomainReadInvocationContext(handle: nil, connectionID: UUID())
            },
            releaseContext: { context in
                await releases.append(context.invocationID.uuidString)
            },
            backend: MCPDomainReadToolBackend { name, context, arguments, _ in
                await backendInvocations.record(name: name, context: context, arguments: arguments)
                return .string("unexpected")
            },
            sideEffects: DomainReadSideEffectCoordinator(identity: identity)
        )
        let read = try XCTUnwrap(provider.binding(named: "read_file"))

        do {
            _ = try await read(["path": .string("file.swift")])
            XCTFail("Expected required authority failure")
        } catch let error as MCPError {
            XCTAssertTrue(String(describing: error).contains("Required domain authority is unavailable"))
        }

        let invocations = await backendInvocations.snapshot()
        XCTAssertTrue(invocations.isEmpty)
        let released = await releases.snapshot()
        XCTAssertEqual(released.count, 1)
    }

    func testCancellationPropagatesWithoutSuccessNormalization() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let provider = MCPDomainReadToolProvider(
            resolveContext: { _, _ in DomainReadInvocationContext(handle: handle, connectionID: handle.connectionID) },
            backend: MCPDomainReadToolBackend { _, _, _, _ in
                try await Task.sleep(for: .seconds(30))
                return .object([:])
            },
            sideEffects: DomainReadSideEffectCoordinator(identity: identity)
        )
        let read = try XCTUnwrap(provider.binding(named: "read_file"))
        let task = Task { try await read(["path": .string("file.swift")]) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testSideEffectCommitCompletesBeforeSuccessfulResponse() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let effects = StringRecorder()
        let provider = MCPDomainReadToolProvider(
            resolveContext: { _, _ in
                DomainReadInvocationContext(handle: handle, connectionID: handle.connectionID)
            },
            backend: MCPDomainReadToolBackend { _, _, _, emitter in
                try await emitter.submitAndWait(fingerprint: "commit-before-response") {
                    await effects.append("committed")
                }
                return .string("success")
            },
            sideEffects: DomainReadSideEffectCoordinator(identity: identity)
        )
        let read = try XCTUnwrap(provider.binding(named: "read_file"))

        let value = try await read(["path": .string("file.swift")])

        XCTAssertEqual(value.stringValue, "success")
        let committed = await effects.snapshot()
        XCTAssertEqual(committed, ["committed"])
    }

    func testDirectBackendVersusM3ProviderWrapperLatencyIsBounded() async throws {
        let identity = makeIdentity()
        let handle = makeHandle(identity: identity)
        let context = DomainReadInvocationContext(handle: handle, connectionID: handle.connectionID)
        let backend = MCPDomainReadToolBackend { _, _, _, _ in .string("ok") }
        let emitter = MCPDomainReadSideEffectEmitter { _, _, _, _, operation in
            try await operation()
        }
        let arguments: [String: Value] = ["path": .string("file.swift")]
        let iterations = 1_000
        let clock = ContinuousClock()

        let baselineStart = clock.now
        for _ in 0 ..< iterations {
            _ = try await backend.execute("read_file", context, arguments, emitter)
        }
        let baseline = baselineStart.duration(to: clock.now)

        let provider = MCPDomainReadToolProvider(
            resolveContext: { _, _ in context },
            backend: backend,
            sideEffects: DomainReadSideEffectCoordinator(identity: identity)
        )
        let read = try XCTUnwrap(provider.binding(named: "read_file"))
        let providerStart = clock.now
        for _ in 0 ..< iterations {
            _ = try await read(arguments)
        }
        let m3 = providerStart.duration(to: clock.now)
        let baselineNanoseconds = Self.nanoseconds(baseline)
        let m3Nanoseconds = Self.nanoseconds(m3)
        let overheadPerCall = max(0, m3Nanoseconds - baselineNanoseconds) / Int64(iterations)
        print(
            "M3_READ_LATENCY iterations=\(iterations) "
                + "direct_backend_ns=\(baselineNanoseconds) "
                + "provider_wrapper_ns=\(m3Nanoseconds) overhead_per_call_ns=\(overheadPerCall)"
        )
        XCTAssertLessThan(overheadPerCall, 100_000)
    }

    func testProviderNormalizesTopLevelInvalidParametersBeforeBackend() async throws {
        let identity = makeIdentity()
        let recorder = InvocationRecorder()
        let resolutions = ContextResolutionRecorder()
        let handle = makeHandle(identity: identity)
        let provider = MCPDomainReadToolProvider(
            resolveContext: { toolName, requirement in
                await resolutions.record(toolName, requirement: requirement)
                return DomainReadInvocationContext(handle: handle, connectionID: handle.connectionID)
            },
            backend: MCPDomainReadToolBackend { name, handle, arguments, _ in
                await recorder.record(name: name, context: handle, arguments: arguments)
                return .object([:])
            },
            sideEffects: DomainReadSideEffectCoordinator(identity: identity)
        )

        let readFile = try XCTUnwrap(provider.binding(named: "read_file"))
        do {
            _ = try await readFile([:])
            XCTFail("Expected invalid parameters")
        } catch let error as MCPError {
            XCTAssertTrue(String(describing: error).contains("missing path"))
        }

        let search = try XCTUnwrap(provider.binding(named: "file_search"))
        do {
            _ = try await search(["pattern": .string("  ")])
            XCTFail("Expected invalid parameters")
        } catch let error as MCPError {
            XCTAssertTrue(String(describing: error).contains("pattern cannot be empty"))
        }
        let structure = try XCTUnwrap(provider.binding(named: "get_code_structure"))
        do {
            _ = try await structure(["bogus": .bool(true)])
            XCTFail("Expected invalid parameters")
        } catch let error as MCPError {
            XCTAssertTrue(String(describing: error).contains("unknown get_code_structure parameter"))
        }

        let invocations = await recorder.snapshot()
        XCTAssertTrue(invocations.isEmpty)
        let resolutionCount = await resolutions.snapshot().count
        XCTAssertEqual(resolutionCount, 0, "argument validation must precede unrelated routing")
    }

    private static func nanoseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1_000_000_000
            + components.attoseconds / 1_000_000_000
    }

    private func makeIdentity() -> DomainRuntimeIdentity {
        DomainRuntimeIdentity(
            runtimeID: UUID(),
            lifecycleGeneration: 3,
            processID: 42,
            mode: .app,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeHandle(identity: DomainRuntimeIdentity) -> DomainReadContextHandle {
        DomainReadContextHandle(
            runtimeID: identity.runtimeID,
            runtimeGeneration: identity.lifecycleGeneration,
            connectionID: UUID(),
            connectionGeneration: 2,
            context: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
            workspaceRevision: 5,
            contextRevision: 7,
            routingRevision: 11,
            bindingKind: .explicit
        )
    }
}

private actor ConcurrentEntryBarrier {
    private let target: Int
    private var arrivals = 0
    private var maximum = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(target: Int) {
        self.target = target
    }

    func arriveAndWait() async {
        arrivals += 1
        maximum = max(maximum, arrivals)
        if arrivals == target {
            let pending = continuations
            continuations.removeAll()
            for continuation in pending {
                continuation.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func maximumConcurrency() -> Int { maximum }
}

private actor StringRecorder {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor ContextResolutionRecorder {
    struct Resolution: Sendable {
        let toolName: String
        let requirement: DomainReadContextRequirement
    }

    private var resolutions: [Resolution] = []
    private var refreshes = 0

    func record(_ toolName: String, requirement: DomainReadContextRequirement) {
        resolutions.append(Resolution(toolName: toolName, requirement: requirement))
    }

    func recordRefresh() { refreshes += 1 }
    func snapshot() -> [Resolution] { resolutions }
    func refreshCount() -> Int { refreshes }
}

private actor InvocationRecorder {
    struct Invocation: Sendable {
        let name: String
        let context: DomainReadInvocationContext
        let arguments: [String: Value]
    }

    private var invocations: [Invocation] = []

    func record(name: String, context: DomainReadInvocationContext, arguments: [String: Value]) {
        invocations.append(Invocation(name: name, context: context, arguments: arguments))
    }

    func snapshot() -> [Invocation] { invocations }
}
