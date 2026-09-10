import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    final class PromptExperimentToolCatalogPolicyTests: XCTestCase {
        func testDebugCatalogAdvertisesOnlyBoundedAgentDraftOperations() throws {
            let name = MCPWindowToolName.promptExperiment
            let entry = try XCTUnwrap(MCPDomainToolCatalog.entry(named: name))
            XCTAssertEqual(entry.scope, .window)
            XCTAssertEqual(entry.capability, .agentReasoningControl)
            XCTAssertEqual(entry.admissionClass, .control)
            XCTAssertNotNil(MCPDomainCanonicalToolDefinitions.definition(named: name))

            for operation in [
                "capabilities", "list", "create_draft", "update_draft",
                "propose_seal", "read", "propose_next_revision"
            ] {
                XCTAssertEqual(
                    MCPDomainToolCatalog.operationIdentity(for: name, input: .value(operation)).normalizedOperation,
                    operation
                )
            }
            for forbidden in ["approve", "run", "cancel", "score", "promote"] {
                XCTAssertEqual(
                    MCPDomainToolCatalog.operationIdentity(for: name, input: .value(forbidden)).normalizedOperation,
                    MCPDomainToolOperationIdentity.unknownOperation,
                    forbidden
                )
            }
        }
    }
#endif
