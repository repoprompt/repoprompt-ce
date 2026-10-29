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

        func testOperationsMatchTheLabCatalogAndEveryAdvertisedArgumentIsAccepted() throws {
            XCTAssertEqual(
                PromptExperimentOperation.allCases.map(\.rawValue),
                ["targets", "prepare", "describe_program", "create_or_update", "request_approval", "run", "status_or_wait", "cancel", "propose_patch", "export"]
            )
            XCTAssertEqual(PromptExperimentOperation.allCases.map(\.rawValue), MCPDomainToolCatalog.promptExperimentOperations)
            let definition = try XCTUnwrap(MCPDomainCanonicalToolDefinitions.definition(named: MCPWindowToolName.promptExperiment))
            let properties = try XCTUnwrap(definition.inputSchema.objectValue?["properties"]?.objectValue)
            let advertised = Set(properties.keys).subtracting(["op"])
            let accepted = PromptExperimentMCPControl.acceptedArguments.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            XCTAssertEqual(advertised, accepted, "the schema advertises exactly the accepted arguments")
        }

        func testPrepareRequiresOneSourceAndDescribesAConcreteGoal() throws {
            let command = try PromptExperimentMCPControl.parse([
                "op": "prepare", "prompt_text": "Write a useful gardening article.",
                "goal": "Use the supplied facts and stay under 700 words.",
                "example_inputs": "A beginner's balcony herb garden", "criteria": "Do not invent facts."
            ])
            guard case let .prepare(request) = command else { return XCTFail("Expected a prepare request") }
            XCTAssertEqual(request.promptText, "Write a useful gardening article.")
            XCTAssertEqual(request.goal, "Use the supplied facts and stay under 700 words.")
            XCTAssertNil(request.promptID)
            XCTAssertThrowsError(try PromptExperimentMCPControl.parse([
                "op": "prepare", "prompt_id": "oracle-plan", "prompt_file": "relative.md", "selection": "text"
            ])) { error in
                XCTAssertEqual(Set((error as? PromptExperimentMCPError)?.fields.map(\.field) ?? []), ["source", "prompt_file", "goal"])
            }
        }

        func testGenericDefinitionDefaultsAndPrivateReferencesSurviveParsing() throws {
            let command = try PromptExperimentMCPControl.parse([
                "op": "create_or_update", "definition": .object([
                    "source": .object(["kind": "pasted", "title": "Blog prompt", "prompt": "Write for {{audience}}."]),
                    "goal": "Stay factual and concise.", "criteria": "Use only supplied facts.", "relativePromptLimit": .double(1),
                    "examples": .array([
                        .object(["id": "intro", "split": "training", "input": "Explain composting.", "expectedOutput": "Private reference", "variables": .object(["audience": "beginners"])]),
                        .object(["id": "water", "split": "validation", "input": "Explain watering."]),
                        .object(["id": "soil", "split": "hidden_test", "input": "Explain soil.", "payload": .object(["question": "Explain soil.", "facts": .array([.object(["count": .int(2), "verified": .bool(true)])])])])
                    ])
                ])
            ])
            guard case let .createOrUpdate(request) = command else { return XCTFail("Expected create request") }
            let definition = try XCTUnwrap(request.definition)
            XCTAssertEqual(definition.runner, .plainPrompt)
            XCTAssertEqual(definition.objective, PromptLabObjective())
            XCTAssertEqual(definition.contractVersion, PromptLabDefinition.contractVersion)
            XCTAssertEqual(definition.examples[0].expectedOutput, "Private reference")
            XCTAssertEqual(definition.examples[0].variables, ["audience": "beginners"])
            XCTAssertEqual(definition.examples[1].variables, [:])
            XCTAssertEqual(definition.relativePromptLimit, 1)
            XCTAssertEqual(definition.examples[2].payload?["facts"], .array([.object(["count": .number(2), "verified": .boolean(true)])]))
            XCTAssertNil(request.promptID, "A project definition must not borrow a built-in ID")
            XCTAssertNil(request.experimentID)
            let roundTrip = try PromptExperimentMCPControl.encodedValue(definition)
            var errors: [PromptExperimentFieldError] = []
            XCTAssertEqual(PromptExperimentMCPControl.decodeDefinition(roundTrip, errors: &errors), definition)
            XCTAssertTrue(errors.isEmpty)
        }

        func testDefinitionRejectsUnknownNestedFieldsRatherThanSilentlyDroppingThem() throws {
            XCTAssertThrowsError(try PromptExperimentMCPControl.parse([
                "op": "create_or_update", "definition": .object([
                    "source": .object(["kind": "pasted", "title": "Prompt", "prompt": "Respond clearly.", "apply": .bool(true)]),
                    "goal": "Improve clarity.", "criteria": "Be clear.", "approved": .bool(true),
                    "examples": .array([
                        .object(["id": "a", "split": "training", "input": "Hello", "unknown": "ignored?"])
                    ])
                ])
            ])) { error in
                XCTAssertEqual(Set((error as? PromptExperimentMCPError)?.fields.map(\.field) ?? []), [
                    "definition.approved", "definition.source.apply", "definition.examples[0].unknown"
                ])
            }
        }

        func testProgramDiscoveryParsesDefaultsWithoutLaunchingAnything() throws {
            let command = try PromptExperimentMCPControl.parse([
                "op": "describe_program", "runner": "dspy",
                "program": .object(["pythonExecutable": "/project/.venv/bin/python", "projectRoot": "/project", "modulePath": "evaluation.py"])
            ])
            guard case let .describeProgram(program, runner) = command else { return XCTFail("Expected program discovery") }
            XCTAssertEqual(runner, .dspy)
            XCTAssertEqual(program.callable, "evaluate")
            XCTAssertEqual(program.timeoutSeconds, 120)
            XCTAssertNil(program.moduleSHA256)
        }

        func testDiscoveredProgramPreservesRoutingEnvironmentAndDependencySeals() throws {
            var errors: [PromptExperimentFieldError] = []
            let program = try XCTUnwrap(PromptExperimentMCPControl.decodeProgram(.object([
                "pythonExecutable": "/project/.venv/bin/python", "projectRoot": "/project", "modulePath": "evaluation.py",
                "modelRouting": "project", "moduleSHA256": "module-hash",
                "environmentKeys": .array(["OPENAI_API_KEY"]),
                "dependencySHA256": .object(["helper.py": "helper-hash"])
            ]), errors: &errors))
            XCTAssertTrue(errors.isEmpty)
            XCTAssertEqual(program.modelRouting, .project)
            XCTAssertEqual(program.environmentKeys, ["OPENAI_API_KEY"])
            XCTAssertEqual(program.dependencySHA256, ["helper.py": "helper-hash"])
            let encoded = try PromptExperimentMCPControl.encodedValue(program)
            XCTAssertEqual(PromptExperimentMCPControl.decodeProgram(encoded, errors: &errors), program)
            XCTAssertTrue(errors.isEmpty)
        }

        func testImportedSourceLiteralRoundTripsWithoutLosingItsEncoding() throws {
            let source = PromptLabSource(
                kind: .file, title: "writer.py", prompt: "Write clearly.\n",
                filePath: "/project/writer.py", originalFileSHA256: "source-hash", selection: #""Write clearly.\n""#,
                literal: PromptLabSourceLiteral(language: .python, token: #""Write clearly.\n""#)
            )
            let definition = PromptLabDefinition(source: source, goal: "Improve clarity.", examples: [], criteria: "Keep supplied facts.")
            let encoded = try PromptExperimentMCPControl.encodedValue(definition)
            var errors: [PromptExperimentFieldError] = []
            XCTAssertEqual(PromptExperimentMCPControl.decodeDefinition(encoded, errors: &errors), definition)
            XCTAssertTrue(errors.isEmpty)
        }

        func testExportRequiresRunAndAbsoluteDestinationWithoutCreatingSourceAuthority() throws {
            let experimentID = UUID(), runID = UUID()
            XCTAssertEqual(try PromptExperimentMCPControl.parse([
                "op": "export", "experiment_id": .string(experimentID.uuidString), "run_id": .string(runID.uuidString),
                "output_path": "/tmp/experiment.json"
            ]), .exportResult(experimentID: experimentID, runID: runID, outputPath: "/tmp/experiment.json"))
            XCTAssertThrowsError(try PromptExperimentMCPControl.parse([
                "op": "export", "experiment_id": .string(experimentID.uuidString), "run_id": .string(runID.uuidString),
                "output_path": "relative.json", "apply": .bool(true)
            ])) { error in
                XCTAssertEqual(Set((error as? PromptExperimentMCPError)?.fields.map(\.field) ?? []), ["apply", "output_path"])
            }
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
            XCTAssertTrue(runtime.submitted.isEmpty, "creating and observing a draft never approves or runs optimization")
            XCTAssertFalse(try XCTUnwrap(service.experiment(id: XCTUnwrap(UUID(uuidString: id)))).isApproved)
        }

        func testTargetsListsPromptsSuitesAndPromptOnlyDefaults() async throws {
            let (service, _) = try makeService()
            let value = try await PromptExperimentMCPControl.handle(args: ["op": "targets"], service: service)
            let object = try XCTUnwrap(value.objectValue)
            XCTAssertEqual(object["operations"]?.arrayValue?.count, 10)
            let prompts = try XCTUnwrap(object["prompts"]?.arrayValue)
            XCTAssertEqual(prompts.compactMap { $0.objectValue?["prompt_id"]?.stringValue }, BuiltInPromptID.allCases.map(\.rawValue))
            let plan = try XCTUnwrap(prompts.first { $0.objectValue?["prompt_id"]?.stringValue == "oracle-plan" }?.objectValue)
            XCTAssertEqual(plan["suite"]?.objectValue?["suite_id"]?.stringValue, "unit-suite", "Discovery must use the same registry as creation")
            let review = try XCTUnwrap(prompts.first { $0.objectValue?["prompt_id"]?.stringValue == "oracle-review" }?.objectValue)
            XCTAssertEqual(review["suite"], .null)
            XCTAssertNotNil(review["suite_unavailable"]?.stringValue)
            XCTAssertEqual(object["scope"]?.objectValue?["project_prompts"], .bool(true))
            XCTAssertEqual(object["defaults"]?.objectValue?["execution_target"]?.stringValue, "engineer")
            XCTAssertEqual(object["defaults"]?.objectValue?["reflection_target"]?.stringValue, "design")
        }
    }
#endif
