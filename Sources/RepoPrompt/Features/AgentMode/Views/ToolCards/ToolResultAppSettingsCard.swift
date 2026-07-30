import Foundation
import SwiftUI

struct AppSettingsCardPresentation: Equatable {
    let subtitle: String?
    let detailText: String?
    let status: ToolCardStatus
}

enum AppSettingsCardPresentationBuilder {
    static func callSubtitle(argsJSON: String?) -> String? {
        guard let args = ToolRawJSON.object(from: argsJSON) else { return nil }
        let op = normalizedOp(string(args, key: "op")) ?? "app_settings"
        switch op {
        case "list":
            return listCallSubtitle(args: args)
        case "get":
            return getCallSubtitle(args: args)
        case "set":
            return setCallSubtitle(args: args)
        default:
            return op
        }
    }

    static func build(argsJSON: String?, resultJSON: String?, toolIsError: Bool?) -> AppSettingsCardPresentation {
        let args = ToolRawJSON.object(from: argsJSON)
        let preferredResultJSON = ToolJSON.preferredStructuredResultJSON(from: resultJSON)
        let result = resultObject(from: resultJSON, preferredResultJSON: preferredResultJSON)
        let op = normalizedOp(string(result, key: "op"))
            ?? normalizedOp(string(args, key: "op"))
            ?? "app_settings"
        let status = ToolResultStatusResolver.resolve(toolIsError: toolIsError, raw: preferredResultJSON ?? resultJSON, fallback: result == nil ? .neutral : .success)

        if toolIsError == true || status == .failure {
            return AppSettingsCardPresentation(
                subtitle: callSubtitle(argsJSON: argsJSON) ?? op,
                detailText: errorDetail(result: result),
                status: .failure
            )
        }

        switch op {
        case "list":
            return listResultPresentation(args: args, result: result, status: status)
        case "get":
            return getResultPresentation(args: args, result: result, status: status)
        case "set":
            return setResultPresentation(args: args, result: result, status: status)
        default:
            return AppSettingsCardPresentation(subtitle: op, detailText: nil, status: status)
        }
    }

    private static func resultObject(from raw: String?, preferredResultJSON: String?) -> [String: Any]? {
        if let object = ToolRawJSON.object(from: preferredResultJSON) {
            return object
        }
        return ToolRawJSON.object(from: raw)
    }

    private static func listCallSubtitle(args: [String: Any]) -> String {
        var parts = ["list"]
        if let group = trimmed(string(args, key: "group")) {
            parts.append(group)
        }
        return parts.joined(separator: " • ")
    }

    private static func getCallSubtitle(args: [String: Any]) -> String {
        var parts = ["get"]
        if let key = trimmed(string(args, key: "key")) {
            parts.append(key)
        } else if let keys = stringArray(args["keys"]), !keys.isEmpty {
            parts.append(keysPreview(keys, label: "keys"))
        } else if let group = trimmed(string(args, key: "group")) {
            parts.append(group)
        }
        return parts.joined(separator: " • ")
    }

    private static func setCallSubtitle(args: [String: Any]) -> String {
        var parts = ["set"]
        if let key = trimmed(string(args, key: "key")) {
            if let value = args["value"] {
                parts.append("\(key) = \(valueSummary(value, maxChars: 24))")
            } else {
                parts.append(key)
            }
        }
        return parts.joined(separator: " • ")
    }

    private static func listResultPresentation(args: [String: Any]?, result: [String: Any]?, status: ToolCardStatus) -> AppSettingsCardPresentation {
        var parts = ["list"]
        if let group = trimmed(string(args, key: "group")) ?? inferredGroup(result?["settings"] as? [Any]) {
            parts.append(group)
        }
        if let count = int(result, key: "count") {
            parts.append("\(count) setting\(count == 1 ? "" : "s")")
        }
        return AppSettingsCardPresentation(
            subtitle: parts.joined(separator: " • "),
            detailText: settingsPreview(result?["settings"] as? [Any]),
            status: status
        )
    }

    private static func getResultPresentation(args: [String: Any]?, result: [String: Any]?, status: ToolCardStatus) -> AppSettingsCardPresentation {
        guard let values = result?["values"] as? [String: Any], !values.isEmpty else {
            return AppSettingsCardPresentation(subtitle: args.flatMap { getCallSubtitle(args: $0) } ?? "get", detailText: nil, status: status)
        }
        let sortedKeys = values.keys.sorted()
        if sortedKeys.count == 1, let key = sortedKeys.first, let value = values[key] {
            return AppSettingsCardPresentation(subtitle: "get • \(key) = \(valueSummary(value, maxChars: 24))", detailText: nil, status: status)
        }
        var subtitleParts = ["get"]
        if let group = args.flatMap({ trimmed(ToolRawJSON.string($0, key: "group")) }) {
            subtitleParts.append(group)
        }
        subtitleParts.append("\(sortedKeys.count) values")
        return AppSettingsCardPresentation(
            subtitle: subtitleParts.joined(separator: " • "),
            detailText: keysPreview(sortedKeys, label: "values"),
            status: status
        )
    }

    private static func setResultPresentation(args: [String: Any]?, result: [String: Any]?, status: ToolCardStatus) -> AppSettingsCardPresentation {
        let key = trimmed(string(result, key: "key"))
            ?? args.flatMap { trimmed(ToolRawJSON.string($0, key: "key")) }
        let changed = bool(result, key: "changed")
        let applied = bool(result, key: "applied")
        let notApplied = changed == true && applied == false
        var parts = ["set"]
        if let key {
            parts.append(key)
        }
        if let changed {
            parts.append(changed ? "changed" : "unchanged")
        }
        if notApplied {
            parts.append("not applied")
        }

        return AppSettingsCardPresentation(
            subtitle: parts.joined(separator: " • "),
            detailText: setValueDetail(result: result, args: args, changed: changed, notApplied: notApplied),
            status: notApplied ? .warning : status
        )
    }

    private static func setValueDetail(result: [String: Any]?, args: [String: Any]?, changed: Bool?, notApplied: Bool = false) -> String? {
        var detail: String?
        if let oldValue = result?["old_value"], let newValue = result?["new_value"] {
            if changed == true {
                detail = "\(valueSummary(oldValue, maxChars: 24)) → \(valueSummary(newValue, maxChars: 24))"
            } else {
                detail = "new value: \(valueSummary(newValue, maxChars: 24))"
            }
        } else if let requestedValue = args?["value"] {
            detail = "value: \(valueSummary(requestedValue, maxChars: 24))"
        }
        var suffixes: [String] = []
        if notApplied {
            suffixes.append("change not applied")
        }
        if let sideEffect = AppSettingValueFormatter.sideEffectLabel(string(result, key: "side_effect")) {
            suffixes.append(sideEffect)
        }
        guard !suffixes.isEmpty else { return detail }
        if let detail, !detail.isEmpty {
            return "\(detail) • \(suffixes.joined(separator: " • "))"
        }
        return suffixes.joined(separator: " • ")
    }

    private static func errorDetail(result: [String: Any]?) -> String? {
        trimmed(string(result, key: "error"))
            ?? trimmed(string(result, key: "message"))
            ?? contentText(result)
    }

    private static func settingsPreview(_ settings: [Any]?) -> String? {
        guard let settings, !settings.isEmpty else { return nil }
        let keys = settings.compactMap { setting -> String? in
            guard let object = setting as? [String: Any] else { return nil }
            return trimmed(ToolRawJSON.string(object, key: "key"))
        }
        guard !keys.isEmpty else { return nil }
        return keysPreview(keys, label: "settings")
    }

    private static func inferredGroup(_ settings: [Any]?) -> String? {
        guard let settings else { return nil }
        let groups = Set(settings.compactMap { setting -> String? in
            guard let object = setting as? [String: Any] else { return nil }
            return trimmed(ToolRawJSON.string(object, key: "group"))
        })
        return groups.count == 1 ? groups.first : nil
    }

    private static func contentText(_ result: [String: Any]?) -> String? {
        guard let content = result?["content"] as? [Any] else { return nil }
        let parts = content.compactMap { element -> String? in
            guard let object = element as? [String: Any] else { return nil }
            if let type = object["type"] as? String, type.lowercased() != "text" {
                return nil
            }
            return trimmed(object["text"] as? String)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func keysPreview(_ keys: [String], label: String) -> String {
        let trimmedKeys = keys.compactMap(trimmed)
        guard !trimmedKeys.isEmpty else { return "0 \(label)" }
        let visible = trimmedKeys.prefix(3).joined(separator: ", ")
        let omitted = trimmedKeys.count - min(trimmedKeys.count, 3)
        return omitted > 0 ? "\(visible) (+\(omitted) more)" : visible
    }

    private static func string(_ object: [String: Any]?, key: String) -> String? {
        guard let object else { return nil }
        return ToolRawJSON.string(object, key: key)
    }

    private static func bool(_ object: [String: Any]?, key: String) -> Bool? {
        guard let object else { return nil }
        return ToolRawJSON.bool(object, key: key)
    }

    private static func int(_ object: [String: Any]?, key: String) -> Int? {
        guard let object else { return nil }
        return ToolRawJSON.int(object, key: key)
    }

    private static func stringArray(_ value: Any?) -> [String]? {
        (value as? [Any])?.compactMap { element in
            if let string = element as? String {
                return trimmed(string)
            }
            if let number = element as? NSNumber {
                return trimmed(number.stringValue)
            }
            return nil
        }
    }

    private static func normalizedOp(_ raw: String?) -> String? {
        guard let op = trimmed(raw)?.lowercased(), !op.isEmpty else { return nil }
        return op
    }

    private static func trimmed(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func valueSummary(_ value: Any, maxChars: Int) -> String {
        AppSettingValueFormatter.summaryForSubtitle(value, maxChars: maxChars)
    }
}

struct AppSettingsResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var presentation: AppSettingsCardPresentation {
        AppSettingsCardPresentationBuilder.build(
            argsJSON: item.toolArgsJSON,
            resultJSON: item.toolResultJSON,
            toolIsError: item.toolIsError
        )
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: "App Settings",
            detailText: nil,
            subtitle: inlineToolCardSummary(presentation.subtitle, presentation.detailText),
            status: presentation.status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}
