@testable import RepoPromptCore
import XCTest

final class WorkspacePersistedOptionCompatibilityTests: XCTestCase {
    func testPersistedWorkspaceOptionRawValuesOrderingAndCodableBytesRemainStable() throws {
        XCTAssertEqual(FileTreeOption.allCases, [.auto, .files, .selected, .none])
        XCTAssertEqual(FileTreeOption.allCases.map(\.rawValue), ["Auto", "Full", "Selected", "None"])
        XCTAssertEqual(FileTreeOption.allCases.map(\.id), ["Auto", "Full", "Selected", "None"])
        XCTAssertEqual(try encodedStrings(FileTreeOption.allCases), ["Auto", "Full", "Selected", "None"])

        XCTAssertEqual(CodeMapUsage.allCases, [.auto, .complete, .selected, .none])
        XCTAssertEqual(CodeMapUsage.allCases.map(\.rawValue), ["auto", "complete", "selected", "none"])
        XCTAssertEqual(try encodedStrings(CodeMapUsage.allCases), ["auto", "complete", "selected", "none"])

        XCTAssertEqual(GitInclusion.allCases, [.none, .selected, .complete])
        XCTAssertEqual(GitInclusion.allCases.map(\.rawValue), ["none", "selected", "complete"])
        XCTAssertEqual(try encodedStrings(GitInclusion.allCases), ["none", "selected", "complete"])

        XCTAssertEqual(FilesTab.selected.rawValue, "Selected Files")
        XCTAssertEqual(FilesTab.context.rawValue, "Context Builder")
        XCTAssertEqual(try JSONDecoder().decode(FilesTab.self, from: Data(#""Apply XML""#.utf8)), .context)
        XCTAssertEqual(try JSONDecoder().decode(FilesTab.self, from: Data(#""unknown""#.utf8)), .context)

        let customizations = CopyCustomizations(
            selectedPromptIDs: [UUID(uuidString: "99999999-8888-7777-6666-555555555555")!],
            fileTreeMode: .files,
            codeMapUsage: .selected,
            gitInclusion: .complete,
            includeFiles: true,
            includeUserPrompt: false,
            includeMetaPrompts: true,
            includeFileTree: false
        )
        let bytes = try JSONEncoder().encode(customizations)
        XCTAssertEqual(
            try canonicalJSON(bytes),
            try canonicalJSON(Data(#"{"selectedPromptIDs":["99999999-8888-7777-6666-555555555555"],"fileTreeMode":"Full","codeMapUsage":"selected","gitInclusion":"complete","includeFiles":true,"includeUserPrompt":false,"includeMetaPrompts":true,"includeFileTree":false}"#.utf8))
        )
        XCTAssertEqual(try JSONDecoder().decode(CopyCustomizations.self, from: bytes), customizations)
    }

    private func encodedStrings<T: Encodable>(_ values: [T]) throws -> [String] {
        try values.map { value in
            try JSONDecoder().decode(String.self, from: JSONEncoder().encode(value))
        }
    }

    private func canonicalJSON(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
