import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class CodexDiscoveredEffortTests: XCTestCase {
    func testDiscoveredPickerEffortsBecomeRequestParameters() throws {
        let records = [record("gpt-future", efforts: ["high", "max", "ultra"])]
        let options = CodexDynamicModelMapper.options(from: records)
        XCTAssertEqual(Set(options.map(\.id)), ["gpt-future-high", "gpt-future-max", "gpt-future-ultra"])
        for option in options {
            let effort = try XCTUnwrap(option.reasoningEffort)
            let selection = CodexModelSpecifier(raw: option.id, discoveredRecords: records)
            XCTAssertEqual(selection.appServerModelParam, "gpt-future", option.id)
            XCTAssertEqual(selection.appServerEffortParam, effort.rawValue, option.id)
            XCTAssertEqual(selection.cliModelArgs, ["--model", "gpt-future"], option.id)
            XCTAssertEqual(selection.cliReasoningConfigArgs, ["-c", "model_reasoning_effort=\(effort.rawValue)"], option.id)
        }
    }

    func testOnlyAdvertisedExtendedEffortsAreDecoded() {
        let records = [record("gpt-future", efforts: ["max"])]
        let unsupported = CodexModelSpecifier(raw: "gpt-future-ultra", discoveredRecords: records)
        XCTAssertEqual(unsupported.appServerModelParam, "gpt-future-ultra")
        XCTAssertNil(unsupported.appServerEffortParam)

        let exact = CodexModelSpecifier(
            raw: "gpt-future-max",
            discoveredRecords: records + [record("gpt-future-max", efforts: ["high"])]
        )
        XCTAssertEqual(exact.appServerModelParam, "gpt-future-max")
        XCTAssertNil(exact.appServerEffortParam)
    }

    func testExactAdvertisedIDWinsMapperDisplayAndParsing() {
        let records = [
            record("  GPT-FUTURE  ", efforts: [" MAX ", " ULTRA "]),
            CodexDynamicModelRecord(
                id: " gPt-FuTuRe-MaX ",
                model: "gPt-FuTuRe-MaX",
                displayName: "Literal Max Model",
                description: "",
                isDefault: false
            ),
            CodexDynamicModelRecord(
                id: " gPt-FuTuRe-Ultra ",
                model: "gPt-FuTuRe-Ultra",
                displayName: "Literal Ultra Model",
                description: "",
                isDefault: false
            )
        ]

        let options = CodexDynamicModelMapper.options(from: records)
        XCTAssertEqual(Set(options.map(\.id)), ["GPT-FUTURE", "gPt-FuTuRe-MaX", "gPt-FuTuRe-Ultra"])
        XCTAssertEqual(
            options.first(where: { $0.id == "gPt-FuTuRe-MaX" })?.displayName,
            "Literal Max Model"
        )
        XCTAssertEqual(
            options.first(where: { $0.id == "gPt-FuTuRe-Ultra" })?.displayName,
            "Literal Ultra Model"
        )
        XCTAssertEqual(
            CodexDynamicModelMapper.displayName(forModelID: "  GPT-FUTURE-MAX  ", records: records),
            "Literal Max Model"
        )
        XCTAssertEqual(
            CodexDynamicModelMapper.displayName(forModelID: "  GPT-FUTURE-ULTRA  ", records: records),
            "Literal Ultra Model"
        )

        for raw in ["  GPT-FUTURE-MAX  ", "  GPT-FUTURE-ULTRA  "] {
            let selection = CodexModelSpecifier(raw: raw, discoveredRecords: records)
            XCTAssertEqual(selection.appServerModelParam, raw.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertNil(selection.appServerEffortParam)
        }
    }

    func testParserUsesNormalizedBaseCapabilityRecordID() {
        let records = [record("  GPT-FUTURE  ", efforts: [" MAX "])]
        let selection = CodexModelSpecifier(raw: "gpt-future-max", discoveredRecords: records)
        XCTAssertEqual(selection.appServerModelParam, "gpt-future")
        XCTAssertEqual(selection.appServerEffortParam, "max")
    }

    func testFastCollisionUsesNormalizedAdvertisedID() {
        let records = [record("  GPT-5.5-FAST-MAX  ", efforts: [])]
        XCTAssertNil(
            CodexServiceTierVariantCatalog.fastVariantID(
                baseModelID: "gpt-5.5",
                reasoningEffort: .max,
                discoveredRecords: records
            )
        )
        XCTAssertEqual(
            CodexServiceTierVariantCatalog.fastVariantID(
                baseModelID: "gpt-5.5",
                reasoningEffort: .ultra,
                discoveredRecords: records
            ),
            "gpt-5.5-fast-ultra"
        )
    }

    func testAdvertisedDefaultEffortAndFastVariantAreDecoded() {
        let records = [record("gpt-5.5", efforts: [], defaultEffort: "ultra")]
        let selection = CodexModelSpecifier(raw: "gpt-5.5-fast-ultra", discoveredRecords: records)
        XCTAssertEqual(selection.appServerModelParam, "gpt-5.5")
        XCTAssertEqual(selection.appServerEffortParam, "ultra")
        XCTAssertEqual(selection.appServerServiceTierParam, "fast")
    }

    func testExtendedEffortCollisionKeepsBothAdvertisedModelsSelectable() {
        let records = [record("gpt-future", efforts: ["max"]), record("gpt-future-max", efforts: ["high"])]
        let options = CodexDynamicModelMapper.options(from: records)
        XCTAssertEqual(Set(options.map(\.id)), ["gpt-future", "gpt-future-max-high"])
        for option in options {
            let selection = CodexModelSpecifier(raw: option.id, discoveredRecords: records)
            XCTAssertEqual(selection.appServerModelParam, option.baseID)
            XCTAssertEqual(selection.appServerEffortParam, option.reasoningEffort?.rawValue)
        }
    }

    func testPersistedCapabilityRefreshAndRemovalReachTheParser() throws {
        let suite = "CodexDiscoveredEffortTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for effort in ["max", "ultra"] {
            CodexDynamicModelStore.save([
                .init(
                    id: "gpt-future", model: "gpt-future", displayName: "Future", description: "", isDefault: false,
                    supportedReasoningEfforts: [.init(reasoningEffort: effort, description: "")], defaultReasoningEffort: effort
                )
            ], defaults: defaults)
            let records = CodexDynamicModelStore.load(defaults: defaults)
            let options = CodexDynamicModelMapper.options(from: records)
            XCTAssertEqual(options.map(\.id), ["gpt-future-\(effort)"])
            let selection = CodexModelSpecifier(raw: options.first?.id, discoveredRecords: records)
            XCTAssertEqual(selection.appServerModelParam, "gpt-future")
            XCTAssertEqual(selection.appServerEffortParam, effort)
        }
        defaults.removePersistentDomain(forName: suite)
        XCTAssertTrue(CodexDynamicModelStore.load(defaults: defaults).isEmpty)
    }

    func testFastEffortVariantCannotShadowAnAdvertisedModel() {
        let records = [record("gpt-5.5", efforts: ["max", "ultra"]), record("gpt-5.5-fast-max", efforts: ["high"])]
        XCTAssertNil(CodexServiceTierVariantCatalog.fastVariantID(baseModelID: "gpt-5.5", reasoningEffort: .max, discoveredRecords: records))
        XCTAssertEqual(
            CodexServiceTierVariantCatalog.fastVariantID(baseModelID: "gpt-5.5", reasoningEffort: .ultra, discoveredRecords: records),
            "gpt-5.5-fast-ultra"
        )
        let exact = CodexModelSpecifier(raw: "gpt-5.5-fast-max", discoveredRecords: records)
        XCTAssertEqual(exact.appServerModelParam, "gpt-5.5-fast-max")
        XCTAssertNil(exact.appServerEffortParam)
        XCTAssertNil(exact.appServerServiceTierParam)
    }

    func testPartialDiscoveryRetainsLegacyEffortSelections() {
        let records = [record("gpt-5.6-sol", efforts: ["high"])]
        let selection = CodexModelSpecifier(raw: "gpt-5.6-sol-ultra", discoveredRecords: records)
        XCTAssertEqual(selection.appServerModelParam, "gpt-5.6-sol")
        XCTAssertEqual(selection.appServerEffortParam, "ultra")
    }

    func testMissingDiscoveryRetainsLegacySelections() {
        for (raw, base, effort) in [
            ("gpt-5.6-sol-ultra", "gpt-5.6-sol", "ultra"),
            ("gpt-5.6-luna-max", "gpt-5.6-luna", "max"),
            ("gpt-5.1-codex-max-high", "gpt-5.1-codex-max", "high")
        ] {
            let selection = CodexModelSpecifier(raw: raw, discoveredRecords: [])
            XCTAssertEqual(selection.appServerModelParam, base)
            XCTAssertEqual(selection.appServerEffortParam, effort)
        }
        let base = CodexModelSpecifier(raw: "gpt-5.1-codex-max", discoveredRecords: [])
        XCTAssertEqual(base.appServerModelParam, "gpt-5.1-codex-max")
        XCTAssertNil(base.appServerEffortParam)
    }

    private func record(_ id: String, efforts: [String], defaultEffort: String? = nil) -> CodexDynamicModelRecord {
        CodexDynamicModelRecord(
            id: id, model: id, displayName: id, description: "", isDefault: false,
            supportedReasoningEfforts: efforts.map { .init(reasoningEffort: $0, description: "") },
            defaultReasoningEffort: defaultEffort
        )
    }
}
