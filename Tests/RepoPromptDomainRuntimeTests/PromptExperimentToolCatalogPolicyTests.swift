import Foundation
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    final class PromptExperimentToolCatalogPolicyTests: XCTestCase {
        private let toolName = MCPWindowToolName.promptExperiment

        func testDebugCatalogAdvertisesSessionLabOperationsAndFields() throws {
            let entry = try XCTUnwrap(MCPDomainToolCatalog.entry(named: toolName))
            XCTAssertEqual(entry.scope, .window)
            XCTAssertEqual(entry.capability, .promptExperimentControl)
            XCTAssertEqual(entry.admissionClass, .control)
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
            let properties = try XCTUnwrap(definition.inputSchema.objectValue?["properties"]?.objectValue)
            let operations = try XCTUnwrap(properties["op"]?.objectValue?["enum"]?.arrayValue?.compactMap(\.stringValue))
            XCTAssertEqual(operations, [
                "targets", "prepare", "describe_program", "create_or_update", "request_approval",
                "run", "status_or_wait", "cancel", "propose_patch", "export"
            ])
            XCTAssertEqual(properties["prompt_id"]?.objectValue?["type"]?.stringValue, "string")
            XCTAssertEqual(properties["max_evaluations"]?.objectValue?["type"]?.stringValue, "integer")
            XCTAssertEqual(properties["timeout_seconds"]?.objectValue?["type"]?.stringValue, "number")
            for removed in ["specification_json", "approval_mode", "workspace_id", "grading_id"] {
                XCTAssertNil(properties[removed], removed)
            }
            for operation in operations {
                XCTAssertEqual(
                    MCPDomainToolCatalog.operationIdentity(for: toolName, input: .value(operation)).normalizedOperation,
                    operation
                )
            }
            for forbidden in ["approve", "score", "promote"] {
                XCTAssertEqual(
                    MCPDomainToolCatalog.operationIdentity(for: toolName, input: .value(forbidden)).normalizedOperation,
                    MCPDomainToolOperationIdentity.unknownOperation
                )
                XCTAssertFalse(operations.contains(forbidden))
            }
        }

        func testFreshEngineerProfilesAdvertiseAndAdmitExperimentWithoutReasoningTools() async throws {
            let runtime = try await makeRuntime()
            let profiles = MCPClientToolPolicyProfile.allCases.filter {
                ![.discovery, .agentModeGenericExplore].contains($0)
            }
            for profile in profiles {
                let policy = snapshot(profile)
                let catalog = await runtime.domainHost.advertisedCatalog(.init(
                    isGloballyEnabled: true, disabledToolNames: [], policy: policy
                ))
                XCTAssertEqual(catalog.definitions.map(\.name), [toolName], profile.rawValue)
                try await runtime.domainHost.evaluateEarlyCallPolicy(toolName: toolName, policy: policy)
                let decision = try await runtime.domainHost.evaluatePreAdmissionCallPolicy(toolName: toolName, policy: policy)
                XCTAssertEqual(decision.admissionClass, .control)
            }
            for profile: MCPClientToolPolicyProfile in [.agentModeCodexEngineer, .agentModeClaudeEngineer] {
                let grants = snapshot(profile).additionalToolNames
                XCTAssertTrue(grants.contains(toolName))
                XCTAssertFalse(grants.contains(MCPWindowToolName.shareThoughts))
                XCTAssertFalse(grants.contains(MCPWindowToolName.waitForNextInstruction))
            }
        }

        func testDiscoveryAndPromptOnlyCallbacksRemainDenied() async throws {
            let runtime = try await makeRuntime()
            let promptOnly = MCPDomainClientPolicySnapshot(
                restrictedToolNames: Set(MCPDomainToolCatalog.orderedToolNames),
                additionalToolNames: [], role: .engineer, allowsAgentExternalControlTools: false
            )
            for policy in [snapshot(.discovery), promptOnly] {
                let catalog = await runtime.domainHost.advertisedCatalog(.init(
                    isGloballyEnabled: true, disabledToolNames: [], policy: policy
                ))
                XCTAssertTrue(catalog.definitions.isEmpty)
                do {
                    try await runtime.domainHost.evaluateEarlyCallPolicy(toolName: toolName, policy: policy)
                    XCTFail("Naming the tool must not grant experiment authority")
                } catch let denial as MCPDomainCallPolicyDenial {
                    XCTAssertEqual(denial, .missingAdditionalGrant(toolName: toolName))
                }
            }
        }

        func testReadOnlyExploreRoleCannotMutateExperimentsEvenWithProfileGrant() async throws {
            let runtime = try await makeRuntime()
            let policy = snapshot(.agentModeGenericExplore)
            let catalog = await runtime.domainHost.advertisedCatalog(.init(
                isGloballyEnabled: true, disabledToolNames: [], policy: policy
            ))
            XCTAssertTrue(catalog.definitions.isEmpty)
            do {
                _ = try await runtime.domainHost.evaluatePreAdmissionCallPolicy(toolName: toolName, policy: policy)
                XCTFail("Read-only explore must not acquire experiment drafting authority")
            } catch let denial as MCPDomainCallPolicyDenial {
                XCTAssertEqual(denial, .roleUnavailable(toolName: toolName))
            }
        }

        private func snapshot(_ profile: MCPClientToolPolicyProfile) -> MCPDomainClientPolicySnapshot {
            let classification = MCPClientToolPolicyCatalog.classification(for: profile)
            return .init(
                restrictedToolNames: MCPDomainToolCatalog.toolNames(for: classification.restrictedCapabilities),
                additionalToolNames: MCPDomainToolCatalog.toolNames(for: classification.grantedCapabilities),
                role: classification.role,
                allowsAgentExternalControlTools: classification.allowsAgentExternalControlTools
            )
        }

        private func makeRuntime() async throws -> MCPDomainRuntime {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-experiment-policy-\(UUID())")
            let runtime = MCPDomainRuntime(configuration: .init(
                mode: .standalone, profileIdentifier: "prompt-experiment-policy-test",
                storageDirectory: directory, eventDirectory: directory, temporaryDirectory: directory,
                externalReloadInterval: nil
            ))
            try await runtime.start()
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: toolName))
            _ = try await runtime.toolRegistry.register(
                registrationID: MCPDomainToolRegistrationID(), scope: .window(id: 1),
                bindings: [MCPDomainToolBinding(definition: definition, operation: { _ in .null })]
            )
            return runtime
        }
    }
#endif
