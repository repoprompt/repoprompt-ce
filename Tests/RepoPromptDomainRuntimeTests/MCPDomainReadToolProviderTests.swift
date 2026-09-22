import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class MCPDomainReadToolProviderTests: XCTestCase {
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

private actor StringRecorder {
    private var values: [String] = []
    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

private actor ContextResolutionRecorder {
    struct Resolution {
        let toolName: String
        let requirement: DomainReadContextRequirement
    }

    private var resolutions: [Resolution] = []
    private var refreshes = 0

    func record(_ toolName: String, requirement: DomainReadContextRequirement) {
        resolutions.append(Resolution(toolName: toolName, requirement: requirement))
    }

    func recordRefresh() {
        refreshes += 1
    }

    func snapshot() -> [Resolution] {
        resolutions
    }

    func refreshCount() -> Int {
        refreshes
    }
}

private actor InvocationRecorder {
    struct Invocation {
        let name: String
        let context: DomainReadInvocationContext
        let arguments: [String: Value]
    }

    private var invocations: [Invocation] = []

    func record(name: String, context: DomainReadInvocationContext, arguments: [String: Value]) {
        invocations.append(Invocation(name: name, context: context, arguments: arguments))
    }

    func snapshot() -> [Invocation] {
        invocations
    }
}
