@testable import RepoPromptApp
import XCTest

final class CodexContextWindowConfigurationTests: XCTestCase {
    func testPresetOverridesArePairedAndDefaultIsEmpty() {
        XCTAssertTrue(CodexContextWindowPreferences.overrides(.codexDefault).isEmpty)
        XCTAssertTrue(CodexContextWindowPreferences.cliArguments(.codexDefault).isEmpty)
        XCTAssertEqual(CodexContextWindowPreferences.cliArguments(.tokens1M), ["-c", "model_auto_compact_token_limit=900000", "-c", "model_context_window=1000000"])
        for (selection, window, compact) in [
            (CodexContextWindowPreferences.Selection.tokens500K, 500_000, 450_000),
            (.tokens800K, 800_000, 720_000),
            (.tokens1M, 1_000_000, 900_000)
        ] {
            let overrides = CodexContextWindowPreferences.overrides(selection)
            XCTAssertEqual(overrides["model_context_window"], window)
            XCTAssertEqual(overrides["model_auto_compact_token_limit"], compact)
            let appServer = CodexNativeSessionController.defaultAppServerConfigOverrides(serverEntries: [], contextWindowSelection: selection)
            XCTAssertEqual(appServer["model_context_window"] as? Int, window)
            XCTAssertEqual(appServer["model_auto_compact_token_limit"] as? Int, compact)
        }
        let defaults = CodexNativeSessionController.defaultAppServerConfigOverrides(serverEntries: [])
        XCTAssertNil(defaults["model_context_window"])
        XCTAssertNil(defaults["model_auto_compact_token_limit"])
    }

    func testSelectionOrderAndLabels() {
        let selections = CodexContextWindowPreferences.Selection.allCases
        XCTAssertEqual(selections.map(\.rawValue), ["default", "500000", "600000", "700000", "800000", "900000", "1000000"])
        XCTAssertEqual(selections.map(\.label), ["Codex default", "500K tokens", "600K tokens", "700K tokens", "800K tokens", "900K tokens", "1M tokens"])
    }

    func testLegacySelectionIsReadWithoutRewriting() throws {
        let name = "CodexContextWindowLegacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let key = "codexContextWindowSelection"
        defaults.set("750000", forKey: key)
        XCTAssertEqual(CodexContextWindowPreferences.selection(defaults: defaults), .tokens800K)
        XCTAssertEqual(defaults.string(forKey: key), "750000")
        defaults.set("unknown", forKey: key)
        XCTAssertEqual(CodexContextWindowPreferences.selection(defaults: defaults), .codexDefault)
        XCTAssertEqual(defaults.string(forKey: key), "unknown")
    }

    @MainActor
    func testBindingKeepsSelectionAcrossControllerReplacementButColdSessionUsesCurrent() {
        let session = AgentTabSession(tabID: UUID())
        XCTAssertEqual(session.codexContextWindowForBinding(current: .tokens500K), .tokens500K)
        XCTAssertEqual(session.codexContextWindowForBinding(current: .tokens1M), .tokens500K)
        let coldSession = AgentTabSession(tabID: UUID())
        XCTAssertEqual(coldSession.codexContextWindowForBinding(current: .tokens1M), .tokens1M)
    }

    func testSelectionPersistence() throws {
        let name = "CodexContextWindowConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(CodexContextWindowPreferences.selection(defaults: defaults), .codexDefault)
        CodexContextWindowPreferences.setSelection(.tokens1M, defaults: defaults)
        XCTAssertEqual(CodexContextWindowPreferences.selection(defaults: defaults), .tokens1M)
        CodexContextWindowPreferences.setSelection(.codexDefault, defaults: defaults)
        XCTAssertEqual(CodexContextWindowPreferences.selection(defaults: defaults), .codexDefault)
    }
}
