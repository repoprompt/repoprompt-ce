import Foundation

enum AgentToolCardRenderStatus: String, Codable, Equatable {
    case neutral
    case success
    case warning
    case failure
    case running
}

struct AgentToolCardRenderSummary: Codable, Equatable {
    let schemaVersion: Int
    let toolName: String
    let title: String
    let subtitle: String?
    let detailText: String?
    let status: AgentToolCardRenderStatus
    let op: String?

    init(
        schemaVersion: Int = 1,
        toolName: String,
        title: String,
        subtitle: String?,
        detailText: String?,
        status: AgentToolCardRenderStatus,
        op: String?
    ) {
        self.schemaVersion = schemaVersion
        self.toolName = toolName
        self.title = title
        self.subtitle = Self.smallSummaryString(subtitle)
        self.detailText = Self.smallSummaryString(detailText)
        self.status = status
        self.op = Self.smallSummaryString(op)
    }

    var inlineSummaryText: String? {
        let parts = [subtitle, detailText]
            .compactMap { Self.trimmed($0) }
        guard !parts.isEmpty else { return nil }
        return Self.smallSummaryString(parts.joined(separator: " • "))
    }

    var dictionary: [String: Any] {
        var object: [String: Any] = [
            "schema_version": schemaVersion,
            "tool_name": toolName,
            "title": title,
            "status": status.rawValue
        ]
        if let subtitle { object["subtitle"] = subtitle }
        if let detailText { object["detail_text"] = detailText }
        if let op { object["op"] = op }
        return object
    }

    func withoutDetailText() -> AgentToolCardRenderSummary {
        AgentToolCardRenderSummary(
            schemaVersion: schemaVersion,
            toolName: toolName,
            title: title,
            subtitle: subtitle,
            detailText: nil,
            status: status,
            op: op
        )
    }

    init?(summaryOnlyObject object: [String: Any]) {
        guard let summaryObject = object["render_summary"] as? [String: Any] else { return nil }
        let schemaVersion = AgentToolCardRenderSummaryBuilder.intValue(summaryObject, keys: ["schema_version", "schemaVersion"]) ?? 1
        guard schemaVersion == 1 else { return nil }
        guard let toolName = AgentToolCardRenderSummaryBuilder.trimmed(
            AgentToolCardRenderSummaryBuilder.stringValue(summaryObject, keys: ["tool_name", "toolName"])
        ) else { return nil }
        let title = AgentToolCardRenderSummaryBuilder.trimmed(
            AgentToolCardRenderSummaryBuilder.stringValue(summaryObject, keys: ["title"])
        ) ?? Self.defaultTitle(for: toolName)
        let subtitle = AgentToolCardRenderSummaryBuilder.stringValue(summaryObject, keys: ["subtitle"])
        let detailText = AgentToolCardRenderSummaryBuilder.stringValue(summaryObject, keys: ["detail_text", "detailText"])
        guard Self.isPlausibleStoredSummary(toolName: toolName, subtitle: subtitle, detailText: detailText) else { return nil }
        let statusRaw = AgentToolCardRenderSummaryBuilder.trimmed(
            AgentToolCardRenderSummaryBuilder.stringValue(summaryObject, keys: ["status"])
        ) ?? "neutral"
        self.init(
            schemaVersion: schemaVersion,
            toolName: toolName,
            title: title,
            subtitle: subtitle,
            detailText: detailText,
            status: AgentToolCardRenderStatus(rawValue: statusRaw) ?? .neutral,
            op: AgentToolCardRenderSummaryBuilder.stringValue(summaryObject, keys: ["op"])
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case toolName = "tool_name"
        case title
        case subtitle
        case detailText = "detail_text"
        case status
        case op
    }

    private static let manageSelectionDetailRegex = try! NSRegularExpression(
        pattern: #"^[0-9]+ full • [0-9]+ sliced • [0-9]+ codemap(?: • code structure)?$"#
    )
    private static let codeStructureSubtitleRegex = try! NSRegularExpression(
        pattern: #"^(?:[0-9]+ files(?: • [0-9]+ omitted)?(?: • [0-9]+ unmapped)?|selected|[0-9]+ paths?)$"#
    )
    private static let codeStructureMoreDetailRegex = try! NSRegularExpression(
        pattern: #"^\(\+[0-9]+ more\)$"#
    )

    private static func isPlausibleStoredSummary(toolName: String, subtitle: String?, detailText: String?) -> Bool {
        let subtitle = trimmed(subtitle)
        let detailText = trimmed(detailText)
        guard [subtitle, detailText].allSatisfy({ $0?.contains("\n") != true && $0?.contains("\r") != true }) else { return false }
        switch toolName {
        case "read_file":
            guard detailText == nil, let subtitle else { return false }
            if subtitle == "file" || subtitle.contains(" • Lines ") { return true }
            let ext = (subtitle as NSString).pathExtension
            return !ext.isEmpty && !subtitle.contains("/") && !subtitle.contains("\\")
        case "manage_selection":
            if let detailText {
                let range = NSRange(detailText.startIndex ..< detailText.endIndex, in: detailText)
                return Self.manageSelectionDetailRegex.firstMatch(in: detailText, range: range) != nil
                    || detailText == "code structure"
            }
            return true
        case "workspace_context":
            if let detailText {
                let allowedLabels = Set(["prompt", "selection", "file tree", "code structure", "file blocks", "copy preset", "presets"])
                for part in detailText.components(separatedBy: " • ") {
                    if part.hasPrefix("+"), part.hasSuffix(" more") { continue }
                    guard allowedLabels.contains(part) else { return false }
                }
            }
            return true
        case "get_code_structure":
            guard let subtitle, Self.matches(Self.codeStructureSubtitleRegex, subtitle) else { return false }
            if let detailText {
                return Self.isPlausibleCodeStructureDetailText(detailText)
            }
            return true
        default:
            return true
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }

    private static func isPlausibleCodeStructureDetailText(_ detailText: String) -> Bool {
        let parts = detailText.components(separatedBy: " • ").filter { !$0.isEmpty }
        guard !parts.isEmpty, parts.count <= 3 else { return false }
        let labels: ArraySlice<String> = if let last = parts.last, matches(codeStructureMoreDetailRegex, last) {
            parts.dropLast()
        } else {
            parts[...]
        }
        guard !labels.isEmpty, labels.count <= 2 else { return false }
        return labels.allSatisfy(isPlausibleCompactCodeStructureLabel)
    }

    private static func isPlausibleCompactCodeStructureLabel(_ label: String) -> Bool {
        let lowered = label.lowercased()
        guard !lowered.contains("unmapped_paths"),
              !lowered.contains("unmappedpaths"),
              !lowered.contains("\"content\""),
              !lowered.contains("content:"),
              !label.contains("{") && !label.contains("}") && !label.contains("[") && !label.contains("]"),
              !label.hasPrefix("/") && !label.hasPrefix("~"),
              !label.contains("\\")
        else { return false }
        let pathPart = label.hasPrefix("…/") ? String(label.dropFirst(2)) : label
        let componentCount = pathPart.split(separator: "/").count
        return componentCount > 0 && componentCount <= 2
    }

    private static func defaultTitle(for toolName: String) -> String {
        switch toolName {
        case "git": "Git"
        case "file_search": "Search"
        case "search": "Web Search"
        case "manage_selection": "Selection"
        case "read_file": "Read File"
        case "workspace_context": "Context"
        case "get_file_tree", "file_tree": "File Tree"
        case "get_code_structure": "Code Structure"
        default: "Tool"
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func smallSummaryString(_ value: String?) -> String? {
        guard let value = trimmed(value) else { return nil }
        if value.count <= 240 { return value }
        let prefix = value.prefix(237).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? nil : prefix + "…"
    }
}

enum AgentToolCardRenderSummaryBuilder {
    private static let safeGitDiffOnelinerRegex = try! NSRegularExpression(
        pattern: #"^(?:[0-9]+ repos?: )?[0-9]+ files? \(\+[0-9]+ -[0-9]+\)$"#
    )
    private static let safeNativeToolNameRegex = try! NSRegularExpression(
        pattern: #"^[a-z][a-z0-9_]{1,48}$"#
    )

    static func build(
        normalizedToolName: String?,
        statusWord: String,
        rawObject: [String: Any]?,
        argsObject: [String: Any]?,
        allowExistingSummaryOnly: Bool = false
    ) -> AgentToolCardRenderSummary? {
        if boolValue(rawObject, keys: ["summary_only", "summaryOnly"]) == true {
            return allowExistingSummaryOnly ? rawObject.flatMap(AgentToolCardRenderSummary.init(summaryOnlyObject:)) : nil
        }
        guard let normalizedToolName else { return nil }
        switch normalizedToolName {
        case "read_file":
            return readFileSummary(statusWord: statusWord, rawObject: rawObject, argsObject: argsObject)
        case "file_search":
            return fileSearchSummary(statusWord: statusWord, rawObject: rawObject, argsObject: argsObject)
        case "search":
            return webSearchSummary(statusWord: statusWord, rawObject: rawObject, argsObject: argsObject)
        case "manage_selection":
            return manageSelectionSummary(statusWord: statusWord, rawObject: rawObject, argsObject: argsObject)
        case "workspace_context":
            return workspaceContextSummary(statusWord: statusWord, rawObject: rawObject)
        case "get_file_tree", "file_tree":
            return fileTreeSummary(normalizedToolName: normalizedToolName, statusWord: statusWord, rawObject: rawObject, argsObject: argsObject)
        case "get_code_structure":
            return codeStructureSummary(statusWord: statusWord, rawObject: rawObject, argsObject: argsObject)
        case "git":
            return gitSummary(statusWord: statusWord, rawObject: rawObject, argsObject: argsObject)
        default:
            return safeNativeToolSummary(normalizedToolName: normalizedToolName, statusWord: statusWord, rawObject: rawObject, argsObject: argsObject)
        }
    }

    static func jsonObject(from raw: String?) -> [String: Any]? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    static func stringValue(_ object: [String: Any]?, keys: [String]) -> String? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? String { return value }
            if let value = object[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    static func intValue(_ object: [String: Any]?, keys: [String]) -> Int? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? NSNumber { return value.intValue }
            if let value = object[key] as? String,
               let intValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return intValue
            }
        }
        return nil
    }

    static func boolValue(_ object: [String: Any]?, keys: [String]) -> Bool? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? Bool { return value }
            if let value = object[key] as? NSNumber { return value.boolValue }
        }
        return nil
    }

    static func arrayValue(_ object: [String: Any]?, keys: [String]) -> [Any]? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? [Any] { return value }
        }
        return nil
    }

    static func objectValue(_ object: [String: Any]?, keys: [String]) -> [String: Any]? {
        guard let object else { return nil }
        for key in keys {
            if let value = object[key] as? [String: Any] { return value }
        }
        return nil
    }

    static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func readFileSummary(statusWord: String, rawObject: [String: Any]?, argsObject: [String: Any]?) -> AgentToolCardRenderSummary? {
        guard rawObject != nil || argsObject != nil else { return nil }
        let path = trimmed(stringValue(rawObject, keys: ["display_path", "displayPath"]))
            ?? trimmed(stringValue(argsObject, keys: ["path"]))
        let name = fileName(from: path ?? "file")
        let lineSummary: String? = {
            guard let firstLine = intValue(rawObject, keys: ["first_line", "firstLine"]),
                  let lastLine = intValue(rawObject, keys: ["last_line", "lastLine"]),
                  let totalLines = intValue(rawObject, keys: ["total_lines", "totalLines"])
            else { return nil }
            return "Lines \(firstLine)-\(lastLine) of \(totalLines)"
        }()
        return AgentToolCardRenderSummary(
            toolName: "read_file",
            title: "Read File",
            subtitle: join(name, lineSummary),
            detailText: nil,
            status: status(from: statusWord, defaultStatus: .neutral),
            op: "read_file"
        )
    }

    private static func fileSearchSummary(statusWord: String, rawObject: [String: Any]?, argsObject: [String: Any]?) -> AgentToolCardRenderSummary? {
        guard rawObject != nil || argsObject != nil else { return nil }
        var parts: [String] = []
        if let pattern = trimmed(stringValue(argsObject, keys: ["pattern"])) {
            parts.append("\"\(pattern)\"")
        }
        if let totalMatches = intValue(rawObject, keys: ["total_matches", "totalMatches"]),
           let totalFiles = intValue(rawObject, keys: ["total_files", "totalFiles"])
        {
            var text = "\(totalMatches) matches in \(totalFiles) files"
            if boolValue(rawObject, keys: ["limit_hit", "limitHit"]) == true
                || boolValue(rawObject, keys: ["size_limit_hit", "sizeLimitHit"]) == true
            {
                text += " (limited)"
            }
            parts.append(text)
        }
        let renderStatus: AgentToolCardRenderStatus = {
            let baseStatus = status(from: statusWord, defaultStatus: .neutral)
            if baseStatus == .failure { return .failure }
            if trimmed(stringValue(rawObject, keys: ["error"])) != nil { return .failure }
            if boolValue(rawObject, keys: ["limit_hit", "limitHit"]) == true
                || boolValue(rawObject, keys: ["size_limit_hit", "sizeLimitHit"]) == true { return .warning }
            if (intValue(rawObject, keys: ["total_matches", "totalMatches"]) ?? 0) > 0 { return .success }
            return baseStatus
        }()
        return AgentToolCardRenderSummary(
            toolName: "file_search",
            title: "Search",
            subtitle: parts.isEmpty ? nil : parts.joined(separator: " • "),
            detailText: nil,
            status: renderStatus,
            op: "file_search"
        )
    }

    private static func webSearchSummary(statusWord: String, rawObject: [String: Any]?, argsObject: [String: Any]?) -> AgentToolCardRenderSummary? {
        guard rawObject != nil || argsObject != nil else { return nil }
        let query = trimmed(stringValue(argsObject, keys: ["query", "q", "search_query", "searchQuery", "text", "value"]))
            ?? trimmed(stringValue(rawObject, keys: ["query", "q", "search_query", "searchQuery", "text", "value"]))
        let resultCount = firstSearchResultCount(rawObject)
        let sourceCount = firstSearchSourceCount(rawObject)
        let errorDetail = webSearchErrorDetail(rawObject)
        let countSummary: String? = {
            var parts: [String] = []
            if let resultCount { parts.append("\(resultCount) result\(resultCount == 1 ? "" : "s")") }
            if let sourceCount { parts.append("\(sourceCount) source\(sourceCount == 1 ? "" : "s")") }
            return parts.isEmpty ? nil : parts.joined(separator: " • ")
        }()
        let subtitle = [query.map { "\"\($0)\"" }, countSummary]
            .compactMap(\.self)
            .joined(separator: " • ")
        let baseStatus = status(from: stringValue(rawObject, keys: ["status", "state", "outcome"]) ?? statusWord, defaultStatus: .neutral)
        let resultDetail = webSearchDetailText(rawObject)
        let renderStatus: AgentToolCardRenderStatus = {
            if errorDetail != nil, baseStatus != .success { return .failure }
            if baseStatus == .failure || baseStatus == .warning || baseStatus == .running { return baseStatus }
            if (resultCount ?? 0) > 0 || (sourceCount ?? 0) > 0 { return .success }
            if resultDetail != nil { return .success }
            return baseStatus
        }()
        let detailText = baseStatus == .success ? (resultDetail ?? errorDetail) : (errorDetail ?? resultDetail)
        return AgentToolCardRenderSummary(
            toolName: "search",
            title: "Web Search",
            subtitle: subtitle.isEmpty ? nil : subtitle,
            detailText: detailText,
            status: renderStatus,
            op: "search"
        )
    }

    private static func safeNativeToolSummary(
        normalizedToolName: String,
        statusWord: String,
        rawObject: [String: Any]?,
        argsObject: [String: Any]?
    ) -> AgentToolCardRenderSummary? {
        guard isSafeNativeToolName(normalizedToolName), rawObject != nil || argsObject != nil else { return nil }
        let subtitle = nativeScalarSummary(
            object: argsObject,
            preferredKeys: ["query", "q", "prompt", "text", "value", "name", "id", "operation", "op"]
        )
        let detailText = nativeScalarSummary(
            object: rawObject,
            preferredKeys: ["summary", "answer", "message", "text", "title", "status", "state", "outcome"]
        )
        guard subtitle != nil || detailText != nil else { return nil }
        return AgentToolCardRenderSummary(
            toolName: normalizedToolName,
            title: nativeToolTitle(from: normalizedToolName),
            subtitle: subtitle,
            detailText: detailText,
            status: status(from: stringValue(rawObject, keys: ["status", "state", "outcome"]) ?? statusWord, defaultStatus: .neutral),
            op: normalizedToolName
        )
    }

    private static func manageSelectionSummary(statusWord: String, rawObject: [String: Any]?, argsObject: [String: Any]?) -> AgentToolCardRenderSummary? {
        guard rawObject != nil || argsObject != nil else { return nil }
        let op = trimmed(stringValue(argsObject, keys: ["op"])) ?? "get"
        var parts: [String] = [op]
        if let files = rawObject?["files"] as? [Any] {
            parts.append("\(files.count) files")
        }
        if let totalTokens = intValue(rawObject, keys: ["total_tokens", "totalTokens"]) {
            parts.append("\(totalTokens) tokens")
        }
        if parts.count == 1,
           let invalid = rawObject?["invalid_paths"] as? [Any],
           !invalid.isEmpty
        {
            parts.append("\(invalid.count) invalid")
        }
        let summary = rawObject?["summary"] as? [String: Any]
        var detailParts: [String] = []
        if summary != nil {
            detailParts.append(contentsOf: [
                "\(intValue(summary, keys: ["full_count", "fullCount"]) ?? 0) full",
                "\(intValue(summary, keys: ["slice_count", "sliceCount"]) ?? 0) sliced",
                "\(intValue(summary, keys: ["codemap_count", "codemapCount"]) ?? 0) codemap"
            ])
        }
        if hasNestedCodeStructureObject(rawObject) {
            detailParts.append("code structure")
        }
        let mappedStatus = status(from: stringValue(rawObject, keys: ["status"]) ?? statusWord, defaultStatus: .neutral)
        let renderStatus: AgentToolCardRenderStatus = {
            if let invalid = rawObject?["invalid_paths"] as? [Any], !invalid.isEmpty,
               mappedStatus == .success || mappedStatus == .neutral
            {
                return .warning
            }
            return mappedStatus
        }()
        return AgentToolCardRenderSummary(
            toolName: "manage_selection",
            title: "Selection",
            subtitle: parts.joined(separator: " • "),
            detailText: detailParts.isEmpty ? nil : detailParts.joined(separator: " • "),
            status: renderStatus,
            op: op
        )
    }

    private static func workspaceContextSummary(statusWord: String, rawObject: [String: Any]?) -> AgentToolCardRenderSummary? {
        guard let rawObject else { return nil }
        var summaryParts: [String] = []
        if let selection = rawObject["selection"] as? [String: Any] {
            if let files = selection["files"] as? [Any] {
                summaryParts.append("\(files.count) files")
            }
            if let totalTokens = intValue(selection, keys: ["total_tokens", "totalTokens"]) {
                summaryParts.append("\(totalTokens) tokens")
            }
        } else if let tokenStats = rawObject["token_stats"] as? [String: Any],
                  let total = intValue(tokenStats, keys: ["total"])
        {
            summaryParts.append("\(total) tokens")
        }
        var sections: [String] = []
        if trimmed(stringValue(rawObject, keys: ["prompt"])) != nil { sections.append("prompt") }
        if rawObject["selection"] != nil { sections.append("selection") }
        if rawObject["file_tree"] != nil || rawObject["fileTree"] != nil { sections.append("file tree") }
        if hasNestedCodeStructureObject(rawObject) { sections.append("code structure") }
        if let fileBlocks = arrayValue(rawObject, keys: ["file_blocks", "fileBlocks"]), !fileBlocks.isEmpty { sections.append("file blocks") }
        if rawObject["copy_preset"] != nil || rawObject["copyPreset"] != nil { sections.append("copy preset") }
        if let copyPresets = rawObject["copy_presets"] as? [Any], !copyPresets.isEmpty { sections.append("presets") }
        let detailText: String? = {
            guard !sections.isEmpty else { return nil }
            let visible = Array(sections.prefix(3))
            if sections.count > visible.count {
                return visible.joined(separator: " • ") + " • +\(sections.count - visible.count) more"
            }
            return visible.joined(separator: " • ")
        }()
        return AgentToolCardRenderSummary(
            toolName: "workspace_context",
            title: "Context",
            subtitle: summaryParts.isEmpty ? "snapshot" : summaryParts.joined(separator: " • "),
            detailText: detailText,
            status: status(from: statusWord, defaultStatus: .success),
            op: "workspace_context"
        )
    }

    private static func codeStructureSummary(statusWord: String, rawObject: [String: Any]?, argsObject: [String: Any]?) -> AgentToolCardRenderSummary? {
        guard rawObject != nil || argsObject != nil else { return nil }
        let codeObject = selectedCodeStructureObject(rawObject)
        let fileCount = intValue(codeObject, keys: ["file_count", "fileCount"])
        let totalOmitted = codeStructureTotalOmitted(codeObject)
        let unmappedPaths = stringArrayValue(codeObject, keys: ["unmapped_paths", "unmappedPaths"])
        let unmappedCount = intValue(codeObject, keys: ["unmapped_count", "unmappedCount"]) ?? unmappedPaths.count
        let subtitle: String? = {
            if let fileCount {
                var parts = ["\(fileCount) files"]
                if totalOmitted > 0 {
                    parts.append("\(totalOmitted) omitted")
                }
                if unmappedCount > 0 {
                    parts.append("\(unmappedCount) unmapped")
                }
                return parts.joined(separator: " • ")
            }
            if trimmed(stringValue(argsObject, keys: ["scope"])) == "selected" {
                return "selected"
            }
            if let pathCount = arrayValue(argsObject, keys: ["paths"])?.count, pathCount > 0 {
                return "\(pathCount) path\(pathCount == 1 ? "" : "s")"
            }
            return nil
        }()
        let detailText = codeStructureUnmappedDetail(paths: unmappedPaths, unmappedCount: unmappedCount)
        let baseStatus = status(from: statusWord, defaultStatus: .neutral)
        let renderStatus: AgentToolCardRenderStatus = {
            if baseStatus == .failure { return .failure }
            if totalOmitted > 0 || boolValue(codeObject, keys: ["token_budget_hit", "tokenBudgetHit"]) == true { return .warning }
            if (fileCount ?? 0) > 0 { return .success }
            if fileCount != nil { return .neutral }
            return baseStatus
        }()
        return AgentToolCardRenderSummary(
            toolName: "get_code_structure",
            title: "Code Structure",
            subtitle: subtitle,
            detailText: detailText,
            status: renderStatus,
            op: "get_code_structure"
        )
    }

    private static func fileTreeSummary(normalizedToolName: String, statusWord: String, rawObject: [String: Any]?, argsObject: [String: Any]?) -> AgentToolCardRenderSummary? {
        guard rawObject != nil || argsObject != nil else { return nil }
        let rootsCount = intValue(rawObject, keys: ["roots_count", "rootsCount"]) ?? 0
        let treeType = normalizedTreeType(rawObject: rawObject, argsObject: argsObject)
        let mode = normalizedTreeMode(stringValue(argsObject, keys: ["mode"]))
        let startPath = normalizedStartPath(stringValue(argsObject, keys: ["path"]))
        let note = trimmed(stringValue(rawObject, keys: ["note"]))
        let wasTruncated = boolValue(rawObject, keys: ["was_truncated", "wasTruncated"]) == true
        let subtitle: String = {
            if note != nil {
                if treeType == "roots" { return "File tree unavailable" }
                return fileTreeFilesSubtitle(mode: mode, startPath: startPath, rootsCount: startPath == nil ? rootsCount : nil) ?? "File tree unavailable"
            }
            if treeType == "roots" { return rootCountText(rootsCount) }
            return fileTreeFilesSubtitle(mode: mode, startPath: startPath, rootsCount: startPath == nil ? rootsCount : nil) ?? "File tree"
        }()
        let renderStatus: AgentToolCardRenderStatus = {
            if status(from: statusWord, defaultStatus: .neutral) == .failure { return .failure }
            if note != nil || wasTruncated { return .warning }
            if trimmed(stringValue(rawObject, keys: ["tree"])) != nil { return .success }
            return status(from: statusWord, defaultStatus: .neutral)
        }()
        return AgentToolCardRenderSummary(
            toolName: normalizedToolName,
            title: "File Tree",
            subtitle: subtitle,
            detailText: note,
            status: renderStatus,
            op: "get_file_tree"
        )
    }

    private static func gitSummary(statusWord: String, rawObject: [String: Any]?, argsObject: [String: Any]?) -> AgentToolCardRenderSummary? {
        guard rawObject != nil || argsObject != nil else { return nil }
        let op = trimmed(stringValue(rawObject, keys: ["op"]))
            ?? trimmed(stringValue(argsObject, keys: ["op"]))
            ?? "git"
        let subtitle: String
        let detailText: String?
        switch op.lowercased() {
        case "status":
            subtitle = join(op, gitStatusPrimarySummary(rawObject: rawObject) ?? gitRepoCountText(rawObject: rawObject))
            detailText = gitStatusDetailText(rawObject: rawObject)
        case "diff":
            subtitle = join(op, gitPreferredDiffSummary(rawObject: rawObject) ?? trimmed(stringValue(argsObject, keys: ["compare"])))
            detailText = gitDiffDetailText(rawObject: rawObject, argsObject: argsObject)
        case "log":
            subtitle = join(op, gitLogSummary(rawObject: rawObject) ?? gitRepoCountText(rawObject: rawObject))
            detailText = gitLogDetailText(rawObject: rawObject)
        case "show":
            subtitle = join(op, gitShowSummary(rawObject: rawObject) ?? gitRepoCountText(rawObject: rawObject))
            detailText = gitShowDetailText(rawObject: rawObject)
        case "blame":
            subtitle = join(op, gitBlameSummary(rawObject: rawObject) ?? gitRepoCountText(rawObject: rawObject))
            detailText = gitBlameDetailText(rawObject: rawObject)
        default:
            subtitle = join(op, gitPreferredDiffSummary(rawObject: rawObject) ?? gitRepoCountText(rawObject: rawObject) ?? trimmed(stringValue(argsObject, keys: ["compare"])))
            detailText = gitDiffDetailText(rawObject: rawObject, argsObject: argsObject)
        }
        let renderStatus: AgentToolCardRenderStatus = {
            if trimmed(stringValue(rawObject, keys: ["error"])) != nil { return .failure }
            if trimmed(stringValue(rawObject, keys: ["empty_reason", "emptyReason", "warning"])) != nil
                || boolValue(rawObject?["diff"] as? [String: Any], keys: ["truncated"]) == true
                || boolValue(rawObject?["inline"] as? [String: Any], keys: ["truncated"]) == true
            {
                return .warning
            }
            return status(from: statusWord, defaultStatus: .success)
        }()
        return AgentToolCardRenderSummary(
            toolName: "git",
            title: "Git",
            subtitle: subtitle,
            detailText: detailText,
            status: renderStatus,
            op: op.lowercased()
        )
    }

    private static func webSearchDetailText(_ object: [String: Any]?) -> String? {
        if let direct = trimmed(stringValue(object, keys: ["summary", "answer", "snippet", "message", "text"])) {
            return safeCollapsedText(direct)
        }
        for arrayKey in ["results", "items", "web_results", "webResults", "search_results", "searchResults"] {
            guard let first = arrayValue(object, keys: [arrayKey])?.first else { continue }
            if let text = webSearchDetailText(fromResult: first) { return text }
        }
        if let nested = objectValue(object, keys: ["result", "output", "response", "content", "data", "payload"]),
           let text = webSearchDetailText(nested)
        {
            return text
        }
        for arrayKey in ["sources", "citations"] {
            guard let first = arrayValue(object, keys: [arrayKey])?.first else { continue }
            if let text = webSearchDetailText(fromResult: first) { return text }
        }
        return nil
    }

    private static func webSearchDetailText(fromResult value: Any) -> String? {
        if let text = value as? String { return safeCollapsedText(text) }
        guard let object = value as? [String: Any] else { return nil }
        let title = safeCollapsedText(stringValue(object, keys: ["title", "name", "source", "url"]))
        let snippet = safeCollapsedText(stringValue(object, keys: ["snippet", "summary", "text", "description", "content"]))
        return join(title, snippet)
    }

    private static func webSearchErrorDetail(_ object: [String: Any]?) -> String? {
        guard let object else { return nil }
        if let error = object["error"] as? String { return safeCollapsedText(error) }
        if let errorMessage = trimmed(stringValue(object, keys: ["error_message", "errorMessage"])) {
            return safeCollapsedText(errorMessage)
        }
        if let error = object["error"] as? [String: Any] {
            return safeCollapsedText(stringValue(error, keys: ["message", "detail", "description", "code"]))
        }
        if let errors = object["errors"] as? [Any], let first = errors.first {
            if let text = first as? String { return safeCollapsedText(text) }
            if let error = first as? [String: Any] {
                return safeCollapsedText(stringValue(error, keys: ["message", "detail", "description", "code"]))
            }
        }
        return nil
    }

    private static func firstSearchResultCount(_ object: [String: Any]?) -> Int? {
        firstArrayCount(object, keys: ["results", "items", "web_results", "webResults", "search_results", "searchResults"])
            ?? intValue(object, keys: ["result_count", "resultCount", "total_results", "totalResults", "count"])
            ?? firstNestedSearchResultCount(object)
    }

    private static func firstNestedSearchResultCount(_ object: [String: Any]?) -> Int? {
        for key in ["result", "output", "response", "content", "data", "payload"] {
            guard let nested = objectValue(object, keys: [key]) else { continue }
            if let count = firstSearchResultCount(nested) { return count }
        }
        return nil
    }

    private static func firstSearchSourceCount(_ object: [String: Any]?) -> Int? {
        firstArrayCount(object, keys: ["sources", "citations"])
            ?? intValue(object, keys: [
                "source_count", "sourceCount", "total_sources", "totalSources",
                "citation_count", "citationCount", "total_citations", "totalCitations"
            ])
            ?? firstNestedSearchSourceCount(object)
    }

    private static func firstNestedSearchSourceCount(_ object: [String: Any]?) -> Int? {
        for key in ["result", "output", "response", "content", "data", "payload"] {
            guard let nested = objectValue(object, keys: [key]) else { continue }
            if let count = firstSearchSourceCount(nested) { return count }
        }
        return nil
    }

    private static func firstArrayCount(_ object: [String: Any]?, keys: [String]) -> Int? {
        for key in keys {
            if let count = arrayValue(object, keys: [key])?.count { return count }
        }
        return nil
    }

    private static func safeCollapsedText(_ value: String?) -> String? {
        guard let value = trimmed(value) else { return nil }
        guard !value.contains("\n"), !value.contains("\r") else {
            let oneline = value
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return smallSummaryString(oneline)
        }
        let lowered = value.lowercased()
        guard !(value.hasPrefix("{") || value.hasPrefix("[")),
              !lowered.contains("\"results\""),
              !lowered.contains("\"content\"")
        else { return nil }
        return smallSummaryString(value)
    }

    private static func smallSummaryString(_ value: String?) -> String? {
        guard let value = trimmed(value) else { return nil }
        if value.count <= 240 { return value }
        let prefix = value.prefix(237).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? nil : prefix + "…"
    }

    private static func nativeScalarSummary(object: [String: Any]?, preferredKeys: [String]) -> String? {
        guard let object else { return nil }
        for key in preferredKeys {
            if let value = safeNativeScalar(object[key]) { return value }
        }
        return nil
    }

    private static func safeNativeScalar(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            safeCollapsedText(string)
        case let number as NSNumber:
            number.stringValue
        default:
            nil
        }
    }

    static func isSafeNativeFallbackToolName(_ name: String?) -> Bool {
        guard let name else { return false }
        return isSafeNativeToolName(name)
    }

    private static func isSafeNativeToolName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized == name,
              normalized != "tool",
              normalized != "other",
              !normalized.hasPrefix("mcp__"),
              !normalized.contains("."),
              !normalized.contains("/")
        else { return false }
        switch normalized {
        case "read", "read_file", "file_search", "grep", "bash", "shell", "apply_edits", "apply_patch", "edit",
             "get_file_tree", "get_code_structure", "file_actions", "manage_selection", "workspace_context", "prompt",
             "ask_oracle", "oracle_send", "oracle_utils", "oracle_chat_log", "chat_send", "chats", "list_models",
             "bind_context", "manage_workspaces", "git", "manage_worktree", "context_builder", "request_user_input",
             "ask_user", "ask_user_question", "agent_explore", "agent_run", "agent_manage", "app_settings":
            return false
        default:
            break
        }
        let range = NSRange(normalized.startIndex ..< normalized.endIndex, in: normalized)
        return safeNativeToolNameRegex.firstMatch(in: normalized, range: range) != nil
    }

    private static func nativeToolTitle(from name: String) -> String {
        name.split(separator: "_")
            .map { part in
                guard let first = part.first else { return "" }
                return String(first).uppercased() + part.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    private static func status(from rawStatus: String, defaultStatus: AgentToolCardRenderStatus) -> AgentToolCardRenderStatus {
        switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "success", "succeeded", "ok", "completed": .success
        case "warning", "partial", "waiting_for_input", "expired": .warning
        case "failed", "failure", "error", "cancelled": .failure
        case "running", "pending": .running
        default: defaultStatus
        }
    }

    private static func fileName(from path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let last = (normalized as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    private static func join(_ lhs: String?, _ rhs: String?) -> String {
        guard let lhs = trimmed(lhs) else { return trimmed(rhs) ?? "" }
        guard let rhs = trimmed(rhs) else { return lhs }
        return "\(lhs) • \(rhs)"
    }

    private static func rootCountText(_ count: Int) -> String {
        "\(count) root\(count == 1 ? "" : "s")"
    }

    private static func normalizedTreeMode(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "full": "full"
        case "folders": "folders"
        case "selected": "selected"
        default: "auto"
        }
    }

    private static func fileTreeModeTitle(_ mode: String) -> String {
        switch mode {
        case "full": "Full"
        case "folders": "Folders"
        case "selected": "Selected"
        default: "Auto"
        }
    }

    private static func fileTreeFilesSubtitle(mode: String, startPath: String?, rootsCount: Int?) -> String? {
        var parts = [fileTreeModeTitle(mode)]
        if let startPath {
            parts.append(fileName(from: startPath))
        } else if let rootsCount {
            parts.append(rootCountText(rootsCount))
        }
        return parts.joined(separator: " • ")
    }

    private static func normalizedStartPath(_ path: String?) -> String? {
        guard let trimmed = trimmed(path), trimmed != ".", trimmed != "./" else { return nil }
        return trimmed
    }

    private static func normalizedTreeType(rawObject: [String: Any]?, argsObject: [String: Any]?) -> String {
        if let raw = trimmed(stringValue(argsObject, keys: ["type"]))?.lowercased() { return raw }
        if stringValue(argsObject, keys: ["mode"]) != nil
            || stringValue(argsObject, keys: ["path"]) != nil
            || intValue(argsObject, keys: ["max_depth", "maxDepth"]) != nil
            || boolValue(rawObject, keys: ["uses_legend", "usesLegend"]) == true
        {
            return "files"
        }
        if let tree = stringValue(rawObject, keys: ["tree"]), tree.contains("├──") || tree.contains("└──") {
            return "files"
        }
        return "roots"
    }

    private static func hasNestedCodeStructureObject(_ object: [String: Any]?) -> Bool {
        guard let object else { return false }
        return object["code_structure"] is [String: Any] || object["codeStructure"] is [String: Any]
    }

    private static func selectedCodeStructureObject(_ object: [String: Any]?) -> [String: Any]? {
        guard let object else { return nil }
        if let codeStructure = object["code_structure"] as? [String: Any] { return codeStructure }
        if let codeStructure = object["codeStructure"] as? [String: Any] { return codeStructure }
        if intValue(object, keys: ["file_count", "fileCount"]) != nil
            || object["content"] != nil
            || object["unmapped_paths"] != nil
            || object["unmappedPaths"] != nil
            || intValue(object, keys: ["codemaps_omitted", "codemapsOmitted", "omitted_count", "omittedCount", "omitted_total", "omittedTotal", "token_budget_omitted", "tokenBudgetOmitted", "tokenBudgetOmittedCount"]) != nil
        {
            return object
        }
        return nil
    }

    private static func codeStructureTotalOmitted(_ object: [String: Any]?) -> Int {
        if let total = intValue(object, keys: ["omitted_total", "omittedTotal"]) {
            return max(0, total)
        }
        let maxResultsOmitted = intValue(object, keys: ["codemaps_omitted", "codemapsOmitted", "omitted_count", "omittedCount"]) ?? 0
        let tokenBudgetOmitted = intValue(object, keys: ["token_budget_omitted", "tokenBudgetOmitted", "tokenBudgetOmittedCount"]) ?? 0
        return max(0, maxResultsOmitted + tokenBudgetOmitted)
    }

    private static func codeStructureUnmappedDetail(paths: [String], unmappedCount: Int) -> String? {
        guard unmappedCount > 0 else { return nil }
        let visible = paths.prefix(2).map { compactDisplayPathLabel($0) }
        guard !visible.isEmpty else { return nil }
        var parts = Array(visible)
        if unmappedCount > visible.count {
            parts.append("(+\(unmappedCount - visible.count) more)")
        }
        return parts.joined(separator: " • ")
    }

    private static func stringArrayValue(_ object: [String: Any]?, keys: [String]) -> [String] {
        arrayValue(object, keys: keys)?.compactMap { element in
            if let string = element as? String { return trimmed(string) }
            return nil
        } ?? []
    }

    private static func compactDisplayPathLabel(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/")
        if components.count <= 2 {
            return normalized
        }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    private static func gitStatusPrimarySummary(rawObject: [String: Any]?) -> String? {
        let status = rawObject?["status"] as? [String: Any]
        return trimmed(stringValue(status, keys: ["branch"])) ?? gitRepoCountText(rawObject: rawObject)
    }

    private static func gitStatusDetailText(rawObject: [String: Any]?) -> String? {
        guard let status = rawObject?["status"] as? [String: Any] else { return nil }
        var parts: [String] = []
        let ahead = intValue(status, keys: ["ahead"])
        let behind = intValue(status, keys: ["behind"])
        if let ahead, let behind, ahead > 0 || behind > 0 {
            parts.append("+\(ahead) -\(behind)")
        }
        if let upstream = trimmed(stringValue(status, keys: ["upstream"])) { parts.append(upstream) }
        appendArrayCountSummary(&parts, object: status, key: "staged", label: "staged")
        appendArrayCountSummary(&parts, object: status, key: "modified", label: "modified")
        appendArrayCountSummary(&parts, object: status, key: "untracked", label: "untracked")
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func gitDiffDetailText(rawObject: [String: Any]?, argsObject: [String: Any]?) -> String? {
        let inputs = rawObject?["inputs"] as? [String: Any]
        let diff = rawObject?["diff"] as? [String: Any]
        let worktree = rawObject?["worktree"] as? [String: Any]
        var parts: [String] = []
        if let compare = trimmed(stringValue(inputs, keys: ["compare"]) ?? stringValue(argsObject, keys: ["compare"])) { parts.append(compare) }
        if let scope = trimmed(stringValue(inputs, keys: ["scope"])) { parts.append(scope) }
        if let detail = trimmed(stringValue(diff, keys: ["detail"]) ?? stringValue(argsObject, keys: ["detail"])) { parts.append(detail) }
        if parts.count < 3, let branch = trimmed(stringValue(worktree, keys: ["worktree_branch", "worktreeBranch"])) { parts.append(branch) }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func gitPreferredDiffSummary(rawObject: [String: Any]?) -> String? {
        let aggregate = rawObject?["aggregate"] as? [String: Any]
        let diff = rawObject?["diff"] as? [String: Any]
        let summary = rawObject?["summary"] as? [String: Any]
        return gitTotalsSummaryText(object: aggregate?["totals"] as? [String: Any])
            ?? gitTotalsSummaryText(object: diff?["totals"] as? [String: Any])
            ?? gitTotalsSummaryText(object: summary)
            ?? safeGitDiffOneliner(stringValue(aggregate, keys: ["oneliner"]))
            ?? safeGitDiffOneliner(stringValue(diff, keys: ["oneliner"]))
            ?? safeGitDiffOneliner(stringValue(rawObject, keys: ["oneliner"]))
    }

    private static func gitTotalsSummaryText(object: [String: Any]?) -> String? {
        guard let files = intValue(object, keys: ["files"]),
              let insertions = intValue(object, keys: ["insertions"]),
              let deletions = intValue(object, keys: ["deletions"])
        else { return nil }
        return "\(files) files (+\(insertions) -\(deletions))"
    }

    private static func gitLogSummary(rawObject: [String: Any]?) -> String? {
        guard let log = rawObject?["log"] as? [String: Any],
              let commits = log["commits"] as? [[String: Any]]
        else { return nil }
        if commits.count == 1,
           let first = commits.first,
           let shortSHA = trimmed(stringValue(first, keys: ["short_sha", "shortSha"]))
        {
            return shortSHA
        }
        return "\(commits.count) commits"
    }

    private static func gitLogDetailText(rawObject: [String: Any]?) -> String? {
        guard let log = rawObject?["log"] as? [String: Any],
              let commits = log["commits"] as? [[String: Any]],
              let first = commits.first
        else { return nil }
        var parts: [String] = []
        if let shortSHA = trimmed(stringValue(first, keys: ["short_sha", "shortSha"])) { parts.append("latest \(shortSHA)") }
        if let author = trimmed(stringValue(first, keys: ["author"])) { parts.append(author) }
        if commits.count == 1,
           let totals = gitTotalsSummaryText(object: [
               "files": intValue(first, keys: ["files_changed", "filesChanged"]) ?? 0,
               "insertions": intValue(first, keys: ["insertions"]) ?? 0,
               "deletions": intValue(first, keys: ["deletions"]) ?? 0
           ])
        {
            parts.append(totals)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func gitShowSummary(rawObject: [String: Any]?) -> String? {
        guard let show = rawObject?["show"] as? [String: Any] else { return nil }
        return trimmed(stringValue(show, keys: ["short_sha", "shortSha"]))
    }

    private static func gitShowDetailText(rawObject: [String: Any]?) -> String? {
        guard let show = rawObject?["show"] as? [String: Any] else { return nil }
        var parts: [String] = []
        if let message = trimmed(stringValue(show, keys: ["message"])) { parts.append(shortenedGitMessage(message)) }
        if let totals = gitTotalsSummaryText(object: show["totals"] as? [String: Any]) { parts.append(totals) }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func gitBlameSummary(rawObject: [String: Any]?) -> String? {
        guard let blame = rawObject?["blame"] as? [String: Any] else { return nil }
        if let lines = blame["lines"] as? [Any] { return "\(lines.count) lines" }
        return nil
    }

    private static func gitBlameDetailText(rawObject: [String: Any]?) -> String? {
        guard let blame = rawObject?["blame"] as? [String: Any],
              let lines = blame["lines"] as? [[String: Any]]
        else { return nil }
        let authors = Set(lines.compactMap { trimmed(stringValue($0, keys: ["author"])) })
        return authors.isEmpty ? nil : "\(authors.count) authors"
    }

    private static func gitRepoCountText(rawObject: [String: Any]?) -> String? {
        guard let repos = rawObject?["repos"] as? [[String: Any]], repos.count > 1 else { return nil }
        return "\(repos.count) repos"
    }

    private static func appendArrayCountSummary(_ parts: inout [String], object: [String: Any], key: String, label: String) {
        guard let array = object[key] as? [Any], !array.isEmpty else { return }
        parts.append("\(array.count) \(label)")
    }

    private static func safeGitDiffOneliner(_ value: String?) -> String? {
        guard let value = trimmed(value) else { return nil }
        let lowered = value.lowercased()
        guard !lowered.contains("diff --"),
              !lowered.contains("@@"),
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("\n"),
              !value.contains("+++"),
              !value.contains("---")
        else { return nil }
        if lowered == "no changes" { return value }
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        return safeGitDiffOnelinerRegex.firstMatch(in: value, range: range) != nil ? value : nil
    }

    private static func shortenedGitMessage(_ message: String) -> String {
        if message.count <= 48 { return message }
        return String(message.prefix(45)) + "…"
    }
}
