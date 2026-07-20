import CryptoKit
import Foundation
@testable import RepoPromptApp
import RepoPromptCodeMapCore
import XCTest

final class CodeMapSourceSnapshotAdapterTests: XCTestCase {
    func testCoreAdapterPreservesRawProvenanceAndDecodedTextWithoutReread() throws {
        let utf8 = Data("same text".utf8)
        var utf16 = Data([0xFF, 0xFE])
        try utf16.append(XCTUnwrap("same text".data(using: .utf16LittleEndian)))

        let first = makeSource(data: utf8, fingerprintSeed: 1)
        let repeated = makeSource(data: utf8, fingerprintSeed: 999)
        let alternateEncoding = makeSource(data: utf16, fingerprintSeed: 1)

        XCTAssertEqual(first.coreSnapshot, repeated.coreSnapshot)
        XCTAssertNotEqual(first.coreSnapshot.rawSHA256, alternateEncoding.coreSnapshot.rawSHA256)
        XCTAssertNotEqual(first.coreSnapshot.rawByteCount, alternateEncoding.coreSnapshot.rawByteCount)
        XCTAssertEqual(decodedText(first.coreSnapshot), decodedText(alternateEncoding.coreSnapshot))

        let identity = try SyntaxManager().pipelineIdentity(
            for: .swift,
            decoderPolicy: .workspaceAutomaticV1
        )
        XCTAssertEqual(
            try CodeMapArtifactKey(source: first, pipelineIdentity: identity),
            try CodeMapArtifactKey(source: repeated, pipelineIdentity: identity)
        )
        XCTAssertNotEqual(
            try CodeMapArtifactKey(source: first, pipelineIdentity: identity),
            try CodeMapArtifactKey(source: alternateEncoding, pipelineIdentity: identity)
        )
    }

    private func makeSource(data: Data, fingerprintSeed: Int64) -> CodeMapSourceSnapshot {
        let fingerprint = FileContentFingerprint(
            deviceID: UInt64(fingerprintSeed),
            fileNumber: UInt64(fingerprintSeed + 1),
            byteSize: Int64(data.count),
            modificationSeconds: fingerprintSeed + 2,
            modificationNanoseconds: fingerprintSeed + 3,
            statusChangeSeconds: fingerprintSeed + 4,
            statusChangeNanoseconds: fingerprintSeed + 5
        )
        return CodeMapSourceSnapshot(
            validatedContent: ValidatedRawFileContentSnapshot(
                data: data,
                modificationDate: Date(timeIntervalSince1970: TimeInterval(fingerprintSeed + 2)),
                fingerprint: fingerprint
            ),
            decoderPolicy: .workspaceAutomaticV1
        )
    }

    private func decodedText(_ snapshot: CodeMapCoreSourceSnapshot) -> String? {
        guard case let .decoded(decoded) = snapshot.decodeResult else { return nil }
        return decoded.text
    }
}
