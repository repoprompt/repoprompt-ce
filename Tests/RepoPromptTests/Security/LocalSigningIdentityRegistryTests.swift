import Darwin
@testable import RepoPrompt
import XCTest

final class LocalSigningIdentityRegistryTests: XCTestCase {
    private let fingerprint = String(repeating: "AB", count: 32)

    func testLoadsOwnerOnlyVersionedRecord() throws {
        let url = try writeRegistry()

        XCTAssertEqual(
            LocalSigningIdentityRegistry.load(from: url),
            .success(
                LocalSigningIdentityRecord(
                    schemaVersion: 1,
                    certificateName: RuntimeCodeSigningPolicy.localSelfSignedCertificateName,
                    certificateSHA256: fingerprint,
                    serviceGeneration: 7
                )
            )
        )
    }

    func testRejectsMissingWrongOwnerInsecureAndMalformedRegistry() throws {
        let directory = try temporaryDirectory()
        let missing = directory.appendingPathComponent("missing.json")
        XCTAssertEqual(LocalSigningIdentityRegistry.load(from: missing), .failure(.missing))

        let valid = try writeRegistry(in: directory)
        XCTAssertEqual(
            LocalSigningIdentityRegistry.load(from: valid, expectedOwnerID: getuid() + 1),
            .failure(.wrongOwner)
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: valid.path)
        XCTAssertEqual(LocalSigningIdentityRegistry.load(from: valid), .failure(.insecurePermissions))

        try "not-json".write(to: valid, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: valid.path)
        XCTAssertEqual(LocalSigningIdentityRegistry.load(from: valid), .failure(.invalidRecord))
    }

    func testSigningContextRequiresMatchingSignedMetadataAndRegistryGeneration() {
        let record = LocalSigningIdentityRecord(
            schemaVersion: 1,
            certificateName: RuntimeCodeSigningPolicy.localSelfSignedCertificateName,
            certificateSHA256: fingerprint,
            serviceGeneration: 7
        )

        XCTAssertEqual(
            RuntimeCodeSigningPolicy.localSigningContext(
                bundleFingerprint: fingerprint.lowercased(),
                bundleGenerationMarker: "7",
                registryResult: .success(record)
            ),
            .valid(
                RuntimeLocalSigningExpectation(
                    bundleLeafCertificateSHA256: fingerprint,
                    registeredLeafCertificateSHA256: fingerprint,
                    bundleServiceGeneration: 7,
                    registeredServiceGeneration: 7
                )
            )
        )
        XCTAssertEqual(
            RuntimeCodeSigningPolicy.localSigningContext(
                bundleFingerprint: nil,
                bundleGenerationMarker: "7",
                registryResult: .success(record)
            ),
            .invalid(.localIdentityMetadataUnavailable)
        )
        XCTAssertEqual(
            RuntimeCodeSigningPolicy.localSigningContext(
                bundleFingerprint: fingerprint,
                bundleGenerationMarker: "8",
                registryResult: .success(record)
            ),
            .invalid(.localIdentityContinuityMismatch)
        )
        XCTAssertEqual(
            RuntimeCodeSigningPolicy.localSigningContext(
                bundleFingerprint: fingerprint,
                bundleGenerationMarker: "7",
                registryResult: .failure(.insecurePermissions)
            ),
            .invalid(.localIdentityRegistryUnavailable)
        )
    }

    private func writeRegistry(in directory: URL? = nil) throws -> URL {
        let directory = try directory ?? temporaryDirectory()
        let url = directory.appendingPathComponent("local-signing-identity-v1.json")
        let record = LocalSigningIdentityRecord(
            schemaVersion: 1,
            certificateName: RuntimeCodeSigningPolicy.localSelfSignedCertificateName,
            certificateSHA256: fingerprint,
            serviceGeneration: 7
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
