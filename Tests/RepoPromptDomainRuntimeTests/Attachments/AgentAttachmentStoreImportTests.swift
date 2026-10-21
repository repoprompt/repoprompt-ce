import Foundation
import RepoPromptDomainRuntime
import XCTest

final class AgentAttachmentStoreImportTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workspace)
    }

    private func write(_ data: Data, as name: String) throws -> URL {
        let url = workspace.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func imported(_ data: Data, as name: String) throws -> AgentFileAttachment {
        let source = try write(data, as: name)
        return try AgentAttachmentStore().importFile(sourceURL: source, workspaceDirectory: workspace).attachment
    }

    func testImportRecordsKindFromBytesNotExtension() throws {
        let csv = try imported(Data("a,b\n1,2\n".utf8), as: "sales.csv")
        XCTAssertEqual(csv.kind, .text)
        XCTAssertEqual(csv.fileName, "sales.csv")
        XCTAssertEqual(csv.byteCount, 8)

        XCTAssertEqual(try imported(AttachmentTestFixtures.pdfBytes(), as: "spec.pdf").kind, .pdf)
        XCTAssertEqual(try imported(Data([0, 1, 2, 3]), as: "blob.dat").kind, .binary)
        XCTAssertEqual(try imported(Data("not an image".utf8), as: "liar.png").kind, .text)
    }

    func testImportCopiesIntoManagedStorageAndKeepsOnlyTheFileName() throws {
        let source = try write(Data("hello".utf8), as: "notes.txt")
        let result = try AgentAttachmentStore().importFile(sourceURL: source, workspaceDirectory: workspace)
        XCTAssertTrue(result.fileURL.path.hasPrefix(AgentAttachmentStore.managedStorageRootURL(for: workspace).path))
        XCTAssertEqual(result.attachment.fileName, "notes.txt")
        XCTAssertFalse(result.attachment.fileName.contains("/"))
    }

    func testImportRejectsFolders() throws {
        let folder = workspace.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AgentAttachmentStore().importFile(sourceURL: folder, workspaceDirectory: workspace)) { error in
            guard case AgentAttachmentStore.Error.sourceIsNotFile = error else { return XCTFail("\(error)") }
        }
    }
}
