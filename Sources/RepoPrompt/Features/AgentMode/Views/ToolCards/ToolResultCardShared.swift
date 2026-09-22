import Foundation

func toolResultHasPayload(_ item: AgentChatItem) -> Bool {
    guard let raw = item.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines) else {
        return false
    }
    guard !raw.isEmpty else { return false }
    if let object = ToolJSON.rawObject(from: item.toolResultJSON),
       ToolRawJSON.bool(object, key: "summary_only") == true
    {
        return false
    }
    return true
}

func toolResultIsSummaryOnly(_ item: AgentChatItem) -> Bool {
    guard let object = ToolJSON.rawObject(from: item.toolResultJSON) else {
        return false
    }
    return ToolRawJSON.bool(object, key: "summary_only") == true
}

func inlineToolCardSummary(_ primary: String?, _ secondary: String?) -> String? {
    let parts = [primary, secondary]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " • ")
}

struct StoredToolCardPresentation: Equatable {
    let title: String?
    let subtitle: String?
    let detailText: String?
    let status: ToolCardStatus?

    var inlineSubtitle: String? {
        inlineToolCardSummary(subtitle, detailText)
    }

    static func fromSummaryOnly(raw: String?) -> StoredToolCardPresentation? {
        guard let object = ToolJSON.rawObject(from: raw),
              ToolRawJSON.bool(object, key: "summary_only") == true
        else {
            return nil
        }
        let legacyFallback = legacyFallback(from: object, raw: raw)
        if let renderSummary = AgentToolCardRenderSummary(summaryOnlyObject: object) {
            let renderStatus = ToolCardStatus.fromRenderStatus(renderSummary.status)
            if renderSummary.inlineSummaryText != nil {
                return StoredToolCardPresentation(
                    title: renderSummary.title,
                    subtitle: renderSummary.subtitle,
                    detailText: renderSummary.detailText,
                    status: renderStatus
                )
            }
            if let legacyFallback {
                return StoredToolCardPresentation(
                    title: renderSummary.title,
                    subtitle: legacyFallback.subtitle,
                    detailText: legacyFallback.detailText,
                    status: renderStatus
                )
            }
            return StoredToolCardPresentation(
                title: renderSummary.title,
                subtitle: nil,
                detailText: nil,
                status: renderStatus
            )
        }
        return legacyFallback
    }

    private static func legacyFallback(from object: [String: Any], raw: String?) -> StoredToolCardPresentation? {
        if let summaryText = ToolRawJSON.string(object, key: "summary_text")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summaryText.isEmpty
        {
            return StoredToolCardPresentation(
                title: nil,
                subtitle: summaryText,
                detailText: nil,
                status: ToolResultStatusResolver.resolve(toolIsError: nil, raw: raw, fallback: .neutral)
            )
        }
        if let summaryText = ToolRawJSON.string(object, key: "summaryText")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summaryText.isEmpty
        {
            return StoredToolCardPresentation(
                title: nil,
                subtitle: summaryText,
                detailText: nil,
                status: ToolResultStatusResolver.resolve(toolIsError: nil, raw: raw, fallback: .neutral)
            )
        }
        if let status = ToolRawJSON.string(object, key: "status")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !status.isEmpty
        {
            return StoredToolCardPresentation(
                title: nil,
                subtitle: status,
                detailText: nil,
                status: ToolResultStatusResolver.resolve(toolIsError: nil, raw: raw, fallback: .neutral)
            )
        }
        return nil
    }
}

extension ToolCardStatus {
    static func fromRenderStatus(_ status: AgentToolCardRenderStatus) -> ToolCardStatus {
        switch status {
        case .neutral:
            .neutral
        case .success:
            .success
        case .warning:
            .warning
        case .failure:
            .failure
        case .running:
            .running
        }
    }
}

func storageStatusSubtitle(for item: AgentChatItem) -> String? {
    guard let object = ToolJSON.rawObject(from: item.toolResultJSON),
          ToolRawJSON.bool(object, key: "summary_only") == true
    else {
        return nil
    }
    if let inlineSubtitle = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON)?.inlineSubtitle {
        return inlineSubtitle
    }
    if let summaryText = ToolRawJSON.string(object, key: "summary_text")?.trimmingCharacters(in: .whitespacesAndNewlines),
       !summaryText.isEmpty
    {
        return summaryText
    }
    if let summaryText = ToolRawJSON.string(object, key: "summaryText")?.trimmingCharacters(in: .whitespacesAndNewlines),
       !summaryText.isEmpty
    {
        return summaryText
    }
    guard let status = ToolRawJSON.string(object, key: "status")?.trimmingCharacters(in: .whitespacesAndNewlines),
          !status.isEmpty
    else {
        return nil
    }
    return status
}

func nonEmptyToolCardSummary(_ summary: String?, fallbackStatusFor item: AgentChatItem) -> String? {
    if let summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
        return summary
    }
    return storageStatusSubtitle(for: item)
}
