import Foundation
@testable import RepoPromptAIContracts
import XCTest

final class CodexDynamicModelMapperTests: XCTestCase {
    func testOptionComparatorObeysStrictWeakOrdering() {
        var options: [CodexDynamicModelOption] = []
        let efforts: [CodexReasoningEffort?] = [nil, .low, .high]
        for base in ["gpt-5.2", "gpt-5.4", "future-model"] {
            for effort in efforts {
                options.append(option(
                    id: "\(base)-\(effort?.rawValue ?? "base")",
                    base: base,
                    name: "\(base) \(effort?.rawValue ?? "Base")",
                    effort: effort,
                    isDefault: base == "gpt-5.2" && effort == .high
                ))
            }
        }
        options.append(option(id: "gpt-5.4-default", base: "gpt-5.4", name: "GPT-5.4", effort: .high, isDefault: true))
        options.append(option(id: "future-model-alpha", base: "future-model", name: "Shared", effort: .high))
        options.append(option(id: "future-model-beta", base: "future-model", name: "shared", effort: .high))
        options.append(option(id: "FUTURE-MODEL-ALPHA", base: "FUTURE-MODEL", name: "SHARED", effort: .high))
        let precedes: (CodexDynamicModelOption, CodexDynamicModelOption) -> Bool = {
            CodexDynamicModelMapper.optionPrecedes($0, $1, catalogRecords: { [] })
        }
        let equivalent = { (lhs: CodexDynamicModelOption, rhs: CodexDynamicModelOption) in
            !precedes(lhs, rhs) && !precedes(rhs, lhs)
        }

        for lhs in options {
            XCTAssertFalse(precedes(lhs, lhs), "Irreflexivity: \(lhs.id)")
            for middle in options {
                if precedes(lhs, middle) {
                    XCTAssertFalse(precedes(middle, lhs), "Asymmetry: \(lhs.id), \(middle.id)")
                }
                for rhs in options {
                    if precedes(lhs, middle), precedes(middle, rhs) {
                        XCTAssertTrue(precedes(lhs, rhs), "Transitivity: \(lhs.id), \(middle.id), \(rhs.id)")
                    }
                    if equivalent(lhs, middle), equivalent(middle, rhs) {
                        XCTAssertTrue(equivalent(lhs, rhs), "Equivalence: \(lhs.id), \(middle.id), \(rhs.id)")
                    }
                }
            }
        }
    }

    func testDefaultPriorityRemovesThePreviousThreeOptionCycle() {
        let options = CodexDynamicModelMapper.options(from: [
            record(id: "gpt-5.2", isDefault: true, efforts: ["low", "high"], defaultEffort: "high"),
            record(id: "gpt-5.4", efforts: ["low"], defaultEffort: "low")
        ], catalogRecords: { [] })

        // Previously: 5.2-low < 5.2-high (effort), 5.2-high < 5.4-low
        // (default), and 5.4-low < 5.2-low (base version).
        XCTAssertEqual(options.map(\.id), ["gpt-5.2-high", "gpt-5.4-low", "gpt-5.2-low"])
        XCTAssertTrue(CodexDynamicModelMapper.optionPrecedes(options[0], options[2], catalogRecords: { [] }))
    }

    func testEqualDisplayNamesUseNormalizedOptionIdentity() {
        let alpha = option(id: "future-alpha", base: "future-model", name: "Shared", effort: .high)
        let beta = option(id: "future-beta", base: "future-model", name: "shared", effort: .high)

        XCTAssertEqual(alpha.displayName.localizedCaseInsensitiveCompare(beta.displayName), .orderedSame)
        for input in [[alpha, beta], [beta, alpha]] {
            XCTAssertEqual(input.sorted { CodexDynamicModelMapper.optionPrecedes($0, $1, catalogRecords: { [] }) }.map(\.id), [alpha.id, beta.id])
        }
    }

    func testMapperOrderIsIndependentOfUniqueRecordPermutation() {
        let records = [
            record(id: "gpt-5.2", isDefault: true, efforts: ["high", "low"], defaultEffort: "high"),
            record(id: "gpt-5.4", efforts: ["low"], defaultEffort: "low"),
            record(id: "future-b", displayName: "Shared"),
            record(id: "future-a", displayName: "shared")
        ]
        let expected = CodexDynamicModelMapper.options(from: records, catalogRecords: { [] })
        for permutation in permutations(records) {
            XCTAssertEqual(CodexDynamicModelMapper.options(from: permutation, catalogRecords: { [] }), expected)
        }
    }

    func testLegacyRecordDefaultsAndRawIdentityRoundTrip() throws {
        let legacy = Data(#"{"id":" GPT-Future-MAX ","model":"remote-model","displayName":"Future","description":"description","isDefault":true}"#.utf8)
        let record = try JSONDecoder().decode(CodexDynamicModelRecord.self, from: legacy)
        XCTAssertEqual(record.id, " GPT-Future-MAX ")
        XCTAssertEqual(record.model, "remote-model")
        XCTAssertTrue(record.supportedReasoningEfforts.isEmpty)
        XCTAssertNil(record.defaultReasoningEffort)
        XCTAssertTrue(record.serviceTiers.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(CodexDynamicModelRecord.self, from: JSONEncoder().encode(record)), record)

        let future = Data(#"{"id":"future","model":"future","displayName":"Future","description":"","isDefault":false,"supportedReasoningEfforts":[{"reasoningEffort":"provider-future","description":"opaque"}],"defaultReasoningEffort":"provider-future","serviceTiers":[{"id":"future-tier","name":"Future Tier","description":"opaque tier"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(CodexDynamicModelRecord.self, from: future)
        XCTAssertEqual(decoded.supportedReasoningEfforts.first?.reasoningEffort, "provider-future")
        XCTAssertEqual(decoded.defaultReasoningEffort, "provider-future")
        XCTAssertEqual(decoded.serviceTiers.first?.id, "future-tier")
        XCTAssertEqual(try JSONDecoder().decode(CodexDynamicModelRecord.self, from: JSONEncoder().encode(decoded)), decoded)
    }

    func testExplicitLookupIsLazyAndExactAdvertisedIdentityWins() {
        var lookups = 0
        let records = [CodexDynamicModelRecord(id: "gpt-5.6-max", model: "gpt-5.6-max", displayName: "", description: "", isDefault: false)]
        func lookup() -> [CodexDynamicModelRecord] {
            lookups += 1
            return records
        }
        for raw: String? in [nil, "", "  ", "default"] {
            XCTAssertNil(CodexModelSpecifier(raw: raw, catalogRecords: lookup).baseModel)
        }
        XCTAssertEqual(lookups, 0)
        let exact = CodexModelSpecifier(raw: "gpt-5.6-max", catalogRecords: lookup)
        XCTAssertEqual(exact.baseModel, "gpt-5.6-max")
        XCTAssertNil(exact.reasoningEffort)
        XCTAssertEqual(lookups, 1)
        let synthetic = CodexModelSpecifier(raw: "gpt-5.6-max", catalogRecords: { [] })
        XCTAssertEqual(synthetic.baseModel, "gpt-5.6")
        XCTAssertEqual(synthetic.reasoningEffort, .max)
    }

    func testStructuredEmptyTiersAndDefaultOptionSemantics() {
        XCTAssertTrue(CodexServiceTierVariantCatalog.advertisedTiers(from: [
            "serviceTiers": [[String: Any]](), "additionalSpeedTiers": ["ultrafast"]
        ]).isEmpty)
        let record = CodexDynamicModelRecord(
            id: "gpt-5.6", model: "gpt-5.6", displayName: "", description: "base", isDefault: true,
            supportedReasoningEfforts: [.init(reasoningEffort: "high", description: "high description")],
            defaultReasoningEffort: "medium"
        )
        let options = CodexDynamicModelMapper.options(from: [record], catalogRecords: { [] })
        XCTAssertEqual(options.map(\.id), ["gpt-5.6-medium", "gpt-5.6-high"])
        XCTAssertEqual(options.map(\.isDefault), [true, false])
        XCTAssertEqual(options.first?.description, "base")
        XCTAssertEqual(options.first?.supportedReasoningEffortRawValues, ["high", "medium"])
        XCTAssertEqual(CodexModelSpecifier(raw: "default", catalogRecords: { [] }).cliModelArgs, [])
    }

    private func option(
        id: String,
        base: String,
        name: String,
        effort: CodexReasoningEffort?,
        isDefault: Bool = false
    ) -> CodexDynamicModelOption {
        CodexDynamicModelOption(id: id, displayName: name, description: "", isDefault: isDefault, baseID: base, reasoningEffort: effort)
    }

    private func record(
        id: String,
        displayName: String? = nil,
        isDefault: Bool = false,
        efforts: [String] = [],
        defaultEffort: String? = nil
    ) -> CodexDynamicModelRecord {
        CodexDynamicModelRecord(
            id: id,
            model: id,
            displayName: displayName ?? id,
            description: "",
            isDefault: isDefault,
            supportedReasoningEfforts: efforts.map { CodexDynamicReasoningRecord(reasoningEffort: $0, description: "") },
            defaultReasoningEffort: defaultEffort
        )
    }

    private func permutations(_ records: [CodexDynamicModelRecord]) -> [[CodexDynamicModelRecord]] {
        guard records.count > 1 else { return [records] }
        return records.indices.flatMap { index in
            var rest = records
            let first = rest.remove(at: index)
            return permutations(rest).map { [first] + $0 }
        }
    }
}
