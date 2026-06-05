import Foundation

struct AgentWebToolActionInput {
    let rawToolName: String?
    let normalizedToolName: String?
    let argsObject: [String: Any]?
    let resultObject: [String: Any]?
}

struct AgentWebToolActionPresentation: Equatable {
    enum Action: Equatable {
        case webSearch
        case readWebPage
        case findInPage
    }

    let action: Action
    let title: String
    let subtitle: String?
    let op: String

    static func classify(_ input: AgentWebToolActionInput) -> AgentWebToolActionPresentation? {
        AgentWebToolActionClassifier.classify(input)
    }

    static func classify(
        rawToolName: String?,
        normalizedToolName: String?,
        argsJSON: String?,
        resultJSON: String?
    ) -> AgentWebToolActionPresentation? {
        guard AgentWebToolCanonicalNames.canonicalToolCardName(rawToolName) != nil
            || AgentWebToolCanonicalNames.canonicalToolCardName(normalizedToolName) != nil
        else { return nil }
        return classify(AgentWebToolActionInput(
            rawToolName: rawToolName,
            normalizedToolName: normalizedToolName,
            argsObject: jsonObject(from: argsJSON),
            resultObject: jsonObject(from: resultJSON)
        ))
    }

    private static func jsonObject(from raw: String?) -> [String: Any]? {
        ToolRawJSON.object(from: raw)
    }
}

enum AgentWebToolPayloadKeys {
    static let wrapperKeys = ["input", "args", "arguments", "parameters", "params", "rawInput"]
    static let urlTargetKeys = ["url", "uri", "href", "link", "page_url", "pageUrl", "source_url", "sourceUrl"]
    static let refTargetKeys = ["ref", "ref_id", "refId", "page_ref", "pageRef"]
    static let findKeys = ["pattern", "needle", "find", "find_text", "findText", "text_to_find", "textToFind", "phrase"]
    static let operationKeys = ["op", "action", "operation"]
    static let queryKeys = ["query", "q", "search_query", "searchQuery", "search_text", "searchText"]
    static let legacySearchQueryKeys = queryKeys + ["text", "value"]
    static let compactScalarKeys = urlTargetKeys + refTargetKeys + findKeys + operationKeys
    static let readResultMetadataKeys = [
        "status", "title", "page_title", "pageTitle", "summary", "description", "match_count", "matchCount",
        "total_matches", "totalMatches", "count"
    ]
}

enum AgentWebToolCanonicalNames {
    static func canonicalToolCardName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let names = normalizedNameCandidates(raw)
        if names.contains(where: isWebSearchName) { return "search" }
        if names.contains(where: isWebReadName) { return "web_read" }
        return nil
    }

    static func isWebSearchName(_ name: String) -> Bool {
        switch normalizedName(name) {
        case "search", "web_search", "web_search_request", "google_web_search", "search_web", "websearch":
            true
        default:
            false
        }
    }

    static func isWebReadName(_ name: String) -> Bool {
        switch normalizedName(name) {
        case "webfetch", "web_fetch", "web_read", "read_web", "browser.open", "browser_open", "open_url",
             "read_url", "fetch_url", "web_page", "webpage", "read_web_page":
            true
        default:
            false
        }
    }

    static func isExcludedNonWebName(raw: String?, normalized: String?) -> Bool {
        nameCandidates(rawToolName: raw, normalizedToolName: normalized).contains { name in
            switch normalizedName(name) {
            case "file_search", "filesearch", "grep", "mcp__repoprompt__file_search", "read_file", "readfile",
                 "get_code_structure", "get_file_tree", "mcp__repoprompt__read_file",
                 "mcp__repoprompt__get_code_structure", "mcp__repoprompt__get_file_tree":
                true
            default:
                false
            }
        }
    }

    static func nameCandidates(rawToolName: String?, normalizedToolName: String?) -> [String] {
        var names: [String] = []
        if let rawToolName { names.append(contentsOf: normalizedNameCandidates(rawToolName)) }
        if let normalizedToolName { names.append(contentsOf: normalizedNameCandidates(normalizedToolName)) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static func normalizedNameCandidates(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let stripped = trimmed.replacingOccurrences(of: "mcp__RepoPrompt__", with: "")
        let normalized = normalizedName(stripped)
        var names = [normalized]
        if let suffix = normalized.split(separator: ".").last.map(String.init), suffix != normalized {
            names.append(suffix)
        }
        return names
    }

    private static func normalizedName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}

private enum AgentWebToolActionClassifier {
    private static let compactTextSeparators = CharacterSet.whitespacesAndNewlines

    private enum PayloadSource {
        case args
        case result
    }

    private struct PayloadSignals {
        let source: PayloadSource
        let target: Target?
        let findText: String?
        let hasFindOperation: Bool
        let hasReadOperation: Bool
        let hasQuery: Bool
        let query: String?
    }

    private enum Target: Equatable {
        case url(String, subtitle: String)
        case ref(String, subtitle: String)

        var subtitle: String {
            switch self {
            case let .url(_, subtitle), let .ref(_, subtitle): subtitle
            }
        }
    }

    static func classify(_ input: AgentWebToolActionInput) -> AgentWebToolActionPresentation? {
        if AgentWebToolCanonicalNames.isExcludedNonWebName(raw: input.rawToolName, normalized: input.normalizedToolName) {
            return nil
        }

        let names = AgentWebToolCanonicalNames.nameCandidates(
            rawToolName: input.rawToolName,
            normalizedToolName: input.normalizedToolName
        )
        let isSearchName = names.contains(where: AgentWebToolCanonicalNames.isWebSearchName)
        let isReadName = names.contains(where: AgentWebToolCanonicalNames.isWebReadName)
        let isSupportedWebName = isSearchName || isReadName
        guard isSupportedWebName else { return nil }

        let argsSignals = input.argsObject.map {
            payloadSignals(from: $0, source: .args, isSupportedWebName: isSupportedWebName)
        }
        func resultSignals() -> PayloadSignals? {
            input.resultObject.map { payloadSignals(from: $0, source: .result, isSupportedWebName: isSupportedWebName) }
        }

        if let find = actionPresentation(
            action: .findInPage,
            signals: argsSignals,
            isSearchName: isSearchName,
            isReadName: isReadName
        ) {
            return find
        }

        if let argsSignals,
           argsSignals.hasQuery,
           isSearchName,
           !argsSignals.hasReadOperation,
           argsSignals.findText == nil,
           !argsSignals.hasFindOperation
        {
            return webSearch(query: argsSignals.query)
        }

        if let read = actionPresentation(
            action: .readWebPage,
            signals: argsSignals,
            isSearchName: isSearchName,
            isReadName: isReadName
        ) {
            return read
        }

        let fallbackResultSignals = resultSignals()
        if let find = actionPresentation(
            action: .findInPage,
            signals: fallbackResultSignals,
            isSearchName: isSearchName,
            isReadName: isReadName
        ) {
            return find
        }
        if let read = actionPresentation(
            action: .readWebPage,
            signals: fallbackResultSignals,
            isSearchName: isSearchName,
            isReadName: isReadName
        ) {
            return read
        }

        if isReadName {
            if input.argsObject.map(containsInvalidLocalTarget) == true || input.resultObject.map(containsInvalidLocalTarget) == true {
                return nil
            }
            return readWebPage(target: nil)
        }

        return webSearch(query: argsSignals?.query ?? fallbackResultSignals?.query)
    }

    private static func actionPresentation(
        action: AgentWebToolActionPresentation.Action,
        signals: PayloadSignals?,
        isSearchName: Bool,
        isReadName: Bool
    ) -> AgentWebToolActionPresentation? {
        guard let signals else { return nil }
        switch action {
        case .findInPage:
            guard let target = signals.target,
                  signals.findText != nil || signals.hasFindOperation
            else { return nil }
            return findInPage(target: target, findText: signals.findText)
        case .readWebPage:
            guard let target = signals.target else { return nil }
            if case .result = signals.source,
               !isReadName,
               !signals.hasReadOperation,
               !signals.hasFindOperation
            {
                return nil
            }
            if isSearchName,
               signals.hasQuery,
               !signals.hasReadOperation,
               !signals.hasFindOperation,
               !isReadName
            {
                return nil
            }
            if isReadName || signals.hasReadOperation || signals.hasFindOperation || targetIsURL(target) {
                return readWebPage(target: target)
            }
            return nil
        case .webSearch:
            return nil
        }
    }

    private static func payloadSignals(
        from object: [String: Any],
        source: PayloadSource,
        isSupportedWebName: Bool
    ) -> PayloadSignals {
        let objects = boundedPayloadObjects(from: object)
        let operation = firstString(in: objects, keys: AgentWebToolPayloadKeys.operationKeys)?.lowercased()
        let hasFindOperation = operation == "find"
        let hasReadOperation = ["read", "open", "fetch", "get", "retrieve"].contains(operation ?? "")
        let findText = firstString(in: objects, keys: AgentWebToolPayloadKeys.findKeys)
        let query = firstString(in: objects, keys: AgentWebToolPayloadKeys.legacySearchQueryKeys)
        let target = firstTarget(
            in: objects,
            isSupportedWebName: isSupportedWebName,
            hasExplicitWebAction: hasFindOperation || hasReadOperation
        )
        return PayloadSignals(
            source: source,
            target: target,
            findText: findText,
            hasFindOperation: hasFindOperation,
            hasReadOperation: hasReadOperation,
            hasQuery: query != nil,
            query: query
        )
    }

    private static func boundedPayloadObjects(from object: [String: Any]) -> [[String: Any]] {
        var objects = [object]
        for key in AgentWebToolPayloadKeys.wrapperKeys {
            if let nested = object[key] as? [String: Any] {
                objects.append(nested)
            }
        }
        return objects
    }

    private static func containsInvalidLocalTarget(in object: [String: Any]) -> Bool {
        boundedPayloadObjects(from: object).contains { payload in
            guard let rawURL = firstString(in: [payload], keys: AgentWebToolPayloadKeys.urlTargetKeys) else { return false }
            return compactWebURLSubtitle(rawURL) == nil && isLocalOrInternalTarget(rawURL)
        }
    }

    private static func firstTarget(
        in objects: [[String: Any]],
        isSupportedWebName: Bool,
        hasExplicitWebAction: Bool
    ) -> Target? {
        for object in objects {
            if let rawURL = firstString(in: [object], keys: AgentWebToolPayloadKeys.urlTargetKeys) {
                if let subtitle = compactWebURLSubtitle(rawURL) {
                    return .url(rawURL, subtitle: subtitle)
                }
                if isLocalOrInternalTarget(rawURL) {
                    continue
                }
            }
        }
        guard isSupportedWebName || hasExplicitWebAction else { return nil }
        for object in objects {
            if let ref = firstString(in: [object], keys: AgentWebToolPayloadKeys.refTargetKeys) {
                return .ref(ref, subtitle: compactRefSubtitle(ref))
            }
        }
        return nil
    }

    private static func firstString(in objects: [[String: Any]], keys: [String]) -> String? {
        for object in objects {
            for key in keys {
                guard let value = object[key] else { continue }
                if let string = stringValue(value) { return string }
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            let text = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func webSearch(query: String?) -> AgentWebToolActionPresentation {
        AgentWebToolActionPresentation(
            action: .webSearch,
            title: "Web Search",
            subtitle: query.map { "\"\(compactText($0, maxLength: 80))\"" },
            op: "search"
        )
    }

    private static func readWebPage(target: Target?) -> AgentWebToolActionPresentation {
        AgentWebToolActionPresentation(
            action: .readWebPage,
            title: "Read Web Page",
            subtitle: target?.subtitle,
            op: "read_web_page"
        )
    }

    private static func findInPage(target: Target, findText: String?) -> AgentWebToolActionPresentation {
        let compactFind = findText.map { compactText($0, maxLength: 48) }
        let subtitle = [target.subtitle, compactFind.map { "\"\($0)\"" }]
            .compactMap(\.self)
            .joined(separator: " • ")
        return AgentWebToolActionPresentation(
            action: .findInPage,
            title: "Find In Page",
            subtitle: subtitle.isEmpty ? target.subtitle : subtitle,
            op: "find_in_page"
        )
    }

    private static func targetIsURL(_ target: Target) -> Bool {
        if case .url = target { return true }
        return false
    }

    private static func compactWebURLSubtitle(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty
        else { return nil }
        var authority = host
        if let port = components.port,
           !(scheme == "http" && port == 80),
           !(scheme == "https" && port == 443)
        {
            authority += ":\(port)"
        }
        let pathComponents = (components.percentEncodedPath.removingPercentEncoding ?? components.path)
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        let text: String = switch pathComponents.count {
        case 0:
            authority
        case 1, 2:
            ([authority] + pathComponents).joined(separator: "/")
        default:
            "\(authority)/…/\(pathComponents.last ?? "")"
        }
        return compactMiddle(text, maxLength: 80)
    }

    private static func compactRefSubtitle(_ raw: String) -> String {
        let ref = compactMiddle(raw, maxLength: 28)
        return "ref \(ref)"
    }

    private static func isLocalOrInternalTarget(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("file:") || trimmed.hasPrefix("repoprompt:") || trimmed.hasPrefix("mcp:") { return true }
        if raw.hasPrefix("/") || raw.hasPrefix("~") || raw.hasPrefix("./") || raw.hasPrefix("../") { return true }
        return false
    }

    private static func compactText(_ raw: String, maxLength: Int) -> String {
        var output = ""
        output.reserveCapacity(min(raw.count, maxLength + 8))
        var lastWasWhitespace = true
        for scalar in raw.unicodeScalars {
            if compactTextSeparators.contains(scalar) {
                if !lastWasWhitespace, !output.isEmpty {
                    output.append(" ")
                    lastWasWhitespace = true
                }
            } else {
                output.unicodeScalars.append(scalar)
                lastWasWhitespace = false
            }
            if output.count > maxLength * 2 { break }
        }
        return compactMiddle(output.trimmingCharacters(in: .whitespacesAndNewlines), maxLength: maxLength)
    }

    private static func compactMiddle(_ raw: String, maxLength: Int) -> String {
        guard raw.count > maxLength, maxLength > 3 else { return raw }
        let sideLength = max((maxLength - 1) / 2, 1)
        let suffixLength = maxLength - sideLength - 1
        return "\(raw.prefix(sideLength))…\(raw.suffix(suffixLength))"
    }
}
