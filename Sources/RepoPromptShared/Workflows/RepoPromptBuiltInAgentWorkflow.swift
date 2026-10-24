import Foundation

public enum RepoPromptBuiltInAgentWorkflow: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case build
    case review
    case refactor
    case investigate
    case oracleExport
    case orchestrate
    case optimize
    case deepPlan

    public struct Metadata: Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let iconName: String
        public let tooltipText: String
        public let descriptionText: String
    }

    public enum ResolutionError: Error, Equatable, Sendable {
        case conflictingReferences
        case unknownReference(String)
    }

    public static let displayOrder: [Self] = [
        .orchestrate,
        .deepPlan,
        .optimize,
        .build,
        .review,
        .refactor,
        .investigate,
        .oracleExport
    ]

    public var id: String {
        rawValue
    }

    public var canonicalID: String {
        "builtin-\(rawValue)"
    }

    public var metadata: Metadata {
        switch self {
        case .build:
            Metadata(
                id: canonicalID,
                displayName: "Plan & Build",
                iconName: "hammer.fill",
                tooltipText: "Deep-research, plan, and implement complex tasks",
                descriptionText: "Researches the code, makes a plan, and implements the change step by step."
            )
        case .review:
            Metadata(
                id: canonicalID,
                displayName: "Review",
                iconName: "eye.fill",
                tooltipText: "Thorough code review across branches and diffs",
                descriptionText: "Deeply reviews the code for subtle bugs, regressions, risks, and missed edge cases."
            )
        case .refactor:
            Metadata(
                id: canonicalID,
                displayName: "Refactor",
                iconName: "arrow.triangle.2.circlepath",
                tooltipText: "Analyze and improve code organization",
                descriptionText: "Cleans up code structure while keeping behavior the same."
            )
        case .investigate:
            Metadata(
                id: canonicalID,
                displayName: "Investigate",
                iconName: "magnifyingglass",
                tooltipText: "Hypothesis-driven research with evidence gathering",
                descriptionText: "Digs into bugs, crashes, security concerns, or research questions and reports the evidence."
            )
        case .oracleExport:
            Metadata(
                id: canonicalID,
                displayName: "ChatGPT Export",
                iconName: "square.and.arrow.up",
                tooltipText: "Export codebase context for ChatGPT analysis",
                descriptionText: "Packages the right code and context into a prompt you can send to ChatGPT."
            )
        case .orchestrate:
            Metadata(
                id: canonicalID,
                displayName: "Orchestrate",
                iconName: "arrow.triangle.branch",
                tooltipText: "Plan, decompose, and delegate tasks across multiple agents",
                descriptionText: "Breaks a complex request into smaller tasks, sends agents to do the work, and checks each result."
            )
        case .optimize:
            Metadata(
                id: canonicalID,
                displayName: "Optimize",
                iconName: "speedometer",
                tooltipText: "Instrument, baseline, and iteratively optimize a target metric",
                descriptionText: "Finds what to measure, adds metrics, tries improvements, and uses evidence to keep iterating."
            )
        case .deepPlan:
            Metadata(
                id: canonicalID,
                displayName: "Deep Plan",
                iconName: "text.book.closed.fill",
                tooltipText: "Deeply research and shape a polished plan document",
                descriptionText: "Researches the code, asks how hands-on you want to be, and writes a clear implementation plan."
            )
        }
    }

    public var template: String {
        RepoPromptWorkflowPrompts.render(id: promptID, variant: .agent)
    }

    public func template(includeSessionCleanupGuidance: Bool) -> String {
        RepoPromptWorkflowPrompts.render(
            id: promptID,
            variant: .agent,
            includeSessionCleanupGuidance: includeSessionCleanupGuidance
        )
    }

    public func wrapUserText(_ text: String, includeSessionCleanupGuidance: Bool = true) -> String {
        let rendered = template(includeSessionCleanupGuidance: includeSessionCleanupGuidance)
        return Self.stripYAMLFrontmatter(rendered)
            .replacingOccurrences(of: "$ARGUMENTS", with: text)
    }

    public static func resolve(
        workflowID: String?,
        workflowName: String?
    ) throws -> Self? {
        let normalizedID = normalized(workflowID)
        let normalizedName = normalized(workflowName)
        if normalizedID != nil, normalizedName != nil {
            throw ResolutionError.conflictingReferences
        }
        guard let reference = normalizedID ?? normalizedName else { return nil }
        let match = allCases.first { workflow in
            reference.caseInsensitiveCompare(workflow.rawValue) == .orderedSame
                || reference.caseInsensitiveCompare(workflow.canonicalID) == .orderedSame
                || reference.caseInsensitiveCompare(workflow.metadata.displayName) == .orderedSame
        }
        guard let match else { throw ResolutionError.unknownReference(reference) }
        return match
    }

    private var promptID: RepoPromptWorkflowID {
        switch self {
        case .build: .build
        case .review: .review
        case .refactor: .refactor
        case .investigate: .investigate
        case .oracleExport: .oracleExport
        case .orchestrate: .orchestrate
        case .optimize: .optimize
        case .deepPlan: .deepPlan
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func stripYAMLFrontmatter(_ text: String) -> String {
        var body = text
        if body.hasPrefix("---") {
            let searchRange = body.index(body.startIndex, offsetBy: 3) ..< body.endIndex
            if let closingRange = body.range(of: "\n---", range: searchRange) {
                body = String(body[closingRange.upperBound...])
                    .trimmingCharacters(in: .newlines)
            }
        }
        return body
    }
}
