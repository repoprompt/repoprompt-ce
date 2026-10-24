import Foundation

/// A structured Grok Build model selection: base model id plus optional reasoning effort.
///
/// Compound raw values follow the Codex suffix convention: `grok-4.6-low` is the base model
/// `grok-4.6` at `.low` effort. Compound raws are ONLY ever produced by the SessionModelState
/// parser's variant synthesis and are decomposed against the advertised option set — raw
/// strings are never re-parsed by suffix guessing at lower layers, so a future Grok model
/// whose id ends in an effort token (`…-high`) stays selectable as that base.
///
/// Wire contract (live-verified against grok 1.0.4): `availableModels[].\_meta` carries
/// `supportsReasoningEffort`, `reasoningEffort` (per-model default), and `reasoningEfforts`
/// ([{id, value, label, description, default}]). Effort rides `session/set_model` via
/// `_meta.reasoningEffort`; unknown efforts are silently ignored by the server, so callers
/// must validate against the advertised per-model list before sending.
struct GrokBuildModelSpecifier: Equatable {
    let baseModel: String
    let reasoningEffort: CodexReasoningEffort?

    var compoundRaw: String {
        guard let reasoningEffort else { return baseModel }
        return "\(baseModel)-\(reasoningEffort.rawValue)"
    }

    /// Resolves the effort to send on the wire: the explicit selection, or the model's
    /// advertised default when the selection is bare.
    func resolvedEffort(defaultEffort: CodexReasoningEffort?) -> CodexReasoningEffort? {
        reasoningEffort ?? defaultEffort
    }

    /// Decomposes a snapshot member into its base option and explicit effort, using the
    /// variant provenance recorded at synthesis time (`AgentModelOption.effortVariant`) —
    /// raw strings are never re-parsed by suffix guessing, so an advertised base whose id
    /// ends in an effort token stays selectable as that base. Returns nil when `raw`
    /// matches no option, or when a variant's recorded base is absent from the snapshot.
    static func decompose(
        raw: String,
        options: [AgentModelOption]
    ) -> (base: AgentModelOption, explicitEffort: CodexReasoningEffort?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let matched = options.first(where: {
            $0.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame
        }) else { return nil }
        guard let variant = matched.effortVariant else {
            return (matched, nil)
        }
        guard let base = options.first(where: {
            $0.rawValue.caseInsensitiveCompare(variant.baseModelRaw) == .orderedSame
        }) else { return nil }
        return (base, variant.reasoningEffort)
    }
}
