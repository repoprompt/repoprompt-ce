import RepoPromptDomainRuntime
import XCTest

final class ApplyEditsNoChangeTests: XCTestCase {
    func testNetZeroBatchesKeepMatchesButNeverWrite() async throws {
        let cases: [[ApplyEditsOperation]] = [
            [.init(search: "A", replace: "B", replaceAll: false), .init(search: "B", replace: "A", replaceAll: false)],
            [.init(search: "A", replace: "A", replaceAll: false)],
            [.init(search: "A", replace: "A", replaceAll: true)],
            [.init(search: "A", replace: "B", replaceAll: false), .init(search: "missing", replace: "C", replaceAll: false), .init(search: "B", replace: "A", replaceAll: false)]
        ]
        for edits in cases {
            let host = RecordingEditHost(text: "A\n")
            let service = ApplyEditsService(engine: .default, host: host)
            let result = try await service.run(.init(path: "file.txt", mode: .batch(edits), verbose: false))

            XCTAssertEqual(result.status.rawValue, "no_change")
            XCTAssertEqual(result.editsApplied, 0)
            XCTAssertEqual(result.editsRequested, edits.count)
            XCTAssertTrue(result.updatedText.utf8.elementsEqual("A\n".utf8))
            XCTAssertEqual(result.outcomes?.count, edits.count)
            XCTAssertEqual(result.outcomes?.count(where: { $0.status == "success" }), edits.count == 3 ? 2 : edits.count)
            XCTAssertTrue(result.note?.contains("no net change") == true)
            XCTAssertNil(result.stats)
            XCTAssertTrue(result.diffChunks.isEmpty)
            XCTAssertNil(result.unifiedDiff)
            XCTAssertNil(result.toolCardUnifiedDiff)
            let writes = await host.writeCount
            XCTAssertEqual(writes, 0)
        }
    }

    func testUnicodeNormalizationChangeIsNotAByteIdenticalNoOp() async throws {
        let original = "\u{00E9}\n"
        let replacement = "e\u{0301}\n"
        let host = RecordingEditHost(text: original)
        let result = try await ApplyEditsService(engine: .default, host: host).run(.init(
            path: "unicode.txt",
            mode: .batch([.init(search: original, replace: replacement, replaceAll: false)]),
            verbose: false
        ))
        XCTAssertEqual(result.status, .success)
        XCTAssertTrue(result.updatedText.utf8.elementsEqual(replacement.utf8))
        let writes = await host.writeCount
        XCTAssertEqual(writes, 1)
    }

    func testWhitespaceMutationAndEmptyCreationStillWrite() async throws {
        let host = RecordingEditHost(text: "A B\n")
        let service = ApplyEditsService(engine: .default, host: host)
        let result = try await service.run(.init(
            path: "file.txt", mode: .batch([.init(search: "A B", replace: "AB", replaceAll: false)]), verbose: false
        ))
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.editsApplied, 1)
        let changedText = await host.text
        let writes = await host.writeCount
        XCTAssertEqual(changedText, "AB\n")
        XCTAssertEqual(writes, 1)

        let missingHost = RecordingEditHost(text: nil)
        let created = try await ApplyEditsService(engine: .default, host: missingHost).run(.init(
            path: "empty.txt", mode: .rewrite(newText: "", onMissing: .create), verbose: false
        ))
        XCTAssertEqual(created.status, .success)
        XCTAssertTrue(created.fileCreated)
        let createWrites = await missingHost.writeCount
        XCTAssertEqual(createWrites, 1)
    }
}

private actor RecordingEditHost: FileEditHost {
    var text: String?
    var writeCount = 0

    init(text: String?) {
        self.text = text
    }

    func fileExists(path: String) async -> Bool {
        text != nil
    }

    func readText(path: String) async throws -> String {
        text ?? ""
    }

    func writeText(path: String, content: String, overwrite: Bool) async throws {
        writeCount += 1
        text = content
    }
}
