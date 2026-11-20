import SwiftUI

/// Reserves an indicator row's full width and height whether or not the indicator is shown, and
/// builds the indicator only while it is shown.
///
/// Hiding the indicator with `.opacity(0)` instead would keep a native indeterminate `ProgressView`
/// and its Core Animation layer animation alive in every idle window. That animation drives no
/// frames itself, but every commit another window's animation drives then has to walk it, even
/// while this window is miniaturized. The reserved frame keeps the transcript from jumping when
/// the indicator appears or disappears.
struct AgentReservedIndicatorSlot<Content: View>: View {
    let isShown: Bool
    let reservedHeight: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .leading) {
            if isShown {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: reservedHeight, alignment: .leading)
        .allowsHitTesting(isShown)
        .accessibilityHidden(!isShown)
    }
}
