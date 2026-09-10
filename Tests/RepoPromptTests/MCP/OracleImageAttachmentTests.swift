import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

/// Contract for the Oracle MCP image-attachment surface: argument parsing,
/// workspace-root confinement, content sniffing, limits, and transport admission.
final class OracleImageAttachmentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OracleImageAttachmentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Loading

    func testLoadsSupportedFormatsAndSniffsMediaTypeIgnoringExtension() throws {
        let png = try write("diagram.png", bytes: Self.pngBytes)
        // Extension deliberately lies: sniffing is authoritative.
        let jpeg = try write("photo.png", bytes: Self.jpegBytes)

        let images = try loader().load([
            OracleImageRequest(index: 0, path: png.path, title: "  Diagram  "),
            OracleImageRequest(index: 1, path: jpeg.path, title: "   ")
        ])

        XCTAssertEqual(images.map(\.mediaType), [.png, .jpeg])
        XCTAssertEqual(images[0].bytes, Self.pngBytes)
        XCTAssertEqual(images[0].title, "  Diagram  ")
        XCTAssertEqual(images[0].normalizedTitle, "Diagram")
        XCTAssertNil(images[1].normalizedTitle)
        XCTAssertEqual(images[0].openAIDataURL, "data:image/png;base64,\(Self.pngBytes.base64EncodedString())")
    }

    func testRejectsPathsOutsideWorkspaceRootsIncludingSymlinkAndTraversalEscapes() throws {
        let outside = root.appendingPathComponent("outside")
        let inside = root.appendingPathComponent("inside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.png")
        try Self.pngBytes.write(to: secret)
        let escape = inside.appendingPathComponent("escape.png")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: secret)

        let scoped = OracleImageAttachmentLoader(workspaceRootPaths: [inside.path])

        assertLoadError(.outsideWorkspaceRoots(index: 0)) {
            try scoped.load([OracleImageRequest(index: 0, path: secret.path, title: nil)])
        }
        assertLoadError(.outsideWorkspaceRoots(index: 0)) {
            try scoped.load([OracleImageRequest(index: 0, path: escape.path, title: nil)])
        }
        assertLoadError(.outsideWorkspaceRoots(index: 0)) {
            try scoped.load([OracleImageRequest(
                index: 0,
                path: inside.path + "/../outside/secret.png",
                title: nil
            )])
        }
        assertLoadError(.invalidPath(index: 0)) {
            try scoped.load([OracleImageRequest(index: 0, path: "relative/secret.png", title: nil)])
        }
        // An empty root list admits nothing.
        assertLoadError(.outsideWorkspaceRoots(index: 0)) {
            try OracleImageAttachmentLoader(workspaceRootPaths: [])
                .load([OracleImageRequest(index: 0, path: secret.path, title: nil)])
        }
    }

    func testRejectsDirectoriesMissingFilesAndUnsupportedContent() throws {
        let directory = root.appendingPathComponent("folder.png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = try write("notes.png", bytes: Data("not an image".utf8))

        assertLoadError(.notRegularFile(index: 0)) {
            try loader().load([OracleImageRequest(index: 0, path: directory.path, title: nil)])
        }
        assertLoadError(.missingOrUnreadable(index: 0)) {
            try loader().load([OracleImageRequest(
                index: 0,
                path: root.appendingPathComponent("absent.png").path,
                title: nil
            )])
        }
        assertLoadError(.unsupportedFormat(index: 0)) {
            try loader().load([OracleImageRequest(index: 0, path: text.path, title: nil)])
        }
    }

    func testEnforcesCountPerImageAndTotalLimits() throws {
        let png = try write("diagram.png", bytes: Self.pngBytes)
        let request = OracleImageRequest(index: 0, path: png.path, title: nil)

        assertLoadError(.tooMany(maximumCount: 1)) {
            try loader(limits: OracleImageAttachmentLimits(maxCount: 1, maxBytesPerImage: 64, maxTotalBytes: 128))
                .load([request, OracleImageRequest(index: 1, path: png.path, title: nil)])
        }
        assertLoadError(.tooLarge(index: 0, maximumBytes: 4)) {
            try loader(limits: OracleImageAttachmentLimits(maxCount: 2, maxBytesPerImage: 4, maxTotalBytes: 128))
                .load([request])
        }
        assertLoadError(.totalTooLarge(maximumBytes: Self.pngBytes.count + 1)) {
            try loader(limits: OracleImageAttachmentLimits(
                maxCount: 2,
                maxBytesPerImage: 1024,
                maxTotalBytes: Self.pngBytes.count + 1
            )).load([request, OracleImageRequest(index: 1, path: png.path, title: nil)])
        }
        XCTAssertEqual(try loader().load([]).count, 0)
    }

    // MARK: - MCP argument contract

    @MainActor
    func testParserAcceptsBoundedPathAndOptionalTitleObjects() throws {
        XCTAssertEqual(try MCPOracleToolService.parseOracleImageRequests(nil), [])
        XCTAssertEqual(try MCPOracleToolService.parseOracleImageRequests(.array([])), [])

        let parsed = try MCPOracleToolService.parseOracleImageRequests(.array([
            .object([
                "path": .string("/workspace/diagram.png"),
                "title": .string("  Architecture  "),
                "_meta": .string("ignored")
            ]),
            .object(["path": .string("/workspace/photo.jpg")])
        ]))

        XCTAssertEqual(parsed, [
            OracleImageRequest(index: 0, path: "/workspace/diagram.png", title: "Architecture"),
            OracleImageRequest(index: 1, path: "/workspace/photo.jpg", title: nil)
        ])
    }

    @MainActor
    func testParserRejectsExpandedAttachmentShapes() {
        let cases: [Value] = [
            .string("/workspace/diagram.png"),
            .array([.string("/workspace/diagram.png")]),
            .array([.object([:])]),
            .array([.object(["path": .string("   ")])]),
            .array([.object([
                "path": .string("/workspace/diagram.png"),
                "url": .string("https://example.com/image.png")
            ])]),
            .array([.object([
                "path": .string("/workspace/diagram.png"),
                "title": .string(String(repeating: "x", count: 201))
            ])]),
            .array((0 ... OracleImageAttachmentLimits.production.maxCount).map {
                .object(["path": .string("/workspace/\($0).png")])
            })
        ]
        for value in cases {
            XCTAssertThrowsError(
                try MCPOracleToolService.parseOracleImageRequests(value),
                "Expected \(value) to be rejected"
            )
        }
    }

    // MARK: - Transport admission

    func testAdmissionAllowsImageCapableTransportsAndRejectsUnsupportedCLIOnes() {
        let supported: [AIModel] = [
            .claude4Sonnet,
            .gpt5,
            .openaiCustom(name: "custom"),
            .ollama,
            .geminiFlash25,
            .deepseekChat,
            .ompCustom(name: "openai/gpt-5.2"),
            .devinCustom(name: "devin-gpt-5.2")
        ]
        for model in supported {
            XCTAssertTrue(OracleImageRouteAdmission.supports(model), "Expected \(model) to admit images")
        }

        let rejected: [AIModel] = [
            .claudeCodeSonnet,
            .codexCustom(name: "codex"),
            .cursorCustom(name: "cursor"),
            .grokBuildCustom(name: "grok")
        ]
        for model in rejected {
            XCTAssertFalse(OracleImageRouteAdmission.supports(model), "Expected \(model) to reject images")
        }
    }

    // MARK: - Helpers

    private static let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02, 0x03])
    private static let jpegBytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])

    private func loader(
        limits: OracleImageAttachmentLimits = .production
    ) -> OracleImageAttachmentLoader {
        OracleImageAttachmentLoader(workspaceRootPaths: [root.path], limits: limits)
    }

    private func write(_ name: String, bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func assertLoadError(
        _ expected: OracleImageLoadError,
        line: UInt = #line,
        _ expression: () throws -> [AITransientImage]
    ) {
        XCTAssertThrowsError(try expression(), line: line) { error in
            XCTAssertEqual(error as? OracleImageLoadError, expected, line: line)
        }
    }
}
