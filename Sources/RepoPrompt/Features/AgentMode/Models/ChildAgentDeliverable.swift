import Foundation
import MCP

struct ChildAgentDeliverable: Equatable {
    enum Source: String {
        case structured
        case assistantMarkdown = "assistant_markdown"
        case assistantFallback = "assistant_fallback"
        case mixed
    }

    let schemaVersion: Int
    let source: Source
    let summary: String?
    let findings: [String]
    let changedFiles: [String]
    let evidence: [String]
    let blockers: [String]
    let confidence: String?
    let recommendedNextAction: String?
    let reportPath: String?
    let exportPath: String?

    init(
        source: Source,
        summary: String? = nil,
        findings: [String] = [],
        changedFiles: [String] = [],
        evidence: [String] = [],
        blockers: [String] = [],
        confidence: String? = nil,
        recommendedNextAction: String? = nil,
        reportPath: String? = nil,
        exportPath: String? = nil
    ) {
        schemaVersion = 1
        self.source = source
        self.summary = Self.cleaned(summary, limit: 500)
        self.findings = Self.cleanedList(findings)
        self.changedFiles = Self.cleanedList(changedFiles, itemLimit: 512)
        self.evidence = Self.cleanedList(evidence)
        self.blockers = Self.cleanedList(blockers)
        self.confidence = Self.cleaned(confidence, limit: 240)
        self.recommendedNextAction = Self.cleaned(recommendedNextAction, limit: 240)
        self.reportPath = Self.cleaned(reportPath, limit: 512)
        self.exportPath = Self.cleaned(exportPath, limit: 512)
    }

    var isEmpty: Bool {
        summary == nil && findings.isEmpty && changedFiles.isEmpty && evidence.isEmpty && blockers.isEmpty && confidence == nil && recommendedNextAction == nil && reportPath == nil && exportPath == nil
    }

    static func fromAssistantText(_ text: String?) -> ChildAgentDeliverable? {
        guard let text = cleaned(text, limit: 12000) else { return nil }
        let parsed = parseMarkdown(text)
        return parsed?.isEmpty == false ? parsed : nil
    }

    static func fromJSONObject(
        _ object: [String: Any]?,
        assistantText: String? = nil,
        allowAssistantTextFallback: Bool = false
    ) -> ChildAgentDeliverable? {
        guard let object else {
            return allowAssistantTextFallback ? fromAssistantText(assistantText) : nil
        }
        let structured = (object["deliverable"] as? [String: Any]) ?? (object["child_deliverable"] as? [String: Any])
        var deliverable = structured.flatMap { fromStructuredObject($0, topLevelObject: object) }
        if deliverable == nil,
           allowAssistantTextFallback,
           let assistant = fromAssistantText(assistantText ?? stringValue(object, keys: ["assistant_text", "assistantText"]))
        {
            deliverable = assistant
        }
        return deliverable?.isEmpty == false ? deliverable : nil
    }

    static func fromValueObject(
        _ object: [String: Value]?,
        assistantText: String? = nil,
        allowAssistantTextFallback: Bool = false
    ) -> ChildAgentDeliverable? {
        fromJSONObject(
            object?.mapValues(anyValue),
            assistantText: assistantText,
            allowAssistantTextFallback: allowAssistantTextFallback
        )
    }

    func asValueObject() -> [String: Value] {
        var object: [String: Value] = [
            "schema_version": .int(schemaVersion),
            "source": .string(source.rawValue)
        ]
        if let summary { object["summary"] = .string(summary) }
        if !findings.isEmpty { object["findings"] = .array(findings.map(Value.string)) }
        if !changedFiles.isEmpty { object["changed_files"] = .array(changedFiles.map(Value.string)) }
        if !evidence.isEmpty { object["evidence"] = .array(evidence.map(Value.string)) }
        if !blockers.isEmpty { object["blockers"] = .array(blockers.map(Value.string)) }
        if let confidence { object["confidence"] = .string(confidence) }
        if let recommendedNextAction { object["recommended_next_action"] = .string(recommendedNextAction) }
        if let reportPath { object["report_path"] = .string(reportPath) }
        if let exportPath { object["export_path"] = .string(exportPath) }
        return object
    }

    func asJSONObject(minimal: Bool = false) -> [String: Any] {
        var object: [String: Any] = [
            "schema_version": schemaVersion,
            "source": source.rawValue
        ]
        if let summary { object["summary"] = summary }
        if !minimal {
            if !findings.isEmpty { object["findings"] = findings }
            if !changedFiles.isEmpty { object["changed_files"] = changedFiles }
            if !evidence.isEmpty { object["evidence"] = evidence }
            if !blockers.isEmpty { object["blockers"] = blockers }
        }
        if let confidence { object["confidence"] = confidence }
        if let recommendedNextAction { object["recommended_next_action"] = recommendedNextAction }
        if let reportPath { object["report_path"] = reportPath }
        if let exportPath { object["export_path"] = exportPath }
        return object
    }

    private static func anyValue(_ value: Value) -> Any {
        if let string = value.stringValue { return string }
        if let int = value.intValue { return int }
        if let double = value.doubleValue { return double }
        if let bool = value.boolValue { return bool }
        if let array = value.arrayValue { return array.map(anyValue) }
        if let object = value.objectValue { return object.mapValues(anyValue) }
        return NSNull()
    }

    private static func fromStructuredObject(_ object: [String: Any], topLevelObject: [String: Any]) -> ChildAgentDeliverable? {
        let deliverable = ChildAgentDeliverable(
            source: .structured,
            summary: stringValue(object, keys: ["summary"]),
            findings: stringListValue(object, keys: ["findings"]),
            changedFiles: stringListValue(object, keys: ["changed_files", "changedFiles"]),
            evidence: stringListValue(object, keys: ["evidence"]),
            blockers: stringListValue(object, keys: ["blockers"]),
            confidence: stringValue(object, keys: ["confidence"]),
            recommendedNextAction: stringValue(object, keys: ["recommended_next_action", "recommendedNextAction"]),
            reportPath: stringValue(object, keys: ["report_path", "reportPath"]),
            exportPath: stringValue(object, keys: ["export_path", "exportPath"]) ?? stringValue(topLevelObject, keys: ["output_path", "outputPath"])
        )
        return deliverable.isEmpty ? nil : deliverable
    }

    private static func parseMarkdown(_ text: String) -> ChildAgentDeliverable? {
        let lines = text.components(separatedBy: .newlines)
        var sections: [String: [String]] = [:]
        var current: String?
        var preface: [String] = []
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let heading = normalizedHeading(line) {
                current = heading
                continue
            }
            if let current {
                sections[current, default: []].append(line)
            } else if !line.isEmpty {
                preface.append(line)
            }
        }
        if sections.isEmpty {
            let paragraph = text.components(separatedBy: "\n\n").first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return ChildAgentDeliverable(source: .assistantFallback, summary: paragraph)
        }
        let summary = scalarSection(sections["summary"])
        let deliverable = ChildAgentDeliverable(
            source: .assistantMarkdown,
            summary: summary ?? preface.first,
            findings: listSection(sections["findings"]),
            changedFiles: listSection(sections["changed_files"]),
            evidence: listSection(sections["evidence"]),
            blockers: listSection(sections["blockers"]),
            confidence: scalarSection(sections["confidence"]),
            recommendedNextAction: scalarSection(sections["recommended_next_action"]),
            reportPath: scalarSection(sections["report_path"]),
            exportPath: scalarSection(sections["export_path"])
        )
        return deliverable.isEmpty ? nil : deliverable
    }

    private static func normalizedHeading(_ line: String) -> String? {
        var text = line
        while text.hasPrefix("#") {
            text.removeFirst()
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix(":") { text.removeLast() }
        switch text.lowercased() {
        case "summary": return "summary"
        case "findings", "key findings": return "findings"
        case "changed files", "changed file", "files changed": return "changed_files"
        case "evidence": return "evidence"
        case "blockers", "blocker": return "blockers"
        case "confidence": return "confidence"
        case "recommended next action", "next action": return "recommended_next_action"
        case "report path", "report": return "report_path"
        case "export path", "export": return "export_path"
        default: return nil
        }
    }

    private static func listSection(_ lines: [String]?) -> [String] {
        guard let lines else { return [] }
        return lines.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil else { return nil }
            let value = trimmed.replacingOccurrences(of: #"^([-*]|\d+\.)\s+"#, with: "", options: .regularExpression)
            return cleaned(value, limit: 240)
        }
    }

    private static func scalarSection(_ lines: [String]?) -> String? {
        guard let lines else { return nil }
        return cleaned(lines.filter { !$0.isEmpty }.joined(separator: " "), limit: 500)
    }

    private static func stringValue(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = scalarStringValue(object[key]) {
                return value
            }
        }
        return nil
    }

    private static func stringListValue(_ object: [String: Any], keys: [String]) -> [String] {
        for key in keys {
            guard let rawValue = object[key], !(rawValue is NSNull) else { continue }
            if let values = rawValue as? [Any] {
                return values.compactMap(scalarStringValue)
            }
            if let value = scalarStringValue(rawValue) {
                return [value]
            }
        }
        return []
    }

    private static func scalarStringValue(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return nil
    }

    private static func cleanedList(_ values: [String], itemLimit: Int = 240) -> [String] {
        Array(values.compactMap { cleaned($0, limit: itemLimit) }.prefix(8))
    }

    private static func cleaned(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let scalars = text.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\t"
        }
        let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(max(0, limit - 1))) + "…"
    }
}
