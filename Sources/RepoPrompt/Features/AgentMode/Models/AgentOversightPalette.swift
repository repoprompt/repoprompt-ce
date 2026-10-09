import AppKit
import SwiftUI

/// Group colour palette for the sidebar oversight marks (Fb's iconography, applied on top of the
/// unified oversight UI).
///
/// Every overseer session gets one stable slot while it holds at least one link (see
/// `AgentOversightColourAllocator`); all marks that reference that overseer — its own `eye.fill`
/// and the `eye`/`eye.circle.fill` ring on its targets — share that slot's colour.
///
/// Colour selection constraints:
/// - No system hues that already carry meaning in the app: blue (accent/selection), purple
///   (Review, merge badges, Oracle), orange (MCP), teal, indigo, green (waiting/completed),
///   red (failed), cyan — and the merge badge's yellow. The remaining unclaimed hue territory is
///   the magenta→rose band (~295°–350°) plus warm neutrals, so the palette lives there. The
///   pink-purple boundary slots stay ~25° warmer than `.systemPurple` (≈280°) and far less
///   saturated, so no slot reads as the reserved purple.
/// - Adjacent slots alternate lightness so neighbouring groups stay distinguishable even where
///   hues sit close together.
/// - Each slot has explicit light- and dark-mode variants; both are contrast-checked in tests
///   (≥ 3:1 WCAG non-text) against the sidebar's approximate background (`#ECECEC` light,
///   `#1E1E1E` dark).
enum AgentOversightPalette {
    /// Number of distinct group colours; the allocator wraps beyond this count.
    static let slotCount = 10

    private struct Entry {
        let name: String
        let light: NSColor
        let dark: NSColor
    }

    /// Ordered so neighbours alternate depth within the constrained hue band.
    private static let entries: [Entry] = [
        Entry(name: "magenta", light: rgb(0xB0308C), dark: rgb(0xEF83CC)),
        Entry(name: "wine", light: rgb(0x9A3550), dark: rgb(0xE08B9C)),
        Entry(name: "orchid", light: rgb(0xA1549B), dark: rgb(0xD27ECB)),
        Entry(name: "rose", light: rgb(0xC4427E), dark: rgb(0xF49AC1)),
        Entry(name: "mulberry", light: rgb(0x865A83), dark: rgb(0xCB8FB8)),
        Entry(name: "raspberry", light: rgb(0xB52660), dark: rgb(0xF2698F)),
        Entry(name: "cocoa", light: rgb(0x8C6A50), dark: rgb(0xCBA98E)),
        Entry(name: "fuchsia", light: rgb(0xC027A2), dark: rgb(0xED6FCE)),
        Entry(name: "dusty rose", light: rgb(0xA8737E), dark: rgb(0xDCA6AE)),
        Entry(name: "taupe", light: rgb(0x7D6E78), dark: rgb(0xC0B0BA))
    ]

    /// The SwiftUI colour for a palette slot. Slot indices wrap, so any integer is safe.
    static func color(for slot: Int) -> Color {
        Color(nsColor: nsColor(for: slot))
    }

    /// Appearance-aware colour for one slot.
    static func nsColor(for slot: Int) -> NSColor {
        let entry = entries[wrapped(slot)]
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? entry.dark
                : entry.light
        }
    }

    /// Concrete colour for one slot in one appearance — used by tests to verify contrast.
    static func resolvedColor(for slot: Int, darkAppearance: Bool) -> NSColor {
        let entry = entries[wrapped(slot)]
        return darkAppearance ? entry.dark : entry.light
    }

    private static func wrapped(_ slot: Int) -> Int {
        ((slot % slotCount) + slotCount) % slotCount
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
