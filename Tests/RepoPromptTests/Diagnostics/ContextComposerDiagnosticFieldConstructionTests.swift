@testable import RepoPromptApp
import XCTest

#if DEBUG
    final class ContextComposerDiagnosticFieldConstructionTests: XCTestCase {
        func testAgentSelectedFilesDiagnosticsSkipsSelectionSignatureBuilderWhenDisabled() {
            var invocationCount = 0
            let expectedFields = ["selectionSignature": "agent-selection"]
            let selection = StoredSelection(selectedPaths: ["Sources/LargeSelection.swift"])

            let disabledFields = AgentSelectedFilesDiagnostics.selectionFields(
                selection,
                diagnosticsEnabled: false,
                signatureBuilder: { _ in
                    invocationCount += 1
                    return expectedFields
                }
            )

            XCTAssertTrue(disabledFields.isEmpty)
            XCTAssertEqual(invocationCount, 0)

            let enabledFields = AgentSelectedFilesDiagnostics.selectionFields(
                selection,
                diagnosticsEnabled: true,
                signatureBuilder: { _ in
                    invocationCount += 1
                    return expectedFields
                }
            )

            XCTAssertEqual(enabledFields, expectedFields)
            XCTAssertEqual(invocationCount, 1)
        }

        func testPromptTokenRecountDiagnosticsSkipsSelectionSignatureBuilderWhenDisabled() {
            var invocationCount = 0
            let expectedFields = ["selectionSignature": "prompt-selection"]
            let selection = StoredSelection(selectedPaths: ["Sources/LargeSelection.swift"])

            let disabledFields = PromptTokenRecountDiagnostics.selectionFields(
                selection,
                diagnosticsEnabled: false,
                signatureBuilder: { _ in
                    invocationCount += 1
                    return expectedFields
                }
            )

            XCTAssertTrue(disabledFields.isEmpty)
            XCTAssertEqual(invocationCount, 0)

            let enabledFields = PromptTokenRecountDiagnostics.selectionFields(
                selection,
                diagnosticsEnabled: true,
                signatureBuilder: { _ in
                    invocationCount += 1
                    return expectedFields
                }
            )

            XCTAssertEqual(enabledFields, expectedFields)
            XCTAssertEqual(invocationCount, 1)
        }
    }
#endif
