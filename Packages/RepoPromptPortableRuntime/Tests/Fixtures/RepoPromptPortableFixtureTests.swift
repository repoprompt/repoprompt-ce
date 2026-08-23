import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptRuntimeModel
import XCTest

final class RepoPromptPortableFixtureTests: XCTestCase {
    func testAgentParityFixturesAreSingleAndDecodable() throws {
        let names = [
            "model-normalization",
            "provider-matrix",
            "provider-turn-semantics",
            "transcript-presentation",
            "turn-compilation"
        ]
        for name in names {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData(name)) as? [String: Any])
            XCTAssertEqual(object["schemaVersion"] as? Int, 2, name)
            XCTAssertEqual(object["prototypeCommit"] as? String, "45c42d65e444884d1681f4504c10d25dcb7d858a", name)
            XCTAssertTrue((object["generatedFrom"] as? String)?.hasPrefix("Packages/RepoPromptPortableRuntime/Sources/") == true, name)
        }
    }

    func testProviderMatrixFixtureExhaustivelySnapshotsCanonicalSemantics() throws {
        let fixture = try JSONDecoder().decode(ProviderMatrixFixture.self, from: fixtureData("provider-matrix"))
        XCTAssertEqual(fixture.schemaVersion, 2)
        XCTAssertEqual(fixture.liveDiscoveryFreshnessSeconds, AgentComposerProviderMatrix.liveFreshnessSeconds)
        XCTAssertEqual(
            fixture.persistedDiscoveryMaximumAgeSeconds,
            AgentComposerProviderMatrix.persistedFallbackMaximumAgeSeconds
        )
        XCTAssertEqual(Set(fixture.providers.map(\.id)), Set(ProviderSettingsID.allCases))
        XCTAssertEqual(fixture.providers.count, ProviderSettingsID.allCases.count)

        for snapshot in fixture.providers {
            let entry = try XCTUnwrap(AgentComposerProviderMatrix.entry(for: snapshot.id))
            XCTAssertEqual(snapshot.modelSource, entry.modelSource, snapshot.id.rawValue)
            XCTAssertEqual(snapshot.persistedFallback, entry.discoveryPolicy.allowsPersistedFallback)
            XCTAssertEqual(
                snapshot.staticFallbackAfterPreflight,
                entry.discoveryPolicy.allowsStaticFallbackAfterSuccessfulPreflight
            )
            XCTAssertEqual(snapshot.discoveryReplacesStatic, entry.discoveryPolicy.discoveryReplacesStaticChoices)
            XCTAssertEqual(snapshot.failurePolicy, entry.failurePolicy)
            XCTAssertEqual(snapshot.nativeImages, entry.nativeImageSupportRequiresAdapter ? "adapter-required" : "unsupported")
        }
    }

    func testTranscriptFixtureProjectsEveryRecordedCompatibilityRule() throws {
        let fixture = try JSONDecoder().decode(TranscriptFixture.self, from: fixtureData("transcript-presentation"))
        for progress in fixture.suppressExactLegacyProgress {
            let entry = TranscriptEntry(
                entryID: UUID(),
                sessionSequence: 1,
                kind: .progress,
                content: progress,
                actor: nil,
                timestamp: Date(timeIntervalSince1970: 0)
            )
            XCTAssertNil(AgentTranscriptPresentationCore.projectLegacy(entry), progress)
        }
        for progress in fixture.retainMeaningfulProgress {
            let entry = TranscriptEntry(
                entryID: UUID(),
                sessionSequence: 1,
                kind: .progress,
                content: progress,
                actor: nil,
                timestamp: Date(timeIntervalSince1970: 0)
            )
            XCTAssertNotNil(AgentTranscriptPresentationCore.projectLegacy(entry), progress)
        }

        let turn = AgentSemanticPresentationTurn(
            turnID: "fixture-turn",
            responseSpanID: nil,
            requestAnchorID: nil,
            requestText: "request",
            terminalState: "completed",
            activities: [
                .init(id: "reasoning", sequence: 1, revision: 1, kind: "reasoning", content: "Considering"),
                .init(id: "assistant", sequence: 2, revision: 1, kind: "assistant", content: "Answer"),
                .init(id: "conclusion", sequence: 3, revision: 1, kind: "conclusion", content: "Done")
            ]
        )
        XCTAssertEqual(AgentTranscriptPresentationCore.project(turn).blocks.map(blockKind), fixture.blockOrder)
    }

    func testProviderTurnFixtureCoversEveryProviderPermissionAndScope() throws {
        let fixture = try JSONDecoder().decode(ProviderTurnFixture.self, from: fixtureData("provider-turn-semantics"))
        XCTAssertEqual(fixture.interpretationRevision, ProviderTurnConfigurationAdapters.interpretationRevision)
        XCTAssertEqual(fixture.requiredMCPServers, ["repoprompt"])
        XCTAssertEqual(fixture.directProviderSettingsIDKey, "provider.settingsID")
        XCTAssertEqual(Set(fixture.families.flatMap(\.providerIds)), Set(ProviderSettingsID.allCases))

        let resource = OwnedResourceReference(
            ownerID: .init(rawValue: "fixture-owner"),
            resourceID: .init(rawValue: "fixture-resource")
        )
        for family in fixture.families {
            for providerID in family.providerIds {
                let adapter = try XCTUnwrap(ProviderTurnConfigurationAdapters.builtIn()[providerID])
                XCTAssertEqual(Set(family.controls), adapter.supportedControlIDs)
                XCTAssertEqual(Set(family.permissionModes.keys), adapter.supportedPermissionIDs)
                let model = ProviderModelDescriptor(
                    providerID: providerID,
                    modelID: "fixture-model",
                    providerRawValue: "fixture-model",
                    displayName: "Fixture Model"
                )
                if providerID.isDirectAPI {
                    XCTAssertEqual(family.fixedExecutionMode, "workspaceWrite")
                    XCTAssertNil(ProviderComposerStableControls.permissionDescriptor(
                        providerID: providerID,
                        selectedID: nil,
                        mutable: true,
                        lockReasonCode: nil
                    ))
                    let compiled = try adapter.compile(.init(
                        providerID: providerID,
                        model: model,
                        settings: ProviderTurnConfigurationAdapters.defaultSettings(for: providerID),
                        scopedResources: [resource]
                    ))
                    XCTAssertEqual(compiled.permissions.executionMode.rawValue, family.fixedExecutionMode)
                    XCTAssertEqual(compiled.permissions.scopedResources, [resource])
                    XCTAssertEqual(compiled.providerSettings[fixture.directProviderSettingsIDKey], providerID.rawValue)
                    XCTAssertNil(compiled.providerSettings["provider.permissionId"])
                    continue
                }
                XCTAssertNil(family.fixedExecutionMode)
                for (permissionID, mode) in family.permissionModes {
                    let compiled = try adapter.compile(.init(
                        providerID: providerID,
                        model: model,
                        permissionID: permissionID,
                        settings: ProviderTurnConfigurationAdapters.defaultSettings(for: providerID),
                        scopedResources: [resource]
                    ))
                    XCTAssertEqual(compiled.permissions.executionMode.rawValue, mode)
                    XCTAssertEqual(compiled.permissions.scopedResources, [resource])
                }
            }
        }
    }

    private func blockKind(_ block: AgentPresentationBlockWire) -> String {
        switch block {
        case .request: "request"
        case .activityCluster: "activityCluster"
        case .standaloneAssistant: "standaloneAssistant"
        case .conclusion: "conclusion"
        case .groupedHistory: "groupedHistory"
        case .collapsedHistoryRange: "collapsedHistoryRange"
        case .standaloneTool: "standaloneTool"
        case .standaloneNote: "standaloneNote"
        case .middleSummary: "middleSummary"
        }
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "AgentParity/v1"
        ))
        return try Data(contentsOf: url)
    }
}

private struct ProviderMatrixFixture: Decodable {
    let schemaVersion: Int
    let liveDiscoveryFreshnessSeconds: Int
    let persistedDiscoveryMaximumAgeSeconds: Int
    let providers: [ProviderSnapshot]
}

private struct TranscriptFixture: Decodable {
    let suppressExactLegacyProgress: [String]
    let retainMeaningfulProgress: [String]
    let blockOrder: [String]
}

private struct ProviderTurnFixture: Decodable {
    let interpretationRevision: String
    let requiredMCPServers: [String]
    let directProviderSettingsIDKey: String
    let families: [ProviderTurnFamily]
}

private struct ProviderTurnFamily: Decodable {
    let providerIds: [ProviderSettingsID]
    let controls: [String]
    let fixedExecutionMode: String?
    let permissionModes: [String: String]
}

private struct ProviderSnapshot: Decodable {
    let id: ProviderSettingsID
    let modelSource: String
    let persistedFallback: Bool
    let staticFallbackAfterPreflight: Bool
    let discoveryReplacesStatic: Bool
    let failurePolicy: String
    let nativeImages: String
}
