import Foundation
@testable import RepoPromptCore
import XCTest

final class Phase1CoreBoundaryContractTests: XCTestCase {
    private struct TestDocument: Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
    }

    private struct TestCodec: WorkspaceDocumentCodec {
        func decode(_ data: Data) throws -> WorkspaceDocumentDecodeResult<TestDocument> {
            WorkspaceDocumentDecodeResult(
                document: TestDocument(id: UUID(uuidString: String(decoding: data, as: UTF8.self))!, name: "decoded"),
                sourceVersion: WorkspaceDocumentFormatVersion(family: "embedded", version: 1),
                warnings: [WorkspaceCodecWarning(code: "legacy_default", message: "Applied a permissive default")],
                requiresRewrite: true
            )
        }

        func encode(_ document: TestDocument) throws -> WorkspaceDocumentEncodeResult {
            WorkspaceDocumentEncodeResult(
                data: Data(document.id.uuidString.utf8),
                schemaVersion: WorkspaceDocumentFormatVersion(family: "canonical", version: 2)
            )
        }
    }

    func testWorkspaceCodecCarriesVersionWarningsAndRewriteMetadataWithoutConcreteAppModel() throws {
        let document = TestDocument(id: UUID(), name: "fixture")
        let encoded = try TestCodec().encode(document)
        XCTAssertEqual(encoded.schemaVersion, WorkspaceDocumentFormatVersion(family: "canonical", version: 2))

        let decoded = try TestCodec().decode(encoded.data)
        XCTAssertEqual(decoded.document.id, document.id)
        XCTAssertEqual(decoded.sourceVersion, WorkspaceDocumentFormatVersion(family: "embedded", version: 1))
        XCTAssertEqual(decoded.warnings.map(\.code), ["legacy_default"])
        XCTAssertTrue(decoded.requiresRewrite)
    }

    func testToolCapabilityPolicyIsImmutableAndRequiresEveryCapability() {
        let policy = ToolCapabilityPolicy(grantedCapabilities: [.workspaceRead, .fileRead])

        XCTAssertTrue(policy.allows(.workspaceRead))
        XCTAssertFalse(policy.allows(.fileWrite))
        XCTAssertTrue(policy.allowsAll([.workspaceRead, .fileRead]))
        XCTAssertFalse(policy.allowsAll([.workspaceRead, .fileWrite]))
    }

    func testSessionToolVocabularyPreservesPhase0Names() {
        XCTAssertEqual(MCPSessionToolName.bindContext, "bind_context")
        XCTAssertEqual(MCPSessionToolName.manageWorkspaces, "manage_workspaces")
        XCTAssertEqual(MCPSessionToolName.manageSelection, "manage_selection")
        XCTAssertEqual(MCPSessionToolName.workspaceContext, "workspace_context")
        XCTAssertEqual(MCPSessionToolName.getFileTree, "get_file_tree")
        XCTAssertEqual(MCPSessionToolName.getCodeStructure, "get_code_structure")
        XCTAssertEqual(MCPSessionToolName.readFile, "read_file")
        XCTAssertEqual(MCPSessionToolName.search, "file_search")
        XCTAssertEqual(MCPSessionToolName.prompt, "prompt")
    }

    func testProcessDescriptorFailureContainsOnlyNeutralFields() {
        let error = ProcessLauncherError.descriptorConfigurationFailed(
            operation: "setCloseOnExec",
            label: "stdout",
            fd: 9,
            errno: EBADF
        )

        guard case let .descriptorConfigurationFailed(operation, label, fd, errno) = error else {
            return XCTFail("Expected descriptor configuration failure")
        }
        XCTAssertEqual(operation, "setCloseOnExec")
        XCTAssertEqual(label, "stdout")
        XCTAssertEqual(fd, 9)
        XCTAssertEqual(errno, EBADF)
    }

    func testMigrationContractsDescribeAssessmentAndResultWithoutExecutingMigration() {
        XCTAssertEqual(WorkspaceLegacyMigrationAssessment.ready(documentCount: 2), .ready(documentCount: 2))
        XCTAssertEqual(WorkspaceLegacyMigrationResult.notRequired, .notRequired)
    }
}
