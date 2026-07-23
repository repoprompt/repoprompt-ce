import Foundation

struct WorkflowPromptArgument: Equatable {
    let name: String
    let description: String
    let required: Bool
}

struct WorkflowPromptDescriptor: Equatable {
    let id: RepoPromptWorkflowID
    let description: String
    let arguments: [WorkflowPromptArgument]

    var name: String {
        id.commandName
    }
}

enum WorkflowPromptCatalog {
    static let descriptorsByID: [RepoPromptWorkflowID: WorkflowPromptDescriptor] = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })

    static let descriptors: [WorkflowPromptDescriptor] = [
        WorkflowPromptDescriptor(
            id: .build,
            description: "Build with RepoPrompt MCP context_builder plan → implement. A structured workflow for implementing features using deep codebase context.",
            arguments: [
                WorkflowPromptArgument(
                    name: "task",
                    description: "Description of the task or feature to implement",
                    required: true
                )
            ]
        ),
        WorkflowPromptDescriptor(
            id: .investigate,
            description: "Deep investigation with RepoPrompt MCP tools. The agent gathers concrete evidence with tools, while chat/oracle synthesizes the selected context into hypotheses and architectural insight.",
            arguments: [
                WorkflowPromptArgument(
                    name: "issue",
                    description: "Description of the topic or issue to investigate",
                    required: true
                )
            ]
        ),
        WorkflowPromptDescriptor(
            id: .deepPlan,
            description: "Deep planning workflow that ends at a polished `docs/plans/<topic>-<YYYY-MM-DD>.md` document (no implementation). First action asks the user how involved they want to be (up front / mid-flow / hands-off). Explore agents map seams and optional external research; context_builder produces a complete implementation-ready specification as the preservation baseline; the orchestrator preserves supported implementation-bearing detail while allowing evidence-backed correction and lossless consolidation; a design agent performs a bounded completeness and correctness critique; and a final fidelity check confirms coverage before cleanup.",
            arguments: [
                WorkflowPromptArgument(
                    name: "topic",
                    description: "Description of what to plan (feature, refactor, migration, redesign, etc.)",
                    required: true
                )
            ]
        ),
        WorkflowPromptDescriptor(
            id: .reminder,
            description: "Token-efficient reminder to use RepoPrompt MCP tools (file_search, read_file, apply_edits, file_actions) instead of built-in alternatives.",
            arguments: []
        ),
        WorkflowPromptDescriptor(
            id: .oracleExport,
            description: "Export a ChatGPT-ready prompt file. Determines whether the task is a Question, Plan, or Review (confirming only when needed), uses a fast path for simple tasks, reviews the selection/prompt, and writes a unique export file.",
            arguments: [
                WorkflowPromptArgument(
                    name: "problem",
                    description: "Description of the problem or question to include in the exported ChatGPT prompt",
                    required: true
                )
            ]
        ),
        WorkflowPromptDescriptor(
            id: .review,
            description: "Code review workflow using the git tool and context_builder. Assesses change scope, gathers context, and provides structured review feedback for PRs, commits, or uncommitted changes.",
            arguments: [
                WorkflowPromptArgument(
                    name: "scope",
                    description: "What to review: 'uncommitted', 'staged', 'back:N' for last N commits, or a branch/commit range like 'main...HEAD'",
                    required: false
                )
            ]
        ),
        WorkflowPromptDescriptor(
            id: .refactor,
            description: "Refactoring assistant that analyzes code structure to identify duplication, complexity, and consolidation opportunities. Proposes safe, incremental improvements without changing core logic.",
            arguments: [
                WorkflowPromptArgument(
                    name: "target",
                    description: "Files, directory, or system to analyze for refactoring (e.g., 'src/auth/', 'the payment module', or specific file paths)",
                    required: false
                )
            ]
        ),
        WorkflowPromptDescriptor(
            id: .orchestrate,
            description: "Plan, decompose, and delegate complex tasks across multiple agents. Coordinates planning, work breakdown, dispatch, monitoring, and final rollup.",
            arguments: [
                WorkflowPromptArgument(
                    name: "task",
                    description: "Description of the complex task to plan, decompose, and delegate across agents",
                    required: true
                )
            ]
        ),
        WorkflowPromptDescriptor(
            id: .optimize,
            description: "Iterative performance optimization loop run as a delegation-first orchestration. Phase 1 fans out parallel explore agents to scout bottleneck candidates around the named target (callers, inputs, adjacent operations, shared infrastructure) plus surface mapping (target & call graph, prior perf work, conventions, scope). Phase 2 routes setup design (metric, instrumentation, first-pass candidates grounded in the bottleneck scouting) through context_builder in plan mode. Phase 3 dispatches a pair to land instrumentation and capture a multi-sample baseline. Phase 4 loops plan → dispatch pair for one optimize+harden cycle → re-measure → ask oracle for next plan until the oracle signals satisfaction, the target metric is met, or the iteration cap is reached.",
            arguments: [
                WorkflowPromptArgument(
                    name: "target",
                    description: "Description of what to optimize (metric, scope, stop criterion if known) — e.g. 'reduce p95 latency of PathMatcher.match under PathMatchingTests'",
                    required: true
                )
            ]
        )
    ]

    static let mcpPromptDescriptors: [WorkflowPromptDescriptor] = RepoPromptWorkflowID.mcpPromptOrder.map { descriptor(for: $0) }
    static let installDescriptors: [WorkflowPromptDescriptor] = RepoPromptWorkflowID.installOrder.map { descriptor(for: $0) }

    static func descriptor(for id: RepoPromptWorkflowID) -> WorkflowPromptDescriptor {
        guard let descriptor = descriptorsByID[id] else {
            preconditionFailure("Missing workflow prompt descriptor for \(id)")
        }
        return descriptor
    }
}
