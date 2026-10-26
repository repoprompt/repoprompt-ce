import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class AgentHandoffOutputFileTests: XCTestCase {
    func testExactArgumentPreservesNativeTextAndDistinguishesOmittedFromInvalid() throws {
        XCTAssertNil(try AgentHandoffOutputFile.pathArgument(nil))
        XCTAssertNil(try AgentHandoffOutputFile.pathArgument(.null))
        for raw in ["", "/fixture/handoff.xml ", "/fixture/handoff.xml\n", "~/literal%20\t.xml "] {
            XCTAssertEqual(try AgentHandoffOutputFile.pathArgument(.string(raw)), raw)
        }
        for value in [Value.bool(true), .int(1), .array([]), .object([:])] {
            XCTAssertThrowsError(try AgentHandoffOutputFile.pathArgument(value)) { error in
                self.assertInvalidParams(error, "output_path must be a string.")
            }
        }
    }

    func testExactWhitespaceOutputWritesNewTargetAndPreservesViableTrimmedDecoy() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let target = fixture.appendingPathComponent("handoff.xml ")
        let decoy = fixture.appendingPathComponent("handoff.xml")
        let original = Data([0xDE, 0xC0])
        try original.write(to: decoy)
        let payload = "<handoff>雪\nexact</handoff>"
        let supplied = try XCTUnwrap(AgentHandoffOutputFile.pathArgument(.string(target.path)))
        let result = try await AgentHandoffOutputFile.write(payload, to: supplied, overwrite: false, homeDirectory: fixture)
        XCTAssertEqual(Array(result.path.utf8), Array(target.path.utf8))
        XCTAssertEqual(result.bytes, payload.utf8.count)
        XCTAssertEqual(try Data(contentsOf: target), Data(payload.utf8))
        XCTAssertEqual(try Data(contentsOf: decoy), original)
    }

    func testExactExistingTargetRetainsOverwriteAndDirectoryErrorContracts() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let target = fixture.appendingPathComponent("handoff.xml ")
        let decoy = fixture.appendingPathComponent("handoff.xml")
        let oldTarget = Data([1, 2]), oldDecoy = Data([3, 4])
        try oldTarget.write(to: target)
        try oldDecoy.write(to: decoy)
        do {
            _ = try await AgentHandoffOutputFile.write("refused", to: target.path, overwrite: false, homeDirectory: fixture)
            XCTFail("Existing exact target must refuse overwrite=false")
        } catch {
            assertInvalidParams(error, "output_path already exists and overwrite=false: \(target.path)")
        }
        XCTAssertEqual(try Data(contentsOf: target), oldTarget)
        XCTAssertEqual(try Data(contentsOf: decoy), oldDecoy)
        let result = try await AgentHandoffOutputFile.write("replacement", to: target.path, overwrite: true, homeDirectory: fixture)
        XCTAssertEqual(result.path, target.path)
        XCTAssertEqual(try Data(contentsOf: target), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: decoy), oldDecoy)
        do {
            _ = try await AgentHandoffOutputFile.write("refused", to: fixture.path, overwrite: true, homeDirectory: fixture)
            XCTFail("Directory target must be refused")
        } catch {
            assertInvalidParams(error, "output_path points to a directory: \(fixture.path)")
        }
    }

    func testRawLineAndNULCharactersAreRefusedBeforeTrimOrWrite() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let marker = fixture.appendingPathComponent("handoff.xml")
        let original = Data([31, 32])
        try original.write(to: marker)
        let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.path)
        for raw in [marker.path + "\n", "\n" + marker.path, marker.path + "\r", "\r" + marker.path, marker.path + "\0ignored"] {
            let supplied = try XCTUnwrap(AgentHandoffOutputFile.pathArgument(.string(raw)))
            do {
                _ = try await AgentHandoffOutputFile.write("must not write", to: supplied, overwrite: true, homeDirectory: fixture)
                XCTFail("Raw single-path control character must be refused")
            } catch {
                assertInvalidParams(error, "output_path must be a single filesystem path.")
            }
            XCTAssertEqual(try Data(contentsOf: marker), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.path), entries)
        }
    }

    func testExplicitHomeExpansionPreservesLiteralFilenameAndRefusesRelativeOrNamedUser() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let target = fixture.appendingPathComponent("nested", isDirectory: true).appendingPathComponent("雪%20#?\t.xml ")
        let raw = "~/nested/雪%20#?\t.xml "
        let result = try await AgentHandoffOutputFile.write("literal", to: raw, overwrite: false, homeDirectory: fixture)
        XCTAssertEqual(Array(result.path.utf8), Array(target.path.utf8))
        XCTAssertEqual(try Data(contentsOf: target), Data("literal".utf8))
        let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.path)
        for (raw, message) in [
            ("", "output_path must not be empty."),
            ("relative.xml", "output_path must be absolute. CLI shorthand resolves relative paths before calling MCP."),
            (" ", "output_path must be absolute. CLI shorthand resolves relative paths before calling MCP."),
            ("~other/file.xml", "output_path supports '~' or '~/' only; use an absolute path otherwise."),
            ("~", "output_path points to a directory: \(fixture.path)")
        ] {
            do {
                _ = try await AgentHandoffOutputFile.write("must not write", to: raw, overwrite: true, homeDirectory: fixture)
                XCTFail("Invalid output must be refused")
            } catch {
                assertInvalidParams(error, message)
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.path), entries)
        XCTAssertEqual(try Data(contentsOf: target), Data("literal".utf8))
    }

    func testNativeDotAndSymlinkTraversalWritesPhysicalTargetInsteadOfLexicalDecoy() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let left = fixture.appendingPathComponent("left", isDirectory: true)
        let right = fixture.appendingPathComponent("right", isDirectory: true)
        let inside = right.appendingPathComponent("inside", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: left.appendingPathComponent("link"), withDestinationURL: inside)
        let physical = right.appendingPathComponent("handoff.xml")
        let lexical = left.appendingPathComponent("handoff.xml")
        try Data("physical old".utf8).write(to: physical)
        try Data("lexical decoy".utf8).write(to: lexical)
        let raw = left.path + "/link/../handoff.xml"
        let result = try await AgentHandoffOutputFile.write("physical replacement", to: raw, overwrite: true, homeDirectory: fixture)
        XCTAssertEqual(result.path, URL(fileURLWithPath: raw).path)
        XCTAssertEqual(try Data(contentsOf: physical), Data("physical replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: lexical), Data("lexical decoy".utf8))
    }

    private func makeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func assertInvalidParams(_ error: Error, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let error = error as? MCPError, case let .invalidParams(message) = error else {
            return XCTFail("Expected invalidParams, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(message, expected, file: file, line: line)
    }
}
