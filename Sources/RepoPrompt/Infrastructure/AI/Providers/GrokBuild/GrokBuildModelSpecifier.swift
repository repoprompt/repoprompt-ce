import Foundation

/// Splits a Grok Build model selection into its base model id and optional reasoning effort.
///
/// Compound raw values follow the Codex suffix convention: `grok-4.6-low` is the base model
/// `grok-4.6` at `.low` effort. Bare raws (`grok-4.6`) carry no effort and resolve to the
/// provider default. Suffix stripping is deliberately conservative: a raw that matches a
/// discovered model id exactly is always treated as that model, so a future Grok model whose
/// id ends in an effort token (`…-high`) can never be misparsed.
///
/// Wire contract (live-verified against grok 1.0.4): `availableModels[].\_meta` carries
/// `supportsReasoningEffort`, `reasoningEffort` (current/default), and `reasoningEfforts`
/// ([{id, value, label, description, default}]). Effort rides `session/set_model` via
/// `_meta.reasoningEffort`; unknown efforts are silently ignored by the server, so callers
/// must validate against the advertised per-model list before sending.
struct GrokBuildModelSpecifier: Equatable {
    let baseModel: String
    let reasoningEffort: CodexReasoningEffort?

    init(baseModel: String, reasoningEffort: CodexReasoningEffort?) {
        self.baseModel = baseModel
        self.reasoningEffort = reasoningEffort
    }

    init(raw: String, knownBaseModels: Set<String> = []) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let exactBase = knownBaseModels.first {
            $0.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if let exactBase {
            self.init(baseModel: exactBase, reasoningEffort: nil)
            return
        }
        // Longest suffix first so `-xhigh` wins over `-high`.
        for suffix in ["-xhigh", "-medium", "-high", "-low"] {
            guard trimmed.lowercased().hasSuffix(suffix),
                  trimmed.count > suffix.count
            else { continue }
            let base = String(trimmed.dropLast(suffix.count))
            guard let effort = CodexReasoningEffort.parse(String(suffix.dropFirst())) else { continue }
            self.init(baseModel: base, reasoningEffort: effort)
            return
        }
        self.init(baseModel: trimmed, reasoningEffort: nil)
    }

    var compoundRaw: String {
        guard let reasoningEffort else { return baseModel }
        return "\(baseModel)-\(reasoningEffort.rawValue)"
    }

    /// Resolves the effort to send on the wire: the explicit selection, or the model's
    /// advertised default when the selection is bare.
    func resolvedEffort(defaultEffort: CodexReasoningEffort?) -> CodexReasoningEffort? {
        reasoningEffort ?? defaultEffort
    }
}
