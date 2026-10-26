import Foundation
@testable import RepoPromptApp
import XCTest

final class AgentSessionLaneProvenanceCodecTests: XCTestCase {
    func testProvenanceRoundTripsThroughSessionMetadataAndSidebarEntry() throws {
        let creatorID = UUID()
        let session = AgentSession(
            id: UUID(),
            composeTabID: UUID(),
            name: "Lane",
            createdByOverseerSessionID: creatorID
        )
        let decodedSession = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decodedSession.createdByOverseerSessionID, creatorID)

        let record = AgentSessionMetadataRecord.record(
            from: decodedSession,
            fileURL: URL(fileURLWithPath: "AgentSession-lane.json"),
            observedFileSize: nil,
            observedFileModificationDate: nil
        )
        let decodedRecord = try JSONDecoder().decode(
            AgentSessionMetadataRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decodedRecord.createdByOverseerSessionID, creatorID)
        XCTAssertEqual(decodedRecord.agentSessionMeta().createdByOverseerSessionID, creatorID)
        XCTAssertEqual(decodedRecord.sidebarEntry()?.createdByOverseerSessionID, creatorID)
        XCTAssertEqual(
            AgentSessionRestoreSupport.buildSidebarIndexEntry(from: decodedSession, tabID: UUID(), name: "Lane").createdByOverseerSessionID,
            creatorID
        )
    }

    func testOldFilesDecodeWithoutProvenanceAndUnknownKeysAreIgnored() throws {
        let session = AgentSession(id: UUID(), name: "Old session")
        let record = AgentSessionMetadataRecord.record(
            from: session,
            fileURL: URL(fileURLWithPath: "AgentSession-old.json"),
            observedFileSize: nil,
            observedFileModificationDate: nil
        )
        for encoded in try [JSONEncoder().encode(session), JSONEncoder().encode(record)] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            object.removeValue(forKey: "createdByOverseerSessionID")
            object["futureField"] = ["unknown": true]
            let oldFile = try JSONSerialization.data(withJSONObject: object)
            if object["filename"] == nil {
                XCTAssertNil(try JSONDecoder().decode(AgentSession.self, from: oldFile).createdByOverseerSessionID)
            } else {
                let decoded = try JSONDecoder().decode(AgentSessionMetadataRecord.self, from: oldFile)
                XCTAssertNil(decoded.createdByOverseerSessionID)
                XCTAssertNil(decoded.sidebarEntry(tabID: UUID())?.createdByOverseerSessionID)
            }
        }
    }
}
