import SwiftUI

/// The probe context a chip host resolves for its target. `.resolved(nil)` builds the
/// legitimate nil-workspace key; `.unavailable` yields no key — no subscription and no
/// actionable chip. A throwing resolution would collapse these two, so hosts pass the value
/// instead of a closure.
enum ACPModelParameterProbeContext: Equatable {
    case resolved(String?)
    case unavailable
}

/// Owns the demand-scoped discovery lifetime for one OpenCode effort chip and renders
/// `ACPModelParameterPinChip`. It owns *nothing else*: saved state and write authority stay with
/// the host, which supplies the saved pin, the probe context, and a guarded write closure.
///
/// Discovery uses `.task(id:)`, which SwiftUI cancels on view teardown **and** on identity
/// change. Because the identity is the canonical key — which contains the workspace — a
/// workspace switch restarts the probe structurally instead of needing a separate observer or a
/// path provider. Ordinary re-renders don't restart it (same key).
struct ACPModelParameterProbeView: View {
    /// The displayed model this chip probes and writes against.
    let modelRaw: String
    let providerID: ACPProviderID
    let probeContext: ACPModelParameterProbeContext
    /// The saved pin value, read from the same profile snapshot the host renders.
    let pinnedValueRaw: String?
    let isEnabled: Bool
    /// Re-checks live host state and performs the atomic write. Receives the advertised
    /// `configID` (never assumed to be `"effort"`) and the chosen value, or nil to clear.
    let onSelect: (_ configID: String, _ valueRaw: String?) -> Void

    @State private var snapshot: OpenCodeACPModelParameterSnapshot?

    init(
        modelRaw: String,
        providerID: ACPProviderID,
        probeContext: ACPModelParameterProbeContext,
        pinnedValueRaw: String?,
        isEnabled: Bool = true,
        onSelect: @escaping (_ configID: String, _ valueRaw: String?) -> Void
    ) {
        self.modelRaw = modelRaw
        self.providerID = providerID
        self.probeContext = probeContext
        self.pinnedValueRaw = pinnedValueRaw
        self.isEnabled = isEnabled
        self.onSelect = onSelect
    }

    /// The model actually probed: trimmed, or nil when there is nothing to acquire.
    private var probedModelRaw: String? {
        guard providerID == .openCode else { return nil }
        let trimmed = modelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The canonical discovery key for the current target, or nil when there is nothing to
    /// acquire (non-OpenCode provider, empty model, or an unresolved workspace).
    private var probeKey: OpenCodeACPModelParameterKey? {
        guard let probedModelRaw else { return nil }
        switch probeContext {
        case .unavailable:
            return nil
        case let .resolved(workspacePath):
            return OpenCodeACPModelParameterKey(workspacePath: workspacePath, modelRaw: probedModelRaw)
        }
    }

    private var definition: ACPModelParameterDefinition? {
        guard let snapshot, snapshot.key == probeKey,
              case let .available(parameterSet) = snapshot.state
        else { return nil }
        return parameterSet.definition(kind: .thinking)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Always-present zero-size host for the discovery task.
            //
            // The task CANNOT hang off the chip's own conditional. With no saved pin and no
            // metadata yet, that conditional collapses to nil content, which SwiftUI gives no
            // render node — `.task` is then never scheduled, so the chip can never acquire the
            // metadata that would make it appear. Verified in isolation: `.task` on a `Group`
            // wrapping nil content does not fire, while this zero-size host does.
            Color.clear
                .frame(width: 0, height: 0)
                .task(id: probeKey) {
                    snapshot = nil
                    guard let probeKey, let probedModelRaw else { return }
                    let stream = await OpenCodeACPModelPollingService.shared.subscribeModelParameters(
                        workspacePath: probeKey.workspacePath,
                        modelRaw: probedModelRaw
                    )
                    for await delivered in stream {
                        // Cancellation is checked explicitly: a cancelled task's body still runs
                        // to its next suspension, so an in-flight delivery could otherwise land
                        // after the target changed and stick until the next remount.
                        guard !Task.isCancelled else { return }
                        // Canonical-key identity, not raw spellings: a foreign or stale delivery
                        // is skipped, never allowed to overwrite this target's held observation.
                        guard delivered.key == probeKey else { continue }
                        guard !Task.isCancelled else { return }
                        snapshot = delivered
                    }
                }

            if definition != nil || pinnedValueRaw != nil {
                ACPModelParameterPinChip(
                    definition: definition,
                    pinnedValueRaw: pinnedValueRaw,
                    isEnabled: isEnabled,
                    onSelect: onSelect
                )
            }
        }
    }
}
