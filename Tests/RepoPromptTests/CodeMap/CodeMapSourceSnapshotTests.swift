import Foundation
@testable import RepoPrompt
import XCTest

final class CodeMapSourceSnapshotTests: XCTestCase {
    func testSnapshotPreservesExactBytesDigestCountAndValidationToken() {
        let data = Data("hello".utf8)
        let fingerprint = makeFingerprint(byteSize: data.count)
        let snapshot = CodeMapSourceSnapshot(
            validatedContent: ValidatedRawFileContentSnapshot(
                data: data,
                modificationDate: fingerprint.modificationDate,
                fingerprint: fingerprint
            )
        )

        XCTAssertEqual(snapshot.rawBytes, data)
        XCTAssertEqual(snapshot.rawByteCount, data.count)
        XCTAssertEqual(
            snapshot.rawSHA256.lowercaseHex,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
        XCTAssertEqual(snapshot.decoderPolicy, .workspaceAutomaticV1)
        XCTAssertEqual(
            snapshot.decodeResult,
            .decoded(
                CodeMapDecodedSource(
                    text: "hello",
                    detectedEncodingRawValue: String.Encoding.utf8.rawValue
                )
            )
        )
        XCTAssertEqual(snapshot.provenance, .validatedWorktree(CodeMapSourceValidationToken(fingerprint: fingerprint)))
    }

    func testSnapshotIdentityIsStableAndDistinguishesByteEncodingsWithSameText() throws {
        let utf8Data = Data("same text".utf8)
        var utf16Data = Data([0xFF, 0xFE])
        try utf16Data.append(XCTUnwrap("same text".data(using: .utf16LittleEndian)))

        let utf8 = makeSnapshot(data: utf8Data)
        let repeatedUTF8 = makeSnapshot(data: utf8Data)
        let utf16 = makeSnapshot(data: utf16Data)

        XCTAssertEqual(utf8.rawBytes, repeatedUTF8.rawBytes)
        XCTAssertEqual(utf8.rawByteCount, repeatedUTF8.rawByteCount)
        XCTAssertEqual(utf8.rawSHA256, repeatedUTF8.rawSHA256)
        XCTAssertEqual(utf8.decodeResult, repeatedUTF8.decodeResult)
        XCTAssertNotEqual(utf8.rawSHA256, utf16.rawSHA256)
        XCTAssertNotEqual(utf8.rawByteCount, utf16.rawByteCount)
        XCTAssertEqual(decodedText(utf8), decodedText(utf16))
    }

    func testSnapshotDecodeResultDistinguishesEmptyAndUndecodableBytes() {
        let empty = makeSnapshot(data: Data())
        let invalidUTF16 = makeSnapshot(data: Data([0xFF, 0xFE, 0x00, 0xD8]))

        XCTAssertEqual(
            empty.decodeResult,
            .decoded(
                CodeMapDecodedSource(
                    text: "",
                    detectedEncodingRawValue: String.Encoding.utf8.rawValue
                )
            )
        )
        XCTAssertEqual(invalidUTF16.decodeResult, .failed(.undecodable))
    }

    func testDigestRejectsInvalidWidthAndSnapshotHasNoCodableSurface() throws {
        let digest = CodeMapRawSourceDigest(bytes: Data(repeating: 0xAB, count: 32))
        let encodedDigest = try JSONEncoder().encode(digest)
        XCTAssertEqual(try JSONDecoder().decode(CodeMapRawSourceDigest.self, from: encodedDigest), digest)

        let invalidEncodedDigest = try JSONEncoder().encode(Data(repeating: 0xAB, count: 31))
        XCTAssertThrowsError(
            try JSONDecoder().decode(CodeMapRawSourceDigest.self, from: invalidEncodedDigest)
        )
        XCTAssertFalse(isCodable(CodeMapSourceSnapshot.self))
    }

    private func makeSnapshot(data: Data) -> CodeMapSourceSnapshot {
        let fingerprint = makeFingerprint(byteSize: data.count)
        return CodeMapSourceSnapshot(
            validatedContent: ValidatedRawFileContentSnapshot(
                data: data,
                modificationDate: fingerprint.modificationDate,
                fingerprint: fingerprint
            )
        )
    }

    private func makeFingerprint(byteSize: Int) -> FileContentFingerprint {
        FileContentFingerprint(
            deviceID: 1,
            fileNumber: 2,
            byteSize: Int64(byteSize),
            modificationSeconds: 3,
            modificationNanoseconds: 4,
            statusChangeSeconds: 5,
            statusChangeNanoseconds: 6
        )
    }

    private func decodedText(_ snapshot: CodeMapSourceSnapshot) -> String? {
        guard case let .decoded(decoded) = snapshot.decodeResult else {
            XCTFail("Expected the shared workspace decoder to recognize this source encoding.")
            return nil
        }
        return decoded.text
    }

    private func isCodable(_ type: Any.Type) -> Bool {
        type is any Codable.Type
    }
}
