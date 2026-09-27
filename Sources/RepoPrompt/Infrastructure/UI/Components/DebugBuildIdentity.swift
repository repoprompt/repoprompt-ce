import SwiftUI

/// DEBUG-only in-window identity for RepoPrompt CE debug builds.
///
/// The debug bundle already differs from production in the Dock and Finder (display name,
/// bundle identifier, `AppBundle/AppIconDebug.icns`), but its windows were visually identical,
/// which made it easy to type into the wrong app's Agent session when both were running.
/// These cues reuse the debug icon's blue "DEBUG" badge color so the window chrome matches the
/// Dock identity, while leaving transcript, code, and syntax colors untouched.
///
/// Every view-level cue is compiled out of release builds, so production chrome is unchanged.
enum DebugBuildIdentity {
    static var isEnabled: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    /// sRGB components of the blue "DEBUG" badge on `AppBundle/AppIconDebug.icns` (#014FF2).
    static let accentSRGB: (red: Double, green: Double, blue: Double) = (1.0 / 255.0, 79.0 / 255.0, 242.0 / 255.0)

    static let accentColor = Color(
        .sRGB,
        red: accentSRGB.red,
        green: accentSRGB.green,
        blue: accentSRGB.blue,
        opacity: 1
    )

    static let badgeTitle = "DEBUG"
    static let accessibilityDescription = "RepoPrompt CE debug build"

    /// Height of the accent rule drawn along the top content edge, directly below the titlebar.
    static let windowEdgeRuleHeight: CGFloat = 2

    /// Opacity of the composer ring. Kept low enough to read as chrome rather than an alert, and
    /// always yields to an explicit composer highlight (for example, MCP-controlled tabs).
    static let composerRingOpacity: Double = 0.45
}

/// Compact titlebar badge mirroring the debug app icon's "DEBUG" badge.
struct DebugBuildToolbarBadge: View {
    var body: some View {
        Text(DebugBuildIdentity.badgeTitle)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(DebugBuildIdentity.accentColor))
            .fixedSize()
            .hoverTooltip(DebugBuildIdentity.accessibilityDescription, .bottomRight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(DebugBuildIdentity.accessibilityDescription)
    }
}

extension View {
    /// DEBUG builds draw a thin accent rule along the top content edge (just below the titlebar).
    /// Release builds return `self` unchanged.
    @ViewBuilder
    func debugBuildWindowEdge() -> some View {
        #if DEBUG
            overlay(alignment: .top) {
                DebugBuildIdentity.accentColor
                    .frame(height: DebugBuildIdentity.windowEdgeRuleHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        #else
            self
        #endif
    }
}
