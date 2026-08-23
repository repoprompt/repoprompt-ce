import CryptoKit
@testable import RepoPromptApp
@testable import RepoPromptShared
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

    func testCanonicalWorkflowIdentityAndMetadataSnapshot() {
        XCTAssertEqual(
            RepoPromptWorkflowID.allCases.map { "\($0.rawValue)|\($0.commandName)" },
            [
                "build|rp-build",
                "investigate|rp-investigate",
                "deepPlan|rp-deep-plan",
                "reminder|rp-reminder",
                "oracleExport|rp-oracle-export",
                "review|rp-review",
                "refactor|rp-refactor",
                "orchestrate|rp-orchestrate",
                "optimize|rp-optimize"
            ]
        )
        XCTAssertEqual(
            RepoPromptBuiltInAgentWorkflow.allCases.map { workflow in
                let metadata = workflow.metadata
                return [
                    workflow.rawValue,
                    workflow.canonicalID,
                    metadata.id,
                    metadata.displayName,
                    metadata.iconName,
                    metadata.tooltipText,
                    metadata.descriptionText
                ].joined(separator: "|")
            },
            [
                "build|builtin-build|builtin-build|Plan & Build|hammer.fill|Deep-research, plan, and implement complex tasks|Researches the code, makes a plan, and implements the change step by step.",
                "review|builtin-review|builtin-review|Review|eye.fill|Thorough code review across branches and diffs|Deeply reviews the code for subtle bugs, regressions, risks, and missed edge cases.",
                "refactor|builtin-refactor|builtin-refactor|Refactor|arrow.triangle.2.circlepath|Analyze and improve code organization|Cleans up code structure while keeping behavior the same.",
                "investigate|builtin-investigate|builtin-investigate|Investigate|magnifyingglass|Hypothesis-driven research with evidence gathering|Digs into bugs, crashes, security concerns, or research questions and reports the evidence.",
                "oracleExport|builtin-oracleExport|builtin-oracleExport|ChatGPT Export|square.and.arrow.up|Export codebase context for ChatGPT analysis|Packages the right code and context into a prompt you can send to ChatGPT.",
                "orchestrate|builtin-orchestrate|builtin-orchestrate|Orchestrate|arrow.triangle.branch|Plan, decompose, and delegate tasks across multiple agents|Breaks a complex request into smaller tasks, sends agents to do the work, and checks each result.",
                "optimize|builtin-optimize|builtin-optimize|Optimize|speedometer|Instrument, baseline, and iteratively optimize a target metric|Finds what to measure, adds metrics, tries improvements, and uses evidence to keep iterating.",
                "deepPlan|builtin-deepPlan|builtin-deepPlan|Deep Plan|text.book.closed.fill|Deeply research and shape a polished plan document|Researches the code, asks how hands-on you want to be, and writes a clear implementation plan."
            ]
        )
    }

    func testRenderedWorkflowPromptHashesStayStable() {
        let variants: [(name: String, value: WorkflowPromptVariant)] = [
            ("mcp", .mcp),
            ("cli", .cli),
            ("agent", .agent)
        ]
        let actual = variants.flatMap { variant in
            RepoPromptWorkflowID.allCases.map { id in
                let prompt = RepoPromptWorkflowPrompts.render(id: id, variant: variant.value)
                let hash = SHA256.hash(data: Data(prompt.utf8))
                    .map { String(format: "%02x", $0) }
                    .joined()
                return "\(variant.name)|\(id.rawValue)|\(hash)"
            }
        }

        XCTAssertEqual(
            actual,
            [
                "mcp|build|4ee7d6c30ed78693d06d6bb30daa6f637246fbb6f07751705ec8fefe4e506ea4",
                "mcp|investigate|98d70868c950d4f5843fe4a5fb3c7c7c6a61b1c18bedb0dd1e1147af45f531f7",
                "mcp|deepPlan|f6f72bb8873ebb032e98eb424690be05a1d00a1b58fd1152459c74c05f4897d1",
                "mcp|reminder|a14a016e035ed958cadfa65a9bb6f8c1d5967c542e5c5b30b253064163c64d26",
                "mcp|oracleExport|93481eee50e79ef13cf1abc0a004741555ac33e1a5573bbac2054d7f8754180f",
                "mcp|review|23c727c32604a1020a4d505134cb72a56fa5ad1ed1f49ef94a0bfde8da32bb78",
                "mcp|refactor|f86326cf57a8906e944f94a086786fedbe8b0a17f252be0094ac3ca75f63e900",
                "mcp|orchestrate|5d596e445dd6ce25c96d816ea1f277b815f1100686ae7d1d26ab9bd31ca721c1",
                "mcp|optimize|362c8ac7014271ccabca7dff1fb669df9e03aa0d64c981fd028e02414b069655",
                "cli|build|f0ac0a053268851aff51052972cd6404f77fb0c186cb47cee2a758fbcf391c80",
                "cli|investigate|d4e9b590132b2ccf00d5a4d795d83313d16a33c66395719af463fb8035e18252",
                "cli|deepPlan|0ecd7922dbaef2e7aa9aa4de036c82b5c5e18fde70bff1f5a0bdf9afd9953d37",
                "cli|reminder|6e615c32cbdfcd61026f3fdca48ac554f9c73c3b017cc04724f669014ae536a4",
                "cli|oracleExport|f4a8e8d75f90c7bf4873d6323af4a545f8422f2dd204b499ec218d33f8f608ed",
                "cli|review|1c7ecffeb88adeeb598cc5da35138745280830b7040708908b85900f79bf5240",
                "cli|refactor|293fe063a4d48fccacc9df59c6a626f0dafe48dfe90f2fbc400f5addc66c9bab",
                "cli|orchestrate|ae7c6e3bc9da37295dabb9cb5db1144072e7c31d2d4e93a4e003f680b9cd45b9",
                "cli|optimize|31fb5586e559c2f13f585c1bb9060baf2044f1abc20d748e3aac525baa220463",
                "agent|build|d2e6ca699d75f5a39050cb48be741c75512d00f4ffa7461d8bb0fb3c568f6307",
                "agent|investigate|f03aa1a084b00ce71073d8bd1b859e790a625a7f5865949bc65ba11195885d13",
                "agent|deepPlan|70c4017281caa13c0a5aac4914da80d6fc91bd8e859982faf6c3ded1e07888ed",
                "agent|reminder|da0b1656bb1b27addf0aaddfb06322fcb91a302261bfeec14b81868676d5977d",
                "agent|oracleExport|a750d5ac89793b7a6fad9c2c6d44673d43ea43a37f97aa3aa64cdc9aedabc4bb",
                "agent|review|121322a42f19768b79d30e1a88103b9220cf5f93e7f52585187869d3f2cf0e3e",
                "agent|refactor|c931e3e71f80c2af12ed98ea70968c6571b69b787860d133015f1a0639a09db8",
                "agent|orchestrate|03660b79b7a807da6541e10f45ed6d85168f800e27836c16faa01c337b04991a",
                "agent|optimize|9977840e1013fc91e829b6e75f5690204c56a253d63fedb808c72e08cebba022"
            ]
        )
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
            let shared = RepoPromptBuiltInAgentWorkflow(rawValue: workflow.rawValue)
            let rendered = shared?.template ?? ""
            XCTAssertFalse(rendered.isEmpty, workflow.rawValue)
            XCTAssertEqual(workflow.template, rendered, workflow.rawValue)
        }
    }

    func testBuiltInAgentWorkflowMetadataAndOrderAreProviderNeutral() {
        XCTAssertEqual(
            RepoPromptBuiltInAgentWorkflow.displayOrder.map(\.rawValue),
            ["orchestrate", "deepPlan", "optimize", "build", "review", "refactor", "investigate", "oracleExport"]
        )
        XCTAssertEqual(RepoPromptBuiltInAgentWorkflow.allCases.count, 8)

        for workflow in AgentWorkflow.allCases {
            let shared = RepoPromptBuiltInAgentWorkflow(rawValue: workflow.rawValue)
            XCTAssertEqual(workflow.displayName, shared?.metadata.displayName)
            XCTAssertEqual(workflow.iconName, shared?.metadata.iconName)
            XCTAssertEqual(workflow.tooltipText, shared?.metadata.tooltipText)
            XCTAssertEqual(workflow.descriptionText, shared?.metadata.descriptionText)
        }
    }
}
