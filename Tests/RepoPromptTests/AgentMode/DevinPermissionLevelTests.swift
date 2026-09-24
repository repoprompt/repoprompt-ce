import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

/// Covers the Devin permission level, its binding, and ACP session mode mapping.
final class DevinPermissionLevelTests: XCTestCase {
    private typealias Level = DevinAgentToolPreferences.PermissionLevel

    // MARK: - PermissionLevel

    func testPickerOrderIsProviderDefaultFirstAndFullApprovalLast() {
        XCTAssertEqual(
            Level.allCases,
            [.providerDefault, .normal, .acceptEdits, .smart, .fullApproval]
        )
    }

    func testStoredRawValueParsingKeepsAbsenceDefaultAndFailsUnknownClosedToNormal() {
        XCTAssertEqual(Level.from(rawValue: nil), .providerDefault)
        XCTAssertEqual(Level.from(rawValue: ""), .providerDefault)
        XCTAssertEqual(Level.from(rawValue: "   "), .providerDefault)
        XCTAssertEqual(Level.from(rawValue: "garbage"), .normal)
        // The pre-ship draft persisted this raw value; it must not resolve to a broader mode.
        XCTAssertEqual(Level.from(rawValue: "providerManaged"), .normal)
        XCTAssertEqual(Level.from(rawValue: "  fullApproval "), .fullApproval)
        for level in Level.allCases {
            XCTAssertEqual(Level.from(rawValue: level.rawValue), level)
        }
    }

    func testSessionModeMapping() {
        XCTAssertNil(Level.providerDefault.sessionModeID)
        XCTAssertEqual(Level.normal.sessionModeID, "accept-edits")
        XCTAssertEqual(Level.acceptEdits.sessionModeID, "accept-edits")
        XCTAssertEqual(Level.smart.sessionModeID, "smart")
        XCTAssertEqual(Level.fullApproval.sessionModeID, "bypass")
    }

    func testDevinPermissionOptionScope() {
        XCTAssertTrue(ACPPermissionOptionPolicy.isAutoSelectable(optionID: "allow_once", for: .devin))
        XCTAssertTrue(ACPPermissionOptionPolicy.isAutoSelectable(optionID: "allow_session", for: .devin))
        for optionID in ["allow_always", "allow_always_global", "allow_server_session", "allow_server_always"] {
            XCTAssertFalse(ACPPermissionOptionPolicy.isAutoSelectable(optionID: optionID, for: .devin))
        }
    }

    func testSparseDevinRepoPromptPermissionUsesExactAllowOnce() async throws {
        let directory = try makeTestDirectory(name: "DevinSparsePermission")
        let executable = directory.appendingPathComponent("devin")
        let record = directory.appendingPathComponent("permission.json")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys

        record_path = r"\#(record.path)"

        def send(message):
            print(json.dumps({"jsonrpc": "2.0", **message}), flush=True)

        prompt_id = None
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "initialize":
                send({"id": request["id"], "result": {"agentCapabilities": {}, "authMethods": []}})
            elif method == "session/new":
                send({"id": request["id"], "result": {"sessionId": "test-session"}})
            elif method == "session/prompt":
                prompt_id = request["id"]
                send({"method": "session/update", "params": {"sessionId": "test-session", "update": {
                    "sessionUpdate": "tool_call", "toolCallId": "tool-1", "title": "Calling get_file_tree from RepoPromptCE",
                    "kind": "read", "rawInput": {"type": "roots"},
                    "_meta": {"cognition.ai/toolName": "mcp__RepoPromptCE__get_file_tree"}
                }}})
                send({"id": "permission-1", "method": "session/request_permission", "params": {
                    "sessionId": "test-session", "toolCall": {"toolCallId": "tool-1"},
                    "options": [
                        {"optionId": "ALLOW_ONCE", "kind": "allow_once", "name": "Alias"},
                        {"optionId": "allow_always", "kind": "allow_always", "name": "Always"},
                        {"optionId": "allow_once", "kind": "allow_once", "name": "Allow"}
                    ]
                }})
            elif request.get("id") == "permission-1":
                with open(record_path, "w", encoding="utf-8") as output:
                    json.dump(request.get("result"), output)
                send({"id": prompt_id, "result": {"stopReason": "end_turn"}})
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let provider = DevinACPAgentProvider(
            config: DevinAgentConfig(commandName: executable.path, includeRepoPromptMCPServer: false)
        )
        let request = makeRequest(workspacePath: directory.path)
        let controller = try ACPAgentSessionController(provider: provider, runRequest: request)
        do {
            _ = try await controller.bootstrap()
            try await controller.prompt(AgentMessage(userMessage: "Read roots"), request: request)
            await controller.shutdown()
        } catch {
            await controller.shutdown()
            throw error
        }
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        let outcome = try XCTUnwrap(response["outcome"] as? [String: Any])
        XCTAssertEqual(outcome["outcome"] as? String, "selected")
        XCTAssertEqual(outcome["optionId"] as? String, "allow_once")
    }

    func testSparsePermissionDoesNotApproveSupersededToolIdentity() async throws {
        let directory = try makeTestDirectory(name: "DevinChangedToolPermission")
        let executable = directory.appendingPathComponent("devin")
        let record = directory.appendingPathComponent("permission.json")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys
        def send(message):
            print(json.dumps({"jsonrpc": "2.0", **message}), flush=True)
        prompt_id = None
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "initialize":
                send({"id": request["id"], "result": {"agentCapabilities": {}, "authMethods": []}})
            elif method == "session/new":
                send({"id": request["id"], "result": {"sessionId": "test-session"}})
            elif method == "session/prompt":
                prompt_id = request["id"]
                send({"method": "session/update", "params": {"sessionId": "test-session", "update": {
                    "sessionUpdate": "tool_call", "toolCallId": "tool-1", "title": "RepoPrompt roots",
                    "kind": "read", "rawInput": {"type": "roots"},
                    "_meta": {"cognition.ai/toolName": "mcp__RepoPromptCE__get_file_tree"}
                }}})
                send({"method": "session/update", "params": {"sessionId": "test-session", "update": {
                    "sessionUpdate": "tool_call_update", "toolCallId": "tool-1", "status": "pending",
                    "title": "Shell command", "kind": "execute", "rawInput": {"command": "printf changed"},
                    "_meta": {"cognition.ai/toolName": "shell"}
                }}})
                send({"id": "permission-1", "method": "session/request_permission", "params": {
                    "sessionId": "test-session", "toolCall": {"toolCallId": "tool-1"},
                    "options": [{"optionId": "allow_once", "kind": "allow_once", "name": "Allow"},
                                {"optionId": "reject_once", "kind": "reject_once", "name": "Decline"}]
                }})
            elif request.get("id") == "permission-1":
                with open(r"\#(record.path)", "w", encoding="utf-8") as output:
                    json.dump(request.get("result"), output)
                send({"id": prompt_id, "result": {"stopReason": "end_turn"}})
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let request = makeRequest(workspacePath: directory.path)
        let controller = try ACPAgentSessionController(
            provider: DevinACPAgentProvider(config: DevinAgentConfig(
                commandName: executable.path,
                includeRepoPromptMCPServer: false
            )),
            runRequest: request
        )
        do {
            _ = try await controller.bootstrap()
            let events = await controller.events
            let responder = Task {
                for await event in events {
                    if case let .approvalRequested(approval) = event {
                        await controller.respondToPermissionRequest(id: approval.requestID.displayValue, decision: .decline)
                        return true
                    }
                }
                return false
            }
            try await controller.prompt(AgentMessage(userMessage: "Run"), request: request)
            responder.cancel()
            let requestedApproval = await responder.value
            XCTAssertTrue(requestedApproval)
            await controller.shutdown()
        } catch {
            await controller.shutdown()
            throw error
        }
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: Any])
        let outcome = try XCTUnwrap(response["outcome"] as? [String: String])
        XCTAssertEqual(outcome["optionId"], "reject_once")
    }

    func testExplicitDevinPermissionUsesExactIDsOrCancels() async throws {
        for (options, decision, expectedID) in [
            (#"[{"optionId":"ALLOW_ONCE","kind":"allow_once"},{"optionId":"allow_session","kind":"allow_always"}]"#, AgentApprovalDecision.accept, nil),
            (#"[{"optionId":"ALLOW_SESSION","kind":"allow_always"},{"optionId":"allow_once","kind":"allow_once"}]"#, .acceptForSession, "allow_once"),
            (#"[{"optionId":"allow_session","kind":"allow_always"},{"optionId":"allow_once","kind":"allow_once"}]"#, .acceptForSession, "allow_session")
        ] {
            let directory = try makeTestDirectory(name: "DevinExactPermission")
            let executable = directory.appendingPathComponent("devin")
            let record = directory.appendingPathComponent("response.json")
            let script = #"""
            #!/usr/bin/env python3
            import json
            import sys
            def send(message):
                print(json.dumps({"jsonrpc": "2.0", **message}), flush=True)
            prompt_id = None
            for line in sys.stdin:
                request = json.loads(line)
                method = request.get("method")
                if method == "initialize":
                    send({"id": request["id"], "result": {"agentCapabilities": {}, "authMethods": []}})
                elif method == "session/new":
                    send({"id": request["id"], "result": {"sessionId": "test-session"}})
                elif method == "session/prompt":
                    prompt_id = request["id"]
                    send({"method": "session/update", "params": {"sessionId": "test-session", "update": {
                        "sessionUpdate": "tool_call", "toolCallId": "tool-1", "title": "Shell command", "kind": "execute"
                    }}})
                    send({"id": "permission-1", "method": "session/request_permission", "params": {
                        "sessionId": "test-session", "toolCall": {"toolCallId": "tool-1"},
                        "options": json.loads(r'\#(options)')
                    }})
                elif request.get("id") == "permission-1":
                    with open(r"\#(record.path)", "w", encoding="utf-8") as output:
                        json.dump(request["result"]["outcome"], output)
                    send({"id": prompt_id, "result": {"stopReason": "end_turn"}})
            """#
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let request = makeRequest(workspacePath: directory.path)
            let controller = try ACPAgentSessionController(
                provider: DevinACPAgentProvider(config: DevinAgentConfig(
                    commandName: executable.path,
                    includeRepoPromptMCPServer: false
                )),
                runRequest: request
            )
            do {
                _ = try await controller.bootstrap()
                let events = await controller.events
                let prompt = Task { try await controller.prompt(AgentMessage(userMessage: "Run"), request: request) }
                for await event in events {
                    if case let .approvalRequested(approval) = event {
                        await controller.respondToPermissionRequest(id: approval.requestID.displayValue, decision: decision)
                        break
                    }
                }
                try await prompt.value
                await controller.shutdown()
            } catch {
                await controller.shutdown()
                throw error
            }
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String: String])
            XCTAssertEqual(response["outcome"], expectedID == nil ? "cancelled" : "selected")
            XCTAssertEqual(response["optionId"], expectedID)
        }
    }

    func testDevinClassifiesOnlyThoughtLevel() {
        let provider = DevinACPAgentProvider(config: DevinAgentConfig())
        XCTAssertTrue(provider.supportsParameterizedModelPicker)
        let cases: [(configID: String, category: String?, kind: ACPModelParameterKind?)] = [
            ("arbitrary_effort_id", " ThOuGhT_LeVeL ", .thinking),
            ("thought_level", "model_config", nil),
            ("speed", "model_config", nil),
            ("speed", "speed", nil)
        ]
        for (configID, category, expectedKind) in cases {
            XCTAssertEqual(provider.modelParameterKind(for: .init(
                configID: configID, category: category, displayName: configID, choices: []
            )), expectedKind)
        }
    }

    func testDevinModelMenusShowAdvertisedEffortWithoutChangingModelIdentity() {
        AgentACPModelRegistry.shared.test_reset(providerID: .devin)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .devin) }
        let option = AgentModelOption(
            rawValue: "swe-2-high", displayName: "SWE-2", description: nil,
            isPlaceholderDefault: false, isProviderDefault: true
        )
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [option],
                currentModelRaw: option.rawValue,
                modelParameterSets: [ACPModelParameterSet(
                    baseModelRaw: option.rawValue,
                    parameters: [ACPModelParameterDefinition(
                        kind: .thinking,
                        configID: "thought_level",
                        displayName: "Thinking",
                        choices: ["medium", "high", "max"].map {
                            ACPModelParameterChoice(rawValue: $0, displayName: $0.capitalized)
                        },
                        currentValueRaw: "high"
                    )]
                )]
            ),
            for: .devin
        )
        let items = AgentModelStableMenuItems.modelItems(
            agentKind: .devin,
            options: [option],
            selectedAgent: .devin,
            selectedModelRaw: option.rawValue,
            onSelect: { _, selected in XCTAssertEqual(selected.rawValue, "swe-2-high") }
        )
        XCTAssertEqual(items.map(\.title), ["SWE-2 · High"])
        XCTAssertEqual(AgentModelMenuTitle.displayName(for: AIModel.devinCustom(name: option.rawValue)), "SWE-2 · High")
        XCTAssertEqual(option.rawValue, "swe-2-high")
    }

    func testOnlyFullApprovalIsAWarningLevel() {
        for level in Level.allCases {
            XCTAssertEqual(level.isWarning, level == .fullApproval, "unexpected warning flag for \(level)")
        }
    }

    // MARK: - Provider binding identity

    func testPermissionLevelIDExposesAllFiveDevinOptions() {
        let options = AgentProviderPermissionLevelID.options(for: .devin)
        XCTAssertEqual(options.count, 5)
        XCTAssertEqual(options.map(\.subagentRawValue), Level.allCases.map(\.rawValue))
        XCTAssertEqual(options.map(\.providerID), Array(repeating: .devin, count: 5))
    }

    func testSubagentDefaultPinsNormal() {
        XCTAssertEqual(AgentProviderPermissionLevelID.subagentDefault(for: .devin), .devin(.normal))
    }

    func testSubagentRawValueInitializerAcceptsKnownLevelsOnly() {
        XCTAssertEqual(
            AgentProviderPermissionLevelID(providerID: .devin, subagentRawValue: "smart"),
            .devin(.smart)
        )
        XCTAssertNil(AgentProviderPermissionLevelID(providerID: .devin, subagentRawValue: "providerManaged"))
        XCTAssertNil(AgentProviderPermissionLevelID(providerID: .devin, subagentRawValue: "dangerous"))
    }

    // MARK: - Snapshot store

    @MainActor
    func testRuntimeBindingCarriesTheSessionModeForEachProfile() throws {
        let (store, _) = try makeStore()

        XCTAssertNil(store.runtimePermission(for: .devin, profile: .userConfigured).acpSessionModeID)

        store.setPermissionLevel(.devin(.acceptEdits))
        let configured = store.runtimePermission(for: .devin, profile: .userConfigured)
        XCTAssertEqual(configured.acpSessionModeID, "accept-edits")

        // Safe Managed ignores the stored direct preference and pins an explicit floor
        // rather than delegating to Devin's own configured default.
        XCTAssertEqual(
            store.runtimePermission(for: .devin, profile: .mcpSafeDefaults).acpSessionModeID,
            "accept-edits"
        )

        // An override aimed at a different provider falls back to the same pinned floor.
        XCTAssertEqual(
            store.runtimePermission(for: .devin, profile: .providerOverride(.grokBuild(.fullAccess))).acpSessionModeID,
            "accept-edits"
        )

        let override = store.runtimePermission(for: .devin, profile: .providerOverride(.devin(.fullApproval)))
        XCTAssertEqual(override.acpSessionModeID, "bypass")

        // RepoPrompt never broadly auto-approves Devin's native tools.
        for binding in [configured, override] {
            XCTAssertFalse(binding.autoApproveAllACPToolPermissions)
            XCTAssertFalse(binding.acceptsPendingACPApprovalWhenActivated)
        }
    }

    @MainActor
    func testPermissionLevelPersistsSecurelyAndIgnoresDefaultsEscalation() throws {
        let secureStrings = DevinPermissionFakeSecureStringStore()
        let secureStore = AgentPermissionSecureStore(
            secureStrings: secureStrings,
            notificationCenter: NotificationCenter()
        )
        let (store, defaults) = try makeStore(securePermissions: secureStore)

        store.setPermissionLevel(.devin(.smart))
        defaults.set(Level.fullApproval.rawValue, forKey: "devinPermissionLevel")

        XCTAssertEqual(
            DevinAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: secureStore),
            .smart
        )
        XCTAssertNotNil(secureStrings.plainValues[AgentPermissionSecureDomain.devin.storageKey])
    }

    @MainActor
    func testSecurePermissionReadFailureFailsClosedToNormal() throws {
        let secureStore = AgentPermissionSecureStore(
            secureStrings: DevinPermissionFailingSecureStringStore(),
            notificationCenter: NotificationCenter()
        )
        let (_, defaults) = try makeStore(securePermissions: secureStore)
        defaults.set(Level.fullApproval.rawValue, forKey: "devinPermissionLevel")

        XCTAssertEqual(
            DevinAgentToolPreferences.permissionLevel(defaults: defaults, secureStore: secureStore),
            .normal
        )
        XCTAssertEqual(secureStore.diagnostic(for: .devin)?.kind, .keychainInteractionNotAllowed)
    }

    @MainActor
    func testChromeBindingRendersFiveEnabledRowsWithTheStoredSelection() throws {
        let (store, _) = try makeStore()
        store.setPermissionLevel(.devin(.smart))

        let binding = store.topLevelSettingsControlsBinding(providerID: .devin)
        XCTAssertEqual(binding.permission.options.count, 5)
        XCTAssertEqual(binding.permission.displayName, Level.smart.displayName)
        XCTAssertFalse(binding.permission.isWarning)
        XCTAssertTrue(binding.permission.options.allSatisfy(\.isEnabled))
        XCTAssertEqual(binding.permission.options.filter(\.isSelected).map(\.id), [.devin(.smart)])
        XCTAssertEqual(binding.permission.options.filter(\.isWarning).map(\.id), [.devin(.fullApproval)])
        XCTAssertNil(binding.codexTools)
        XCTAssertNil(binding.claudeTools)
    }

    @MainActor
    func testChromeBindingUnderSafeManagedShowsThePinnedFloor() throws {
        let (store, _) = try makeStore()
        store.setPermissionLevel(.devin(.fullApproval))

        let binding = store.controlsBinding(
            selectedAgent: .devin,
            permissionProfile: .mcpSafeDefaults,
            isSubagent: true,
            externallyManagedReason: nil
        )
        XCTAssertEqual(binding.permission.displayName, Level.normal.displayName)
        XCTAssertEqual(binding.permission.options.filter(\.isSelected).map(\.id), [.devin(.normal)])
        XCTAssertFalse(binding.permission.isWarning)
        XCTAssertEqual(binding.runtimePermission.acpSessionModeID, "accept-edits")
    }

    @MainActor
    func testExternallyManagedReasonDisablesEveryDevinOption() throws {
        let (store, _) = try makeStore()
        let binding = store.controlsBinding(
            selectedAgent: .devin,
            permissionProfile: .userConfigured,
            isSubagent: false,
            externallyManagedReason: "Managed by MCP policy"
        )
        XCTAssertEqual(binding.permission.externallyManagedReason, "Managed by MCP policy")
        XCTAssertTrue(binding.permission.options.allSatisfy { !$0.isEnabled })
    }

    @MainActor
    func testProductionRequestBuilderPropagatesSessionModeForNewAndFollowUpRuns() throws {
        let session = AgentModeViewModel.TabSession(tabID: UUID())
        session.selectedAgent = .devin
        let runtimePermission = AgentProviderRuntimePermissionBinding(acpSessionModeID: "smart")

        let newRun = try XCTUnwrap(AgentModeRunService.makeACPRunRequest(
            session: session,
            workspacePath: "/tmp/workspace",
            attachments: [],
            runtimePermission: runtimePermission
        ))
        XCTAssertEqual(newRun.sessionModeID, "smart")
        XCTAssertNil(newRun.resumeSessionID)

        session.providerSessionID = "devin-session"
        let followUp = try XCTUnwrap(AgentModeRunService.makeACPRunRequest(
            session: session,
            workspacePath: "/tmp/workspace",
            attachments: [],
            runtimePermission: runtimePermission
        ))
        XCTAssertEqual(followUp.sessionModeID, "smart")
        XCTAssertEqual(followUp.resumeSessionID, "devin-session")
    }

    // MARK: - Provider launch arguments

    func testLaunchUsesBareACPSubcommand() throws {
        let (provider, directory) = try makeProvider()
        let launch = try provider.makeLaunchConfiguration(
            for: makeRequest(workspacePath: directory.path)
        )
        XCTAssertEqual(launch.arguments, ["acp"])
        XCTAssertEqual(launch.providerID, .devin)

        let headlessProvider = DevinACPAgentProvider(config: DevinAgentConfig(
            commandName: (directory.appendingPathComponent("devin")).path,
            includeRepoPromptMCPServer: false,
            useAutoPermissionModeAtLaunch: true
        ))
        let headlessLaunch = try headlessProvider.makeLaunchConfiguration(
            for: makeRequest(workspacePath: directory.path)
        )
        XCTAssertEqual(headlessLaunch.arguments, ["--permission-mode", "auto", "acp"])
    }

    func testResolvedLaunchAlwaysHoldsTheBareACPSubcommand() throws {
        // The resolver must never emit a wrapper/shim invocation ahead of `acp`.
        let directory = try makeTestDirectory(name: "DevinResolvedLaunchInvariant")
        let executable = directory.appendingPathComponent("devin")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolved = try DevinACPLaunchResolver().resolvedLaunch(
            for: DevinAgentConfig(commandName: executable.path)
        )
        XCTAssertEqual(resolved.arguments, ["acp"])
        XCTAssertEqual((resolved.command as NSString).lastPathComponent, "devin")
    }

    func testBareCommandSupportPreflightWarmsTheProductionLaunch() async throws {
        let directory = try makeTestDirectory(name: "DevinBareCommandLaunch")
        let executable = directory.appendingPathComponent("devin")
        try "#!/bin/sh\necho 'Run as an ACP server over stdio'\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let resolver = DevinACPLaunchResolver(launchEnvironmentProvider: { _ in
            ACPLaunchEnvironment(environment: ["PATH": directory.path])
        })
        let provider = DevinACPAgentProvider(
            config: DevinAgentConfig(commandName: "devin", includeRepoPromptMCPServer: false),
            launchResolver: resolver
        )
        let request = makeRequest(workspacePath: directory.path)

        let support = try await provider.support(for: request)
        XCTAssertEqual(support, .supported)
        let launch = try provider.makeLaunchConfiguration(for: request)

        XCTAssertEqual(
            launch.command,
            try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: executable.path).canonicalPath
        )
        XCTAssertEqual(launch.arguments, ["acp"])
        let overlayRoot = try XCTUnwrap(launch.environment["XDG_CONFIG_HOME"])
        let overlayMCP = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: URL(fileURLWithPath: overlayRoot)
                        .appendingPathComponent("devin/mcp_config.json")
                )
            ) as? [String: Any]
        )
        XCTAssertEqual((overlayMCP["mcpServers"] as? [String: Any])?.count, 0)
        let cleanupArtifact = try XCTUnwrap(launch.cleanupArtifact)
        DevinIntegrationConfiguration.cleanupReportingFailures(artifact: cleanupArtifact)
    }

    func testConcurrentProbeDoesNotInvalidateAResolvedBareCommandLaunch() async throws {
        let directory = try makeTestDirectory(name: "DevinConcurrentBareCommandLaunch")
        let executable = directory.appendingPathComponent("devin")
        try "#!/bin/sh\necho 'Run as an ACP server over stdio'\n".write(
            to: executable,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let gate = DevinProbeEnvironmentGate(environment: ["PATH": directory.path])
        let resolver = DevinACPLaunchResolver(launchEnvironmentProvider: { _ in
            await gate.nextEnvironment()
        })
        let config = DevinAgentConfig(commandName: "devin", includeRepoPromptMCPServer: false)

        let initialSupport = try await resolver.probeSupport(for: config)
        XCTAssertEqual(initialSupport, .supported)
        let secondProbe = Task { try await resolver.probeSupport(for: config) }
        await gate.waitForSecondCall()
        let resolved = Result { try resolver.resolvedLaunch(for: config) }
        await gate.releaseSecondCall()
        let secondSupport = try await secondProbe.value
        XCTAssertEqual(secondSupport, .supported)

        XCTAssertEqual(
            try resolved.get().command,
            try ExecutableFileIdentity.captureForTrustedPathLaunch(atPath: executable.path).canonicalPath
        )
    }

    func testRoutineInfoStderrIsHiddenWhileActionableOutputRemainsVisible() throws {
        let (provider, _) = try makeProvider()

        XCTAssertFalse(provider.shouldEmitStderrLine(
            "2026-09-14T09:52:20.134260Z  INFO chisel: elapsed_since_main_ms=4 logging initialized"
        ))
        XCTAssertFalse(provider.shouldEmitStderrLine(
            "2026-09-14T09:52:20Z INFO chisel: logging initialized"
        ))
        XCTAssertTrue(provider.shouldEmitStderrLine("2026-09-14T09:52:20Z ERROR chisel: startup failed"))
        XCTAssertFalse(provider.shouldEmitStderrLine(
            "2026-09-15T11:10:05.047288Z  WARN message_forest: MessageChain tree duplication: system prefix changed"
        ))
        XCTAssertFalse(provider.shouldEmitStderrLine(
            "2026-09-17T09:10:27.520189Z  WARN windsurf_api_client::remote_config: remote config revalidation failed, keeping last-good value: error sending request for url (https://unleash.codeium.com/api/client/features): operation timed out"
        ))
        XCTAssertFalse(provider.shouldEmitStderrLine(
            "2026-09-17T09:11:36Z WARN windsurf_api_client::remote_config: remote config revalidation failed, keeping last-good value: error decoding response body"
        ))
        XCTAssertTrue(provider.shouldEmitStderrLine("2026-09-14T09:52:20Z  WARN chisel: retrying"))
        XCTAssertTrue(provider.shouldEmitStderrLine("permission denied while reading config"))
    }

    func testOracleOneShotArgumentsUseSelectedModelAndPromptFile() {
        XCTAssertEqual(
            DevinCLIProvider.test_arguments(
                modelName: "claude-opus-4-6",
                promptFilePath: "/tmp/prompt.md"
            ),
            [
                "--model", "claude-opus-4-6",
                "--respect-workspace-trust", "false",
                "--permission-mode", "auto",
                "--prompt-file", "/tmp/prompt.md",
                "-p"
            ]
        )
    }

    func testOracleOneShotPromptRequestsOnePlainAnswerWithoutTools() {
        let prompt = DevinCLIProvider.test_promptText(from: AIMessage(
            systemPrompt: "Return Markdown.",
            userMessage: "Summarize this."
        ))

        XCTAssertTrue(prompt.contains("Return Markdown."))
        XCTAssertTrue(prompt.contains("Summarize this."))
        XCTAssertTrue(prompt.contains("Do not use any tools"))
    }

    func testOracleModelIdentityPreservesRawDevinModelID() {
        let model = AIModel.devinCustom(name: "anthropic/claude-opus-4.6")

        XCTAssertEqual(model.rawValue, "devin_custom_anthropic/claude-opus-4.6")
        XCTAssertEqual(model.modelName, "anthropic/claude-opus-4.6")
        XCTAssertEqual(model.providerType, .devin)
        XCTAssertEqual(AIModel.fromModelName(model.rawValue), model)
    }

    func testDevinPickersExposeOnlyAdvertisedModels() {
        AgentACPModelRegistry.shared.test_reset(providerID: .devin)
        addTeardownBlock { AgentACPModelRegistry.shared.test_reset(providerID: .devin) }
        let availability = AgentModelCatalog.AvailabilityContext(devinAvailable: true)

        XCTAssertTrue(AgentModelCatalog.options(for: .devin, availability: availability).isEmpty)
        XCTAssertFalse(AgentModelCatalog.isValid(rawModel: "default", for: .devin, availability: availability))

        let options = [
            AgentModelOption(rawValue: "swe-2-high", displayName: "SWE-2 High", description: nil, isDefault: true),
            AgentModelOption(rawValue: "gpt-5-6-sol-medium", displayName: "GPT-5.6 Sol Medium Thinking", description: nil, isDefault: false)
        ]
        AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(options: options, currentModelRaw: "swe-2-high"),
            for: .devin
        )

        XCTAssertEqual(Set(AgentModelCatalog.options(for: .devin, availability: availability)), Set(options))
        XCTAssertEqual(AgentModelCatalog.defaultModelRaw(for: .devin, availability: availability), "swe-2-high")
        XCTAssertEqual(Set(ACPAIModelCatalog.devinModelsFromStore().map(\.modelName)), Set(options.map(\.rawValue)))
        XCTAssertFalse(ACPAIModelCatalog.devinModelsFromStore().contains(.devinCustom(name: "default")))
    }

    func testOraclePickerExpandsAdvertisedDevinThinkingChoices() {
        AgentACPModelRegistry.shared.test_reset(providerID: .devin)
        addTeardownBlock { AgentACPModelRegistry.shared.test_reset(providerID: .devin) }
        let base = "gpt-6-astra-medium"
        let choices = ["low", "medium", "high", "xhigh", "max"].map {
            ACPModelParameterChoice(rawValue: $0, displayName: $0.capitalized)
        }
        AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: base,
                        displayName: "GPT-6 Astra Medium Thinking",
                        description: nil,
                        isDefault: true
                    ),
                    AgentModelOption(rawValue: "swe-1-7-medium", displayName: "SWE-1.7", description: nil, isDefault: false)
                ],
                currentModelRaw: base,
                modelParameterSets: [
                    ACPModelParameterSet(
                        baseModelRaw: base,
                        parameters: [ACPModelParameterDefinition(
                            kind: .thinking,
                            configID: "thought_level",
                            displayName: "Thought level",
                            choices: choices,
                            currentValueRaw: "medium"
                        )]
                    ),
                    ACPModelParameterSet(
                        baseModelRaw: "swe-1-7-medium",
                        parameters: [ACPModelParameterDefinition(
                            kind: .thinking,
                            configID: "thought_level",
                            displayName: "Thought level",
                            choices: [
                                ACPModelParameterChoice(rawValue: "medium", displayName: "Medium"),
                                ACPModelParameterChoice(rawValue: "max", displayName: "Max")
                            ],
                            currentValueRaw: "medium"
                        )]
                    )
                ]
            ),
            for: .devin
        )

        let pickerModels = ACPAIModelCatalog.devinModelsFromStore()
        XCTAssertEqual(
            Set(pickerModels.map(\.modelName)),
            Set(choices.map { "gpt-6-astra-\($0.rawValue)" } + ["swe-1-7-medium"])
        )
        XCTAssertEqual(AIModel.devinCustom(name: "gpt-6-astra-high").displayName, "GPT-6 Astra High Thinking")
        XCTAssertEqual(AIModel.devinCustom(name: "gpt-6-astra-xhigh").modelName, "gpt-6-astra-xhigh")
        XCTAssertEqual(AgentModelCatalog.options(
            for: .devin,
            availability: .init(devinAvailable: true)
        ).map(\.rawValue), [base, "swe-1-7-medium"])
    }

    func testHeadlessAndOracleDoNotInheritAgentModePermission() {
        let message = AgentMessage(systemPrompt: "system", userMessage: "prompt")
        let headless = DevinACPHeadlessAgentProvider.makeRunRequest(
            config: DevinAgentConfig(includeRepoPromptMCPServer: true),
            workspacePath: "/tmp/workspace",
            message: message
        )
        let oracle = DevinACPHeadlessAgentProvider.makeRunRequest(
            config: DevinAgentConfig(includeRepoPromptMCPServer: false),
            workspacePath: nil,
            message: message
        )

        XCTAssertNil(headless.sessionModeID)
        XCTAssertNil(oracle.sessionModeID)
        XCTAssertTrue(AgentModelCatalog.AgentSelectionSurface.headless.allows(.devin))
        XCTAssertTrue(
            AgentRuntimeProviderService.shared.makeProvider(
                for: .devin,
                modelString: "swe-2-high",
                workspacePath: "/tmp/workspace"
            ) is DevinACPHeadlessAgentProvider
        )
    }

    func testLiveModeFailureEmitsOptInStreamError() async throws {
        let workspace = try makeTestDirectory(name: "DevinLiveModeFailure")
        let controller = try ACPAgentSessionController(
            provider: ReuseKeyFakeDevinProvider(),
            runRequest: makeRequest(workspacePath: workspace.path)
        )
        do {
            try await controller.setSessionMode("smart")
            XCTFail("expected unopened session rejection")
        } catch {}
        do {
            try await controller.setSessionMode("smart", reportFailure: true)
            XCTFail("expected unopened session rejection")
        } catch {}
        var events = await controller.events.makeAsyncIterator()
        guard case let .stream(result)? = await events.next() else {
            await controller.shutdown()
            return XCTFail("expected stream failure")
        }
        XCTAssertEqual(result.type, "error")
        await controller.shutdown()
    }

    // MARK: - Controller reuse key

    func testControllerReuseAllowsLiveModeChange() async throws {
        let workspace = try makeTestDirectory(name: "DevinPermissionReuseKeyTests")
        let controller = try ACPAgentSessionController(
            provider: ReuseKeyFakeDevinProvider(),
            runRequest: makeRequest(workspacePath: workspace.path)
        )

        let sameMode = await controller.isCompatibleWith(
            request: makeRequest(workspacePath: workspace.path)
        )
        let changedMode = await controller.isCompatibleWith(
            request: makeRequest(workspacePath: workspace.path, sessionModeID: "smart")
        )
        let changedModel = await controller.isCompatibleWith(
            request: makeRequest(workspacePath: workspace.path, modelString: "opus")
        )

        XCTAssertTrue(sameMode)
        XCTAssertTrue(changedMode, "Devin mode changes apply to the running ACP session")
        XCTAssertTrue(changedModel, "Devin model switching stays live; it must not recycle the controller")

        await controller.shutdown()
    }

    func testProviderDefaultRestoresOpenedSessionMode() async throws {
        let directory = try makeTestDirectory(name: "DevinRestoreOpenedMode")
        let executable = directory.appendingPathComponent("devin")
        let record = directory.appendingPathComponent("modes.json")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys

        mode = "accept-edits"
        applied = []
        def options():
            return [{"id": "mode", "category": "mode", "type": "select", "currentValue": mode,
                     "options": [{"value": value, "name": value} for value in ["accept-edits", "smart", "bypass"]]}]
        def send(message):
            print(json.dumps({"jsonrpc": "2.0", **message}), flush=True)

        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "initialize":
                send({"id": request["id"], "result": {"agentCapabilities": {}, "authMethods": []}})
            elif method == "session/new":
                send({"id": request["id"], "result": {"sessionId": "test-session", "configOptions": options()}})
            elif method == "session/set_config_option":
                mode = request["params"]["value"]
                applied.append(mode)
                with open(r"\#(record.path)", "w", encoding="utf-8") as output:
                    json.dump(applied, output)
                send({"id": request["id"], "result": {"configOptions": options()}})
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let request = makeRequest(workspacePath: directory.path)
        let controller = try ACPAgentSessionController(
            provider: DevinACPAgentProvider(config: DevinAgentConfig(
                commandName: executable.path,
                includeRepoPromptMCPServer: false
            )),
            runRequest: request
        )
        do {
            _ = try await controller.bootstrap()
            try await controller.setSessionMode("bypass")
            try await controller.restoreOpenedSessionMode()
            await controller.shutdown()
        } catch {
            await controller.shutdown()
            throw error
        }
        let applied = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: record)) as? [String])
        XCTAssertEqual(applied, ["bypass", "accept-edits"])
    }

    func testCancelledDiscoveryDoesNotCacheFailure() async throws {
        final class RunCounter: @unchecked Sendable {
            var value = 0
        }
        let runs = RunCounter()
        let service = DevinModelDiscoveryService(
            isInstalled: { true },
            runSession: { _ in
                runs.value += 1
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        )

        let first = Task { await service.discoverIfNeeded() }
        try await Task.sleep(for: .milliseconds(80))
        first.cancel()
        _ = await first.value

        let second = Task { await service.discoverIfNeeded() }
        try await Task.sleep(for: .milliseconds(80))
        second.cancel()
        _ = await second.value

        XCTAssertEqual(runs.value, 2)
    }

    func testFailedDiscoveryDoesNotCacheFailure() async {
        final class RunCounter: @unchecked Sendable {
            var value = 0
        }
        let runs = RunCounter()
        let service = DevinModelDiscoveryService(
            isInstalled: { true },
            runSession: { _ in
                runs.value += 1
                throw AIProviderError.invalidConfiguration(detail: "transient")
            }
        )

        let first = await service.discoverIfNeeded()
        let second = await service.discoverIfNeeded()

        guard case .failed = first, case .failed = second else {
            return XCTFail("expected uncached failures, got \(first) then \(second)")
        }
        XCTAssertEqual(runs.value, 2)
    }

    func testStaleDiscoveryCancelDoesNotCancelALaterAttempt() async {
        final class RunCounter: @unchecked Sendable {
            var value = 0
        }
        let runs = RunCounter()
        let firstStarted = expectation(description: "first discovery started")
        let service = DevinModelDiscoveryService(
            isInstalled: { true },
            runSession: { _ in
                runs.value += 1
                if runs.value == 1 {
                    firstStarted.fulfill()
                    try await Task.sleep(for: .seconds(30))
                    return 1
                }
                return 2
            }
        )

        let first = Task { await service.discoverIfNeeded() }
        await fulfillment(of: [firstStarted], timeout: 2)
        first.cancel()
        _ = await first.value

        let second = await service.discoverIfNeeded()
        XCTAssertEqual(second, .discovered(modelCount: 2))
        XCTAssertEqual(runs.value, 2)
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore(
        securePermissions: AgentPermissionSecureStore? = nil
    ) throws -> (AgentProviderPreferenceSnapshotStore, UserDefaults) {
        let suiteName = "DevinPermissionLevelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let store = AgentProviderPreferenceSnapshotStore(
            defaults: defaults,
            securePermissions: securePermissions,
            codexMCPServerEntries: { [] }
        )
        return (store, defaults)
    }

    private func makeProvider() throws -> (DevinACPAgentProvider, URL) {
        let directory = try makeTestDirectory(name: "DevinPermissionLevelTests")
        let executable = directory.appendingPathComponent("devin")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let provider = DevinACPAgentProvider(
            config: DevinAgentConfig(
                commandName: executable.path,
                includeRepoPromptMCPServer: false
            )
        )
        return (provider, directory)
    }

    private func makeRequest(
        workspacePath: String,
        sessionModeID: String? = nil,
        modelString: String? = nil
    ) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: .devin,
            modelString: modelString,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil,
            sessionModeID: sessionModeID
        )
    }
}

private actor DevinProbeEnvironmentGate {
    private let environment: [String: String]
    private var callCount = 0
    private var secondCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseSecondCallContinuation: CheckedContinuation<Void, Never>?

    init(environment: [String: String]) {
        self.environment = environment
    }

    func nextEnvironment() async -> ACPLaunchEnvironment {
        callCount += 1
        if callCount == 2 {
            let waiters = secondCallWaiters
            secondCallWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseSecondCallContinuation = continuation
            }
        }
        return ACPLaunchEnvironment(environment: environment)
    }

    func waitForSecondCall() async {
        guard callCount < 2 else { return }
        await withCheckedContinuation { continuation in
            secondCallWaiters.append(continuation)
        }
    }

    func releaseSecondCall() {
        releaseSecondCallContinuation?.resume()
        releaseSecondCallContinuation = nil
    }
}

final class DevinIntegrationConfigurationTests: XCTestCase {
    func testOverlayPreservesXDGEntriesAndDevinWritesThroughCleanup() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinIntegrationSource")
        let devinSource = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        let ghSource = sourceRoot.appendingPathComponent("gh", isDirectory: true)
        try FileManager.default.createDirectory(at: devinSource, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ghSource, withIntermediateDirectories: true)
        try "native gh config".write(
            to: ghSource.appendingPathComponent("hosts.yml"),
            atomically: true,
            encoding: .utf8
        )
        try "native config".write(
            to: devinSource.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        try "untouched state".write(
            to: devinSource.appendingPathComponent("state.bin"),
            atomically: true,
            encoding: .utf8
        )
        let sourceMCP: [String: Any] = [
            "mcpServers": [
                "Existing": ["transport": "stdio", "command": "existing"]
            ]
        ]
        try JSONSerialization.data(withJSONObject: sourceMCP).write(
            to: devinSource.appendingPathComponent("mcp_config.json")
        )
        let executable = sourceRoot.appendingPathComponent("repoprompt-mcp")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(
                command: executable.path,
                args: ["--backend", "app"]
            ),
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path, "HOME": sourceRoot.path]
        )
        let overlayRoot = try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]).asFileURL
        let overlayDevin = overlayRoot.appendingPathComponent("devin", isDirectory: true)
        let ghDestination = try FileManager.default.destinationOfSymbolicLink(
            atPath: overlayRoot.appendingPathComponent("gh").path
        )
        XCTAssertEqual(
            URL(fileURLWithPath: ghDestination).resolvingSymlinksInPath(),
            ghSource.resolvingSymlinksInPath()
        )
        let mergedData = try Data(contentsOf: overlayDevin.appendingPathComponent("mcp_config.json"))
        let mergedRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: mergedData) as? [String: Any])
        let mergedServers = try XCTUnwrap(mergedRoot["mcpServers"] as? [String: Any])
        XCTAssertNotNil(mergedServers["Existing"])
        XCTAssertNotNil(mergedServers[RepoPromptMCPServerConfiguration.defaultServerName])
        let existing = try XCTUnwrap(mergedServers["Existing"] as? [String: Any])
        XCTAssertEqual((existing["env"] as? [String: String])?["XDG_CONFIG_HOME"], sourceRoot.path)

        let replacedConfig = overlayDevin.appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: replacedConfig)
        try "updated config".write(to: replacedConfig, atomically: true, encoding: .utf8)
        try "new state".write(
            to: overlayDevin.appendingPathComponent("new-state.json"),
            atomically: true,
            encoding: .utf8
        )

        try DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact)

        XCTAssertEqual(
            try String(contentsOf: devinSource.appendingPathComponent("config.json"), encoding: .utf8),
            "updated config"
        )
        XCTAssertEqual(
            try String(contentsOf: devinSource.appendingPathComponent("new-state.json"), encoding: .utf8),
            "new state"
        )
        let untouchedState = devinSource.appendingPathComponent("state.bin")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: untouchedState.path))
        XCTAssertEqual(try String(contentsOf: untouchedState, encoding: .utf8), "untouched state")
        XCTAssertEqual(
            try Data(contentsOf: devinSource.appendingPathComponent("mcp_config.json")),
            try JSONSerialization.data(withJSONObject: sourceMCP)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlayRoot.path))
    }

    func testCleanupPreservesNewerNativeConfigAndRetainsRecoveryOverlay() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinIntegrationConcurrentNativeWrite")
        let devinSource = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: devinSource, withIntermediateDirectories: true)
        let nativeConfig = devinSource.appendingPathComponent("config.json")
        try "original".write(to: nativeConfig, atomically: true, encoding: .utf8)

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            mcpServers: .disableAll,
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path, "HOME": sourceRoot.path]
        )
        let overlayRoot = try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]).asFileURL
        let overlayConfig = overlayRoot
            .appendingPathComponent("devin", isDirectory: true)
            .appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: overlayConfig)
        try "overlay update".write(to: overlayConfig, atomically: true, encoding: .utf8)
        try "newer native update".write(to: nativeConfig, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Recovery data remains at \(overlayRoot.path)"))
        }
        XCTAssertEqual(try String(contentsOf: nativeConfig, encoding: .utf8), "newer native update")
        XCTAssertTrue(FileManager.default.fileExists(atPath: overlayRoot.path))
        try? FileManager.default.removeItem(at: overlayRoot)
    }

    func testCleanupRestoresNativeConfigWhenItChangesDuringPublication() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinIntegrationPublicationRace")
        let devinSource = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: devinSource, withIntermediateDirectories: true)
        let nativeConfig = devinSource.appendingPathComponent("config.json")
        try "original".write(to: nativeConfig, atomically: true, encoding: .utf8)

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            mcpServers: .disableAll,
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path, "HOME": sourceRoot.path]
        )
        let overlayRoot = try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]).asFileURL
        let overlayConfig = overlayRoot
            .appendingPathComponent("devin", isDirectory: true)
            .appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: overlayConfig)
        try "overlay update".write(to: overlayConfig, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try DevinIntegrationConfiguration.cleanup(
            artifact: prepared.cleanupArtifact,
            beforeReplacing: { sourceEntry in
                try "newer native update".write(to: sourceEntry, atomically: true, encoding: .utf8)
            }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("Recovery data remains at \(overlayRoot.path)"))
        }
        XCTAssertEqual(try String(contentsOf: nativeConfig, encoding: .utf8), "newer native update")
        XCTAssertTrue(FileManager.default.fileExists(atPath: overlayRoot.path))
        try? FileManager.default.removeItem(at: overlayRoot)
    }

    func testOverlayRestoresNativeXDGForCommandOnlyStdioEntries() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinIntegrationCommandOnlyStdio")
        let devinSource = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: devinSource, withIntermediateDirectories: true)
        let executable = sourceRoot.appendingPathComponent("repoprompt-mcp")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try JSONSerialization.data(withJSONObject: [
            "mcpServers": [
                "CommandOnly": ["command": "existing", "args": []],
                "HTTP": ["url": "https://example.invalid"]
            ]
        ]).write(to: devinSource.appendingPathComponent("mcp_config.json"))

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: executable.path),
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path, "HOME": sourceRoot.path]
        )
        let overlayRoot = try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]).asFileURL
        let overlayMCP = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: overlayRoot
                        .appendingPathComponent("devin")
                        .appendingPathComponent("mcp_config.json")
                )
            ) as? [String: Any]
        )
        let servers = try XCTUnwrap(overlayMCP["mcpServers"] as? [String: Any])
        let commandOnly = try XCTUnwrap(servers["CommandOnly"] as? [String: Any])
        XCTAssertEqual((commandOnly["env"] as? [String: String])?["XDG_CONFIG_HOME"], sourceRoot.path)
        let http = try XCTUnwrap(servers["HTTP"] as? [String: Any])
        XCTAssertNil(http["env"])

        try DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact)
    }

    func testCleanupRejectsPermissionOnlyNativeChange() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinIntegrationPermissionOnlyNativeWrite")
        let devinSource = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: devinSource, withIntermediateDirectories: true)
        let nativeConfig = devinSource.appendingPathComponent("config.json")
        try "original".write(to: nativeConfig, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: nativeConfig.path)

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            mcpServers: .disableAll,
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path, "HOME": sourceRoot.path]
        )
        let overlayRoot = try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]).asFileURL
        let overlayConfig = overlayRoot
            .appendingPathComponent("devin", isDirectory: true)
            .appendingPathComponent("config.json")
        try FileManager.default.removeItem(at: overlayConfig)
        try "overlay update".write(to: overlayConfig, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try DevinIntegrationConfiguration.cleanup(
            artifact: prepared.cleanupArtifact,
            beforeReplacing: { sourceEntry in
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: sourceEntry.path
                )
            }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("Recovery data remains at \(overlayRoot.path)"))
        }
        XCTAssertEqual(try String(contentsOf: nativeConfig, encoding: .utf8), "original")
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: nativeConfig.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(mode.uint16Value, 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: overlayRoot.path))
        try? FileManager.default.removeItem(at: overlayRoot)
    }

    func testDisableAllMCPOverlayPreservesConfigWithoutNativeServers() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinIntegrationNoMCP")
        let devinSource = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: devinSource, withIntermediateDirectories: true)
        try "native config".write(
            to: devinSource.appendingPathComponent("config.json"),
            atomically: true,
            encoding: .utf8
        )
        let sourceMCP: [String: Any] = [
            "mcpServers": ["Existing": ["transport": "stdio", "command": "existing"]]
        ]
        let sourceMCPURL = devinSource.appendingPathComponent("mcp_config.json")
        try JSONSerialization.data(withJSONObject: sourceMCP).write(to: sourceMCPURL)

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            mcpServers: .disableAll,
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path, "HOME": sourceRoot.path]
        )
        let overlayRoot = try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]).asFileURL
        let overlayDevin = overlayRoot.appendingPathComponent("devin", isDirectory: true)
        let overlayMCP = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: overlayDevin.appendingPathComponent("mcp_config.json"))
            ) as? [String: Any]
        )

        XCTAssertEqual((overlayMCP["mcpServers"] as? [String: Any])?.count, 0)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(
            atPath: overlayDevin.appendingPathComponent("config.json").path
        ))

        try DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact)
        XCTAssertEqual(
            try Data(contentsOf: sourceMCPURL),
            try JSONSerialization.data(withJSONObject: sourceMCP)
        )
    }

    func testMalformedSourceMCPDoesNotLeaveAnOverlay() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinIntegrationMalformed")
        let devinSource = sourceRoot.appendingPathComponent("devin", isDirectory: true)
        try FileManager.default.createDirectory(at: devinSource, withIntermediateDirectories: true)
        try "[]".write(
            to: devinSource.appendingPathComponent("mcp_config.json"),
            atomically: true,
            encoding: .utf8
        )
        let executable = sourceRoot.appendingPathComponent("repoprompt-mcp")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let before = try overlayNames()

        XCTAssertThrowsError(
            try DevinIntegrationConfiguration.prepare(
                workingDirectory: sourceRoot.path,
                repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: executable.path),
                sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path]
            )
        )

        XCTAssertEqual(try overlayNames(), before)
    }

    func testCleanupFailureKeepsRecoveryOverlayAndReportsItsPath() throws {
        let sourceRoot = try makeTestDirectory(name: "DevinIntegrationCleanupFailure")
        let executable = sourceRoot.appendingPathComponent("repoprompt-mcp")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let prepared = try DevinIntegrationConfiguration.prepare(
            workingDirectory: sourceRoot.path,
            repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration(command: executable.path),
            sourceEnvironment: ["XDG_CONFIG_HOME": sourceRoot.path]
        )
        let overlayRoot = try XCTUnwrap(prepared.environment["XDG_CONFIG_HOME"]).asFileURL
        try FileManager.default.removeItem(
            at: overlayRoot.appendingPathComponent(".repoprompt-source-devin-path")
        )

        XCTAssertThrowsError(try DevinIntegrationConfiguration.cleanup(artifact: prepared.cleanupArtifact)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Recovery data remains at \(overlayRoot.path)"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: overlayRoot.path))
        try? FileManager.default.removeItem(at: overlayRoot)
    }

    private func overlayNames() throws -> Set<String> {
        try Set(
            FileManager.default.contentsOfDirectory(
                at: FileManager.default.temporaryDirectory,
                includingPropertiesForKeys: nil
            )
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("RepoPromptDevinACP-") }
        )
    }
}

private extension String {
    var asFileURL: URL {
        URL(fileURLWithPath: self, isDirectory: true)
    }
}

private final class DevinPermissionFakeSecureStringStore: SecurePlainStringStoring {
    let persistsValuesAcrossLaunches = true
    var plainValues: [String: String] = [:]

    func getPlainValue(for account: SecureStorageAccount, accessMode _: KeychainAccessMode) throws -> String? {
        plainValues[account.identifier]
    }

    func savePlainValue(
        _ value: String,
        for account: SecureStorageAccount,
        accessMode _: KeychainAccessMode
    ) throws {
        plainValues[account.identifier] = value
    }

    func deletePlainValue(for account: SecureStorageAccount, accessMode _: KeychainAccessMode) throws {
        plainValues.removeValue(forKey: account.identifier)
    }
}

private final class DevinPermissionFailingSecureStringStore: SecurePlainStringStoring {
    let persistsValuesAcrossLaunches = true

    func getPlainValue(for _: SecureStorageAccount, accessMode _: KeychainAccessMode) throws -> String? {
        throw KeychainService.KeychainError.interactionNotAllowed
    }

    func savePlainValue(_: String, for _: SecureStorageAccount, accessMode _: KeychainAccessMode) throws {
        throw KeychainService.KeychainError.interactionNotAllowed
    }

    func deletePlainValue(for _: SecureStorageAccount, accessMode _: KeychainAccessMode) throws {
        throw KeychainService.KeychainError.interactionNotAllowed
    }
}

/// Minimal Devin provider double for controller-lifecycle tests (no launch resolution).
private struct ReuseKeyFakeDevinProvider: ACPAgentProvider {
    var providerID: ACPProviderID {
        .devin
    }

    func support(for _: ACPRunRequest) async -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: "/bin/echo",
            arguments: [],
            environment: [:],
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        try ACPSessionConfiguration(
            mode: .new,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: []
        )
    }

    func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(_: [String: Any], sessionID _: String) -> [NormalizedAgentRuntimeEvent] {
        []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}
