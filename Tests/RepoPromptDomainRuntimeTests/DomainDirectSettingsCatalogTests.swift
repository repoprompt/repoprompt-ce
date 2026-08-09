import Foundation
@testable import RepoPromptDomainRuntime
import XCTest

final class DomainDirectSettingsCatalogTests: XCTestCase {
    private let secondaryModelKey = "models.secondary_oracle_model"

    func testSecondaryOracleModelIsPortableNullableCodexSetting() throws {
        let descriptor = try XCTUnwrap(
            DomainAppSettingsCatalog.descriptor(for: secondaryModelKey)
        )

        XCTAssertEqual(descriptor.group, "models")
        XCTAssertEqual(descriptor.valueKind, .string)
        XCTAssertEqual(descriptor.defaultValue, .null)
        XCTAssertTrue(descriptor.optionsAvailable)
        XCTAssertNoThrow(try DomainAppSettingsCatalog.validate(.null, for: descriptor))
        XCTAssertNoThrow(
            try DomainAppSettingsCatalog.validate(
                .string("codex_cli_gpt-5.6-sol-high"),
                for: descriptor
            )
        )
        XCTAssertThrowsError(
            try DomainAppSettingsCatalog.validate(.bool(true), for: descriptor)
        )
    }

    func testSecondaryOracleSelectionResolvesCurrentLegacyAndCustomCodexModels() throws {
        let current = try XCTUnwrap(
            DomainAppSettingsCatalog.secondaryOracleModelSelection(
                raw: " codex_cli_gpt-5.6-terra-ultra\n"
            )
        )
        XCTAssertEqual(current.canonicalRawID, "codex_cli_gpt-5.6-terra-ultra")
        XCTAssertEqual(current.cliBaseModel, "gpt-5.6-terra")
        XCTAssertEqual(current.reasoningEffort, "ultra")
        XCTAssertNil(current.serviceTier)
        XCTAssertEqual(current.displayName, "CLI·GPT-5.6 Terra Ultra")

        let legacy = try XCTUnwrap(
            DomainAppSettingsCatalog.secondaryOracleModelSelection(
                raw: "codex_cli_gpt-5.5-xhigh"
            )
        )
        XCTAssertEqual(legacy.canonicalRawID, "codex_cli_gpt-5.6-sol-xhigh")
        XCTAssertEqual(legacy.cliBaseModel, "gpt-5.6-sol")
        XCTAssertEqual(legacy.reasoningEffort, "xhigh")
        XCTAssertNil(legacy.serviceTier)
        XCTAssertEqual(legacy.displayName, "CLI·GPT-5.6 Sol XHigh")

        let custom = try XCTUnwrap(
            DomainAppSettingsCatalog.secondaryOracleModelSelection(
                raw: "codex_custom_acme-coder-high"
            )
        )
        XCTAssertEqual(custom.canonicalRawID, "codex_custom_acme-coder-high")
        XCTAssertEqual(custom.cliBaseModel, "acme-coder")
        XCTAssertEqual(custom.reasoningEffort, "high")
        XCTAssertNil(custom.serviceTier)
        XCTAssertEqual(custom.displayName, "CLI·Acme Coder High")

        let fast = try XCTUnwrap(
            DomainAppSettingsCatalog.secondaryOracleModelSelection(
                raw: "codex_custom_gpt-5.4-fast-high"
            )
        )
        XCTAssertEqual(fast.cliBaseModel, "gpt-5.4")
        XCTAssertEqual(fast.reasoningEffort, "high")
        XCTAssertEqual(fast.serviceTier, "fast")
        XCTAssertEqual(fast.displayName, "CLI·GPT-5.4 Fast High")
    }

    func testSecondaryOracleSelectionTreatsBlankAsDisabledAndRejectsUnknown() throws {
        XCTAssertNil(try DomainAppSettingsCatalog.secondaryOracleModelSelection(raw: " \n\t"))
        XCTAssertThrowsError(
            try DomainAppSettingsCatalog.secondaryOracleModelSelection(raw: "not-a-real-model")
        ) { error in
            XCTAssertEqual(
                error as? DomainDirectSettingsError,
                .unrecognizedSecondaryOracleModel("not-a-real-model")
            )
            XCTAssertEqual(
                error.localizedDescription,
                "Secondary Oracle Model 'not-a-real-model' is not a recognized Oracle model ID."
            )
        }
        XCTAssertThrowsError(
            try DomainAppSettingsCatalog.secondaryOracleModelSelection(raw: "codex_custom_")
        )
    }

    func testStoreCanonicalizesLegacyAliasAndBlankOnSet() async throws {
        let fixture = try DirectSettingsFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        await store.bootstrap()

        _ = try await store.set(
            key: secondaryModelKey,
            value: .string(" codex_cli_gpt-5.5-medium ")
        )
        let selectedValue = try await store.effectiveValue(for: secondaryModelKey)
        XCTAssertEqual(selectedValue, .string("codex_cli_gpt-5.6-sol-medium"))

        _ = try await store.set(key: secondaryModelKey, value: .string(" \n"))
        let disabledValue = try await store.effectiveValue(for: secondaryModelKey)
        XCTAssertEqual(disabledValue, .null)
    }

    func testStoreCanonicalizesPersistedAliasDuringBootstrap() async throws {
        let fixture = try DirectSettingsFixture()
        defer { fixture.remove() }
        try await fixture.writeDocument(
            values: [secondaryModelKey: .string("codex_cli_gpt-5.5-low")]
        )
        let store = fixture.makeStore()

        await store.bootstrap()

        let selectedValue = try await store.effectiveValue(for: secondaryModelKey)
        XCTAssertEqual(selectedValue, .string("codex_cli_gpt-5.6-sol-low"))
    }

    func testStoreTreatsPersistedBlankSecondaryModelAsDisabledDuringBootstrap() async throws {
        let fixture = try DirectSettingsFixture()
        defer { fixture.remove() }
        try await fixture.writeDocument(
            values: [secondaryModelKey: .string(" \n")]
        )
        let store = fixture.makeStore()

        await store.bootstrap()

        let selectedValue = try await store.effectiveValue(for: secondaryModelKey)
        XCTAssertEqual(selectedValue, .null)
    }

    func testStoreRejectsUnknownPersistedSecondaryModelDuringBootstrap() async throws {
        let fixture = try DirectSettingsFixture()
        defer { fixture.remove() }
        try await fixture.writeDocument(
            values: [secondaryModelKey: .string("not-a-real-model")]
        )
        let store = fixture.makeStore()
        await store.bootstrap()

        do {
            _ = try await store.set(key: "ui.show_tooltips", value: .bool(false))
            XCTFail("Expected corrupt Secondary Oracle selection to degrade direct settings")
        } catch let error as DomainDirectSettingsError {
            XCTAssertEqual(
                error,
                .readOnlyDegraded(
                    "Secondary Oracle Model 'not-a-real-model' is not a recognized Oracle model ID."
                )
            )
        }
    }
}

private struct DirectSettingsFixture {
    private struct Document: Codable {
        let version: Int
        let profileIdentifier: String
        let revision: UInt64
        let values: [String: DomainSettingValue]
        let updatedAt: Date
    }

    let root: URL
    let profileIdentifier: String
    let persistence: DomainPersistenceCoordinator

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DomainDirectSettingsCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        profileIdentifier = "direct-settings-test"
        let identity = DomainRuntimeIdentity(
            runtimeID: UUID(),
            lifecycleGeneration: 1,
            processID: 42,
            mode: .standalone,
            createdAt: Date()
        )
        let configuration = DomainRuntimeConfiguration(
            mode: .standalone,
            profileIdentifier: profileIdentifier,
            storageDirectory: root,
            eventDirectory: root.appendingPathComponent("Events", isDirectory: true),
            temporaryDirectory: root.appendingPathComponent("Temporary", isDirectory: true),
            externalReloadInterval: nil
        )
        persistence = DomainPersistenceCoordinator(configuration: configuration, identity: identity)
    }

    func makeStore() -> DomainDirectSettingsStore {
        DomainDirectSettingsStore(
            persistence: persistence,
            profileIdentifier: profileIdentifier
        )
    }

    func writeDocument(values: [String: DomainSettingValue]) async throws {
        let document = Document(
            version: 1,
            profileIdentifier: profileIdentifier,
            revision: 7,
            values: values,
            updatedAt: Date()
        )
        let data = try JSONEncoder().encode(document)
        try await persistence.compareAndSwapDirectSettingsData(expectedDigest: nil, data: data)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
