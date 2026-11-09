import Foundation

enum CodexContextWindowPreferences {
    enum Selection: String, CaseIterable {
        case codexDefault = "default"
        case tokens500K = "500000"
        case tokens600K = "600000"
        case tokens700K = "700000"
        case tokens800K = "800000"
        case tokens900K = "900000"
        case tokens1M = "1000000"

        var tokens: Int? {
            Int(rawValue)
        }

        var label: String {
            switch self {
            case .codexDefault: "Codex default"
            case .tokens500K: "500K tokens"
            case .tokens600K: "600K tokens"
            case .tokens700K: "700K tokens"
            case .tokens800K: "800K tokens"
            case .tokens900K: "900K tokens"
            case .tokens1M: "1M tokens"
            }
        }
    }

    private static let key = "codexContextWindowSelection"

    static func selection(defaults: UserDefaults = .standard) -> Selection {
        let raw = defaults.string(forKey: key)
        if raw == "750000" { return .tokens800K }
        return raw.flatMap(Selection.init(rawValue:)) ?? .codexDefault
    }

    static func setSelection(_ selection: Selection, defaults: UserDefaults = .standard) {
        if selection == .codexDefault {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(selection.rawValue, forKey: key)
        }
    }

    static func cliArguments(_ selection: Selection) -> [String] {
        overrides(selection).sorted { $0.key < $1.key }.flatMap { ["-c", "\($0.key)=\($0.value)"] }
    }

    static func overrides(_ selection: Selection) -> [String: Int] {
        guard let tokens = selection.tokens else { return [:] }
        return ["model_context_window": tokens, "model_auto_compact_token_limit": tokens * 9 / 10]
    }
}
