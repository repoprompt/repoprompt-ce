import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

@MainActor
final class HeadlessMCPDomainRuntimeM0ContractTests: XCTestCase {
    func testCanonicalCatalogActionsPoliciesAndDependenciesMatchFrozenManifest() async throws {
        let manifest = try loadJSONObject("Scripts/Fixtures/headless_mcp_domain_runtime_m0_contract.json")
        let catalog = try dictionary(manifest, key: "catalog")
        let globals = try strings(catalog, key: "global_tools")
        let windows = try strings(catalog, key: "window_tools")
        let allTools = globals + windows

        XCTAssertEqual(globals, MCPGlobalToolName.orderedToolNames)
        XCTAssertEqual(windows, MCPWindowToolGroup.orderedToolNames)
        XCTAssertEqual(allTools.count, 27)
        XCTAssertEqual(Set(allTools).count, allTools.count)

        let actionFixtures = try stringArrays(catalog, key: "actions")
        let actionlessFixtures = try dictionariesByKey(catalog, key: "actionless_tools")
        XCTAssertEqual(Set(actionFixtures.keys).union(actionlessFixtures.keys), Set(allTools))
        XCTAssertTrue(Set(actionFixtures.keys).isDisjoint(with: actionlessFixtures.keys))
        XCTAssertTrue(actionFixtures.values.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(actionFixtures.values.reduce(0) { $0 + $1.count }, 86)
        XCTAssertEqual(try integer(catalog, key: "canonical_discriminated_action_count"), 86)
        XCTAssertEqual(actionlessFixtures.count, try integer(catalog, key: "actionless_tool_count"))

        let actionEvidence = try dictionary(catalog, key: "action_execution_evidence")
        XCTAssertEqual(try string(actionEvidence, key: "status"), "explicitly_unmeasured_in_m0")
        XCTAssertEqual(actionEvidence["wire_envelope_claim"] as? Bool, false)

        let window = makeWindowWithoutAutoStart()
        addTeardownBlock { @MainActor in
            window.beginClose()
            await window.tearDown()
        }
        let liveTools = await window.mcpServer.windowMCPTools
        XCTAssertEqual(liveTools.map(\.name), windows)
        for tool in liveTools {
            if let actionless = actionlessFixtures[tool.name] {
                let properties = try schemaProperties(for: tool)
                let required = try schemaRequiredProperties(for: tool)
                XCTAssertEqual(required, try strings(actionless, key: "required_properties"), tool.name)
                XCTAssertNil(properties["op"], tool.name)
                XCTAssertNil(properties["action"], tool.name)
                continue
            }
            let expected = try XCTUnwrap(actionFixtures[tool.name], tool.name)
            let properties = try schemaProperties(for: tool)
            if tool.name == MCPWindowToolName.applyEdits {
                XCTAssertNotNil(properties["rewrite"])
                XCTAssertNotNil(properties["search"])
                XCTAssertNotNil(properties["edits"])
                XCTAssertEqual(expected, ["rewrite", "single_replace", "multiple_edits"])
                continue
            }
            let discriminator = properties["op"] ?? properties["action"]
            let object = try XCTUnwrap(discriminator?.objectValue, tool.name)
            let actual = try XCTUnwrap(object["enum"]?.arrayValue?.compactMap(\.stringValue), tool.name)
            XCTAssertEqual(actual, expected, tool.name)
        }

        let appSettings = try source("Sources/RepoPrompt/Infrastructure/MCP/AppSettingsMCPService.swift")
        let routing = try source("Sources/RepoPrompt/Infrastructure/MCP/WindowRoutingService.swift")
        XCTAssertEqual(
            try enumValues(in: appSettings, after: "static let toolName = MCPGlobalToolName.appSettings", key: "op"),
            actionFixtures[MCPGlobalToolName.appSettings]
        )
        XCTAssertEqual(
            try enumValues(in: routing, after: "name: MCPGlobalToolName.bindContext", key: "op"),
            actionFixtures[MCPGlobalToolName.bindContext]
        )
        XCTAssertEqual(
            try enumValues(in: routing, after: "name: MCPGlobalToolName.manageWorkspaces", key: "action"),
            actionFixtures[MCPGlobalToolName.manageWorkspaces]
        )

        let discriminatorContracts = try dictionaries(catalog, key: "missing_discriminator_contracts")
        XCTAssertEqual(Set(discriminatorContracts.compactMap { $0["tool"] as? String }), Set(actionFixtures.keys))
        for contract in discriminatorContracts {
            let tool = try string(contract, key: "tool")
            let behavior = try string(contract, key: "behavior")
            XCTAssertTrue(["defaults_to_action", "source_declares_typed_invalid_params", "source_declares_typed_error_reply"].contains(behavior), tool)
            let evidence = try dictionary(contract, key: "source_evidence")
            let sourceText = try source(string(evidence, key: "path"))
            let marker = try string(evidence, key: "marker")
            XCTAssertTrue(sourceText.contains(marker), tool)
            if behavior == "defaults_to_action" {
                let defaultAction = try string(contract, key: "default_action")
                XCTAssertTrue(marker.contains("?? \"\(defaultAction)\""), tool)
            } else {
                let errorType = try string(contract, key: "error_type")
                let typeMarker = try string(evidence, key: "type_marker")
                XCTAssertTrue(sourceText.contains(typeMarker), tool)
                if behavior == "source_declares_typed_invalid_params" {
                    XCTAssertEqual(typeMarker, errorType, tool)
                } else {
                    XCTAssertTrue(errorType.contains("HistoryToolReply.error"), tool)
                }
            }
        }

        let policy = try dictionary(manifest, key: "policy")
        let admissionFixture = try stringArrays(policy, key: "admission")
        let actualAdmission = Dictionary(grouping: MCPToolAdmissionPolicy.classifications) { $0.value.rawValue }
            .mapValues { Set($0.map(\.key)) }
        XCTAssertEqual(actualAdmission, admissionFixture.mapValues(Set.init))

        let executionFixture = try stringArrays(policy, key: "execution")
        var actualExecution: [String: Set<String>] = [:]
        for toolName in allTools {
            let contract = try XCTUnwrap(MCPToolExecutionContractCatalog.contract(for: toolName), toolName)
            let kind = switch contract.kind {
            case .bounded: "bounded"
            case .longSynchronousCancellable: "long_synchronous"
            case .lifecycleManagedCancellable: "lifecycle_managed"
            case .interactiveCancellable: "interactive"
            case .workspaceLifecycleCancellable: "workspace_lifecycle"
            }
            actualExecution[kind, default: []].insert(toolName)
        }
        XCTAssertEqual(actualExecution, executionFixture.mapValues(Set.init))

        let profiles = try stringArrays(policy, key: "advertisement_profiles")
        XCTAssertEqual(
            Set(DiscoverMCPToolPolicy.restrictedCapabilities.map(\.externalName)),
            try Set(XCTUnwrap(profiles["discover_restricted_capabilities"]))
        )
        XCTAssertEqual(
            Set(DiscoverMCPToolPolicy.grantedCapabilities.map(\.externalName)),
            try Set(XCTUnwrap(profiles["discover_granted_capabilities"]))
        )
        XCTAssertEqual(
            Set(AgentModeMCPToolPolicy.restrictedCapabilities.map(\.externalName)),
            try Set(XCTUnwrap(profiles["agent_mode_restricted_capabilities"]))
        )
        XCTAssertEqual(
            Set(AgentModeMCPToolPolicy.grantedCapabilities.map(\.externalName)),
            try Set(XCTUnwrap(profiles["agent_mode_generic_granted_capabilities"]))
        )
        XCTAssertEqual(Set(AgentModeMCPToolPolicy.claudeNativeGrantedCapabilities.map(\.externalName)), try Set(XCTUnwrap(profiles["agent_mode_claude_granted_capabilities"])))
        XCTAssertEqual(Set(AgentModeMCPToolPolicy.codexNativeGrantedCapabilities.map(\.externalName)), try Set(XCTUnwrap(profiles["agent_mode_codex_granted_capabilities"])))
        XCTAssertEqual(Set(AgentModeMCPToolPolicy.openCodeGrantedCapabilities.map(\.externalName)), try Set(XCTUnwrap(profiles["agent_mode_open_code_granted_capabilities"])))
        XCTAssertEqual(Set(AgentModeMCPToolPolicy.cursorGrantedCapabilities.map(\.externalName)), try Set(XCTUnwrap(profiles["agent_mode_cursor_granted_capabilities"])))
        XCTAssertEqual(
            Set(MCPPolicyGatedTools.gatedCapabilities.map(\.externalName)),
            try Set(XCTUnwrap(profiles["policy_gated_capabilities"]))
        )

        let capabilityFixtures = try stringArrays(policy, key: "tool_capabilities")
        XCTAssertEqual(Set(capabilityFixtures.keys), Set(allTools))
        for tool in allTools {
            XCTAssertEqual(
                Set(MCPToolCapabilities.capabilities(for: tool).map(\.externalName)),
                try Set(XCTUnwrap(capabilityFixtures[tool])),
                tool
            )
        }

        XCTAssertEqual(
            try string(policy, key: "resolved_tool_policy_projection_classification"),
            "production_policy_projection_not_runtime_registry_evidence"
        )
        let resolvedProfiles = try stringArrays(policy, key: "resolved_tool_policy_projection")
        XCTAssertEqual(resolvedProfiles["direct"], resolvedAdvertisedTools(allTools: allTools))
        XCTAssertEqual(
            resolvedProfiles["discovery"],
            resolvedAdvertisedTools(
                allTools: allTools,
                restricted: DiscoverMCPToolPolicy.restrictedTools,
                additional: DiscoverMCPToolPolicy.grantedTools
            )
        )
        XCTAssertEqual(
            resolvedProfiles["agent_mode_generic_explore"],
            resolvedAdvertisedTools(
                allTools: allTools,
                restricted: AgentModeMCPToolPolicy.restrictedTools,
                additional: AgentModeMCPToolPolicy.grantedTools,
                role: .explore
            )
        )
        XCTAssertEqual(
            resolvedProfiles["agent_mode_generic_engineer"],
            resolvedAdvertisedTools(
                allTools: allTools,
                restricted: AgentModeMCPToolPolicy.restrictedTools,
                additional: AgentModeMCPToolPolicy.grantedTools,
                role: .engineer
            )
        )
        XCTAssertEqual(
            resolvedProfiles["agent_mode_generic_engineer_orchestrator"],
            resolvedAdvertisedTools(
                allTools: allTools,
                restricted: AgentModeMCPToolPolicy.restrictedTools,
                additional: AgentModeMCPToolPolicy.grantedTools,
                role: .engineer,
                allowsAgentExternalControlTools: true
            )
        )
        let nativeProfiles: [(String, Set<String>)] = [
            ("agent_mode_claude_engineer", AgentModeMCPToolPolicy.claudeNativeGrantedTools),
            ("agent_mode_codex_engineer", AgentModeMCPToolPolicy.codexNativeGrantedTools),
            ("agent_mode_open_code_engineer", AgentModeMCPToolPolicy.openCodeGrantedTools),
            ("agent_mode_cursor_engineer", AgentModeMCPToolPolicy.cursorGrantedTools)
        ]
        for (name, granted) in nativeProfiles {
            XCTAssertEqual(
                resolvedProfiles[name],
                resolvedAdvertisedTools(
                    allTools: allTools,
                    restricted: AgentModeMCPToolPolicy.restrictedTools,
                    additional: granted,
                    role: .engineer
                ),
                name
            )
        }

        let dependencies = try dictionary(manifest, key: "dependencies")
        let expectedDependencies = try strings(dependencies, key: "stored_dependencies")
        let sourceDependencies = try storedPropertyNames(
            inStructNamed: "MCPWindowToolDependencies",
            source: source("Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPWindowToolDependencies.swift")
        )
        XCTAssertEqual(sourceDependencies, expectedDependencies)
        XCTAssertEqual(expectedDependencies.count, try integer(dependencies, key: "stored_dependency_count"))
    }

    func testEveryExecutableEvidenceCitationResolvesInCuratedTestLedger() throws {
        let artifactPaths = [
            "Scripts/Fixtures/headless_mcp_domain_runtime_m0_contract.json",
            "docs/spec/headless-mcp-domain-runtime-m0-editflowperf-baseline.json"
        ]
        var citations = Set<String>()
        for path in artifactPaths {
            try citations.formUnion(executableTestCitations(in: loadJSONObject(path)))
        }

        XCTAssertEqual(citations.count, 6, "Update the reviewed M0 citation inventory when evidence is added or removed")
        let ledgerEntries = try curatedTestLedgerEntries()
        let missing = citations.filter { ledgerEntries[$0] == nil }.sorted()
        XCTAssertTrue(missing.isEmpty, "M0 executable citations missing from the curated test ledger: \(missing)")
    }

    func testSDKCredentialAndPrivateChildContractsAreFailClosedEvidence() throws {
        let manifest = try loadJSONObject("Scripts/Fixtures/headless_mcp_domain_runtime_m0_contract.json")
        let package = try source("Package.swift")
        let sdk = try dictionary(manifest, key: "sdk_stdio")
        let revision = try string(sdk, key: "revision")
        XCTAssertTrue(package.contains("swift-sdk.git\", revision: \"\(revision)\""))
        let sourceEvidence = try dictionary(sdk, key: "source_evidence")
        XCTAssertEqual(try string(sourceEvidence, key: "assessment_kind"), "pinned_dependency_source_inspection")
        let sdkTransport = try sdkCheckoutSource(string(sourceEvidence, key: "transport"))
        XCTAssertTrue(sdkTransport.contains("if bytesRead == 0"))
        XCTAssertTrue(sdkTransport.contains("logger.error(\"Read error occurred\""))
        XCTAssertTrue(sdkTransport.contains("messageContinuation.finish()"))
        XCTAssertTrue(sdkTransport.contains("var pendingData = Data()"))
        let sdkServer = try sdkCheckoutSource(string(sourceEvidence, key: "server"))
        XCTAssertTrue(sdkServer.contains("for try await data in stream"))
        XCTAssertTrue(sdkServer.contains("closeConnectionAfterTerminalEvent(throwing: MCPError.connectionClosed)"))
        let assessment = try dictionary(sdk, key: "observed_terminal_assessment")
        XCTAssertEqual(try string(assessment, key: "host_visible_error"), "none; all three collapse to connectionClosed")
        XCTAssertTrue(try string(assessment, key: "decision").contains("RepoPromptMCP-owned stdio transport adapter"))
        let elicitation = try dictionary(sdk, key: "elicitation")
        XCTAssertEqual(try string(elicitation, key: "method"), "elicitation/create")
        XCTAssertEqual(try strings(elicitation, key: "actions"), ["accept", "decline", "cancel"])
        XCTAssertTrue(try string(elicitation, key: "classification").contains("client-negotiated"))

        let credential = try dictionary(manifest, key: "credential_gate")
        let measurement = try loadJSONObject("Scripts/Fixtures/item0_measurement_record.json")
        let keychain = try dictionary(measurement, key: "keychain_access_measurement")
        XCTAssertEqual(try string(credential, key: "observation_status"), "not_observed_approval_required")
        XCTAssertEqual(try string(credential, key: "record_classification"), "unresolved_procedure_record_not_empirical_evidence")
        XCTAssertEqual(try string(credential, key: "prescribed_measurement_milestone"), "before_M5_credential_transport")
        XCTAssertEqual(try string(keychain, key: "status"), "incomplete")
        XCTAssertEqual(keychain["startup_scan_approved"] as? Bool, false)
        XCTAssertTrue(try string(credential, key: "prescribed_fallback").contains("Parent-owned secure storage"))
        XCTAssertEqual(SecureStorageAccountCatalog.allAccounts.count, try integer(credential, key: "secure_account_catalog_count"))

        let packageScript = try source("Scripts/package_app.sh")
        let cliCopy = "cp \"$BUILD_DIR/$exe\" \"$APP_BUNDLE/Contents/MacOS/$exe\""
        let cliSign = "sign_path \"$APP_BUNDLE/Contents/MacOS/repoprompt-mcp\""
        let appSign = "sign_path \"$APP_BUNDLE/Contents/MacOS/$APP_NAME\""
        XCTAssertTrue(packageScript.contains(cliCopy))
        XCTAssertLessThan(
            try XCTUnwrap(packageScript.range(of: cliSign)?.lowerBound),
            try XCTUnwrap(packageScript.range(of: appSign)?.lowerBound)
        )

        let child = try dictionary(manifest, key: "child_launch")
        let currentLeaseFields = try strings(child, key: "current_lease_fields")
        let leaseSource = try source("Sources/RepoPrompt/Infrastructure/MCP/MCPBootstrapLease.swift")
        XCTAssertEqual(
            try storedPropertyNames(inStructNamed: "MCPBootstrapLeaseSpec", source: leaseSource),
            currentLeaseFields
        )
        let endpoint = try dictionary(child, key: "private_endpoint_contract")
        XCTAssertEqual(try string(endpoint, key: "directory_mode"), "0700")
        XCTAssertEqual(try string(endpoint, key: "socket_mode"), "0600")
        XCTAssertEqual(try string(endpoint, key: "descriptor_inheritance"), "prohibited")
        XCTAssertEqual(try string(endpoint, key: "admission"), "single_use_expected_child_or_descendant")
        XCTAssertEqual(try string(endpoint, key: "cleanup"), "identity_fenced_idempotent_settlement")
        let token = try dictionary(child, key: "domain_run_launch_token_contract")
        XCTAssertEqual(try string(token, key: "status"), "frozen_contract_only_not_implemented")
        XCTAssertEqual(try strings(token, key: "child_material"), ["opaque_random_capability"])
        XCTAssertEqual(try string(token, key: "policy_selection_authority"), "host_only")
        XCTAssertTrue(try strings(token, key: "host_record_bindings").contains("restricted_tools"))
        XCTAssertTrue(try Set(strings(token, key: "rules")).isSuperset(of: ["single_use", "memory_only", "never_logged", "never_persisted"]))

        let packageManifest = try source("Package.swift")
        XCTAssertFalse(packageManifest.contains("HeadlessMCPDomainRuntime"))
        XCTAssertFalse(packageManifest.contains("RepoPromptDomainRuntime"))
        let productionSwift = try allSwiftSource()
        XCTAssertFalse(productionSwift.contains("DomainRunLaunchToken"))
    }

    func testPersistenceApprovalMainActorAndPerformanceInventoriesRemainComplete() throws {
        let manifest = try loadJSONObject("Scripts/Fixtures/headless_mcp_domain_runtime_m0_contract.json")
        let persistence = try dictionary(manifest, key: "persistence")
        let classifications = try stringArrays(persistence, key: "save_source_classification")
        var classifiedSources: [String] = []
        for key in classifications.keys.sorted() {
            classifiedSources += try XCTUnwrap(classifications[key], key)
        }
        let saveSource = try source("Sources/RepoPrompt/Features/Workspaces/ViewModels/WorkspaceSaveDiagnostics.swift")
        let expression = try NSRegularExpression(pattern: #"WorkspaceSaveSource\("([^"]+)"\)"#)
        let range = NSRange(saveSource.startIndex..., in: saveSource)
        let actualSources = expression.matches(in: saveSource, range: range).compactMap { match -> String? in
            guard let valueRange = Range(match.range(at: 1), in: saveSource) else { return nil }
            return String(saveSource[valueRange])
        }
        XCTAssertEqual(Set(classifiedSources), Set(actualSources))
        XCTAssertEqual(classifiedSources.count, actualSources.count)

        let journal = try dictionaries(persistence, key: "working_journal_migration_rows")
        XCTAssertEqual(Set(journal.compactMap { $0["migration_milestone"] as? String }), ["M2", "M4", "never_to_child_disk"])
        XCTAssertTrue(journal.allSatisfy { $0["state"] != nil && $0["current_authority"] != nil })

        let approval = try dictionary(manifest, key: "approval")
        XCTAssertEqual(
            WorkspaceApprovalOperation.allCases.map(\.rawValue),
            try strings(approval, key: "workspace_operations")
        )
        XCTAssertEqual(try string(approval, key: "cancellation_result"), "denied")
        let approvalManager = try source("Sources/RepoPrompt/Infrastructure/MCP/WorkspaceApproval/WorkspaceApprovalManager.swift")
        XCTAssertTrue(approvalManager.contains("continuation.resume(returning: .denied)"))

        let actorInventory = try dictionary(manifest, key: "main_actor")
        let scannerFixture = """
        @MainActor final class InlineActor {}
          @MainActor
          final class IndentedActor {}
        @MainActor // retained annotation comment
        @Observable
        private final class AttributedActor {}
        @MainActor
        extension ExtendedActor {}
        """
        let scannerFixtureSites = try mainActorDeclarationSites(in: scannerFixture, path: "fixture.swift")
        XCTAssertEqual(Set(scannerFixtureSites.compactMap { $0["symbol"] as? String }), ["InlineActor", "IndentedActor", "AttributedActor", "ExtendedActor"])

        let expectedLocalSiteRows = try dictionaries(actorInventory, key: "mcp_local_declaration_sites")
        let expectedLocalSites = expectedLocalSiteRows.map(mainActorSiteKey).sorted()
        let actualLocalSites = try mainActorDeclarationSites(
            under: "Sources/RepoPrompt/Infrastructure/MCP"
        ).map(mainActorSiteKey).sorted()
        XCTAssertEqual(actualLocalSites, expectedLocalSites)
        XCTAssertEqual(actualLocalSites.count, try integer(actorInventory, key: "mcp_local_declaration_count"))
        XCTAssertEqual(actualLocalSites.count, 42)

        let externalSites = try dictionaries(actorInventory, key: "external_collaborators")
        for site in externalSites {
            let path = try string(site, key: "path")
            let symbol = try string(site, key: "symbol")
            let declarations = try mainActorDeclarationSites(in: source(path), path: path)
            XCTAssertTrue(declarations.contains { ($0["symbol"] as? String) == symbol }, "\(symbol) at \(path)")
        }

        let perToolHops = try stringArrays(actorInventory, key: "per_tool_source_guarded_hops")
        let allTools = try strings(dictionary(manifest, key: "catalog"), key: "global_tools")
            + strings(dictionary(manifest, key: "catalog"), key: "window_tools")
        XCTAssertEqual(Set(perToolHops.keys), Set(allTools))
        let inventoriedSymbols = Set(expectedLocalSites.map { $0.split(separator: "|").last.map(String.init) ?? "" })
            .union(externalSites.compactMap { $0["symbol"] as? String })
        for tool in allTools {
            let hops = try XCTUnwrap(perToolHops[tool], tool)
            XCTAssertFalse(hops.isEmpty, tool)
            XCTAssertTrue(Set(hops).isSubset(of: inventoriedSymbols), tool)
            if MCPWindowToolGroup.orderedToolNames.contains(tool) {
                XCTAssertTrue(hops.contains("MCPServerViewModel"), tool)
                XCTAssertTrue(hops.contains("MCPWindowToolRuntime"), tool)
                let provider = try XCTUnwrap(hops.first { $0.hasSuffix("ToolProvider") }, tool)
                let providerPaths = expectedLocalSiteRows.compactMap { site -> String? in
                    guard (site["symbol"] as? String) == provider else { return nil }
                    return site["path"] as? String
                }
                let marker = "name: MCPWindowToolName.\(swiftToolIdentifier(tool))"
                XCTAssertTrue(try providerPaths.contains { try source($0).contains(marker) }, "\(tool) owner \(provider)")
            }
        }
        XCTAssertTrue(try XCTUnwrap(perToolHops["manage_worktree"]).contains("MCPWorktreeToolProvider"))
        XCTAssertFalse(try XCTUnwrap(perToolHops["manage_worktree"]).contains("MCPGitToolProvider"))

        let delegatedInventory = try dictionary(actorInventory, key: "reviewed_delegated_hops")
        XCTAssertEqual(try string(delegatedInventory, key: "evidence_status"), "reviewed_non_executable_inventory")
        let delegatedTools = try stringArrays(delegatedInventory, key: "tools")
        XCTAssertTrue(Set(delegatedTools.keys).isSubset(of: Set(allTools)))
        for (tool, symbols) in delegatedTools {
            XCTAssertFalse(symbols.isEmpty, tool)
            XCTAssertTrue(Set(symbols).isSubset(of: inventoriedSymbols), tool)
        }

        let baseline = try loadJSONObject("docs/spec/headless-mcp-domain-runtime-m0-editflowperf-baseline.json")
        try assertSubstantiveEditFlowPerfEvidence(in: baseline)

        let performance = try dictionary(manifest, key: "performance_baseline")
        XCTAssertEqual(try string(performance, key: "live_sample_status"), "not_observed_task_prohibited")
        XCTAssertEqual(try string(performance, key: "required_before"), "M2_no_regression_decisions")
        let result = try dictionary(manifest, key: "milestone_result")
        XCTAssertEqual(try string(result, key: "status"), "contract_freeze_complete_with_carried_forward_evidence_gates")
        XCTAssertEqual(try strings(result, key: "carried_forward_gates").count, 2)
    }

    private func loadJSONObject(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: RepoRoot.url().appendingPathComponent(relativePath))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], relativePath)
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: RepoRoot.url().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func sdkCheckoutSource(_ relativePath: String) throws -> String {
        let checkout = try RepoRoot.url()
            .appendingPathComponent(".build/checkouts/swift-sdk", isDirectory: true)
            .appendingPathComponent(relativePath)
        return try String(contentsOf: checkout, encoding: .utf8)
    }

    private func dictionary(_ object: [String: Any], key: String) throws -> [String: Any] {
        try XCTUnwrap(object[key] as? [String: Any], key)
    }

    private func dictionaries(_ object: [String: Any], key: String) throws -> [[String: Any]] {
        try XCTUnwrap(object[key] as? [[String: Any]], key)
    }

    private func string(_ object: [String: Any], key: String) throws -> String {
        try XCTUnwrap(object[key] as? String, key)
    }

    private func strings(_ object: [String: Any], key: String) throws -> [String] {
        try XCTUnwrap(object[key] as? [String], key)
    }

    private func stringArrays(_ object: [String: Any], key: String) throws -> [String: [String]] {
        try XCTUnwrap(object[key] as? [String: [String]], key)
    }

    private func dictionariesByKey(_ object: [String: Any], key: String) throws -> [String: [String: Any]] {
        try XCTUnwrap(object[key] as? [String: [String: Any]], key)
    }

    private func integer(_ object: [String: Any], key: String) throws -> Int {
        try XCTUnwrap((object[key] as? NSNumber)?.intValue, key)
    }

    private func executableTestCitations(in value: Any) -> Set<String> {
        if let dictionary = value as? [String: Any] {
            return dictionary.values.reduce(into: Set<String>()) { result, child in
                result.formUnion(executableTestCitations(in: child))
            }
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { result, child in
                result.formUnion(executableTestCitations(in: child))
            }
        }
        guard let string = value as? String,
              string.hasPrefix("RepoPromptTests.") || string.hasPrefix("RepoPromptClaudeCompatibleProviderTests.")
        else { return [] }
        return [string]
    }

    private func curatedTestLedgerEntries() throws -> [String: String] {
        let ledger = try source("Scripts/Fixtures/test-suite-contract-ledger.tsv")
        let lines = ledger.split(separator: "\n", omittingEmptySubsequences: true)
        let header = try XCTUnwrap(lines.first, "test ledger header")
            .split(separator: "\t", omittingEmptySubsequences: false)
            .map(String.init)
        let methodIDIndex = try XCTUnwrap(header.firstIndex(of: "method_id"))
        let fileIndex = try XCTUnwrap(header.firstIndex(of: "file"))
        var entries: [String: String] = [:]
        entries.reserveCapacity(lines.count - 1)

        for line in lines.dropFirst() {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.indices.contains(methodIDIndex), columns.indices.contains(fileIndex) else {
                XCTFail("Malformed curated test ledger row: \(line.prefix(120))")
                continue
            }
            let ledgerID = columns[methodIDIndex]
            guard let separator = ledgerID.firstIndex(of: "/") else {
                XCTFail("Malformed curated test ledger method_id: \(ledgerID)")
                continue
            }
            let citation = String(ledgerID[ledgerID.index(after: separator)...])
            XCTAssertNil(entries.updateValue(columns[fileIndex], forKey: citation), "Duplicate curated test ledger ID: \(citation)")
        }
        return entries
    }

    private func assertSubstantiveEditFlowPerfEvidence(in baseline: [String: Any]) throws {
        XCTAssertEqual(
            try string(baseline, key: "classification"),
            "deterministic_contract_evidence_index_not_live_latency_baseline"
        )
        XCTAssertEqual(
            try string(baseline, key: "curated_test_ledger"),
            "Scripts/Fixtures/test-suite-contract-ledger.tsv"
        )

        let constraints = try dictionary(baseline, key: "capture_constraints")
        XCTAssertEqual(try string(constraints, key: "live_mcp_round_trip_status"), "not_observed_task_prohibited")
        XCTAssertTrue(try string(constraints, key: "fallback").contains("already-running CE debug app"))

        let evidenceFloorsField = "m0_evidence_floors"
        let floors = try dictionary(baseline, key: evidenceFloorsField)
        let checkout = try dictionary(baseline, key: "checkout_baseline")
        XCTAssertEqual(try string(checkout, key: "classification"), "current_checkout_size_snapshot_not_performance_sample")
        XCTAssertGreaterThanOrEqual(try integer(checkout, key: "tracked_files"), try integer(floors, key: "minimum_tracked_files"))
        XCTAssertGreaterThanOrEqual(
            try integer(checkout, key: "tracked_source_test_script_files"),
            try integer(floors, key: "minimum_tracked_source_test_script_files")
        )
        XCTAssertGreaterThanOrEqual(
            try integer(checkout, key: "tracked_source_test_script_bytes"),
            try integer(floors, key: "minimum_tracked_source_test_script_bytes")
        )
        XCTAssertTrue(try isLowercaseHexIdentifier(string(checkout, key: "base_commit"), length: 7 ... 40))

        let ledgerEntries = try curatedTestLedgerEntries()
        let stages = try dictionaries(baseline, key: "guarded_stage_contracts")
        let expectedStages: Set = ["queue", "main_actor", "execution", "persistence", "response"]
        XCTAssertEqual(stages.count, expectedStages.count)
        XCTAssertEqual(Set(stages.compactMap { $0["stage"] as? String }), expectedStages)
        var evidenceCitations = Set<String>()

        for stageRecord in stages {
            let stage = try string(stageRecord, key: "stage")
            XCTAssertEqual(
                try string(stageRecord, key: "evidence_kind"),
                "curated_ledger_executable_contract_reference",
                stage
            )
            let citation = try string(stageRecord, key: "evidence")
            let sourceFile = try string(stageRecord, key: "source_file")
            XCTAssertEqual(ledgerEntries[citation], sourceFile, "\(stage) evidence provenance")
            evidenceCitations.insert(citation)
            let observations = try dictionary(stageRecord, key: "observations")

            switch stage {
            case "queue":
                let ordinaryCapacity = try integer(observations, key: "ordinary_connection_capacity")
                XCTAssertGreaterThan(ordinaryCapacity, 0)
                XCTAssertGreaterThanOrEqual(try integer(observations, key: "file_search_connection_capacity"), ordinaryCapacity)
                XCTAssertGreaterThanOrEqual(try integer(observations, key: "store_search_capacity"), ordinaryCapacity)
                XCTAssertGreaterThanOrEqual(
                    try integer(observations, key: "controlled_oldest_waiter_age_milliseconds"),
                    try integer(floors, key: "minimum_controlled_queue_age_milliseconds")
                )
                XCTAssertGreaterThan(try integer(observations, key: "cancelled_waiter_count"), 0)
            case "main_actor":
                XCTAssertEqual(
                    try strings(observations, key: "ordered_events"),
                    ["MCP.ToolCall.MainActorScheduled", "MCP.ToolCall.MainActorEntered", "MCP.ToolCall.MainActorExited"]
                )
                XCTAssertEqual(observations["shared_request_identity_required"] as? Bool, true)
            case "execution":
                XCTAssertGreaterThanOrEqual(
                    try integer(observations, key: "joined_tool_lifecycle_event_count"),
                    try integer(floors, key: "minimum_joined_tool_lifecycle_event_count")
                )
                let matrices = try strings(observations, key: "workload_matrices")
                XCTAssertEqual(matrices.count, try integer(observations, key: "workload_matrix_count"))
                XCTAssertGreaterThanOrEqual(matrices.count, try integer(floors, key: "minimum_workload_matrix_count"))
                XCTAssertEqual(Set(matrices).count, matrices.count)
            case "persistence":
                let stageNames = try strings(observations, key: "stage_names")
                let lifecycleEvents = try strings(observations, key: "lifecycle_events")
                XCTAssertGreaterThanOrEqual(stageNames.count, try integer(floors, key: "minimum_durability_stage_count"))
                XCTAssertGreaterThanOrEqual(
                    lifecycleEvents.count,
                    try integer(floors, key: "minimum_durability_lifecycle_event_count")
                )
                XCTAssertEqual(observations["path_data_in_dimensions"] as? Bool, false)
            case "response":
                let orderedEvents = try strings(observations, key: "ordered_events")
                XCTAssertEqual(orderedEvents.count, try integer(observations, key: "ordered_event_count"))
                XCTAssertGreaterThanOrEqual(
                    orderedEvents.count,
                    try integer(floors, key: "minimum_response_delivery_event_count")
                )
                XCTAssertEqual(orderedEvents.first, "frame_accepted")
                XCTAssertEqual(orderedEvents.last, "stdout_write_completed")
                XCTAssertEqual(observations["shared_request_identity_required"] as? Bool, true)
            default:
                XCTFail("Unexpected EditFlowPerf stage: \(stage)")
            }
        }
        XCTAssertEqual(evidenceCitations.count, try integer(floors, key: "required_unique_executable_citations"))

        let historical = try dictionary(baseline, key: "historical_work_count_evidence")
        XCTAssertEqual(try string(historical, key: "status"), "observed_no_visible_app")
        XCTAssertTrue(try isLowercaseHexIdentifier(string(historical, key: "git_blob"), length: 40 ... 40))
        XCTAssertTrue(try isLowercaseHexIdentifier(string(historical, key: "source_commit"), length: 7 ... 40))
        let gitCommands = try dictionary(historical, key: "git_commands")
        XCTAssertGreaterThanOrEqual(
            gitCommands.count,
            try integer(floors, key: "minimum_historical_git_command_scenarios")
        )
        XCTAssertTrue(gitCommands.values.allSatisfy { ($0 as? NSNumber)?.intValue ?? 0 > 0 })
        let readFile = try dictionary(historical, key: "read_file_fixture")
        XCTAssertGreaterThan(try integer(readFile, key: "full_disk_bytes"), try integer(readFile, key: "returned_bytes"))
        XCTAssertGreaterThan(try integer(readFile, key: "returned_bytes"), 0)
        XCTAssertGreaterThan(try integer(readFile, key: "returned_lines"), 0)
        XCTAssertEqual(readFile["cache_hit"] as? Bool, false)
    }

    private func isLowercaseHexIdentifier(_ value: String, length: ClosedRange<Int>) -> Bool {
        let allowed = CharacterSet(charactersIn: "0123456789abcdef")
        return length.contains(value.count) && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private func schemaProperties(for tool: RepoPromptApp.Tool) throws -> [String: Value] {
        let schema = try XCTUnwrap(Value(tool.inputSchema).objectValue, tool.name)
        return try XCTUnwrap(schema["properties"]?.objectValue, tool.name)
    }

    private func schemaRequiredProperties(for tool: RepoPromptApp.Tool) throws -> [String] {
        let schema = try XCTUnwrap(Value(tool.inputSchema).objectValue, tool.name)
        return schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func resolvedAdvertisedTools(
        allTools: [String],
        restricted: Set<String> = [],
        additional: Set<String> = [],
        role: AgentModelCatalog.TaskLabelKind? = nil,
        allowsAgentExternalControlTools: Bool = false
    ) -> [String] {
        allTools.filter { tool in
            !restricted.contains(tool)
                && (!MCPPolicyGatedTools.names.contains(tool) || additional.contains(tool))
                && AgentModeMCPToolAdvertisementPolicy.shouldAdvertise(
                    toolName: tool,
                    taskLabelKind: role,
                    allowsAgentExternalControlTools: allowsAgentExternalControlTools
                )
        }
    }

    private func enumValues(in source: String, after anchor: String, key: String) throws -> [String] {
        let anchorRange = try XCTUnwrap(source.range(of: anchor), anchor)
        let tail = source[anchorRange.lowerBound...]
        let keyRange = try XCTUnwrap(tail.range(of: "\"\(key)\""), key)
        let keyedTail = tail[keyRange.lowerBound...]
        let enumRange = try XCTUnwrap(keyedTail.range(of: "enum: ["), key)
        let valuesTail = keyedTail[enumRange.upperBound...]
        let close = try XCTUnwrap(valuesTail.firstIndex(of: "]"), key)
        let values = String(valuesTail[..<close])
        let expression = try NSRegularExpression(pattern: #""([^"]+)""#)
        let matches = expression.matches(in: values, range: NSRange(values.startIndex..., in: values))
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: values) else { return nil }
            return String(values[range])
        }
    }

    private func storedPropertyNames(inStructNamed name: String, source: String) throws -> [String] {
        let declaration = try XCTUnwrap(source.range(of: "struct \(name)"), name)
        let openingBrace = try XCTUnwrap(source[declaration.upperBound...].firstIndex(of: "{"), name)
        var depth = 1
        var index = source.index(after: openingBrace)
        var lineStart = index
        var names: [String] = []
        let propertyExpression = try NSRegularExpression(
            pattern: #"^\s*(?:[A-Za-z_][A-Za-z0-9_]*\s+)*(?:let|var)\s+`?([A-Za-z_][A-Za-z0-9_]*)`?\s*:"#
        )
        while index < source.endIndex, depth > 0 {
            let character = source[index]
            if character == "\n" {
                if depth == 1 {
                    let line = String(source[lineStart ..< index])
                    let range = NSRange(line.startIndex..., in: line)
                    if let match = propertyExpression.firstMatch(in: line, range: range),
                       let nameRange = Range(match.range(at: 1), in: line)
                    {
                        names.append(String(line[nameRange]))
                    }
                }
                lineStart = source.index(after: index)
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
            }
            index = source.index(after: index)
        }
        XCTAssertEqual(depth, 0, "unterminated struct \(name)")
        return names
    }

    private func swiftToolIdentifier(_ externalName: String) -> String {
        if externalName == "file_search" { return "search" }
        if externalName == "wait_for_next_user_instruction" { return "waitForNextInstruction" }
        let components = externalName.split(separator: "_")
        guard let first = components.first else { return externalName }
        return String(first) + components.dropFirst().map { $0.prefix(1).uppercased() + String($0.dropFirst()) }.joined()
    }

    private func mainActorSiteKey(_ site: [String: Any]) -> String {
        let path = site["path"] as? String ?? ""
        let kind = site["kind"] as? String ?? ""
        let symbol = site["symbol"] as? String ?? ""
        return "\(path)|\(kind)|\(symbol)"
    }

    private func mainActorDeclarationSites(under relativeDirectory: String) throws -> [[String: Any]] {
        let root = try RepoRoot.url()
        let directory = root.appendingPathComponent(relativeDirectory, isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var sites: [[String: Any]] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relativePath = String(url.path.dropFirst(root.path.count + 1))
            try sites.append(contentsOf: mainActorDeclarationSites(in: String(contentsOf: url, encoding: .utf8), path: relativePath))
        }
        return sites
    }

    private func mainActorDeclarationSites(in source: String, path: String) throws -> [[String: Any]] {
        let expression = try NSRegularExpression(
            pattern: #"(?m)^[ \t]*@MainActor(?:[ \t]+|[^\n]*\n[ \t]*(?:@[A-Za-z_][^\n]*\n[ \t]*)*)(?:(?:public|package|internal|private|fileprivate|open|final)\s+)*(protocol|class|struct|enum|actor|extension)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        )
        return expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            guard let kindRange = Range(match.range(at: 1), in: source),
                  let symbolRange = Range(match.range(at: 2), in: source)
            else { return nil }
            return [
                "path": path,
                "kind": String(source[kindRange]),
                "symbol": String(source[symbolRange])
            ]
        }
    }

    private func allSwiftSource() throws -> String {
        let sources = try RepoRoot.url().appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var content = ""
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            content += try String(contentsOf: url, encoding: .utf8)
        }
        return content
    }

    private func makeWindowWithoutAutoStart() -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        return window
    }
}
