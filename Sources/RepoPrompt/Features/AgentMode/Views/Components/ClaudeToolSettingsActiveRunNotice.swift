import SwiftUI

struct ClaudeToolSettingsActiveRunNotice: View {
    let isVisible: Bool
    let fontPreset: FontScalePreset

    var body: some View {
        if isVisible {
            Section {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                    Text("Claude tool setting changes apply to the next Claude turn")
                        .font(fontPreset.captionFont)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
