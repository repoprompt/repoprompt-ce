#if os(Linux)
    import Foundation
    import Glibc
    import RepoPromptC
    @testable import RepoPromptDomainRuntime
    import RepoPromptShared
    import XCTest

    final class LinuxPortabilityTests: XCTestCase {
        func testXDGDataHomePreservesDebugReleaseIsolation() throws {
            let home = URL(fileURLWithPath: "/tmp/repoprompt-linux-home", isDirectory: true)
            let locations = AppProfileLocations(
                identity: .repoPromptCE(.debug), homeDirectory: home,
                environment: ["XDG_DATA_HOME": "/tmp/repoprompt-linux-data"]
            )
            XCTAssertEqual(locations.applicationSupportRoot.path, "/tmp/repoprompt-linux-data/repoprompt-ce-debug")
            XCTAssertEqual(locations.releaseStateRoots.first?.path, "/tmp/repoprompt-linux-data/repoprompt-ce")
            XCTAssertThrowsError(try locations.validateWritableRoot(URL(fileURLWithPath: "/tmp/repoprompt-linux-data/repoprompt-ce")))
            let relative = AppProfileLocations(
                identity: .repoPromptCE(.release), homeDirectory: home,
                environment: ["XDG_DATA_HOME": "relative/path"]
            )
            XCTAssertEqual(relative.applicationSupportRoot.path, home.path + "/.local/share/repoprompt-ce")
        }

        func testExclusiveRenameNeverOverwritesAnExistingDestination() throws {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("source")
            let destination = directory.appendingPathComponent("destination")
            try Data("source".utf8).write(to: source)
            try Data("destination".utf8).write(to: destination)
            let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(fd, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            let renameResult = repo_rename_exclusive(fd, "source", fd, "destination")
            let renameError = errno
            XCTAssertEqual(renameResult, -1)
            XCTAssertEqual(renameError, EEXIST)
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "source")
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "destination")
            XCTAssertEqual(repo_rename_exclusive(fd, "source", fd, "moved"), 0)
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("moved"), encoding: .utf8), "source")
        }

        func testDescriptorPathIsResolvedAndTruncationRejected() throws {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(fd, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var path = [CChar](repeating: 0, count: 4096)
            XCTAssertEqual(repo_get_file_descriptor_path(fd, &path, path.count), 0)
            XCTAssertEqual(String(cString: path), directory.resolvingSymlinksInPath().path)
            var short = [CChar](repeating: 0, count: 2)
            let pathResult = repo_get_file_descriptor_path(fd, &short, short.count)
            let pathError = errno
            XCTAssertEqual(pathResult, -1)
            XCTAssertEqual(pathError, ENAMETOOLONG)
        }

        func testKernelRandomBytesAndBrokenPipeWrite() {
            var first = [UInt8](repeating: 0, count: 32)
            var second = [UInt8](repeating: 0, count: 32)
            XCTAssertEqual(repo_random_bytes(&first, first.count), 0)
            XCTAssertEqual(repo_random_bytes(&second, second.count), 0)
            XCTAssertNotEqual(first, second)
            var descriptors: [Int32] = [-1, -1]
            XCTAssertEqual(pipe(&descriptors), 0)
            guard descriptors.allSatisfy({ $0 >= 0 }) else { return }
            close(descriptors[0])
            defer { close(descriptors[1]) }
            var byte: UInt8 = 42
            let writeResult = repo_write_no_sigpipe(descriptors[1], &byte, 1)
            let writeError = errno
            XCTAssertEqual(writeResult, -1)
            XCTAssertEqual(writeError, EPIPE)
        }

        func testDescriptorPathRejectsAnUnlinkedFileEvenIfADeletedSuffixDecoyExists() throws {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("original (deleted)")
            try Data("original".utf8).write(to: file)
            let fd = open(file.path, O_RDONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(fd, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var path = [CChar](repeating: 0, count: 4096)
            XCTAssertEqual(repo_get_file_descriptor_path(fd, &path, path.count), 0)
            XCTAssertEqual(String(cString: path), file.path)
            try FileManager.default.removeItem(at: file)
            try Data("decoy".utf8).write(to: directory.appendingPathComponent("original (deleted) (deleted)"))
            XCTAssertEqual(repo_get_file_descriptor_path(fd, &path, path.count), -1)
        }

        func testNativeAttachmentsWorkWithoutAThumbnailRenderer() throws {
            let png = try AttachmentTestFixtures.requireEncodedImage(.png)
            let payload = try AttachmentClassifier.classify(bytes: png, fileName: "picture.png")
            XCTAssertEqual(payload, .image(.png, png))
            XCTAssertNil(try AttachmentPreviewRenderer.jpegData(from: OracleAttachment(payload: payload, fileName: "picture.png", title: nil)))
        }

        func testAttachmentRootCaptureReadsTheAdmittedFileAndRejectsPathSubstitution() throws {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let root = directory.appendingPathComponent("root", isDirectory: true)
            let outside = directory.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let png = try AttachmentTestFixtures.requireEncodedImage(.png)
            try png.write(to: root.appendingPathComponent("image.png"))
            try png.write(to: outside.appendingPathComponent("image.png"))
            let capture = try OracleImagePhysicalRootCapture.capture(physicalRootPath: root.path, index: 0)
            XCTAssertNil(capture.rootIdentity.generation)
            let authority = OracleImageWorkspaceAuthority(roots: [capture.projection(logicalRootPath: root.path)])
            let requests = [OracleAttachmentRequest(index: 0, path: root.appendingPathComponent("image.png").path, title: nil)]
            let loaded = try OracleAttachmentLoader().load(requests: requests, authority: authority)
            XCTAssertEqual(loaded.count, 1)
            XCTAssertEqual(loaded.first?.payload, .image(.png, png))
            try FileManager.default.moveItem(at: root, to: directory.appendingPathComponent("held"))
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
            XCTAssertThrowsError(try OracleAttachmentLoader().load(requests: requests, authority: authority))
        }

        func testBitmapConversionWithOptionalImageMagick() throws {
            var bytes = Data([
                0x42, 0x4D, 58, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0,
                40, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 24, 0,
                0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0
            ])
            bytes.append(contentsOf: [0, 0, 255, 0])
            let result: AttachmentPayload
            do {
                result = try AttachmentClassifier.classify(bytes: bytes, fileName: "red.bmp")
            } catch AttachmentClassificationError.imageConverterUnavailable {
                throw XCTSkip("ImageMagick is optional; conversion requires it to be installed")
            }
            guard case let .image(type, converted) = result else { return XCTFail("Expected a converted image") }
            XCTAssertEqual(type, .jpeg)
            XCTAssertTrue(converted.starts(with: [0xFF, 0xD8, 0xFF]))
        }

        func testTIFFConversionPreservesAlphaWithOptionalImageMagick() throws {
            // One uncompressed RGBA pixel with 50% alpha, encoded as an 8-bit TIFF.
            let bytes = try XCTUnwrap(Data(base64Encoded: "SUkqAAwAAAD/AAB/EAAAAQMAAQAAAAEAAAABAQMAAQAAAAEAAAACAQMABAAAANIAAAADAQMAAQAAAAEAAAAGAQMAAQAAAAIAAAAKAQMAAQAAAAEAAAARAQQAAQAAAAgAAAASAQMAAQAAAAEAAAAVAQMAAQAAAAQAAAAWAQMAAQAAAAEAAAAXAQQAAQAAAAQAAAAcAQMAAQAAAAEAAAApAQMAAgAAAAAAAQA+AQUAAgAAAAoBAAA/AQUABgAAANoAAABSAQMAAQAAAAIAAAAAAAAACAAIAAgACACF61EAAACAAMP1qAAAAAACzcxMAAAAAAHNzEwAAACAAM3MTAAAAAACj8L1AAAAABA3GqAAAAAAAiuHCgAAACAA"))
            let result: AttachmentPayload
            do {
                result = try AttachmentClassifier.classify(bytes: bytes, fileName: "transparent.tiff")
            } catch AttachmentClassificationError.imageConverterUnavailable {
                throw XCTSkip("ImageMagick is optional; conversion requires it to be installed")
            }
            guard case let .image(type, converted) = result else { return XCTFail("Expected a converted image") }
            XCTAssertEqual(type, .png)
            XCTAssertTrue(converted.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        }

        private func temporaryDirectory() throws -> URL {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return directory
        }
    }
#endif
