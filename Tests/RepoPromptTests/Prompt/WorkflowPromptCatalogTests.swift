@testable import RepoPromptApp
import XCTest

final class WorkflowPromptCatalogTests: XCTestCase {
    func testWorkflowCommandOrdersAndNamesStayStable() {
        XCTAssertEqual(
            RepoPromptWorkflowID.mcpPromptOrder.map(\.commandName),
            [
                "rp-build",
                "rp-investigate",
                "rp-deep-plan",
                "rp-reminder",
                "rp-oracle-export",
                "rp-review",
                "rp-refactor",
                "rp-orchestrate",
                "rp-optimize"
            ]
        )
        XCTAssertEqual(
            RepoPromptWorkflowID.installOrder.map(\.commandName),
            [
                "rp-investigate",
                "rp-build",
                "rp-reminder",
                "rp-oracle-export",
                "rp-review",
                "rp-refactor",
                "rp-orchestrate",
                "rp-optimize",
                "rp-deep-plan"
            ]
        )
        XCTAssertEqual(RepoPromptWorkflowID.allCases.count, 9)
    }

    func testCatalogMetadataMatchesWorkflowIDs() {
        XCTAssertEqual(WorkflowPromptCatalog.descriptors.count, RepoPromptWorkflowID.allCases.count)
        XCTAssertEqual(WorkflowPromptCatalog.mcpPromptDescriptors.map(\.id), RepoPromptWorkflowID.mcpPromptOrder)
        XCTAssertEqual(WorkflowPromptCatalog.installDescriptors.map(\.id), RepoPromptWorkflowID.installOrder)

        for descriptor in WorkflowPromptCatalog.descriptors {
            XCTAssertEqual(descriptor.name, descriptor.id.commandName)
            XCTAssertFalse(descriptor.description.isEmpty, descriptor.name)
        }
    }

    func testDeepPlanCatalogMetadataTracksPreservationWorkflow() throws {
        let description = try XCTUnwrap(
            WorkflowPromptCatalog.descriptors.first(where: { $0.id == .deepPlan })?.description
        )

        XCTAssertTrue(description.contains("complete implementation-ready specification"))
        XCTAssertTrue(description.contains("preservation baseline"))
        XCTAssertTrue(description.contains("evidence-backed correction and lossless consolidation"))
        XCTAssertTrue(description.contains("completeness and correctness critique"))
        XCTAssertTrue(description.contains("final fidelity check"))
        XCTAssertFalse(description.contains("architectural bones"))
        XCTAssertFalse(description.contains("one-page critique"))
        XCTAssertFalse(description.contains("tighter, executable document"))
    }

    func testRenderedManagedPromptFrontmatterCompatibility() {
        XCTAssertEqual(RepoPromptWorkflowPrompts.skillsVersion, 62)

        for descriptor in WorkflowPromptCatalog.installDescriptors {
            let rendered = RepoPromptWorkflowPrompts.render(id: descriptor.id, variant: .mcp)
            XCTAssertTrue(rendered.hasPrefix("---\n"), descriptor.name)
            XCTAssertTrue(rendered.contains("name: \"\(descriptor.name)\""), descriptor.name)
            XCTAssertTrue(rendered.contains("repoprompt_managed: true"), descriptor.name)
            XCTAssertTrue(rendered.contains("repoprompt_skills_version: 62"), descriptor.name)
            XCTAssertTrue(rendered.contains("repoprompt_variant: mcp"), descriptor.name)
            XCTAssertFalse(RepoPromptWorkflowPrompts.stripYAMLFrontmatter(rendered).hasPrefix("---"), descriptor.name)
        }
    }

    func testAgentWorkflowTemplatesRenderFromProviderNeutralCatalog() {
        for workflow in AgentWorkflow.allCases {
            let rendered = RepoPromptWorkflowPrompts.render(id: workflow.workflowPromptID, variant: .agent)
            XCTAssertFalse(rendered.isEmpty, workflow.rawValue)
            XCTAssertEqual(workflow.template, rendered, workflow.rawValue)
        }
    }
}
