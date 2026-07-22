import Foundation
import XCTest
@testable import RepoPromptCodeMapCore

final class CodeMapQueryOptimizationBenchmarkTests: XCTestCase {
    #if RPCE_BENCHMARK_TESTS
        func testSwiftCorpusCorrectnessReference() throws {
            guard SwiftCodeMapPipelineBenchmarkSupport.isRuntimeEnabled else {
                throw XCTSkip("Set RP_RUN_SWIFT_CODEMAP_PIPELINE_BENCHMARK=1 to run the Swift corpus reference test")
            }

            let files = SwiftCodeMapPipelineBenchmarkSupport.makeCorpus()
            let artifacts = try SwiftCodeMapPipelineBenchmarkSupport.buildArtifacts(files: files)
            let repeated = try SwiftCodeMapPipelineBenchmarkSupport.buildArtifacts(files: files)
            XCTAssertEqual(artifacts, repeated)
            let evidence = try SwiftCodeMapPipelineBenchmarkSupport.makeEvidence(
                files: files,
                artifacts: artifacts
            )
            SwiftCodeMapPipelineBenchmarkSupport.printDigestRecord(evidence.reference)
            let comparisonMode = try SwiftCodeMapPipelineBenchmarkSupport.configuredReferenceComparisonMode()
            try SwiftCodeMapPipelineBenchmarkSupport.validateFixedDigests(
                evidence.reference,
                comparisonMode: comparisonMode
            )
            try SwiftCodeMapPipelineBenchmarkSupport.applyReferenceMode(to: evidence.reference)
        }

        func testSwiftFileToCodeMapPipelineBenchmark() throws {
            guard SwiftCodeMapPipelineBenchmarkSupport.isRuntimeEnabled else {
                throw XCTSkip("Set RP_RUN_SWIFT_CODEMAP_PIPELINE_BENCHMARK=1 to run the Swift pipeline benchmark")
            }

            let files = SwiftCodeMapPipelineBenchmarkSupport.makeCorpus()
            let expected = try SwiftCodeMapPipelineBenchmarkSupport.buildArtifacts(files: files)
            for _ in 0 ..< 2 {
                XCTAssertEqual(
                    try SwiftCodeMapPipelineBenchmarkSupport.buildArtifacts(files: files),
                    expected
                )
            }

            var samplesMS: [Double] = []
            samplesMS.reserveCapacity(5)
            for _ in 0 ..< 5 {
                let start = ProcessInfo.processInfo.systemUptime
                let artifacts = try SwiftCodeMapPipelineBenchmarkSupport.buildArtifacts(files: files)
                samplesMS.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                XCTAssertEqual(artifacts, expected)
            }

            let collector = CodeMapPerformanceCollector(collectsCaptureNames: true)
            let attributed = try SwiftCodeMapPipelineBenchmarkSupport.buildArtifacts(
                files: files,
                performanceCollector: collector
            )
            XCTAssertEqual(attributed, expected)
            XCTAssertEqual(collector.syntaxCalls, files.count)
            XCTAssertEqual(collector.syntaxQueryExecutes, files.count)
            XCTAssertGreaterThan(collector.syntaxCaptures, 0)

            let evidence = try SwiftCodeMapPipelineBenchmarkSupport.makeEvidence(
                files: files,
                artifacts: attributed
            )
            SwiftCodeMapPipelineBenchmarkSupport.printDigestRecord(evidence.reference)
            let comparisonMode = try SwiftCodeMapPipelineBenchmarkSupport.configuredReferenceComparisonMode()
            try SwiftCodeMapPipelineBenchmarkSupport.validateFixedDigests(
                evidence.reference,
                comparisonMode: comparisonMode
            )
            try SwiftCodeMapPipelineBenchmarkSupport.applyReferenceMode(to: evidence.reference)

            print([
                "SWIFT_CODEMAP_PIPELINE_PRIMARY",
                "files=\(files.count)",
                "raw_samples_ms=\(SwiftCodeMapPipelineBenchmarkSupport.formattedSamples(samplesMS))",
                "invocation_median_ms=\(String(format: "%.3f", SwiftCodeMapPipelineBenchmarkSupport.median(samplesMS)))",
                "query_sha256=\(evidence.reference.querySHA256)",
                "content_sha256=\(evidence.reference.contentDigest)",
                "capture_sha256=\(evidence.reference.captureDigest)",
                "artifact_sha256=\(evidence.reference.artifactDigest)",
                "reference_mode=\(SwiftCodeMapPipelineBenchmarkSupport.referenceMode)",
                "artifact_parity=true",
            ].joined(separator: " "))
            print(SwiftCodeMapPipelineBenchmarkSupport.attributionRecord(
                collector: collector,
                reference: evidence.reference
            ))
        }

        func testSwiftPipelineReferenceExactComparisonAcceptsOnlyIdenticalRecord() throws {
            let reference = Self.makeSwiftPipelineReference()
            XCTAssertNoThrow(try SwiftCodeMapPipelineBenchmarkSupport.compareReference(
                expected: reference,
                actual: reference
            ))

            let changedQuery = Self.makeSwiftPipelineReference(
                querySHA256: "candidate-query",
                captureDigest: "candidate-captures"
            )
            XCTAssertThrowsError(try SwiftCodeMapPipelineBenchmarkSupport.compareReference(
                expected: reference,
                actual: changedQuery
            ))
        }

        func testSwiftPipelineReferenceAllowsOnlyAllowlistedCaptureRemovals() throws {
            let reference = Self.makeSwiftPipelineReference()
            let candidate = Self.makeSwiftPipelineReference(
                querySHA256: "candidate-query",
                captureDigest: "candidate-captures",
                captures: [reference.captures[0]]
            )

            XCTAssertNoThrow(try SwiftCodeMapPipelineBenchmarkSupport.compareReference(
                expected: reference,
                actual: candidate,
                comparisonMode: .allowingCaptureRemovals(named: ["type.class"])
            ))
        }

        func testSwiftPipelineReferenceRejectsUnsafeCaptureDeltas() throws {
            let reference = Self.makeSwiftPipelineReference()
            let allowedMode = SwiftCodeMapPipelineBenchmarkSupport.ReferenceComparisonMode
                .allowingCaptureRemovals(named: ["type.class"])

            let added = Self.makeSwiftPipelineReference(
                querySHA256: "candidate-query",
                captureDigest: "candidate-captures",
                captures: [
                    reference.captures[0],
                    .init(logicalPath: "Sources/Test.swift", name: "zzz.added", location: 40, length: 2)
                ]
            )
            XCTAssertThrowsError(try SwiftCodeMapPipelineBenchmarkSupport.compareReference(
                expected: reference,
                actual: added,
                comparisonMode: allowedMode
            ))

            let modified = Self.makeSwiftPipelineReference(
                querySHA256: "candidate-query",
                captureDigest: "candidate-captures",
                captures: [
                    .init(logicalPath: "Sources/Test.swift", name: "function.method", location: 10, length: 99)
                ]
            )
            XCTAssertThrowsError(try SwiftCodeMapPipelineBenchmarkSupport.compareReference(
                expected: reference,
                actual: modified,
                comparisonMode: allowedMode
            ))

            let modifiedAllowlistedCapture = Self.makeSwiftPipelineReference(
                querySHA256: "candidate-query",
                captureDigest: "candidate-captures",
                captures: [
                    reference.captures[0],
                    .init(logicalPath: "Sources/Test.swift", name: "type.class", location: 20, length: 99)
                ]
            )
            XCTAssertThrowsError(try SwiftCodeMapPipelineBenchmarkSupport.compareReference(
                expected: reference,
                actual: modifiedAllowlistedCapture,
                comparisonMode: allowedMode
            ))

            let unchangedCaptures = Self.makeSwiftPipelineReference(
                querySHA256: "candidate-query",
                captureDigest: "candidate-captures"
            )
            XCTAssertThrowsError(try SwiftCodeMapPipelineBenchmarkSupport.compareReference(
                expected: reference,
                actual: unchangedCaptures,
                comparisonMode: allowedMode
            ))

            let disallowedRemoval = Self.makeSwiftPipelineReference(
                querySHA256: "candidate-query",
                captureDigest: "candidate-captures",
                captures: [reference.captures[1]]
            )
            XCTAssertThrowsError(try SwiftCodeMapPipelineBenchmarkSupport.compareReference(
                expected: reference,
                actual: disallowedRemoval,
                comparisonMode: allowedMode
            ))

            let changedArtifact = Self.makeSwiftPipelineReference(
                querySHA256: "candidate-query",
                captureDigest: "candidate-captures",
                artifactDigest: "changed-artifact",
                captures: [reference.captures[0]]
            )
            XCTAssertThrowsError(try SwiftCodeMapPipelineBenchmarkSupport.compareReference(
                expected: reference,
                actual: changedArtifact,
                comparisonMode: allowedMode
            ))

            let changedContent = Self.makeSwiftPipelineReference(
                querySHA256: "candidate-query",
                contentDigest: "changed-content",
                captureDigest: "candidate-captures",
                captures: [reference.captures[0]]
            )
            XCTAssertThrowsError(try SwiftCodeMapPipelineBenchmarkSupport.compareReference(
                expected: reference,
                actual: changedContent,
                comparisonMode: allowedMode
            ))
        }

        private static func makeSwiftPipelineReference(
            querySHA256: String = "base-query",
            contentDigest: String = "content",
            captureDigest: String = "base-captures",
            artifactDigest: String = "base-artifact",
            captures: [SwiftCodeMapPipelineBenchmarkSupport.CaptureRecord] = [
                .init(logicalPath: "Sources/Test.swift", name: "function.method", location: 10, length: 4),
                .init(logicalPath: "Sources/Test.swift", name: "type.class", location: 20, length: 8)
            ]
        ) -> SwiftCodeMapPipelineBenchmarkSupport.ReferenceRecord {
            SwiftCodeMapPipelineBenchmarkSupport.ReferenceRecord(
                schemaVersion: 1,
                semanticBase: "base",
                fileCount: 1,
                querySHA256: querySHA256,
                contentDigest: contentDigest,
                captureDigest: captureDigest,
                artifactDigest: artifactDigest,
                artifacts: [
                    .init(logicalPath: "Sources/Test.swift", canonicalJSON: Data("artifact".utf8))
                ],
                captures: captures
            )
        }
    #endif

    func testCaptureIndexCountsMissingNamedBuckets() {
        let collector = CodeMapPerformanceCollector()
        let index = CodeMapCaptureIndex([], performanceCollector: collector)
        let parent = NSRange(location: 0, length: 1)

        XCTAssertNil(index.firstCapture(named: "missing", containedIn: parent))
        XCTAssertTrue(index.captures(named: "missing", containedIn: parent).isEmpty)
        XCTAssertNil(index.smallestCapture(named: "missing", containing: parent))
        XCTAssertEqual(collector.captureIndexFirstContainedLookupCount, 1)
        XCTAssertEqual(collector.captureIndexAllContainedLookupCount, 1)
        XCTAssertEqual(collector.captureIndexSmallestContainingLookupCount, 1)
        XCTAssertEqual(collector.captureIndexFirstContainedCandidateVisits, 0)
        XCTAssertEqual(collector.captureIndexAllContainedCandidateVisits, 0)
        XCTAssertEqual(collector.captureIndexSmallestContainingCandidateVisits, 0)
        XCTAssertEqual(collector.captureIndexMaximumCandidateVisits, 0)
    }

    func testPreMaterializedSwiftAndTypeScriptGeneratorAttribution() throws {
        let cases: [(name: String, language: LanguageType, source: String)] = [
            ("swift", .swift, Self.swiftSource(declarationCount: 200)),
            ("typescript", .ts, Self.typeScriptSource(declarationCount: 200)),
        ]

        for benchmark in cases {
            let queryOutcome = try CodeMapSyntaxEngine.shared.codeMap(
                content: benchmark.source,
                language: benchmark.language
            )
            guard case let .captures(captures) = queryOutcome else {
                throw BenchmarkError.queryNotReady(queryOutcome)
            }
            guard let expectedArtifact = CodeMapGenerator.generateSyntaxArtifact(
                from: captures,
                content: benchmark.source,
                language: benchmark.language
            ) else {
                throw BenchmarkError.generatorReturnedNil
            }

            for _ in 0 ..< 2 {
                let artifact = CodeMapGenerator.generateSyntaxArtifact(
                    from: captures,
                    content: benchmark.source,
                    language: benchmark.language
                )
                XCTAssertEqual(artifact, expectedArtifact)
            }

            var samplesMS: [Double] = []
            samplesMS.reserveCapacity(20)
            for _ in 0 ..< 20 {
                let start = ProcessInfo.processInfo.systemUptime
                let artifact = CodeMapGenerator.generateSyntaxArtifact(
                    from: captures,
                    content: benchmark.source,
                    language: benchmark.language
                )
                samplesMS.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                XCTAssertEqual(artifact, expectedArtifact)
            }

            let collector = CodeMapPerformanceCollector(collectsCaptureNames: false)
            let attributedArtifact = CodeMapGenerator.generateSyntaxArtifact(
                from: captures,
                content: benchmark.source,
                language: benchmark.language,
                perfOptions: .countersOnly,
                perfStats: collector
            )
            let repeatArtifactEquality = attributedArtifact == expectedArtifact
            XCTAssertTrue(repeatArtifactEquality)

            print(
                [
                    "CODEMAP_PREMATERIALIZED_GENERATOR_BENCHMARK",
                    "language=\(benchmark.name)",
                    "declarations=200",
                    "raw_samples_ms=\(Self.formattedSamples(samplesMS))",
                    "median_ms=\(Self.formattedMilliseconds(Self.median(samplesMS)))",
                    "p95_ms=\(Self.formattedMilliseconds(Self.percentile95(samplesMS)))",
                    "max_ms=\(Self.formattedMilliseconds(samplesMS.max() ?? 0))",
                    "capture_index_ms=\(Self.milliseconds(collector.captureIndexDuration))",
                    "capture_loop_ms=\(Self.milliseconds(collector.captureLoopDuration))",
                    "captures=\(captures.count)",
                    "repeat_artifact_equality=\(repeatArtifactEquality)",
                ].joined(separator: " ")
            )
        }
    }

    func testSyntheticSwiftAndTypeScriptAttribution() throws {
        let cases: [(name: String, language: LanguageType, source: String)] = [
            ("swift", .swift, Self.swiftSource(declarationCount: 200)),
            ("typescript", .ts, Self.typeScriptSource(declarationCount: 200)),
        ]

        for benchmark in cases {
            for _ in 0 ..< 2 {
                _ = try build(source: benchmark.source, language: benchmark.language)
            }

            var samplesMS: [Double] = []
            for _ in 0 ..< 5 {
                let start = ProcessInfo.processInfo.systemUptime
                _ = try build(source: benchmark.source, language: benchmark.language)
                samplesMS.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
            }
            samplesMS.sort()
            let collector = CodeMapPerformanceCollector(collectsCaptureNames: true)
            _ = try build(
                source: benchmark.source,
                language: benchmark.language,
                options: .countersOnly,
                collector: collector
            )
            XCTAssertEqual(collector.syntaxQueryExecutes, 1)
            XCTAssertGreaterThan(collector.syntaxCaptures, 0)

            print(
                [
                    "CODEMAP_QUERY_BENCHMARK",
                    "language=\(benchmark.name)",
                    "declarations=200",
                    "median_ms=\(String(format: "%.3f", samplesMS[samplesMS.count / 2]))",
                    "max_ms=\(String(format: "%.3f", samplesMS.last ?? 0))",
                    "parse_ms=\(Self.milliseconds(collector.syntaxParseDuration))",
                    "query_ms=\(Self.milliseconds(collector.syntaxQueryExecuteDuration))",
                    "materialize_ms=\(Self.milliseconds(collector.syntaxCaptureMaterializationDuration))",
                    "capture_name_count_ms=\(Self.milliseconds(collector.syntaxCaptureNameCountingDuration))",
                    "index_ms=\(Self.milliseconds(collector.captureIndexDuration))",
                    "capture_loop_ms=\(Self.milliseconds(collector.captureLoopDuration))",
                    "captures=\(collector.syntaxCaptures)",
                    "lte_function_calls=\(collector.lteMatchAnyFunctionCalls)",
                    "lte_variable_calls=\(collector.lteMatchAnyVariableCalls)",
                    "jsts_calls=\(collector.jstsSignatureCallsFunctionLike + collector.jstsSignatureCallsStatementLike)",
                    "ts_duplicate_suppressions=\(collector.tsDuplicateFunctionVariableSuppressions)",
                    "swift_bodies=\(collector.syntaxCaptureCountsByName["swift.function.body", default: 0])",
                    "swift_returns=\(collector.syntaxCaptureCountsByName["swift.function.return_type", default: 0])",
                    "swift_property_types=\(collector.syntaxCaptureCountsByName["swift.property.type", default: 0])",
                    "ts_variables=\(collector.syntaxCaptureCountsByName["variable.global", default: 0])",
                ].joined(separator: " ")
            )
        }
    }

    func testStructuralFastPathsPreserveRoutingAndTypes() throws {
        let swiftCollector = CodeMapPerformanceCollector(collectsCaptureNames: true)
        let swiftSource = """
        struct Example {
            let result: Result<[String: Int], BenchError> = .success([:])
            func transform<T>(
                _ input: T,
                fallback: @autoclosure () -> String = "}"
            ) async throws -> Result<T, BenchError> where T: Sendable {
                _ = fallback()
                return .success(input)
            }
        }
        """
        let swiftArtifact = try build(
            source: swiftSource,
            language: .swift,
            options: .countersOnly,
            collector: swiftCollector
        )
        XCTAssertEqual(swiftArtifact.classes.first?.properties.first?.typeName, "Result<[String: Int], BenchError>")
        XCTAssertTrue(swiftArtifact.classes.first?.methods.first?.definitionLine.contains("async throws -> Result<T, BenchError> where T: Sendable") == true)
        XCTAssertEqual(
            swiftArtifact.classes.first?.methods.first?.parameters.map(\.typeName),
            ["T", "@autoclosure () -> String"]
        )
        XCTAssertEqual(swiftCollector.syntaxCaptureCountsByName["swift.param.type", default: 0], 0)
        XCTAssertEqual(swiftCollector.syntaxCaptureCountsByName["function.definition", default: 0], 0)
        XCTAssertEqual(swiftCollector.lteMatchAnyVariableCalls, 1)

        let tsCollector = CodeMapPerformanceCollector(collectsCaptureNames: true)
        let tsSource = """
        export const transform = async <T>(input: T): Promise<{ value: T }> => {
            return { value: input };
        };
        export const payload: { marker: string } = { marker: "=>" };
        """
        let tsArtifact = try build(
            source: tsSource,
            language: .ts,
            options: .countersOnly,
            collector: tsCollector
        )
        XCTAssertEqual(tsArtifact.functions.map(\.name), ["transform"])
        XCTAssertEqual(tsArtifact.globalVars.count, 1)
        XCTAssertTrue(tsArtifact.globalVars[0].definitionLine.contains("payload"))
        XCTAssertEqual(tsCollector.tsDuplicateFunctionVariableSuppressions, 1)

        let tsxCollector = CodeMapPerformanceCollector(collectsCaptureNames: true)
        let tsxSource = """
        export const Card = (props: { title: string }) => <div>{props.title}</div>;
        export const marker: { text: string } = { text: "=>" };
        """
        let tsxArtifact = try build(
            source: tsxSource,
            language: .tsx,
            options: .countersOnly,
            collector: tsxCollector
        )
        XCTAssertEqual(tsxArtifact.functions.map(\.name), ["Card"])
        XCTAssertEqual(tsxArtifact.globalVars.count, 1)
        XCTAssertEqual(tsxCollector.tsDuplicateFunctionVariableSuppressions, 1)
    }

    func testSwiftParameterFallbackSkipsNestedAttributeColons() throws {
        let source = """
        struct Example {
            func wrapped(@Wrapper(label: "x:y") value: Int = 42) {}
        }
        """
        let artifact = try build(source: source, language: .swift)
        let example = try XCTUnwrap(artifact.classes.first { $0.name == "Example" })
        let wrapped = try XCTUnwrap(example.methods.first { $0.name == "wrapped" })

        XCTAssertEqual(wrapped.parameters.map(\.localName), ["value"])
        XCTAssertEqual(wrapped.parameters.map(\.typeName), ["Int"])
    }

    func testTypeScriptUncontainedMembersFallThroughBeforeExtraction() throws {
        let source = """
        class Example {
            value: string = "value";
            method(): void {}
        }
        interface Shape {
            property: string;
            method(): void;
            (): void;
            new (): Shape;
            [key: string]: unknown;
        }
        """
        let outcome = try CodeMapSyntaxEngine.shared.codeMap(content: source, language: .ts)
        guard case let .captures(captures) = outcome else {
            return XCTFail("Expected TypeScript query captures, got \(outcome)")
        }
        let targetNames: Set<String> = [
            "method",
            "variable.field",
            "method_signature",
            "property_signature",
            "call_signature",
            "construct_signature",
            "index_signature",
        ]
        let index = CodeMapCaptureIndex(captures)
        let targetCaptures = index.all.filter { targetNames.contains($0.name) }
        XCTAssertEqual(Set(targetCaptures.map(\.name)), targetNames)
        let nsContent = source as NSString

        for capture in targetCaptures {
            var classesByLine: [Int: ClassInfo] = [:]
            var interfacesByLine: [Int: InterfaceInfo] = [:]
            var globalFunctions: [FunctionInfo] = []
            var globalVariables: [VariableInfo] = []
            var referencedTypes = ReferencedTypesAccumulator(language: .ts)
            var extractionMemo = CodeMapExtractionMemo()
            var trimmedLineCalls = 0

            let handled = TypeScriptCodeMapStrategy.handleCapture(
                capture,
                context: .init(),
                index: index,
                content: source,
                nsContent: nsContent,
                boundaries: [0],
                lineNo: 1,
                language: .ts,
                getTrimmedLine: { _ in
                    trimmedLineCalls += 1
                    return "unexpected"
                },
                classesByLine: &classesByLine,
                interfaceBoundaries: &interfacesByLine,
                globalFunctions: &globalFunctions,
                globalVariables: &globalVariables,
                referencedTypes: &referencedTypes,
                extractionMemo: &extractionMemo
            )

            XCTAssertFalse(handled, "Expected \(capture.name) to fall through without a container")
            XCTAssertEqual(trimmedLineCalls, 0)
            XCTAssertTrue(classesByLine.isEmpty)
            XCTAssertTrue(interfacesByLine.isEmpty)
            XCTAssertTrue(globalFunctions.isEmpty)
            XCTAssertTrue(globalVariables.isEmpty)
            XCTAssertTrue(referencedTypes.types.isEmpty)
        }
    }

    private enum BenchmarkError: Error {
        case notReady(CodeMapSyntaxArtifactOutcome)
        case queryNotReady(CodeMapSyntaxQueryOutcome)
        case generatorReturnedNil
    }

    private func build(
        source: String,
        language: LanguageType,
        options: CodeMapPerfOptions = .disabled,
        collector: CodeMapPerformanceCollector? = nil
    ) throws -> CodeMapSyntaxArtifact {
        let outcome = try CodeMapSyntaxArtifactBuilder.build(
            source: CodeMapFixtureRunner.makeSourceSnapshot(content: source),
            language: language,
            performanceOptions: options,
            performanceCollector: collector
        )
        guard case let .ready(artifact) = outcome else {
            throw BenchmarkError.notReady(outcome)
        }
        return artifact
    }

    private static func milliseconds(_ duration: TimeInterval) -> String {
        String(format: "%.3f", duration * 1_000)
    }

    private static func formattedMilliseconds(_ milliseconds: Double) -> String {
        String(format: "%.3f", milliseconds)
    }

    private static func formattedSamples(_ samples: [Double]) -> String {
        "[\(samples.map(formattedMilliseconds).joined(separator: ","))]"
    }

    private static func median(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return 0 }
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }

    private static func percentile95(_ samples: [Double]) -> Double {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[index]
    }

    private static func swiftSource(declarationCount: Int) -> String {
        (0 ..< declarationCount).map { index in
            """
            struct SwiftBench\(index) {
                let value\(index): Result<[String: Int], BenchError> = .success([:])
                func transform\(index)<T>(_ input: T, fallback: @autoclosure () -> String = "}") async throws -> Result<T, BenchError> where T: Sendable {
                    _ = fallback()
                    return .success(input)
                }
            }
            """
        }.joined(separator: "\n")
    }

    private static func typeScriptSource(declarationCount: Int) -> String {
        (0 ..< declarationCount).map { index in
            """
            export interface TypeBench\(index)<T> {
                value\(index): Promise<Record<string, T>>;
                transform\(index)(input: T, fallback?: () => { value: T }): Promise<{ value: T }>;
            }
            export const transform\(index) = async <T>(input: T): Promise<{ value: T }> => {
                return { value: input };
            };
            export const payload\(index): Record<string, number> = { value: \(index) };
            """
        }.joined(separator: "\n")
    }
}
