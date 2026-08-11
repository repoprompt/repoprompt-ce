import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class MCPDomainToolCatalogTests: XCTestCase {
    func testCanonicalCatalogHasExplicitUniqueCapabilityAndAdmissionClassification() {
        XCTAssertEqual(MCPDomainToolCatalog.entries.count, 27)
        XCTAssertEqual(Set(MCPDomainToolCatalog.orderedToolNames).count, 27)
        XCTAssertEqual(MCPDomainToolCatalog.globalToolNames, [
            "app_settings",
            "bind_context",
            "manage_workspaces"
        ])
        XCTAssertEqual(MCPDomainToolCatalog.windowToolNames.count, 24)
        XCTAssertEqual(Set(MCPDomainToolCatalog.classifications.keys), Set(MCPDomainToolCatalog.orderedToolNames))
        XCTAssertTrue(MCPDomainToolCatalog.entries.allSatisfy {
            MCPDomainToolCatalog.capabilities(for: $0.name) == [$0.capability]
                && MCPDomainToolCatalog.admissionClass(for: $0.name) == $0.admissionClass
        })
        XCTAssertTrue(MCPToolCapability.allCases.allSatisfy {
            !MCPDomainToolCatalog.toolNames(for: [$0]).isEmpty
        })
        XCTAssertEqual(MCPDomainToolCatalog.capabilities(for: "read_file"), [.fileRead])
        XCTAssertEqual(MCPDomainToolCatalog.capabilities(for: "file_search"), [.fileSearch])
        XCTAssertEqual(MCPDomainToolCatalog.capabilities(for: "history"), [.historyRead])
        XCTAssertEqual(MCPToolCapability.statusPublication.externalName, "agent_session_control")
        XCTAssertNil(MCPDomainToolCatalog.admissionClass(for: "unknown"))
        XCTAssertTrue(MCPDomainToolCatalog.capabilities(for: "unknown").isEmpty)
    }

    func testOperationIdentityMirrorsCatalogSelectorsNormalizationAndHandlerDefaults() {
        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.manageSelection, input: .missing),
            MCPDomainToolOperationIdentity(canonicalTool: MCPWindowToolName.manageSelection, normalizedOperation: "get")
        )
        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.workspaceContext, input: .missing).normalizedOperation,
            "snapshot"
        )
        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.prompt, input: .missing).normalizedOperation,
            "get"
        )
        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.agentRun, input: .missing).normalizedOperation,
            "wait"
        )
        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.git, input: .missing).normalizedOperation,
            "status"
        )
        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.agentManage, input: .missing).normalizedOperation,
            "list_sessions"
        )
        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.workspaceContext, input: .value("  EXPORT ")).normalizedOperation,
            "export"
        )
        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.manageSelection, input: .value("SET")).normalizedOperation,
            "set"
        )
        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.agentManage, input: .value("handoff")).normalizedOperation,
            "extract_handoff"
        )
        XCTAssertEqual(MCPDomainToolCatalog.operationArgumentKey(for: MCPGlobalToolName.manageWorkspaces), "action")
        XCTAssertEqual(MCPDomainToolCatalog.operationArgumentKey(for: MCPWindowToolName.fileActions), "action")
        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.fileActions, input: .value("CREATE")).normalizedOperation,
            "create"
        )
        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.fileActions, input: .value("rename")).normalizedOperation,
            "move"
        )
        XCTAssertNil(MCPDomainToolCatalog.operationArgumentKey(for: MCPWindowToolName.readFile))
        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.readFile, input: .malformed).normalizedOperation,
            MCPDomainToolOperationIdentity.callOperation
        )
    }

    func testOperationIdentityBoundsUnknownAndMalformedValuesWithoutRetainingInput() {
        let privateValue = "private/path/session/prompt/" + String(repeating: "x", count: 10000)
        let unknownOperation = MCPDomainToolCatalog.operationIdentity(
            for: MCPWindowToolName.manageSelection,
            input: .value(privateValue)
        )
        XCTAssertEqual(unknownOperation.canonicalTool, MCPWindowToolName.manageSelection)
        XCTAssertEqual(unknownOperation.normalizedOperation, MCPDomainToolOperationIdentity.unknownOperation)
        XCTAssertFalse(unknownOperation.normalizedOperation.contains("private"))

        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.manageSelection, input: .malformed).normalizedOperation,
            MCPDomainToolOperationIdentity.unknownOperation
        )
        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: MCPGlobalToolName.appSettings, input: .missing).normalizedOperation,
            MCPDomainToolOperationIdentity.unknownOperation
        )
        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: "future_private_tool_\(privateValue)", input: .value(privateValue)),
            .unknown
        )
        XCTAssertEqual(
            MCPDomainToolCatalog.operationIdentity(for: MCPWindowToolName.history, input: .value("SEARCH")).normalizedOperation,
            MCPDomainToolOperationIdentity.unknownOperation
        )
    }

    func testConfiguredLimitsReportCurrentConnectionAndResourceScopes() throws {
        let appMutation = try XCTUnwrap(MCPDomainToolCatalog.configuredLimits(for: MCPGlobalToolName.appSettings))
        XCTAssertEqual(appMutation.connectionLane, MCPDomainToolAdmissionLimits.exclusiveConnection)
        XCTAssertEqual(appMutation.resourceLease, MCPDomainToolAdmissionLimits.exclusiveConnection)
        XCTAssertEqual(appMutation.resourceScope, .application)

        let smallRead = try XCTUnwrap(MCPDomainToolCatalog.configuredLimits(for: MCPWindowToolName.readFile))
        XCTAssertEqual(smallRead.connectionLane, MCPDomainToolAdmissionLimits.smallReadConnection)
        XCTAssertEqual(smallRead.resourceLease, MCPDomainToolAdmissionLimits.smallReadPerWindow)
        XCTAssertEqual(smallRead.resourceScope, .window)

        let gitRead = try XCTUnwrap(MCPDomainToolCatalog.configuredLimits(for: MCPWindowToolName.git))
        XCTAssertEqual(gitRead.connectionLane, MCPDomainToolAdmissionLimits.gitReadConnection)
        XCTAssertEqual(gitRead.resourceLease, MCPDomainToolAdmissionLimits.gitReadPerRepository)
        XCTAssertEqual(gitRead.resourceScope, .repository)

        let control = try XCTUnwrap(MCPDomainToolCatalog.configuredLimits(for: MCPWindowToolName.agentRun))
        XCTAssertEqual(control.connectionLane, MCPDomainToolAdmissionLimits.controlConnection)
        XCTAssertNil(control.resourceLease)
        XCTAssertNil(control.resourceScope)
        XCTAssertNil(MCPDomainToolCatalog.configuredLimits(for: "unknown"))
    }

    func testEveryClientProfileHasExplicitPolicyAndPreservesFrozenVisibility() {
        XCTAssertEqual(
            Set(MCPClientToolPolicyCatalog.classifications.keys),
            Set(MCPClientToolPolicyProfile.allCases)
        )
        let expected: [MCPClientToolPolicyProfile: [String]] = [
            .direct: ["app_settings", "bind_context", "manage_workspaces", "manage_selection", "file_actions", "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt", "apply_edits", "oracle_utils", "oracle_send", "git", "manage_worktree", "context_builder", "agent_run", "agent_manage", "history"],
            .discovery: ["manage_selection", "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt", "git", "ask_user", "history"],
            .agentModeGenericExplore: ["app_settings", "get_code_structure", "get_file_tree", "read_file", "file_search", "git", "ask_user", "share_thoughts", "set_status", "wait_for_next_user_instruction", "history"],
            .agentModeGenericEngineer: ["app_settings", "manage_selection", "file_actions", "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt", "apply_edits", "ask_oracle", "oracle_chat_log", "git", "manage_worktree", "context_builder", "ask_user", "agent_explore", "share_thoughts", "set_status", "wait_for_next_user_instruction", "history"],
            .agentModeGenericEngineerOrchestrator: ["app_settings", "manage_selection", "file_actions", "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt", "apply_edits", "ask_oracle", "oracle_chat_log", "git", "manage_worktree", "context_builder", "ask_user", "agent_explore", "agent_run", "agent_manage", "share_thoughts", "set_status", "wait_for_next_user_instruction", "history"],
            .agentModeClaudeEngineer: ["app_settings", "manage_selection", "file_actions", "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt", "apply_edits", "ask_oracle", "oracle_chat_log", "git", "manage_worktree", "context_builder", "ask_user", "agent_explore", "set_status", "history"],
            .agentModeCodexEngineer: ["app_settings", "manage_selection", "file_actions", "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt", "apply_edits", "ask_oracle", "oracle_chat_log", "git", "manage_worktree", "context_builder", "ask_user", "agent_explore", "set_status", "history"],
            .agentModeOpenCodeEngineer: ["app_settings", "manage_selection", "file_actions", "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt", "apply_edits", "ask_oracle", "oracle_chat_log", "git", "manage_worktree", "context_builder", "ask_user", "agent_explore", "set_status", "history"],
            .agentModeCursorEngineer: ["app_settings", "manage_selection", "file_actions", "get_code_structure", "get_file_tree", "read_file", "file_search", "workspace_context", "prompt", "apply_edits", "ask_oracle", "oracle_chat_log", "git", "manage_worktree", "context_builder", "ask_user", "agent_explore", "set_status", "history"]
        ]
        for profile in MCPClientToolPolicyProfile.allCases {
            XCTAssertEqual(
                MCPClientToolPolicyCatalog.resolvedToolNames(for: profile),
                expected[profile] ?? [],
                profile.rawValue
            )
            let expectedAnnotations: MCPClientToolAnnotationProfile = profile == .agentModeCodexEngineer
                ? .suppressReadOnlyHint
                : .canonical
            XCTAssertEqual(
                MCPClientToolPolicyCatalog.classification(for: profile).annotationProfile,
                expectedAnnotations,
                profile.rawValue
            )
        }
    }
}

final class MCPDomainToolRegistryTests: XCTestCase {
    func testRegistrationIsAtomicAndRejectsUnknownScopeDuplicateAndFingerprintDrift() async throws {
        let registry = try MCPDomainToolRegistry(registryID: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
        let readFile = Self.binding(name: MCPWindowToolName.readFile)
        let initial = await registry.snapshot()

        await assertRegistryError(.emptyRegistration) {
            try await registry.register(
                registrationID: .init(rawValue: 1),
                scope: .window(id: 1),
                bindings: []
            )
        }
        await assertRegistryError(.invalidWindowID(0)) {
            try await registry.register(
                registrationID: .init(rawValue: 1),
                scope: .window(id: 0),
                bindings: [readFile]
            )
        }
        await assertRegistryError(.duplicateToolName(MCPWindowToolName.readFile)) {
            try await registry.register(
                registrationID: .init(rawValue: 1),
                scope: .window(id: 1),
                bindings: [readFile, readFile]
            )
        }
        await assertRegistryError(.unknownToolName("unknown")) {
            try await registry.register(
                registrationID: .init(rawValue: 1),
                scope: .window(id: 1),
                bindings: [Self.binding(name: "unknown")]
            )
        }
        await assertRegistryError(.scopeMismatch(toolName: MCPWindowToolName.readFile, expected: .window, actual: .application)) {
            try await registry.register(
                registrationID: .init(rawValue: 1),
                scope: .application,
                bindings: [readFile]
            )
        }
        let afterRejectedRegistrations = await registry.snapshot()
        XCTAssertEqual(afterRejectedRegistrations.revision, initial.revision)

        let firstHandle = try await registry.register(
            registrationID: .init(rawValue: 1),
            scope: .window(id: 1),
            bindings: [readFile]
        )
        await assertRegistryError(.bindingAlreadyRegistered(toolName: MCPWindowToolName.readFile, scope: .window(id: 1))) {
            try await registry.register(
                registrationID: .init(rawValue: 2),
                scope: .window(id: 1),
                bindings: [readFile]
            )
        }
        let beforeConflict = await registry.snapshot()
        await assertRegistryError(.conflictingDefinition(toolName: MCPWindowToolName.readFile)) {
            try await registry.register(
                registrationID: .init(rawValue: 3),
                scope: .window(id: 2),
                bindings: [Self.binding(name: MCPWindowToolName.readFile, description: "changed")]
            )
        }
        let afterConflict = await registry.snapshot()
        XCTAssertEqual(afterConflict.revision, beforeConflict.revision)
        let firstRemoval = await registry.unregister(firstHandle)
        XCTAssertEqual(firstRemoval, .removed)
        let changedAfterRemoval = try await registry.register(
            registrationID: .init(rawValue: 3),
            scope: .window(id: 2),
            bindings: [Self.binding(name: MCPWindowToolName.readFile, description: "changed")]
        )
        let changedAfterRemovalIsActive = await registry.isActive(changedAfterRemoval)
        XCTAssertTrue(changedAfterRemovalIsActive)
    }

    func testRegistrationBatchRollsBackEarlierEntriesWhenLaterEntryFails() async throws {
        let registry = MCPDomainToolRegistry()
        let initial = await registry.snapshot()
        let appSettingsID = MCPDomainToolRegistrationID(rawValue: 41)

        await assertRegistryError(.scopeMismatch(
            toolName: MCPWindowToolName.readFile,
            expected: .window,
            actual: .application
        )) {
            _ = try await registry.registerAtomically([
                MCPDomainToolRegistrationRequest(
                    registrationID: appSettingsID,
                    scope: .application,
                    bindings: [Self.binding(name: MCPGlobalToolName.appSettings)]
                ),
                MCPDomainToolRegistrationRequest(
                    registrationID: .init(rawValue: 42),
                    scope: .application,
                    bindings: [Self.binding(name: MCPWindowToolName.readFile)]
                )
            ])
        }

        let afterFailure = await registry.snapshot()
        let presenceAfterFailure = await registry.scopePresence(
            requiredToolNames: [MCPGlobalToolName.appSettings],
            scope: .application
        )
        let rolledBackResolution = await registry.resolve(
            toolName: MCPGlobalToolName.appSettings,
            scope: .application
        )
        XCTAssertEqual(afterFailure.revision, initial.revision)
        XCTAssertEqual(afterFailure.toolNames, initial.toolNames)
        XCTAssertFalse(presenceAfterFailure.isComplete)
        XCTAssertNil(rolledBackResolution)

        let retry = try await registry.registerWithResult(
            registrationID: appSettingsID,
            scope: .application,
            bindings: [Self.binding(name: MCPGlobalToolName.appSettings)]
        )
        let presenceAfterRetry = await registry.scopePresence(
            requiredToolNames: [MCPGlobalToolName.appSettings],
            scope: .application
        )
        XCTAssertEqual(retry.disposition, .inserted)
        XCTAssertEqual(retry.handle.generation, 1, "A failed batch must restore generation ownership.")
        XCTAssertTrue(presenceAfterRetry.isComplete)

        _ = await registry.unregister(retry.handle)
        let presenceAfterRemoval = await registry.scopePresence(
            requiredToolNames: [MCPGlobalToolName.appSettings],
            scope: .application
        )
        XCTAssertFalse(presenceAfterRemoval.isComplete, "Unregister must remove stale readiness index entries.")
    }

    func testSnapshotsDeduplicateCanonicalDefinitionsAndResolutionStaysScopeSpecific() async throws {
        let registry = MCPDomainToolRegistry()
        let first = try await registry.register(
            registrationID: .init(rawValue: 1),
            scope: .window(id: 1),
            bindings: [Self.binding(name: MCPWindowToolName.readFile, result: "one")]
        )
        let second = try await registry.register(
            registrationID: .init(rawValue: 2),
            scope: .window(id: 2),
            bindings: [Self.binding(name: MCPWindowToolName.readFile, result: "two")]
        )
        let global = try await registry.register(
            registrationID: .init(rawValue: 3),
            scope: .application,
            bindings: [Self.binding(name: MCPGlobalToolName.appSettings, result: "global")]
        )
        let snapshot = await registry.snapshot()
        XCTAssertEqual(snapshot.toolNames, [MCPGlobalToolName.appSettings, MCPWindowToolName.readFile])
        XCTAssertEqual(snapshot.activeScopesByToolName[MCPWindowToolName.readFile], [.window(id: 1), .window(id: 2)])
        XCTAssertFalse(snapshot.catalogFingerprint.isEmpty)

        let ambiguousWindowResolution = await registry.resolveUniqueWindowTool(
            toolName: MCPWindowToolName.readFile
        )
        XCTAssertNil(ambiguousWindowResolution)

        let firstResolution = await registry.resolve(toolName: MCPWindowToolName.readFile, scope: .window(id: 1))
        let secondResolution = await registry.resolve(toolName: MCPWindowToolName.readFile, scope: .window(id: 2))
        let firstTool = try XCTUnwrap(firstResolution)
        let secondTool = try XCTUnwrap(secondResolution)
        let firstResult = try await firstTool.binding([:])
        let secondResult = try await secondTool.binding([:])
        XCTAssertEqual(firstResult.stringValue, "one")
        XCTAssertEqual(secondResult.stringValue, "two")
        let applicationResolution = await registry.resolve(toolName: MCPWindowToolName.readFile, scope: .application)
        XCTAssertNil(applicationResolution)

        let firstRemoval = await registry.unregister(first)
        let repeatedRemoval = await registry.unregister(first)
        let retainedResolution = await registry.resolve(toolName: MCPWindowToolName.readFile, scope: .window(id: 2))
        let uniqueWindowResolution = await registry.resolveUniqueWindowTool(
            toolName: MCPWindowToolName.readFile
        )
        let secondIsActive = await registry.isActive(second)
        let globalIsActive = await registry.isActive(global)
        XCTAssertEqual(firstRemoval, .removed)
        XCTAssertEqual(repeatedRemoval, .unchanged)
        XCTAssertNotNil(retainedResolution)
        XCTAssertEqual(uniqueWindowResolution?.scope, .window(id: 2))
        XCTAssertTrue(secondIsActive)
        XCTAssertTrue(globalIsActive)
    }

    func testReplacingARegistrationInvalidatesThePriorGenerationHandle() async throws {
        let registry = MCPDomainToolRegistry()
        let registrationID = MCPDomainToolRegistrationID(rawValue: 1)
        let first = try await registry.register(
            registrationID: registrationID,
            scope: .window(id: 1),
            bindings: [Self.binding(name: MCPWindowToolName.readFile, result: "first")]
        )
        let identical = try await registry.registerWithResult(
            registrationID: registrationID,
            scope: .window(id: 1),
            bindings: [Self.binding(name: MCPWindowToolName.readFile, result: "ignored replacement")]
        )
        let unchangedResolution = await registry.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: .window(id: 1)
        )
        XCTAssertEqual(identical.disposition, .unchanged)
        XCTAssertEqual(identical.handle, first)
        let unchangedBinding = try XCTUnwrap(unchangedResolution)
        let unchangedValue = try await unchangedBinding.binding([:])
        XCTAssertEqual(unchangedValue.stringValue, "first")
        let unchangedSnapshot = await registry.snapshot()
        XCTAssertEqual(unchangedSnapshot.revision, 1)

        let replacement = try await registry.registerWithResult(
            registrationID: registrationID,
            scope: .window(id: 1),
            bindings: [Self.binding(
                name: MCPWindowToolName.readFile,
                description: "actual replacement",
                result: "second"
            )]
        )
        let second = replacement.handle
        XCTAssertEqual(replacement.disposition, .replaced)

        let firstIsActive = await registry.isActive(first)
        let secondIsActive = await registry.isActive(second)
        let staleRemoval = await registry.unregister(first)
        let currentResolution = await registry.resolve(
            toolName: MCPWindowToolName.readFile,
            scope: .window(id: 1)
        )
        XCTAssertFalse(firstIsActive)
        XCTAssertTrue(secondIsActive)
        XCTAssertEqual(staleRemoval, .unchanged)
        let resolved = try XCTUnwrap(currentResolution)
        let result = try await resolved.binding([:])
        XCTAssertEqual(result.stringValue, "second")
    }

    func testResolvedInvocationMayFinishAfterUnregisterButNewResolutionFails() async throws {
        let registry = MCPDomainToolRegistry()
        let invocationGate = MCPDomainInvocationGate()
        let handle = try await registry.register(
            registrationID: .init(rawValue: 1),
            scope: .window(id: 1),
            bindings: [Self.binding(
                name: MCPWindowToolName.readFile,
                operation: { _ in try await invocationGate.invoke() }
            )]
        )
        let initialResolution = await registry.resolve(toolName: MCPWindowToolName.readFile, scope: .window(id: 1))
        let resolved = try XCTUnwrap(initialResolution)
        let admittedInvocation = Task { try await resolved.binding([:]) }
        await invocationGate.waitUntilEntered()

        let removal = await registry.unregister(handle)
        let resolutionAfterRemoval = await registry.resolve(toolName: MCPWindowToolName.readFile, scope: .window(id: 1))
        let cancellationCount = await invocationGate.cancellationCount
        XCTAssertEqual(removal, .removed)
        XCTAssertNil(resolutionAfterRemoval)
        XCTAssertEqual(cancellationCount, 0, "Registry unregister must not cancel already-admitted work.")

        await invocationGate.release()
        let retainedResult = try await admittedInvocation.value
        XCTAssertEqual(retainedResult.stringValue, "retained")
    }

    func testIndexedRegisterResolveAndUnregisterChurnRemainsBoundedAtScale() async throws {
        for windowCount in [1, 10, 100] {
            let registry = MCPDomainToolRegistry()
            var handles: [MCPDomainToolRegistrationHandle] = []
            for windowID in 1 ... windowCount {
                try await handles.append(registry.register(
                    registrationID: .init(rawValue: UInt(windowID)),
                    scope: .window(id: windowID),
                    bindings: [Self.binding(name: MCPWindowToolName.readFile)]
                ))
            }

            let registered = await registry.diagnostics()
            XCTAssertEqual(registered.registrationCount, windowCount)
            XCTAssertEqual(registered.exactScopedToolCount, windowCount)
            XCTAssertEqual(registered.canonicalToolCount, 1)
            XCTAssertEqual(registered.canonicalRegistrationMembershipCount, windowCount)
            XCTAssertEqual(registered.windowToolCount, 1)
            XCTAssertEqual(registered.windowRegistrationMembershipCount, windowCount)
            XCTAssertEqual(registered.scopePresenceCount, windowCount)

            for windowID in 1 ... windowCount {
                let resolved = await registry.resolve(
                    toolName: MCPWindowToolName.readFile,
                    scope: .window(id: windowID)
                )
                XCTAssertEqual(resolved?.scope, .window(id: windowID))
            }
            let initialUnique = await registry.resolveUniqueWindowTool(toolName: MCPWindowToolName.readFile)
            XCTAssertEqual(initialUnique?.scope, windowCount == 1 ? .window(id: 1) : nil)

            for handle in handles.dropLast() {
                let removal = await registry.unregister(handle)
                XCTAssertEqual(removal, .removed)
            }
            let finalUnique = await registry.resolveUniqueWindowTool(toolName: MCPWindowToolName.readFile)
            XCTAssertEqual(finalUnique?.scope, .window(id: windowCount))
            if let first = handles.first, windowCount > 1 {
                let staleRemoval = await registry.unregister(first)
                XCTAssertEqual(staleRemoval, .unchanged)
            }
            if let last = handles.last {
                let finalRemoval = await registry.unregister(last)
                XCTAssertEqual(finalRemoval, .removed)
            }

            let emptied = await registry.diagnostics()
            XCTAssertEqual(emptied.registrationCount, 0)
            XCTAssertEqual(emptied.exactScopedToolCount, 0)
            XCTAssertEqual(emptied.canonicalToolCount, 0)
            XCTAssertEqual(emptied.canonicalRegistrationMembershipCount, 0)
            XCTAssertEqual(emptied.windowToolCount, 0)
            XCTAssertEqual(emptied.windowRegistrationMembershipCount, 0)
            XCTAssertEqual(emptied.scopePresenceCount, 0)
        }
    }

    func testConcurrentWindowRegistrationsPublishOneCanonicalDefinition() async throws {
        let registry = MCPDomainToolRegistry()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 1 ... 12 {
                group.addTask {
                    _ = try await registry.register(
                        registrationID: .init(rawValue: UInt(id)),
                        scope: .window(id: id),
                        bindings: [Self.binding(name: MCPWindowToolName.readFile)]
                    )
                }
            }
            try await group.waitForAll()
        }
        let snapshot = await registry.snapshot()
        XCTAssertEqual(snapshot.toolNames, [MCPWindowToolName.readFile])
        XCTAssertEqual(snapshot.activeScopesByToolName[MCPWindowToolName.readFile]?.count, 12)
        XCTAssertEqual(snapshot.revision, 12)
    }

    private static func binding(
        name: String,
        description: String = "fixture",
        result: String = "ok",
        operation: (@Sendable ([String: Value]) async throws -> Value)? = nil
    ) -> MCPDomainToolBinding {
        MCPDomainToolBinding(
            definition: MCPDomainToolDefinition(
                name: name,
                description: description,
                inputSchema: .object([
                    "properties": .object([:]),
                    "type": .string("object")
                ]),
                annotations: .init(
                    readOnlyHint: true,
                    destructiveHint: false,
                    idempotentHint: true,
                    openWorldHint: false
                )
            ),
            operation: operation ?? { _ in .string(result) }
        )
    }

    private func assertRegistryError(
        _ expected: MCPDomainToolRegistryError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected registry error: \(expected)")
        } catch let error as MCPDomainToolRegistryError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private actor MCPDomainInvocationGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Value, Error>?
    private(set) var cancellationCount = 0

    func invoke() async throws -> Value {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                releaseContinuation = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume(returning: .string("retained"))
        releaseContinuation = nil
    }

    private func cancel() {
        cancellationCount += 1
        releaseContinuation?.resume(throwing: CancellationError())
        releaseContinuation = nil
    }
}

final class MCPDomainToolFingerprintTests: XCTestCase {
    func testFingerprintCanonicalizesSchemaKeysAndTracksEveryMetadataField() throws {
        let first = definition(schema: .object([
            "properties": .object(["b": .string("two"), "a": .string("one")]),
            "type": .string("object")
        ]))
        let reordered = definition(schema: .object([
            "type": .string("object"),
            "properties": .object(["a": .string("one"), "b": .string("two")])
        ]))
        XCTAssertEqual(
            try MCPDomainToolFingerprint(definition: first),
            try MCPDomainToolFingerprint(definition: reordered)
        )

        let fingerprint = try MCPDomainToolFingerprint(definition: first)
        XCTAssertTrue(fingerprint.goldenSignature(index: 4).hasPrefix("4|read_file|enabled=true|ann="))
        XCTAssertNotEqual(
            fingerprint,
            try MCPDomainToolFingerprint(definition: definition(schema: first.inputSchema, description: "changed"))
        )
        XCTAssertNotEqual(
            fingerprint,
            try MCPDomainToolFingerprint(definition: MCPDomainToolDefinition(
                name: first.name,
                description: first.description,
                inputSchema: first.inputSchema,
                annotations: .init(readOnlyHint: false),
                isEnabledByDefault: first.isEnabledByDefault
            ))
        )
    }

    private func definition(
        schema: Value,
        description: String = "fixture"
    ) -> MCPDomainToolDefinition {
        MCPDomainToolDefinition(
            name: MCPWindowToolName.readFile,
            description: description,
            inputSchema: schema,
            annotations: .init(readOnlyHint: true),
            isEnabledByDefault: true
        )
    }
}

final class RepoPromptDomainRuntimeLifecycleTests: XCTestCase {
    func testInertRuntimeStartIsIdempotentAndStoppedInstanceCannotRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-owner-test-\(UUID().uuidString)", isDirectory: true)
        let runtime = try MCPDomainRuntime(
            configuration: .init(
                mode: .app,
                profileIdentifier: "owner-test",
                storageDirectory: directory,
                eventDirectory: directory,
                temporaryDirectory: directory
            ),
            runtimeID: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000010")),
            lifecycleGeneration: 7,
            processID: 42,
            createdAt: Date(timeIntervalSince1970: 123),
            registryID: XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000011"))
        )

        let created = await runtime.snapshot()
        XCTAssertEqual(created.lifecycle, .created)
        XCTAssertEqual(created.publicationSequence, 0)
        try await runtime.start()
        try await runtime.start()
        let ready = await runtime.snapshot()
        XCTAssertEqual(ready.lifecycle, .ready)
        XCTAssertEqual(ready.publicationSequence, 2)
        XCTAssertEqual(ready.identity.lifecycleGeneration, 7)
        XCTAssertEqual(ready.identity.processID, 42)
        XCTAssertEqual(ready.catalogRevision, 0)

        let result = await runtime.shutdown()
        XCTAssertEqual(result.previousLifecycle, .ready)
        XCTAssertEqual(result.finalLifecycle, .stopped)
        let stopped = await runtime.snapshot()
        XCTAssertEqual(stopped.publicationSequence, 4)
        let rejectedRouting = await runtime.routingCoordinator.openWindow(
            windowID: 1,
            activeWorkspaceID: nil,
            activeContextID: nil,
            presentationRevision: 1,
            operationID: UUID()
        )
        XCTAssertEqual(rejectedRouting.disposition, .rejected)
        XCTAssertEqual(rejectedRouting.diagnostic, "routing_coordinator_stopped")
        XCTAssertTrue(rejectedRouting.snapshot.windows.isEmpty)
        do {
            _ = try await runtime.routingCoordinator.issueLaunchToken(.init(
                runID: UUID(),
                context: DomainContextIdentity(workspaceID: UUID(), contextID: UUID()),
                expectedContextRevision: 0,
                windowID: nil,
                clientPrincipal: "stopped-runtime-test",
                providerIdentifier: "fixture",
                runPurpose: "must-fail-after-shutdown"
            ))
            XCTFail("Stopped routing coordinator issued a launch token")
        } catch let error as DomainRunLaunchTokenError {
            XCTAssertEqual(error, .runtimeStopped)
        }
        do {
            try await runtime.start()
            XCTFail("Stopped runtime restarted")
        } catch let error as DomainRuntimeLifecycleError {
            XCTAssertEqual(error, .stoppedRuntimeCannotRestart)
        }
    }
}
