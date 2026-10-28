import Foundation
import MCP
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import XCTest

#if DEBUG
    @MainActor
    final class PromptExperimentMCPControlTests: XCTestCase {
        private var roots: [URL] = []

        override func tearDown() async throws {
            for root in roots {
                try? FileManager.default.removeItem(at: root)
            }
            roots = []
            try await super.tearDown()
        }

        private func makeService() throws -> (PromptExperimentService, FakeRuntime) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            roots.append(root)
            let registry = try PromptExperimentTestFixtures.makeRegistry(root: root)
            let runtime = FakeRuntime(root: root)
            return (PromptExperimentTestFixtures.makeService(root: root, registry: registry, runtime: runtime), runtime)
        }

        private func expectError(
            _ args: [String: Value],
            service: PromptExperimentService,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async -> PromptExperimentMCPError? {
            do {
                _ = try await PromptExperimentMCPControl.handle(args: args, service: service)
                XCTFail("Expected a structured error", file: file, line: line)
                return nil
            } catch let error as PromptExperimentMCPError {
                return error
            } catch {
                XCTFail("Unexpected error \(error)", file: file, line: line)
                return nil
            }
        }

        func testOperationsAreTheSevenTypedOpsAdvertisedByTheCatalog() throws {
            XCTAssertEqual(
                PromptExperimentOperation.allCases.map(\.rawValue),
                ["targets", "create_or_update", "request_approval", "run", "status_or_wait", "cancel", "propose_patch"]
            )
            XCTAssertEqual(PromptExperimentOperation.allCases.map(\.rawValue), MCPDomainToolCatalog.promptExperimentOperations)
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.promptExperiment))
            let properties = try XCTUnwrap(definition.inputSchema.objectValue?["properties"]?.objectValue)
            let advertised = Set(properties.keys).subtracting(["op"])
            let accepted = PromptExperimentMCPControl.acceptedArguments.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            XCTAssertEqual(advertised, accepted, "the schema advertises exactly the accepted arguments")
        }

        func testProposePatchParsesRequiredSelectionButCannotApply() throws {
            let experimentID = UUID()
            let runID = UUID()
            XCTAssertEqual(try PromptExperimentMCPControl.parse([
                "op": .string("propose_patch"), "experiment_id": .string(experimentID.uuidString),
                "run_id": .string(runID.uuidString), "candidate_index": .int(2)
            ]), .proposePatch(experimentID: experimentID, runID: runID, candidateIndex: 2))
            XCTAssertThrowsError(try PromptExperimentMCPControl.parse([
                "op": .string("propose_patch"), "experiment_id": .string(experimentID.uuidString),
                "run_id": .string(runID.uuidString), "candidate_index": .int(-1), "apply": .bool(true)
            ])) { error in
                let fields = (error as? PromptExperimentMCPError)?.fields.map(\.field)
                XCTAssertEqual(Set(fields ?? []), ["apply", "candidate_index"])
            }
        }

        func testThereIsNoApprovalOperationOrArgument() async throws {
            let (service, runtime) = try makeService()
            let unknownOp = await expectError(["op": "approve", "experiment_id": .string(UUID().uuidString)], service: service)
            XCTAssertEqual(unknownOp?.code, "invalid_request")
            XCTAssertEqual(unknownOp?.fields.map(\.field), ["op"])
            let smuggled = await expectError([
                "op": "request_approval", "experiment_id": .string(UUID().uuidString), "approved": .bool(true)
            ], service: service)
            XCTAssertEqual(smuggled?.fields.map(\.field), ["approved"])
            XCTAssertTrue(runtime.submitted.isEmpty)
        }

        func testArgumentErrorsAreAggregatedIntoOneStructuredError() async throws {
            let (service, _) = try makeService()
            let error = await expectError([
                "op": "create_or_update", "max_evaluations": .string("many"), "workspace_id": .string("x"),
                "experiment_id": .string("not-a-uuid")
            ], service: service)
            XCTAssertEqual(error?.code, "invalid_request")
            XCTAssertEqual(Set(error?.fields.map(\.field) ?? []), ["experiment_id", "max_evaluations", "workspace_id"])
            let object = try JSONSerialization.jsonObject(with: Data(XCTUnwrap(error?.jsonText).utf8)) as? [String: Any]
            let payload = try XCTUnwrap(object?["error"] as? [String: Any])
            XCTAssertEqual(payload["code"] as? String, "invalid_request")
            XCTAssertEqual((payload["fields"] as? [[String: Any]])?.count, 3)
        }

        func testServiceValidationFailuresKeepFieldDetails() async throws {
            let (service, _) = try makeService()
            let error = await expectError([
                "op": "create_or_update", "prompt_id": "oracle-plan", "max_evaluations": .int(2), "max_provider_retries": .int(99)
            ], service: service)
            XCTAssertEqual(error?.code, "validation_failed")
            XCTAssertEqual(Set(error?.fields.map(\.field) ?? []), ["max_evaluations", "max_provider_retries"])
        }

        func testCreateRequestAndWaitNeverSelfApprove() async throws {
            let (service, runtime) = try makeService()
            let created = try await PromptExperimentMCPControl.handle(args: [
                "op": "create_or_update", "prompt_id": "oracle-plan", "max_evaluations": .int(4)
            ], service: service)
            let object = try XCTUnwrap(created.objectValue)
            XCTAssertEqual(object["status"]?.stringValue, "unapproved")
            XCTAssertEqual(object["authority"]?.objectValue?["maximum_total_evaluations"], .int(6))
            let id = try XCTUnwrap(object["experiment_id"]?.stringValue)
            let digest = try XCTUnwrap(object["authority_digest"]?.stringValue)

            let refused = await expectError(["op": "run", "experiment_id": .string(id)], service: service)
            XCTAssertEqual(refused?.code, "not_approved")

            let requested = try await PromptExperimentMCPControl.handle(args: [
                "op": "request_approval", "experiment_id": .string(id), "expected_authority_digest": .string(digest)
            ], service: service)
            XCTAssertEqual(requested.objectValue?["status"]?.stringValue, "awaiting_approval")
            XCTAssertEqual(requested.objectValue?["approved_at"], .null)

            let waited = try await PromptExperimentMCPControl.handle(args: [
                "op": "status_or_wait", "experiment_id": .string(id), "timeout_seconds": .int(0)
            ], service: service)
            XCTAssertEqual(waited.objectValue?["status"]?.stringValue, "awaiting_approval")
            let listed = try await PromptExperimentMCPControl.handle(args: ["op": "status_or_wait"], service: service)
            XCTAssertEqual(listed.objectValue?["experiments"]?.arrayValue?.count, 1)
            XCTAssertTrue(runtime.submitted.isEmpty, "nothing reachable from MCP approves or spends")
            XCTAssertFalse(try XCTUnwrap(service.experiment(id: XCTUnwrap(UUID(uuidString: id)))).isApproved)
        }

        func testTargetsListsPromptsSuitesAndPromptOnlyDefaults() async throws {
            let (service, _) = try makeService()
            let value = try await PromptExperimentMCPControl.handle(args: ["op": "targets"], service: service)
            let object = try XCTUnwrap(value.objectValue)
            XCTAssertEqual(object["operations"]?.arrayValue?.count, 7)
            let prompts = try XCTUnwrap(object["prompts"]?.arrayValue)
            XCTAssertEqual(prompts.compactMap { $0.objectValue?["prompt_id"]?.stringValue }, BuiltInPromptID.allCases.map(\.rawValue))
            let plan = try XCTUnwrap(prompts.first { $0.objectValue?["prompt_id"]?.stringValue == "oracle-plan" }?.objectValue)
            XCTAssertEqual(plan["suite"]?.objectValue?["suite_id"]?.stringValue, "unit-suite", "Discovery must use the same registry as creation")
            let review = try XCTUnwrap(prompts.first { $0.objectValue?["prompt_id"]?.stringValue == "oracle-review" }?.objectValue)
            XCTAssertEqual(review["suite"], .null)
            XCTAssertNotNil(review["suite_unavailable"]?.stringValue)
            XCTAssertEqual(object["scope"]?.objectValue?["project_prompts"], .bool(false))
            XCTAssertEqual(object["defaults"]?.objectValue?["execution_target"]?.stringValue, "engineer")
            XCTAssertEqual(object["defaults"]?.objectValue?["reflection_target"]?.stringValue, "design")
        }
    }
#endif
