import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptShared
import RepoPromptTestSupport
import XCTest

/// Regression guard for https://github.com/repoprompt/repoprompt-ce/issues/1039.
///
/// On macOS < 15, async `TaskLocal.withValue` runs the client-emitted `@backDeployed` fallback.
/// Xcode 26 miscompiles that fallback for runtime-sized payloads (`UUID?`, or structs/enums
/// carrying one): it frees a task-allocator temporary after `swift_task_localValuePush`, which
/// aborts in `swift_task_dealloc` ("freed pointer was not the last allocation"). The shipped
/// binary cannot be reproduced on a macOS 15+ host or with a newer toolchain, so this guard pins
/// the structural invariant instead: raw `@TaskLocal` is reserved for reviewed fixed-size payloads,
/// and every boxed handle binds a single class reference.
final class TaskLocalPayloadLayoutGuardTests: XCTestCase {
    /// Raw `@TaskLocal` declarations whose payload is a class reference, closure, existential, or
    /// fixed-size scalar. Anything else must use `BoxedTaskLocal`.
    private static let reviewedFixedSizeTaskLocals: [String: String] = [
        "Sources/RepoPrompt/Features/Workspaces/WorkspaceModel.swift#recorder": "final class",
        "Sources/RepoPrompt/Features/Search/StoreBackedWorkspaceSearch.swift#readinessWaitTimeoutOverrideForTesting":
            "frozen stdlib Duration",
        "Sources/RepoPrompt/Features/Search/StoreBackedWorkspaceSearch.swift#freshnessWaitTimeoutOverrideForTesting":
            "frozen stdlib Duration",
        "Sources/RepoPrompt/Features/Search/StoreBackedWorkspaceSearch.swift#freshnessWaitOperationOverrideForTesting":
            "closure",
        "Sources/RepoPrompt/Features/Diagnostics/App/WorktreeStartupInstrumentation.swift#currentRecorder": "final class",
        "Sources/RepoPrompt/Features/Diagnostics/App/WorkspaceProjectionDecodeDiagnostics.swift#attempt": "final class",
        "Sources/RepoPrompt/Infrastructure/WorkspaceContext/WorkspaceFileContextStore.swift#activePublicationInvalidationRecorder":
            "final class",
        "Sources/RepoPrompt/Infrastructure/MCP/MCPToolWorkCountDiagnostics.swift#currentGitCapture": "final class",
        "Sources/RepoPrompt/Infrastructure/MCP/MCPToolWorkCountDiagnostics.swift#currentReadFileCapture": "final class",
        "Sources/RepoPrompt/Infrastructure/MCP/MCPInvocationContext.swift#diagnosticSink": "closure",
        "Sources/RepoPrompt/Infrastructure/MCP/MCPToolObserverDiagnostics.swift#recorder": "final class",
        "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/WorkspaceFileSearchDebugTiming.swift#collector": "final class",
        "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/WorkspaceFileSearchDebugTiming.swift#catalogBuildObserver":
            "final class",
        "Sources/RepoPrompt/Infrastructure/WorkspaceContext/Search/WorkspaceFileSearchDebugTiming.swift#coldStartCollector":
            "final class",
        "Sources/RepoPrompt/Infrastructure/VCS/GitService.swift#currentReceiptParentLookupTrace": "final class",
        "Sources/RepoPromptInstrumentation/MCPToolExecutionPhaseInstrumentation.swift#recorder": "existential container",
        "Sources/RepoPromptFileSystem/FileSystemRuntimeHooks.swift#currentContext":
            "struct of closures and an existential only; no Foundation or resilient fields",
        "Sources/RepoPromptDomainRuntime/MCPDomainProtectedMutationToolProvider.swift#observer": "closure",
        "Sources/RepoPromptShared/ProviderProcessLaunchPolicy.swift#allowsLaunchForTesting": "Bool"
    ]

    func testRawTaskLocalDeclarationsAreLimitedToReviewedFixedSizePayloads() throws {
        let repoRoot = try RepoRoot.url()
        let sourcesURL = repoRoot.appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourcesURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        let namePattern = try NSRegularExpression(pattern: #"static\s+var\s+(\w+)"#)
        var found: Set<String> = []
        var unparsed: [String] = []

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let relativePath = RepoRoot.relativePath(for: fileURL, relativeTo: repoRoot)
            let lines = try String(contentsOf: fileURL, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("@TaskLocal") else { continue }
                let declaration = index + 1 < lines.count ? trimmed + " " + lines[index + 1] : trimmed
                let range = NSRange(declaration.startIndex..., in: declaration)
                guard let match = namePattern.firstMatch(in: declaration, range: range),
                      let nameRange = Range(match.range(at: 1), in: declaration)
                else {
                    unparsed.append("\(relativePath):\(index + 1)")
                    continue
                }
                found.insert("\(relativePath)#\(declaration[nameRange])")
            }
        }

        XCTAssertTrue(unparsed.isEmpty, "Unparsed @TaskLocal declarations:\n\(unparsed.joined(separator: "\n"))")
        let unreviewed = found.subtracting(Self.reviewedFixedSizeTaskLocals.keys).sorted()
        XCTAssertTrue(
            unreviewed.isEmpty,
            """
            New raw @TaskLocal declarations must use BoxedTaskLocal unless their payload is a class \
            reference, closure, existential, or fixed-size scalar (#1039). Box them, or add a reviewed \
            entry with the reason:
            \(unreviewed.joined(separator: "\n"))
            """
        )
        let stale = Set(Self.reviewedFixedSizeTaskLocals.keys).subtracting(found).sorted()
        XCTAssertTrue(stale.isEmpty, "Remove stale reviewed @TaskLocal entries:\n\(stale.joined(separator: "\n"))")
    }

    func testBoxedTaskLocalHandlesBindPointerSizedClassReferences() {
        assertPointerSizedCarrier(ServerNetworkManager.currentConnectionIDTaskLocal)
        assertPointerSizedCarrier(ServerNetworkManager.currentProgressStateTaskLocal)
        assertPointerSizedCarrier(ServerNetworkManager.currentTabContextHintTaskLocal)
        assertPointerSizedCarrier(ServerNetworkManager.currentToolDispatchAuthorizationTaskLocal)
        assertPointerSizedCarrier(ServerNetworkManager.currentExplicitWindowRoutingHintTaskLocal)
        assertPointerSizedCarrier(MCPInvocationContextBridge.currentTaskLocal)
        assertPointerSizedCarrier(AgentSelfMCPCallOrigin.currentTaskLocal)
        assertPointerSizedCarrier(AgentSessionLinkWaitCallOrigin.currentTaskLocal)
        assertPointerSizedCarrier(EditFlowPerf.currentLifecycleCorrelationTaskLocal)
        assertPointerSizedCarrier(EditFlowPerf.currentFileSystemPublicationCorrelationTaskLocal)
        assertPointerSizedCarrier(MCPDomainInvocationSecurityContext.currentTaskLocal)
        assertPointerSizedCarrier(MCPDomainAdmittedContextValues.currentTaskLocal)
        assertPointerSizedCarrier(DomainChildLaunchContext.currentTaskLocal)
        assertPointerSizedCarrier(DomainChildLaunchContext.bundleTaskLocal)
        assertPointerSizedCarrier(DomainInteractionPresentationContext.requestIDTaskLocal)
        assertPointerSizedCarrier(MCPDomainMutationCommitContext.controllerTaskLocal)
        assertPointerSizedCarrier(MCPRequestTimelineContext.currentTaskLocal)
        #if DEBUG
            assertPointerSizedCarrier(OracleReviewPackagingDiagnostics.currentTaskLocal)
            assertPointerSizedCarrier(WorktreeStartupBenchmarkDiagnostics.currentPendingStartTaskLocal)
            assertPointerSizedCarrier(WorktreeStartupInstrumentation.currentBenchmarkMetricTagTaskLocal)
            assertPointerSizedCarrier(WorkspaceProjectionDecodeDiagnostics.contextTaskLocal)
        #endif
    }

    func testBoxedTaskLocalPreservesTaskLocalScopingSemantics() async {
        let local = BoxedTaskLocal<UUID?>(nil)
        let outer = UUID()
        XCTAssertNil(local.get())

        let observed = await local.withValue(outer) { () async -> [UUID?] in
            let shadowed = await local.withValue(nil) { () async -> UUID? in
                await Task.yield()
                return local.get()
            }
            let inherited = await Task { local.get() }.value
            let synchronous = local.withValue(nil) { local.get() }
            return [local.get(), shadowed, inherited, synchronous]
        }

        XCTAssertEqual(observed, [outer, nil, outer, nil])
        XCTAssertNil(local.get())
    }

    private func assertPointerSizedCarrier<Value>(
        _: BoxedTaskLocal<Value>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            MemoryLayout<BoxedTaskLocal<Value>.Reference?>.size,
            MemoryLayout<UnsafeRawPointer>.size,
            file: file,
            line: line
        )
    }
}
