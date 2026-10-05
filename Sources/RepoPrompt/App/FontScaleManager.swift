import Foundation
import RepoPromptSettingsCore
import SwiftUI

/// Centralised manager for app-wide font scaling.
/// - Owns the current FontScalePreset
/// - Persists through GlobalSettingsStore so app_settings and the app share one store
/// - Publishes changes so SwiftUI views can update without each view
///   individually observing UserDefaults (avoids layout feedback loops).
@MainActor
final class FontScaleManager: ObservableObject {
    static let shared = FontScaleManager()

    /// Current preset used for UI scaling.
    @Published private(set) var preset: FontScalePreset

    /// Cached preset used during AI response streaming to prevent layout changes
    private var cachedPreset: FontScalePreset?

    /// Whether font scaling changes are currently frozen (e.g., during AI streaming)
    private(set) var isFrozen = false

    /// Cross-process Darwin notification name shared by every running app instance.
    /// Pinned by `ModularizationCompatibilityGoldenTests`.
    static let externalChangeNotificationRawName = "com.repoprompt.fontScaleDidChange"
    private static let externalChangeNotificationName = CFNotificationName(externalChangeNotificationRawName as CFString)

    private let store: GlobalSettingsStore
    private var didRegisterExternalChangeObserver = false

    private init(store: GlobalSettingsStore? = nil) {
        let store = store ?? GlobalSettingsStore.shared
        self.store = store
        let initial = FontScalePreset(rawValue: store.fontScaleBodySize()) ?? .normal
        preset = initial
        // Keep the static cache in sync for AppKit bridges and helpers.
        FontScalePreset.updateCachedPreset(initial)
        #if DEBUG
            FontScalePerfDiagnostics.event(
                "fontScale.manager.init",
                fields: ["preset": String(describing: initial), "raw": String(initial.rawValue)]
            )
        #endif
        registerExternalChangeObserverIfNeeded()
    }

    /// Sets a new preset, persists it, and refreshes the static cache.
    func setPreset(_ newPreset: FontScalePreset) {
        #if DEBUG
            FontScalePerfDiagnostics.event(
                "fontScale.setPreset.request",
                fields: ["current": String(describing: preset), "new": String(describing: newPreset)]
            )
        #endif
        applyPreset(
            newPreset,
            persist: true,
            bypassFreeze: false,
            broadcastExternalChange: false,
            source: "setPreset"
        )
    }

    /// Freezes font scale changes (e.g., during AI response streaming)
    /// This prevents layout changes while text is being streamed
    func freeze() {
        guard !isFrozen else {
            return
        }
        isFrozen = true
        #if DEBUG
            FontScalePerfDiagnostics.event(
                "fontScale.freeze",
                fields: ["wasFrozen": "false", "changed": "true"]
            )
        #endif
    }

    /// Unfreezes font scale changes and applies any cached preset
    func unfreeze() {
        guard isFrozen else {
            return
        }
        #if DEBUG
            let hadCachedPreset = cachedPreset != nil
        #endif
        isFrozen = false
        #if DEBUG
            FontScalePerfDiagnostics.event(
                "fontScale.unfreeze",
                fields: [
                    "wasFrozen": "true",
                    "changed": "true",
                    "hadCachedPreset": String(hadCachedPreset)
                ]
            )
        #endif

        // Apply any cached preset that was requested while frozen
        if let cached = cachedPreset {
            cachedPreset = nil
            #if DEBUG
                FontScalePerfDiagnostics.event(
                    "fontScale.unfreeze.applyCachedPreset",
                    fields: ["cached": String(describing: cached)]
                )
            #endif
            setPreset(cached)
        }
    }

    /// Increase font scale to the next preset, if any.
    func increase() {
        step(+1)
    }

    /// Decrease font scale to the previous preset, if any.
    func decrease() {
        step(-1)
    }

    /// Optional helper to set directly from a stored raw value.
    func setRawValue(_ rawValue: Double) {
        guard let p = FontScalePreset(rawValue: rawValue) else {
            #if DEBUG
                FontScalePerfDiagnostics.event(
                    "fontScale.setRawValue.invalid",
                    fields: ["raw": String(rawValue)]
                )
            #endif
            return
        }
        setPreset(p)
    }

    /// Reconciles the live manager after app_settings has already persisted the
    /// canonical value through its injected GlobalSettingsStore. This path is
    /// intentionally applied even for no-op persistent sets so stale visible UI can
    /// catch up to the shared settings document.
    func applyAppSettingsRawValue(
        _ rawValue: Double,
        broadcastExternalChange: Bool = true
    ) {
        guard let preset = FontScalePreset(rawValue: rawValue) else {
            #if DEBUG
                FontScalePerfDiagnostics.event(
                    "fontScale.appSettings.invalidRawValue",
                    fields: ["raw": String(rawValue)]
                )
            #endif
            return
        }
        applyPreset(
            preset,
            persist: false,
            bypassFreeze: true,
            broadcastExternalChange: broadcastExternalChange,
            source: "appSettings"
        )
    }

    func reloadAfterExternalChange() {
        guard let rawValue = store.reloadFontScaleBodySizeFromDisk() else {
            #if DEBUG
                FontScalePerfDiagnostics.event("fontScale.externalReload.noRawValue")
            #endif
            return
        }
        guard let preset = FontScalePreset(rawValue: rawValue) else {
            #if DEBUG
                FontScalePerfDiagnostics.event(
                    "fontScale.externalReload.invalidRawValue",
                    fields: ["raw": String(rawValue)]
                )
            #endif
            return
        }
        #if DEBUG
            FontScalePerfDiagnostics.event(
                "fontScale.externalReload.resolved",
                fields: ["preset": String(describing: preset), "raw": String(rawValue)]
            )
        #endif
        applyPreset(
            preset,
            persist: false,
            bypassFreeze: true,
            broadcastExternalChange: false,
            source: "externalReload"
        )
    }

    // MARK: - Private

    private func applyPreset(
        _ newPreset: FontScalePreset,
        persist: Bool,
        bypassFreeze: Bool,
        broadcastExternalChange: Bool,
        source: String
    ) {
        #if DEBUG
            FontScalePerfDiagnostics.event(
                "fontScale.applyPreset.called",
                fields: [
                    "source": source,
                    "current": String(describing: preset),
                    "new": String(describing: newPreset),
                    "persist": String(persist),
                    "bypassFreeze": String(bypassFreeze),
                    "broadcastExternalChange": String(broadcastExternalChange),
                    "isFrozen": String(isFrozen)
                ]
            )
        #endif
        if isFrozen, !bypassFreeze {
            if newPreset != preset {
                cachedPreset = newPreset
                #if DEBUG
                    FontScalePerfDiagnostics.event(
                        "fontScale.applyPreset.frozenCached",
                        fields: ["source": source, "cached": String(describing: newPreset)]
                    )
                #endif
            } else {
                #if DEBUG
                    FontScalePerfDiagnostics.event(
                        "fontScale.applyPreset.frozenNoop",
                        fields: ["source": source, "preset": String(describing: newPreset)]
                    )
                #endif
            }
            return
        }

        if bypassFreeze {
            #if DEBUG
                let hadCachedPreset = cachedPreset != nil
            #endif
            cachedPreset = nil
            #if DEBUG
                FontScalePerfDiagnostics.event(
                    "fontScale.applyPreset.bypassFreezeClearedCache",
                    fields: ["source": source, "hadCachedPreset": String(hadCachedPreset)]
                )
            #endif
        }

        let changed = newPreset != preset
        if changed {
            preset = newPreset
            #if DEBUG
                FontScalePerfDiagnostics.event(
                    "fontScale.preset.published",
                    fields: ["source": source, "new": String(describing: newPreset)]
                )
            #endif
        } else {
            #if DEBUG
                FontScalePerfDiagnostics.event(
                    "fontScale.applyPreset.noop",
                    fields: ["source": source, "preset": String(describing: newPreset)]
                )
            #endif
        }

        if changed || bypassFreeze {
            #if DEBUG
                FontScalePerfDiagnostics.event(
                    "fontScale.cache.updateRequested",
                    fields: ["source": source, "preset": String(describing: newPreset)]
                )
            #endif
            FontScalePreset.updateCachedPreset(newPreset)
        }

        if persist, changed {
            #if DEBUG
                FontScalePerfDiagnostics.event(
                    "fontScale.persist.setRawValue",
                    fields: ["source": source, "raw": String(newPreset.rawValue)]
                )
            #endif
            store.setFontScaleBodySize(newPreset.rawValue)
        }

        if broadcastExternalChange, changed || bypassFreeze {
            postExternalChangeNotification()
        }
    }

    private func step(_ delta: Int) {
        let all = FontScalePreset.allCases
        guard let idx = all.firstIndex(of: preset) else {
            #if DEBUG
                FontScalePerfDiagnostics.event(
                    "fontScale.step.invalidCurrentPreset",
                    fields: ["delta": String(delta), "current": String(describing: preset)]
                )
            #endif
            return
        }
        let boundedIndex = max(min(idx + delta, all.count - 1), 0)
        #if DEBUG
            if boundedIndex == idx {
                FontScalePerfDiagnostics.event(
                    "fontScale.step.boundaryNoop",
                    fields: ["delta": String(delta), "current": String(describing: preset)]
                )
            } else {
                FontScalePerfDiagnostics.event(
                    "fontScale.step.changed",
                    fields: [
                        "delta": String(delta),
                        "from": String(describing: preset),
                        "to": String(describing: all[boundedIndex])
                    ]
                )
            }
        #endif
        setPreset(all[boundedIndex])
    }

    private func registerExternalChangeObserverIfNeeded() {
        guard !didRegisterExternalChangeObserver else {
            #if DEBUG
                FontScalePerfDiagnostics.event("fontScale.externalObserver.registerNoop")
            #endif
            return
        }
        didRegisterExternalChangeObserver = true
        #if DEBUG
            FontScalePerfDiagnostics.event("fontScale.externalObserver.registered")
        #endif
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                #if DEBUG
                    FontScalePerfDiagnostics.event("fontScale.externalNotification.received")
                #endif
                Task { @MainActor in
                    FontScaleManager.shared.handleExternalChangeNotification()
                }
            },
            Self.externalChangeNotificationName.rawValue,
            nil,
            .deliverImmediately
        )
    }

    private func handleExternalChangeNotification() {
        #if DEBUG
            FontScalePerfDiagnostics.event("fontScale.externalNotification.handle")
        #endif
        reloadAfterExternalChange()
    }

    private func postExternalChangeNotification() {
        #if DEBUG
            FontScalePerfDiagnostics.event("fontScale.externalNotification.post")
        #endif
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Self.externalChangeNotificationName,
            nil,
            nil,
            true
        )
    }
}
