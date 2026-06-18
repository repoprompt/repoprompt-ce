//
//  FontPreset.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-04-22.
//

import AppKit
import SwiftUI

/// Body‑point‑sizes the app supports.
/// Extend or localise the enum later without touching the rest of the code‑base.
enum FontScalePreset: Double, CaseIterable, Identifiable {
    case normal = 14 // 100 % – macOS default
    case large = 16 // ~115 %
    case extraLarge = 18 // ~130 %

    var id: Self {
        self
    }

    /// Convenience so we can write `.environment(\.font, preset.font)`
    var font: Font {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("font", preset: self)
        #endif
        return .system(size: rawValue, design: .rounded)
    }

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }
}

// swiftformat:disable environmentEntry
private struct RepoPromptFontScalePresetKey: EnvironmentKey {
    static let defaultValue: FontScalePreset = .current
}

extension EnvironmentValues {
    var repoPromptFontScalePreset: FontScalePreset {
        get { self[RepoPromptFontScalePresetKey.self] }
        set { self[RepoPromptFontScalePresetKey.self] = newValue }
    }
}

// swiftformat:enable environmentEntry

extension FontScalePreset {
    var standardFont: Font {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("standardFont", preset: self)
        #endif
        return .system(size: rawValue, design: .rounded)
    }

    /// Semibold version of standard font
    var standardFontSemibold: Font {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("standardFontSemibold", preset: self)
        #endif
        return .system(size: rawValue, weight: .semibold, design: .rounded)
    }

    /// Scaled equivalent of `.headline`
    var headlineFont: Font {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("headlineFont", preset: self)
        #endif
        return .system(size: rawValue + 2, weight: .bold, design: .rounded)
    }

    /// Scaled equivalent of `.subheadline`
    var subheadlineFont: Font {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("subheadlineFont", preset: self)
        #endif
        return .system(size: rawValue + 1, weight: .regular, design: .rounded)
    }

    var subHeadlineBoldFont: Font {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("subHeadlineBoldFont", preset: self)
        #endif
        return .system(size: rawValue + 1, weight: .bold, design: .rounded)
    }

    /// Scaled equivalent of `.caption`
    var captionFont: Font {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("captionFont", preset: self)
        #endif
        return .system(size: max(rawValue - 2, 9), weight: .regular, design: .rounded)
    }

    /// Monospace font for code/diffs
    var codeFont: Font {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("codeFont", preset: self)
        #endif
        return .system(size: max(rawValue - 2, 9), weight: .regular, design: .monospaced)
    }

    /// Scaled equivalent of `.title`
    var titleFont: Font {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("titleFont", preset: self)
        #endif
        return .system(size: rawValue + 4, weight: .bold, design: .rounded)
    }
}

/// Extension to add a scale method to Font
extension Font {
    /// Scale a font by a multiplier factor
    func scale(_ factor: CGFloat) -> Font {
        #if DEBUG
            FontScalePerfDiagnostics.increment("helper.Font.scale")
        #endif
        // We can't directly scale a Font, but we can create a relative font
        // using the .system() with a relative size
        return .system(size: CGFloat(NSFont.systemFontSize) * factor)
    }
}

extension FontScalePreset {
    /// Body font for AppKit views that mirrors the SwiftUI preset.
    var nsFont: NSFont {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("nsFont", preset: self)
        #endif
        return NSFont.systemFont(ofSize: CGFloat(rawValue))
    }

    /// Scales a metric from its Normal preset value to the current preset.
    func scaledMetric(_ valueAtNormal: CGFloat) -> CGFloat {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("scaledMetric.cgFloat", preset: self)
        #endif
        return valueAtNormal * scaleFactor
    }

    /// Scales a metric from its Normal preset value to the current preset.
    func scaledMetric(_ valueAtNormal: Double) -> Double {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("scaledMetric.double", preset: self)
        #endif
        return valueAtNormal * rawValue / FontScalePreset.normal.rawValue
    }

    /// Scales a metric and optionally clamps it to a minimum and/or maximum.
    func scaledClamped(
        _ valueAtNormal: CGFloat,
        min minimum: CGFloat? = nil,
        max maximum: CGFloat? = nil
    ) -> CGFloat {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("scaledClamped", preset: self)
        #endif
        let scaled = scaledMetric(valueAtNormal)
        let lowerBounded = minimum.map { Swift.max(scaled, $0) } ?? scaled
        return maximum.map { Swift.min(lowerBounded, $0) } ?? lowerBounded
    }

    /// Generic SwiftUI font helper for call sites that need a deliberate base size.
    func swiftUIFont(
        sizeAtNormal: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .rounded
    ) -> Font {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("swiftUIFont", preset: self)
        #endif
        return .system(size: scaledMetric(sizeAtNormal), weight: weight, design: design)
    }

    /// Generic AppKit font helper for call sites that need a deliberate base size.
    func nsFont(
        sizeAtNormal: CGFloat,
        weight: NSFont.Weight = .regular,
        rounded: Bool = true
    ) -> NSFont {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("nsFont.sized", preset: self)
        #endif
        let size = scaledMetric(sizeAtNormal)
        if rounded,
           let descriptor = NSFont.systemFont(ofSize: size, weight: weight)
           .fontDescriptor
           .withDesign(.rounded),
           let font = NSFont(descriptor: descriptor, size: size)
        {
            return font
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// Generic monospaced AppKit font helper for code-like text.
    func monospacedNSFont(
        sizeAtNormal: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSFont {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("monospacedNSFont", preset: self)
        #endif
        return NSFont.monospacedSystemFont(ofSize: scaledMetric(sizeAtNormal), weight: weight)
    }

    /// Returns the *cached* preset (automatically refreshed by Settings).
    static var current: FontScalePreset {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("current", preset: _cachedCurrent)
        #endif
        return _cachedCurrent
    }

    /// Multiplier relative to `.normal` (14 pt) so other UI metrics can scale
    /// together with the body font size.
    var scaleFactor: CGFloat {
        CGFloat(rawValue / FontScalePreset.normal.rawValue)
    }
}

extension FontScalePreset {
    /// Internal backing store for the cached preset.
    /// FontScaleManager seeds this from GlobalSettingsStore during app startup.
    private static var _cachedCurrent: FontScalePreset = .normal

    /// Convenience: latest cached preset’s row height (28 pt @ Normal).
    static var cachedRowHeight: CGFloat {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("cachedRowHeight", preset: _cachedCurrent)
        #endif
        return _cachedCurrent.rowHeight
    }

    /// True when the cached preset is still the default `.normal`.
    static var isDefaultPreset: Bool {
        _cachedCurrent == .normal
    }

    /// Refreshes the cached preset from the JSON-backed global settings store.
    @MainActor
    static func refreshCachedPreset() {
        #if DEBUG
            let previous = _cachedCurrent
        #endif
        let stored = GlobalSettingsStore.shared.fontScaleBodySize()
        _cachedCurrent = FontScalePreset(rawValue: stored) ?? .normal
        #if DEBUG
            FontScalePerfDiagnostics.event(
                "fontScale.cache.refresh",
                fields: [
                    "previous": String(describing: previous),
                    "new": String(describing: _cachedCurrent),
                    "changed": String(previous != _cachedCurrent),
                    "raw": String(stored)
                ]
            )
        #endif
    }

    /// Updates the cached preset directly when the live manager already resolved
    /// the canonical value from the shared settings store.
    static func updateCachedPreset(_ preset: FontScalePreset) {
        #if DEBUG
            let previous = _cachedCurrent
        #endif
        _cachedCurrent = preset
        #if DEBUG
            FontScalePerfDiagnostics.event(
                "fontScale.cache.update",
                fields: [
                    "previous": String(describing: previous),
                    "new": String(describing: preset),
                    "changed": String(previous != preset)
                ]
            )
        #endif
    }
}

extension FontScalePreset {
    /// Default row height (28 pt at "Normal") scaled with the preset.
    var rowHeight: CGFloat {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("rowHeight", preset: self)
        #endif
        return 28 * scaleFactor
    }

    /// Convenience for current preset without repeating `.current`.
    static var currentRowHeight: CGFloat {
        #if DEBUG
            FontScalePerfDiagnostics.recordHelper("currentRowHeight", preset: _cachedCurrent)
        #endif
        return FontScalePreset.current.rowHeight
    }
}
