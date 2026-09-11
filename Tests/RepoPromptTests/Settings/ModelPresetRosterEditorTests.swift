import Foundation
@testable import RepoPromptApp
import XCTest

final class ModelPresetRosterEditorTests: XCTestCase {
    func testDraftPreservesDuplicateIdentityOrderAndPrimaryPromotion() throws {
        var draft = ModelPresetRosterDraft(modelStrings: ["first", "duplicate", "duplicate"])
        let duplicateIDs = draft.rows.dropFirst().map(\.id)

        XCTAssertEqual(Set(duplicateIDs).count, 2)
        XCTAssertTrue(draft.remove(id: draft.rows[0].id))
        XCTAssertEqual(draft.rows.map(\.modelString), ["duplicate", "duplicate"])
        XCTAssertEqual(draft.rows.map(\.id), duplicateIDs)

        draft.move(from: 1, to: 0)
        XCTAssertEqual(draft.rows.map(\.id), Array(duplicateIDs.reversed()))
        let preset = try ModelPreset(name: "Ordered", modelStrings: draft.rows.map(\.modelString))
        XCTAssertEqual(preset.modelStrings, ["duplicate", "duplicate"])
    }

    func testDraftEnforcesOneAndFiveModelBounds() {
        var draft = ModelPresetRosterDraft(modelStrings: ["one"])
        XCTAssertFalse(draft.remove(id: draft.rows[0].id))

        XCTAssertTrue(draft.append(modelString: "two"))
        XCTAssertTrue(draft.append(modelString: "three"))
        XCTAssertTrue(draft.append(modelString: "four"))
        XCTAssertTrue(draft.append(modelString: "five"))
        XCTAssertFalse(draft.append(modelString: "six"))
        XCTAssertEqual(draft.rows.count, 5)
    }

    func testDraftRetainsUnresolvedStoredModelWhenEditingOtherFields() throws {
        let unresolved = "provider/model-no-longer-in-catalog"
        let draft = ModelPresetRosterDraft(modelStrings: [unresolved, AIModel.gpt54.rawValue])

        let preset = try ModelPreset(
            name: "Renamed",
            modelStrings: draft.rows.map(\.modelString),
            description: "Updated"
        )

        XCTAssertEqual(preset.modelStrings, [unresolved, AIModel.gpt54.rawValue])
        XCTAssertNil(preset.optionalPrimaryModel)
    }
}
