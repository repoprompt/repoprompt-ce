import Foundation
import RepoPromptCodeMapCore
import RepoPromptFileSystem
@testable import RepoPromptWorkspaceContext
import XCTest

final class HostResourceCodeMapAdmissionTests: XCTestCase {
    private enum Failure: Error { case blockedBehindUnrelatedReadActivity }

    func testCapturedSourceDemandBuildProgressesDuringForegroundSearch() async throws {
        let data = Data("public struct CapturedDemand { public var value: Int }\n".utf8)
        let fingerprint = FileContentFingerprint(
            deviceID: 1, fileNumber: 2, byteSize: Int64(data.count),
            modificationSeconds: 3, modificationNanoseconds: 4,
            statusChangeSeconds: 5, statusChangeNanoseconds: 6
        )
        let source = CodeMapSourceSnapshot(validatedContent: ValidatedRawFileContentSnapshot(
            data: data, modificationDate: fingerprint.modificationDate, fingerprint: fingerprint
        ))
        let input = try CodeMapArtifactBuildInput(source: source, language: .swift)
        let builder = CodeMapArtifactBuilderClient()
        // The previous default builder acquired the codemap bulk-read permit. That
        // permit is suppressed for this entire scope, so a captured-source demand
        // could never finish until an unrelated search ended (or its query timed out).
        let result = try await FileSystemService.withContentReadForegroundActivity(kind: .storeBackedSearch) {
            try await withThrowingTaskGroup(of: CodeMapArtifactBuilderExecution.self) { group in
                group.addTask { try await builder.execute(input, UUID(), .demand) }
                group.addTask {
                    try await Task.sleep(for: .seconds(5))
                    throw Failure.blockedBehindUnrelatedReadActivity
                }
                defer { group.cancelAll() }
                let result = try await group.next()
                return try XCTUnwrap(result)
            }
        }
        guard case let .ready(artifact) = result.outcome else {
            return XCTFail("Expected a parsed artifact, got \(result.outcome)")
        }
        XCTAssertEqual(artifact.definedTypeNames, ["CapturedDemand"])
    }
}
