import RepoPromptSettingsCore

//
//  ModelOverrideSettings.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-04.
//

import Combine
import Foundation

/// This singleton stores per-model override values (diff editing and streaming)
/// in the JSON-backed global settings store.
class ModelOverridesSettings: ObservableObject {
    static let shared = ModelOverridesSettings()

    @Published var diffOverrides: [String: Bool] {
        didSet {
            saveOverrides()
        }
    }

    @Published var streamOverrides: [String: Bool] {
        didSet {
            saveOverrides()
        }
    }

    @Published var temperatureOverrides: [String: Double] {
        didSet { saveOverrides() }
    }

    // NEW: Per-model Responses-API route override
    @Published var responsesOverrides: [String: Bool] {
        didSet { saveOverrides() }
    }

    private init() {
        let snapshot = Self.loadInitialOverrides()
        diffOverrides = snapshot.diff
        streamOverrides = snapshot.stream
        temperatureOverrides = snapshot.temperature
        responsesOverrides = snapshot.responses
    }

    func diffOverride(for modelRaw: String) -> Bool? {
        diffOverrides[modelRaw]
    }

    func setDiffOverride(for modelRaw: String, value: Bool) {
        diffOverrides[modelRaw] = value
    }

    func streamOverride(for modelRaw: String) -> Bool? {
        streamOverrides[modelRaw]
    }

    func setStreamOverride(for modelRaw: String, value: Bool) {
        streamOverrides[modelRaw] = value
    }

    func temperatureOverride(for modelRaw: String) -> Double? {
        temperatureOverrides[modelRaw]
    }

    /// Pass nil to remove the override
    func setTemperatureOverride(for modelRaw: String, value: Double?) {
        if let v = value {
            temperatureOverrides[modelRaw] = v
        } else {
            temperatureOverrides.removeValue(forKey: modelRaw)
        }
    }

    // MARK: - Responses-API helpers

    func responsesOverride(for modelRaw: String) -> Bool? {
        responsesOverrides[modelRaw]
    }

    func setResponsesOverride(for modelRaw: String, value: Bool) {
        responsesOverrides[modelRaw] = value
    }

    private func saveOverrides() {
        let snapshot = OverrideSnapshot(
            diff: diffOverrides,
            stream: streamOverrides,
            temperature: temperatureOverrides,
            responses: responsesOverrides
        )
        Self.persist(snapshot)
    }

    private struct OverrideSnapshot {
        var diff: [String: Bool]
        var stream: [String: Bool]
        var temperature: [String: Double]
        var responses: [String: Bool]
    }

    private static func loadInitialOverrides() -> OverrideSnapshot {
        if Thread.isMainThread {
            return loadFromGlobalStoreOnMainActor()
        }
        var snapshot: OverrideSnapshot?
        DispatchQueue.main.sync {
            snapshot = loadFromGlobalStoreOnMainActor()
        }
        return snapshot ?? OverrideSnapshot(diff: [:], stream: [:], temperature: [:], responses: [:])
    }

    private static func loadFromGlobalStoreOnMainActor() -> OverrideSnapshot {
        MainActor.assumeIsolated {
            OverrideSnapshot(
                diff: GlobalSettingsStore.shared.modelDiffOverrides(),
                stream: GlobalSettingsStore.shared.modelStreamOverrides(),
                temperature: GlobalSettingsStore.shared.modelTemperatureOverrides(),
                responses: GlobalSettingsStore.shared.modelResponsesOverrides()
            )
        }
    }

    private static func persist(_ snapshot: OverrideSnapshot) {
        let persistOnMain = {
            MainActor.assumeIsolated {
                GlobalSettingsStore.shared.updateModelOverrides({ settings in
                    settings.diffOverrides = snapshot.diff
                    settings.streamOverrides = snapshot.stream
                    settings.temperatureOverrides = snapshot.temperature
                    settings.responsesOverrides = snapshot.responses
                }, commit: true)
            }
        }

        if Thread.isMainThread {
            persistOnMain()
        } else {
            DispatchQueue.main.sync(execute: persistOnMain)
        }
    }
}
