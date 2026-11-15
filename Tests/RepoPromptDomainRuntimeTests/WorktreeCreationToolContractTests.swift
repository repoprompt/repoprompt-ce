import Foundation
import MCP
@testable import RepoPromptDomainRuntime
import XCTest

final class WorktreeCreationToolContractTests: XCTestCase {
    func testCanonicalCreationToolsExposeManagedDefaultWithoutPromptHistory() throws {
        // This is the catalog consumed by both app bindings and direct tools/list,
        // not legacy provider prose or a conversation's system-prompt fragment.
        for (name, pathKey) in [("manage_worktree", "path"), ("agent_run", "worktree_path")] {
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: name))
            let firstLine = try XCTUnwrap(definition.description.components(separatedBy: "\n").first)
            XCTAssertTrue(firstLine.contains(".repoprompt-worktrees"), name)
            XCTAssertTrue(firstLine.contains("omit"), name)
            XCTAssertTrue(definition.description.contains("unless the user explicitly requests that location"), name)
            for location in ["`/tmp`", "`/private/tmp`", "`/var/tmp`", "`$TMPDIR`", "`/var/folders`", "symlink aliases"] {
                XCTAssertTrue(definition.description.contains(location), "\(name): missing \(location)")
            }

            let schema = try XCTUnwrap(definition.inputSchema.objectValue)
            let properties = try XCTUnwrap(schema["properties"]?.objectValue)
            let path = try XCTUnwrap(properties[pathKey]?.objectValue)
            let help = try XCTUnwrap(path["description"]?.stringValue, name)
            XCTAssertTrue(help.contains(".repoprompt-worktrees"), name)
            XCTAssertTrue(help.lowercased().contains("omit"), name)
            XCTAssertFalse(schema["required"]?.arrayValue?.contains(.string(pathKey)) ?? false, name)
            XCTAssertNil(path["default"], "The app computes the destination; do not advertise a literal relative path")
        }
    }

    func testCreationProjectionIsIdempotentAndPreservesAuthorityAndSchemaShapes() throws {
        for (name, pathKey, flagKey) in [("manage_worktree", "path", "allow_external_path"), ("agent_run", "worktree_path", "allow_external_worktree_path")] {
            let canonical = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: name))
            let rawSchema: Value = .object([
                "type": .string("object"),
                "required": .array([.string("op")]),
                "additionalProperties": .bool(false),
                "properties": .object([
                    pathKey: .object(["type": .string("string"), "description": .string("Legacy path help")]),
                    flagKey: .object(["type": .string("boolean"), "description": .string("Legacy flag help")]),
                    "op": .object(["type": .string("string"), "enum": .array([.string("create")]), "description": .string("Unrelated help")])
                ])
            ])
            let legacy = MCPDomainToolDefinition(
                name: name,
                description: "Legacy description without creation guidance.",
                inputSchema: rawSchema,
                annotations: canonical.annotations,
                isEnabledByDefault: canonical.isEnabledByDefault
            )
            let projected = MCPWorktreeCreationCopy.applying(to: legacy)
            XCTAssertEqual(MCPWorktreeCreationCopy.applying(to: projected), projected)
            XCTAssertTrue(projected.description.hasPrefix(legacy.description + " "), "Keep the canonical intro rather than replacing it")
            XCTAssertEqual(projected.annotations, legacy.annotations)
            XCTAssertEqual(projected.isEnabledByDefault, legacy.isEnabledByDefault)
            let before = try XCTUnwrap(legacy.inputSchema.objectValue)
            let after = try XCTUnwrap(projected.inputSchema.objectValue)
            var beforeShape = before
            var afterShape = after
            beforeShape.removeValue(forKey: "properties")
            afterShape.removeValue(forKey: "properties")
            XCTAssertEqual(afterShape, beforeShape)
            XCTAssertEqual(after["properties"]?.objectValue?.keys.sorted(), before["properties"]?.objectValue?.keys.sorted())
            for (key, property) in try XCTUnwrap(before["properties"]?.objectValue) {
                var expected = try XCTUnwrap(property.objectValue)
                var actual = try XCTUnwrap(after["properties"]?.objectValue?[key]?.objectValue)
                if key == pathKey || key == flagKey {
                    XCTAssertNotEqual(actual["description"], expected["description"], "Replace legacy creation help")
                    expected.removeValue(forKey: "description")
                    actual.removeValue(forKey: "description")
                }
                XCTAssertEqual(actual, expected, "\(name).\(key): only help text may change")
            }
        }
        let git = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "git"))
        XCTAssertEqual(MCPWorktreeCreationCopy.applying(to: git), git)
    }

    func testCanonicalManageWorktreeTeachesPathlessCreationRatherThanGuessingLocation() throws {
        let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: "manage_worktree"))
        XCTAssertTrue(definition.description.contains(#"{"op":"create"}"#))
        XCTAssertTrue(definition.description.contains("Do not invent a path"))
        XCTAssertTrue(definition.description.contains("Direct headless"))
    }
}
