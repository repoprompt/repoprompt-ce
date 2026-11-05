import Foundation
import RepoPromptAgentProviderContracts

struct ClaudeModelSpecifier: Equatable {
    let baseModel: String?
    let effortLevel: ClaudeCodeEffortLevel?

    init(raw: String?) {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            baseModel = nil
            effortLevel = nil
            return
        }

        if trimmed.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame {
            baseModel = nil
            effortLevel = nil
            return
        }

        if let colonIndex = trimmed.lastIndex(of: ":") {
            let prefix = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(trimmed[trimmed.index(after: colonIndex)...])
            if !prefix.isEmpty, let effort = ClaudeCodeEffortLevel.parse(suffix) {
                baseModel = prefix.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame
                    ? nil
                    : prefix
                effortLevel = effort
                return
            }
        }

        baseModel = trimmed
        effortLevel = nil
    }

    init(baseModel: String?, effortLevel: ClaudeCodeEffortLevel?) {
        let trimmedBase = baseModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedBase, !trimmedBase.isEmpty,
           trimmedBase.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        {
            self.baseModel = trimmedBase
        } else {
            self.baseModel = nil
        }
        self.effortLevel = effortLevel
    }

    static func encodedRaw(baseModelRaw: String, effort: ClaudeCodeEffortLevel) -> String {
        let trimmedBase = baseModelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmedBase.isEmpty ? AgentModel.defaultModel.rawValue : trimmedBase
        return "\(base):\(effort.rawValue)"
    }

    var runtimeModelParam: String? {
        guard let baseModel = baseModel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !baseModel.isEmpty,
              baseModel.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else {
            return nil
        }
        return baseModel
    }

    var explicitEffortLevel: ClaudeCodeEffortLevel? {
        effortLevel
    }
}
