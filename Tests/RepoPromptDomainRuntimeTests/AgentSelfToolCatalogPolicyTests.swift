import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class AgentSelfToolCatalogPolicyTests: XCTestCase {
    func testSelfCompactIsAdvertisedWithoutLegacyAlias() {
        let names = MCPDomainCanonicalToolDefinitions.definitions.map(\.name)
        XCTAssertEqual(names.filter { $0 == "self_compact" }.count, 1)
        XCTAssertFalse(names.contains("agent_self"))
        XCTAssertTrue(MCPDomainToolCatalog.orderedToolNames.contains("self_compact"))
        XCTAssertNil(MCPDomainToolCatalog.entry(named: "agent_self"))
        XCTAssertNil(MCPDomainCanonicalToolDefinitions.definition(named: "agent_self"))
        for profile in MCPClientToolPolicyProfile.allCases {
            XCTAssertFalse(MCPClientToolPolicyCatalog.resolvedToolNames(for: profile).contains("agent_self"))
        }
    }

    func testCanonicalSelfToolHasOnlyTwoOperationsAndNoTargetSelectors() throws {
        let name = "self_compact"
        let entry = try XCTUnwrap(MCPDomainToolCatalog.entry(named: name))
        XCTAssertEqual(entry.scope, .window)
        XCTAssertEqual(entry.capability, .agentSelfControl)
        XCTAssertEqual(entry.admissionClass, .control)
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: name))
        let schema = try XCTUnwrap(definition.inputSchema.objectValue)
        XCTAssertEqual(schema["additionalProperties"], .bool(false))
        XCTAssertEqual(schema["required"], .array([.string("op")]))
        let properties = try XCTUnwrap(schema["properties"]?.objectValue)
        XCTAssertEqual(properties["op"]?.objectValue?["enum"], .array([.string("context"), .string("compact")]))
        XCTAssertEqual(Set(properties.keys), ["op", "note", "idempotency_key"])
        for operation in ["context", "compact"] {
            XCTAssertEqual(MCPDomainToolCatalog.operationIdentity(for: name, input: .value(operation)).normalizedOperation, operation)
        }
        XCTAssertEqual(MCPDomainToolCatalog.operationIdentity(for: name, input: .value("poll")).normalizedOperation, MCPDomainToolOperationIdentity.unknownOperation)
    }

    func testCanonicalSelfDefinitionFitsOneThousandCharactersWithEssentialContract() throws {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "self_compact"))
        let serialized = String(decoding: try JSONEncoder().encode(definition), as: UTF8.self)
        XCTAssertLessThanOrEqual(serialized.count, 1_000, "Complete minified definition, not description alone")
        let description = definition.description
        for required in [
            "Agent Mode session", "no target selector", "`context`", "load", "status",
            "`compact`", "nonempty `note`", "8,192 UTF-8 bytes", "`idempotency_key`",
            "200 UTF-8 bytes", "same note", "New `scheduled`", "finish this turn normally",
            "no new authority"
        ] {
            XCTAssertTrue(description.contains(required), required)
        }
    }

    func testConcurrentLegacyLifecycleProjectionIsIsolatedAndDoesNotRewriteCallerText() async throws {
        let failure = MCPDomainHostError.staleRegistration(toolName: "self_compact")
        async let legacy = MCPDomainSelfToolCallContext.withRequestedName("agent_self") {
            await Task.yield()
            return String(describing: MCPDomainSelfToolCallContext.errorForPresentation(failure))
        }
        async let canonical = MCPDomainSelfToolCallContext.withRequestedName("self_compact") {
            await Task.yield()
            return String(describing: MCPDomainSelfToolCallContext.errorForPresentation(failure))
        }
        let (legacyText, canonicalText) = await (legacy, canonical)
        XCTAssertEqual(legacyText, String(describing: MCPDomainHostError.staleRegistration(toolName: "agent_self")))
        XCTAssertEqual(canonicalText, String(describing: failure))
        await MCPDomainSelfToolCallContext.withRequestedName("agent_self") {
            let callerError = MCPError.invalidParams("Keep the caller's literal self_compact text.")
            XCTAssertEqual(MCPDomainSelfToolCallContext.errorForPresentation(callerError) as? MCPError, callerError)
            let unrelated = MCPDomainHostError.staleRegistration(toolName: "read_file")
            XCTAssertEqual(MCPDomainSelfToolCallContext.errorForPresentation(unrelated) as? MCPDomainHostError, unrelated)
            let contract = MCPToolExecutionDispatchError.missingContract(toolName: "self_compact")
            XCTAssertEqual(
                MCPDomainSelfToolCallContext.errorForPresentation(contract) as? MCPToolExecutionDispatchError,
                .missingContract(toolName: "agent_self")
            )
        }
        XCTAssertFalse(MCPDomainSelfToolCallContext.isLegacyAlias)
        XCTAssertEqual(failure, .staleRegistration(toolName: "self_compact"), "The host's authoritative error is not changed")
    }

    func testSelfToolGrantedToAllAgentProfilesIncludingExploreButNotDirectOrDiscovery() {
        let name = "self_compact"
        for profile in MCPClientToolPolicyProfile.allCases {
            let visible = MCPClientToolPolicyCatalog.resolvedToolNames(for: profile)
            XCTAssertEqual(visible.contains(name), profile != .direct && profile != .discovery, profile.rawValue)
        }
        XCTAssertFalse(MCPClientToolPolicyCatalog.hiddenToolNames(for: .explore).contains(name))
        XCTAssertFalse(MCPDomainHost.executionRoleGatedCapabilities.contains(.agentSelfControl))
    }

    func testRevokedCapabilityDeniedAtCallTimeEvenWithExactLinkGrant() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = MCPDomainRuntime(configuration: .init(
            mode: .standalone, profileIdentifier: "agent-self-policy-test",
            storageDirectory: directory, eventDirectory: directory, temporaryDirectory: directory,
            externalReloadInterval: nil
        ))
        try await runtime.start()
        let revoked = MCPDomainClientPolicySnapshot(
            restrictedToolNames: [], additionalToolNames: [], role: .engineer,
            allowsAgentExternalControlTools: true, hasExactAgentSessionLinkGrant: true
        )
        for name in ["self_compact", "agent_self"] {
            let canonical = MCPDomainToolCatalog.canonicalCallName(for: name)
            do {
                try await runtime.domainHost.evaluateEarlyCallPolicy(toolName: canonical, policy: revoked)
                XCTFail("revoked self_compact grant must deny both names")
            } catch let denial as MCPDomainCallPolicyDenial {
                XCTAssertEqual(denial, .missingAdditionalGrant(toolName: "self_compact"))
            }
        }
    }
}
