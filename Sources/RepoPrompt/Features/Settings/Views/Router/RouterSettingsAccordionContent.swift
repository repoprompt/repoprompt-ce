import SwiftUI

/// Presents Router Settings disclosure content with native SwiftUI transitions.
struct RouterSettingsAccordionContent<Content: View>: View {
    let isExpanded: Bool
    private let content: () -> Content

    init(
        isExpanded: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        Group {
            if isExpanded {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}
