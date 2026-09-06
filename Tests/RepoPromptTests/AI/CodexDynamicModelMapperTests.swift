import Foundation
@testable import RepoPromptApp
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
        let precedes = CodexDynamicModelMapper.optionPrecedes
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
        ])

        // Previously: 5.2-low < 5.2-high (effort), 5.2-high < 5.4-low
        // (default), and 5.4-low < 5.2-low (base version).
        XCTAssertEqual(options.map(\.id), ["gpt-5.2-high", "gpt-5.4-low", "gpt-5.2-low"])
        XCTAssertTrue(CodexDynamicModelMapper.optionPrecedes(options[0], options[2]))
    }

    func testEqualDisplayNamesUseNormalizedOptionIdentity() {
        let alpha = option(id: "future-alpha", base: "future-model", name: "Shared", effort: .high)
        let beta = option(id: "future-beta", base: "future-model", name: "shared", effort: .high)

        XCTAssertEqual(alpha.displayName.localizedCaseInsensitiveCompare(beta.displayName), .orderedSame)
        for input in [[alpha, beta], [beta, alpha]] {
            XCTAssertEqual(input.sorted(by: CodexDynamicModelMapper.optionPrecedes).map(\.id), [alpha.id, beta.id])
        }
    }

    func testMapperOrderIsIndependentOfUniqueRecordPermutation() {
        let records = [
            record(id: "gpt-5.2", isDefault: true, efforts: ["high", "low"], defaultEffort: "high"),
            record(id: "gpt-5.4", efforts: ["low"], defaultEffort: "low"),
            record(id: "future-b", displayName: "Shared"),
            record(id: "future-a", displayName: "shared")
        ]
        let expected = CodexDynamicModelMapper.options(from: records)
        for permutation in permutations(records) {
            XCTAssertEqual(CodexDynamicModelMapper.options(from: permutation), expected)
        }
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
