@testable import RepoPromptApp
import XCTest

final class AppDomainRuntimeCompositionTests: XCTestCase {
    func testCollectLegacyRuntimeDefaultsSerializesBooleanScalarFragments() throws {
        for value in [true, false] {
            let (defaults, suiteName) = try makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(value, forKey: "agentModeAutoEditEnabled")

            let collected = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)
            let data = try XCTUnwrap(collected["agentModeAutoEditEnabled"])

            XCTAssertEqual(try JSONDecoder().decode(Bool.self, from: data), value)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), value ? "true" : "false")
        }
    }

    func testCollectLegacyRuntimeDefaultsPreservesRawDataAlongsideBoolean() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let approvalBytes = Data([0x00, 0xFF, 0x7B, 0x01])
        defaults.set(approvalBytes, forKey: "workspace.approvalSettings")
        defaults.set(false, forKey: "agentModeAutoEditEnabled")

        let collected = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)

        XCTAssertEqual(collected["workspace.approvalSettings"], approvalBytes)
        let booleanData = try XCTUnwrap(collected["agentModeAutoEditEnabled"])
        XCTAssertFalse(try JSONDecoder().decode(Bool.self, from: booleanData))
    }

    func testCollectLegacyRuntimeDefaultsSkipsInvalidValueWithoutMutationAndIsRepeatable() throws {
        let (defaults, suiteName) = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let invalidDate = Date(timeIntervalSince1970: 1_725_000_000)
        defaults.set(invalidDate, forKey: "workspace.approvalSettings")
        defaults.set(true, forKey: "agentModeAutoEditEnabled")

        let first = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)
        let second = AppDomainRuntimeComposition.collectLegacyRuntimeDefaults(from: defaults)

        XCTAssertEqual(first, second)
        XCTAssertNil(first["workspace.approvalSettings"])
        let booleanData = try XCTUnwrap(first["agentModeAutoEditEnabled"])
        XCTAssertTrue(try JSONDecoder().decode(Bool.self, from: booleanData))
        XCTAssertEqual(defaults.object(forKey: "workspace.approvalSettings") as? Date, invalidDate)
        XCTAssertEqual(defaults.object(forKey: "agentModeAutoEditEnabled") as? Bool, true)
    }

    private func makeIsolatedDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "AppDomainRuntimeCompositionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
