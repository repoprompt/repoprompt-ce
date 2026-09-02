import Darwin
import Dispatch
import Foundation
@testable import RepoPromptApp
import XCTest

final class OracleImageAttachmentLoaderTests: XCTestCase {
    private var testRoot: URL!

    override func setUpWithError() throws {
        testRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/oracle-image-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
    }

    func testLoadsClassicFormatsAndPreservesOrderWithoutPaths() throws {
        let fixtures: [(String, Data, AIImageMediaType)] = [
            ("one.png", Self.pngData, .png),
            ("two.JPG", Self.jpegData, .jpeg),
            ("three.gif", Self.gifData, .gif),
            ("four.webp", Self.webpData, .webp)
        ]
        let requests = try fixtures.enumerated().map { index, fixture in
            let url = testRoot.appendingPathComponent(fixture.0)
            try fixture.1.write(to: url)
            return OracleImageRequest(index: index, path: url.path, title: "Image \(index + 1)")
        }

        let images = try OracleImageAttachmentLoader().load(
            requests: requests,
            authority: authority(logical: testRoot, physical: testRoot)
        )

        XCTAssertEqual(images.map(\.mediaType), fixtures.map(\.2))
        XCTAssertEqual(images.map(\.bytes), fixtures.map(\.1))
        XCTAssertEqual(images.map(\.title), ["Image 1", "Image 2", "Image 3", "Image 4"])
    }

    func testLogicalPathReadsBoundPhysicalWorktreeFile() throws {
        let logicalRoot = testRoot.appendingPathComponent("logical", isDirectory: true)
        let physicalRoot = testRoot.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: logicalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: physicalRoot, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: logicalRoot.appendingPathComponent("asset.png"))
        try Self.pngData.write(to: physicalRoot.appendingPathComponent("asset.png"))

        let images = try OracleImageAttachmentLoader().load(
            requests: [.init(
                index: 0,
                path: logicalRoot.appendingPathComponent("asset.png").path,
                title: nil
            )],
            authority: authority(logical: logicalRoot, physical: physicalRoot)
        )

        XCTAssertEqual(images.first?.bytes, Self.pngData)
    }

    func testRejectsNonCanonicalOutsideAndSymlinkPathsWithoutLeakingThem() throws {
        let imageURL = testRoot.appendingPathComponent("image.png")
        try Self.pngData.write(to: imageURL)
        let linkURL = testRoot.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: imageURL)
        let siblingURL = testRoot.deletingLastPathComponent().appendingPathComponent("outside-\(UUID()).png")
        try Self.pngData.write(to: siblingURL)
        defer { try? FileManager.default.removeItem(at: siblingURL) }

        let cases = [
            "relative.png",
            testRoot.appendingPathComponent("folder/../image.png").path,
            siblingURL.path,
            linkURL.path
        ]
        for path in cases {
            XCTAssertThrowsError(try OracleImageAttachmentLoader().load(
                requests: [.init(index: 0, path: path, title: nil)],
                authority: authority(logical: testRoot, physical: testRoot)
            )) { error in
                XCTAssertFalse(error.localizedDescription.contains(testRoot.path))
                XCTAssertFalse(error.localizedDescription.contains("image.png"))
                XCTAssertFalse(error.localizedDescription.contains("link.png"))
            }
        }
    }

    func testAllowsSymlinkedTrustedRootButRejectsSymlinksBelowIt() throws {
        let actualRoot = testRoot.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actualRoot, withIntermediateDirectories: true)
        try Self.gifData.write(to: actualRoot.appendingPathComponent("image.gif"))

        let trustedRoot = testRoot.appendingPathComponent("trusted-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: trustedRoot, withDestinationURL: actualRoot)
        let pinnedAuthority = try authority(logical: trustedRoot, physical: trustedRoot)
        let images = try OracleImageAttachmentLoader().load(
            requests: [.init(
                index: 0,
                path: trustedRoot.appendingPathComponent("image.gif").path,
                title: nil
            )],
            authority: pinnedAuthority
        )
        XCTAssertEqual(images.first?.bytes, Self.gifData)

        let retargetedRoot = testRoot.appendingPathComponent("retargeted", isDirectory: true)
        try FileManager.default.createDirectory(at: retargetedRoot, withIntermediateDirectories: true)
        let retargetedData = Data(Array("GIF87a".utf8) + [2, 0, 1, 0])
        try retargetedData.write(to: retargetedRoot.appendingPathComponent("image.gif"))
        try FileManager.default.removeItem(at: trustedRoot)
        try FileManager.default.createSymbolicLink(at: trustedRoot, withDestinationURL: retargetedRoot)
        let pinnedImages = try OracleImageAttachmentLoader().load(
            requests: [.init(
                index: 0,
                path: trustedRoot.appendingPathComponent("image.gif").path,
                title: nil
            )],
            authority: pinnedAuthority
        )
        XCTAssertEqual(pinnedImages.first?.bytes, Self.gifData)

        let realDirectory = actualRoot.appendingPathComponent("real-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try Self.gifData.write(to: realDirectory.appendingPathComponent("nested.gif"))
        try FileManager.default.createSymbolicLink(
            at: actualRoot.appendingPathComponent("linked-directory", isDirectory: true),
            withDestinationURL: realDirectory
        )
        XCTAssertThrowsError(try OracleImageAttachmentLoader().load(
            requests: [.init(
                index: 0,
                path: trustedRoot.appendingPathComponent("linked-directory/nested.gif").path,
                title: nil
            )],
            authority: pinnedAuthority
        )) { error in
            guard let loadError = error as? OracleImageLoadError else {
                return XCTFail("Expected OracleImageLoadError, got \(error)")
            }
            XCTAssertTrue(
                loadError == .unsafePath(index: 0)
                    || loadError == .missingOrUnreadable(index: 0)
            )
        }
    }

    func testParentCancellationCancelsDetachedLoad() async throws {
        let imageURL = testRoot.appendingPathComponent("cancel.gif")
        try Self.gifData.write(to: imageURL)
        let authority = try authority(logical: testRoot, physical: testRoot)
        let started = DispatchSemaphore(value: 0)
        let loader = OracleImageAttachmentLoader(afterFirstRead: { _ in
            started.signal()
            let deadline = Date().addingTimeInterval(2)
            while !Task.isCancelled, Date() < deadline {
                Darwin.usleep(1000)
            }
            guard Task.isCancelled else {
                throw CancellationProbeError.notPropagated
            }
            throw CancellationError()
        })
        let task = Task {
            try await OracleImageAttachmentLoader.loadDetached(
                requests: [.init(index: 0, path: imageURL.path, title: nil)],
                authority: authority,
                loader: loader
            )
        }

        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: parent cancellation reached detached loader work.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testEnforcesPerImageAndTotalLimitsBeforeReturningPayloads() throws {
        let firstURL = testRoot.appendingPathComponent("first.gif")
        let secondURL = testRoot.appendingPathComponent("second.gif")
        try Self.gifData.write(to: firstURL)
        try Self.gifData.write(to: secondURL)

        XCTAssertThrowsError(try OracleImageAttachmentLoader(
            limits: .init(maxCount: 10, maxBytesPerImage: Self.gifData.count - 1, maxTotalBytes: 100)
        ).load(
            requests: [.init(index: 0, path: firstURL.path, title: nil)],
            authority: authority(logical: testRoot, physical: testRoot)
        )) { error in
            XCTAssertEqual(
                error as? OracleImageLoadError,
                .tooLarge(index: 0, maximumBytes: Self.gifData.count - 1)
            )
        }

        XCTAssertThrowsError(try OracleImageAttachmentLoader(
            limits: .init(
                maxCount: 10,
                maxBytesPerImage: Self.gifData.count,
                maxTotalBytes: Self.gifData.count * 2 - 1
            )
        ).load(
            requests: [
                .init(index: 0, path: firstURL.path, title: nil),
                .init(index: 1, path: secondURL.path, title: nil)
            ],
            authority: authority(logical: testRoot, physical: testRoot)
        )) { error in
            XCTAssertEqual(
                error as? OracleImageLoadError,
                .totalTooLarge(maximumBytes: Self.gifData.count * 2 - 1)
            )
        }
    }

    func testRejectsExtensionMismatchIncompleteJPEGAndFileReplacementDuringRead() throws {
        let incompleteJPEGURL = testRoot.appendingPathComponent("incomplete.jpg")
        try Self.jpegData.dropLast(2).write(to: incompleteJPEGURL)
        XCTAssertThrowsError(try OracleImageAttachmentLoader().load(
            requests: [.init(index: 0, path: incompleteJPEGURL.path, title: nil)],
            authority: authority(logical: testRoot, physical: testRoot)
        )) { error in
            XCTAssertEqual(error as? OracleImageLoadError, .unsupportedFormat(index: 0))
        }

        let mismatchURL = testRoot.appendingPathComponent("wrong.jpg")
        try Self.pngData.write(to: mismatchURL)
        XCTAssertThrowsError(try OracleImageAttachmentLoader().load(
            requests: [.init(index: 0, path: mismatchURL.path, title: nil)],
            authority: authority(logical: testRoot, physical: testRoot)
        )) { error in
            XCTAssertEqual(
                error as? OracleImageLoadError,
                .extensionMismatch(index: 0, mediaType: .png)
            )
        }

        let changingURL = testRoot.appendingPathComponent("changing.gif")
        try Self.gifData.write(to: changingURL)
        let replacement = Data(Array("GIF87a".utf8) + [2, 0, 1, 0])
        let loader = OracleImageAttachmentLoader(afterFirstRead: { _ in
            try replacement.write(to: changingURL, options: .atomic)
        })
        XCTAssertThrowsError(try loader.load(
            requests: [.init(index: 0, path: changingURL.path, title: nil)],
            authority: authority(logical: testRoot, physical: testRoot)
        )) { error in
            XCTAssertEqual(error as? OracleImageLoadError, .changedWhileReading(index: 0))
        }
    }

    func testPhysicalRootCapturePinsEveryAliasToOneIdentity() throws {
        let originalRoot = testRoot.appendingPathComponent("original", isDirectory: true)
        let retargetedRoot = testRoot.appendingPathComponent("retargeted", isDirectory: true)
        try FileManager.default.createDirectory(at: originalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retargetedRoot, withIntermediateDirectories: true)
        try Self.gifData.write(to: originalRoot.appendingPathComponent("image.gif"))
        let replacement = Data(Array("GIF87a".utf8) + [2, 0, 1, 0])
        try replacement.write(to: retargetedRoot.appendingPathComponent("image.gif"))

        let trustedRoot = testRoot.appendingPathComponent("trusted-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: trustedRoot, withDestinationURL: originalRoot)
        let capture = try OracleImagePhysicalRootCapture.capture(
            physicalRootPath: trustedRoot.path,
            index: 0
        )
        let firstAlias = testRoot.appendingPathComponent("alias-a", isDirectory: true)
        let firstProjection = capture.projection(logicalRootPath: firstAlias.path)

        try FileManager.default.removeItem(at: trustedRoot)
        try FileManager.default.createSymbolicLink(at: trustedRoot, withDestinationURL: retargetedRoot)
        let secondAlias = testRoot.appendingPathComponent("alias-b", isDirectory: true)
        let secondProjection = capture.projection(logicalRootPath: secondAlias.path)

        XCTAssertEqual(firstProjection.rootIdentity, secondProjection.rootIdentity)
        XCTAssertEqual(firstProjection.resolvedPhysicalRootPath, secondProjection.resolvedPhysicalRootPath)

        let images = try OracleImageAttachmentLoader().load(
            requests: [
                .init(index: 0, path: firstAlias.appendingPathComponent("image.gif").path, title: nil),
                .init(index: 1, path: secondAlias.appendingPathComponent("image.gif").path, title: nil),
                .init(index: 2, path: trustedRoot.appendingPathComponent("image.gif").path, title: nil)
            ],
            authority: OracleImageWorkspaceAuthority(roots: [
                firstProjection,
                secondProjection,
                capture.projection(logicalRootPath: trustedRoot.path)
            ])
        )
        XCTAssertEqual(images.map(\.bytes), [Self.gifData, Self.gifData, Self.gifData])
    }

    private func authority(logical: URL, physical: URL) throws -> OracleImageWorkspaceAuthority {
        let capture = try OracleImagePhysicalRootCapture.capture(
            physicalRootPath: physical.path,
            index: 0
        )
        return OracleImageWorkspaceAuthority(roots: [
            capture.projection(logicalRootPath: logical.path)
        ])
    }

    private enum CancellationProbeError: Error {
        case notPropagated
    }

    private static let pngData: Data = {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += [0, 0, 0, 13]
        bytes += Array("IHDR".utf8)
        bytes += Array(repeating: 0, count: 17)
        return Data(bytes)
    }()

    private static let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0xFF, 0xD9])
    private static let gifData = Data(Array("GIF89a".utf8) + [1, 0, 1, 0])
    private static let webpData = Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBPVP8 ".utf8))
}
