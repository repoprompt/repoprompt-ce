import SwiftUI

/// Passive OpenCode effort-pin renderer shared by the Settings, popover and Context Builder
/// surfaces.
///
/// It renders whenever there is something honest to show: usable discovery metadata
/// (`definition != nil`) **or** a saved pin (`pinnedValueRaw != nil`). It never invents
/// choices, never presents a provider default as if it were a saved pin, and never hides a
/// saved pin just because its metadata is currently unavailable.
struct ACPModelParameterPinChip: View {
    /// The `.thinking` definition from a live observation, or nil when metadata is loading,
    /// failed, unusable, or the target does not resolve.
    let definition: ACPModelParameterDefinition?
    /// The saved pin value verbatim, or nil for "not pinned".
    let pinnedValueRaw: String?
    let isEnabled: Bool
    /// Receives the advertised `configID` and the chosen raw value, or nil to clear the pin.
    /// The configID comes from the live definition — never assumed to be `"effort"` — so a
    /// saved pin round-trips the provider's actual selector key.
    let onSelect: (_ configID: String, _ valueRaw: String?) -> Void

    @ObservedObject private var fontScale = FontScaleManager.shared

    private var fontPreset: FontScalePreset {
        fontScale.preset
    }

    private var pinnedChoice: ACPModelParameterChoice? {
        guard let pinnedValueRaw else { return nil }
        return definition?.choice(matching: pinnedValueRaw)
    }

    /// The label is the pinned choice's display name when available, else the saved raw value
    /// verbatim. Never substituted with the advertised current value.
    private var label: String {
        guard let pinnedValueRaw else { return "Default" }
        return pinnedChoice?.displayName ?? pinnedValueRaw
    }

    /// Honest rule: warn only when we have a live definition and the saved value is absent from
    /// its choices (a level later disabled in `opencode.json`). While metadata is loading or
    /// unavailable (`definition == nil`) the saved pin is shown plainly — never a false warning.
    private var isSavedPinUnavailable: Bool {
        guard let pinnedValueRaw, let definition else { return false }
        return definition.choice(matching: pinnedValueRaw) == nil
    }

    private var tooltip: String {
        if isSavedPinUnavailable {
            return "Saved thinking level \"\(label)\" is not currently advertised for this model."
        }
        return definition?.displayName ?? "Thinking level"
    }

    var body: some View {
        Menu {
            // "Not pinned" is a first-class state: choosing it clears the pin.
            Button {
                onSelect(definition?.configID ?? "", nil)
            } label: {
                HStack {
                    Text("Default")
                    if pinnedValueRaw == nil {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
            if let definition {
                // Every advertised choice renders, including a single-choice menu.
                ForEach(definition.choices, id: \.rawValue) { choice in
                    Button {
                        onSelect(definition.configID, choice.rawValue)
                    } label: {
                        HStack {
                            Text(choice.displayName)
                            if choice.rawValue == pinnedValueRaw {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Text(label)
                .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                .foregroundColor(isSavedPinUnavailable ? .orange : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        }
        .menuStyle(.borderlessButton)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1.0 : 0.55)
        .hoverTooltip(tooltip)
        .fixedSize()
    }
}
