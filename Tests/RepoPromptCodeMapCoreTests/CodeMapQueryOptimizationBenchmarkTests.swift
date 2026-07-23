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
            XCTAssertEqual(
                collector.swiftSignatureNormalizationASCIINoOpCount +
                    collector.swiftSignatureNormalizationASCIIRewriteCount +
                    collector.swiftSignatureNormalizationUnicodeFallbackCount,
                collector.swiftStrategyFunctionSignatureCount
            )
            XCTAssertGreaterThan(collector.swiftSignatureNormalizationInputUTF8ByteCount, 0)
            XCTAssertGreaterThan(collector.swiftSignatureNormalizationOutputUTF8ByteCount, 0)
            XCTAssertLessThanOrEqual(
                collector.swiftSignatureNormalizationOutputUTF8ByteCount,
                collector.swiftSignatureNormalizationInputUTF8ByteCount
            )
            XCTAssertEqual(
                collector.swiftParameterTypeASCIIFastPathCount +
                    collector.swiftParameterTypeUnicodeLegacyFallbackCount,
                collector.swiftParameterTypeFallbackParserCount
            )
            XCTAssertGreaterThan(
                collector.swiftParameterTypeDirectCaptureCount +
                    collector.swiftParameterTypeFallbackParserCount,
                0
            )
            XCTAssertLessThanOrEqual(
                collector.swiftParameterTypeFallbackParserCount,
                collector.swiftNestedFunctionContainmentLookupCount
            )
            if collector.swiftParameterTypeFallbackParserCount > 0 {
                XCTAssertGreaterThan(collector.swiftParameterTypeInputUTF8ByteCount, 0)
            }
            XCTAssertGreaterThanOrEqual(
                collector.swiftParameterTypeResolutionDuration,
                collector.swiftParameterTypeLegacyFallbackDuration
            )
            XCTAssertEqual(
                collector.swiftPropertyTypeResolutionCount,
                collector.swiftStrategyPropertyTypeExtractionCount
            )
            XCTAssertEqual(
                collector.swiftPropertyTypeASCIIDirectTypeCount +
                    collector.swiftPropertyTypeASCIIDirectNilCount +
                    collector.swiftPropertyTypeLegacyFallbackCount,
                collector.swiftPropertyTypeResolutionCount
            )
            XCTAssertEqual(
                collector.swiftPropertyTypeLegacyFallbackCount,
                collector.swiftPropertyTypeUnicodeLegacyFallbackCount +
                    collector.swiftPropertyTypeASCIIIneligibleFallbackCount
            )
            XCTAssertGreaterThan(
                collector.swiftPropertyTypeASCIIDirectTypeCount +
                    collector.swiftPropertyTypeASCIIDirectNilCount,
                0
            )
            if collector.swiftPropertyTypeResolutionCount > 0 {
                XCTAssertGreaterThan(collector.swiftPropertyTypeInputUTF8ByteCount, 0)
            }
            XCTAssertGreaterThanOrEqual(
                collector.swiftPropertyTypeResolutionDuration,
                collector.swiftPropertyTypeASCIIFastPathDuration
            )
            XCTAssertGreaterThanOrEqual(
                collector.swiftPropertyTypeResolutionDuration,
                collector.swiftPropertyTypeLegacyFallbackDuration
            )
            XCTAssertLessThan(
                collector.swiftPropertyTypeLegacyFallbackCount,
                collector.swiftPropertyTypeResolutionCount
            )
            XCTAssertGreaterThan(collector.referencedTypesSwiftDedupEligibleCount, 0)
            XCTAssertGreaterThan(collector.referencedTypesSwiftFirstSeenCount, 0)
            XCTAssertGreaterThan(collector.referencedTypesSwiftDuplicateSkipCount, 0)
            XCTAssertEqual(
                collector.referencedTypesSwiftFirstSeenCount +
                    collector.referencedTypesSwiftDuplicateSkipCount,
                collector.referencedTypesSwiftDedupEligibleCount
            )
            XCTAssertGreaterThan(collector.referencedTypesSwiftDuplicateSkippedUTF8ByteCount, 0)
            XCTAssertGreaterThanOrEqual(collector.referencedTypesSwiftRawTypeDedupDuration, 0)
            XCTAssertLessThanOrEqual(
                collector.referencedTypesSwiftRawTypeDedupDuration,
                collector.builderGeneratorDuration
            )
            XCTAssertLessThanOrEqual(
                collector.referencedTypesSwiftRawTypeDedupDuration,
                collector.builderTotalDuration
            )
            XCTAssertEqual(
                collector.typeCleanerExtractCalls,
                collector.typeCleanerCacheHits + collector.typeCleanerCacheMisses
            )
            XCTAssertLessThan(collector.typeCleanerExtractCalls, 1_497)
            XCTAssertLessThan(collector.typeCleanerCacheHits, 759)
            XCTAssertEqual(collector.typeCleanerCacheMisses, 738)
            XCTAssertEqual(collector.typeCleanerSwiftCalls, 738)

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

    func testTypeScriptAndTSXCorpusCorrectnessReference() throws {
        #if RPCE_BENCHMARK_TESTS
            guard TypeScriptCodeMapPipelineBenchmarkSupport.isRuntimeEnabled else {
                throw XCTSkip("Set RP_RUN_TYPESCRIPT_CODEMAP_REFERENCE=1 to run the TS/TSX corpus reference test")
            }

            let files = TypeScriptCodeMapPipelineBenchmarkSupport.makeCorpus(
                tsSource: Self.typeScriptSource(declarationCount: 200),
                tsxSource: Self.typeScriptXSource(declarationCount: 200)
            )
            let artifacts = try files.map(TypeScriptCodeMapPipelineBenchmarkSupport.buildArtifact)
            let repeated = try files.map(TypeScriptCodeMapPipelineBenchmarkSupport.buildArtifact)
            XCTAssertEqual(artifacts, repeated)

            let evidences = try zip(files, artifacts).map {
                try TypeScriptCodeMapPipelineBenchmarkSupport.makeEvidence(file: $0, artifact: $1)
            }
            XCTAssertEqual(evidences.count, 2)
            TypeScriptCodeMapPipelineBenchmarkSupport.printDigestRecord(
                evidences[0].reference,
                language: .ts
            )
            TypeScriptCodeMapPipelineBenchmarkSupport.printDigestRecord(
                evidences[1].reference,
                language: .tsx
            )
            try TypeScriptCodeMapPipelineBenchmarkSupport.applyReferenceMode(
                tsReference: evidences[0].reference,
                tsxReference: evidences[1].reference
            )
        #else
            throw XCTSkip("Compile with RPCE_ENABLE_BENCHMARK_TESTS=1 to run the TS/TSX corpus reference test")
        #endif
    }

    func testJSTSSignatureNormalizerMatchesLegacyBehavior() {
        let cases: [(name: String, input: String, expected: String)] = [
            ("empty", "", ""),
            ("already normalized", "function value(input: string): string", "function value(input: string): string"),
            ("no whitespace", "constValue", "constValue"),
            ("spaces", "  const   value: string  ", "const value: string"),
            ("tab", "const\tvalue: string", "const value: string"),
            ("newline", "const\nvalue: string", "const value: string"),
            ("vertical tab", "const\u{000B}value: string", "const value: string"),
            ("form feed", "const\u{000C}value: string", "const value: string"),
            ("carriage return", "const\rvalue: string", "const value: string"),
            ("mixed whitespace", "\tconst \n\u{000B}\u{000C}\r value: string\r\n", "const value: string"),
            ("one semicolon", "const value: string;", "const value: string"),
            ("space before semicolon", "const value: string ;", "const value: string"),
            ("two semicolons", "const value: string;;", "const value: string;"),
            ("three semicolons", "const value: string;;;", "const value: string;;"),
            ("semicolon only", ";", ""),
            ("arrow", "const map = ( value: T ): U =>", "const map = ( value: T ): U =>"),
            ("generic", "method<T extends { value: string }>(input: T): Promise<T>", "method<T extends { value: string }>(input: T): Promise<T>"),
            ("object literal", "type Payload = { value: string; count: number };", "type Payload = { value: string; count: number }"),
            ("union", "type State = Ready | Pending | Failed;", "type State = Ready | Pending | Failed"),
            ("conditional", "type Pick<T> = T extends string ? Text<T> : Other<T>;", "type Pick<T> = T extends string ? Text<T> : Other<T>"),
            ("template", "const value = `a  b; ${item}`;", "const value = `a b; ${item}`"),
            ("line comment", "const value = 1; //  comment", "const value = 1; // comment"),
            ("block comment", "const value = /*  comment  */ 1;", "const value = /* comment */ 1"),
            ("JSX", "const view = <section  data-id=\"x\"> {value} </section>;", "const view = <section data-id=\"x\"> {value} </section>"),
            ("string default", #"function value(text = "a  b;")"#, #"function value(text = "a b;")"#),
            ("template default", "function value(text = `a  b;`)", "function value(text = `a b;`)")
        ]

        for testCase in cases {
            let legacy = JSTSSignatureExtractor.normalizeSingleLineLegacy(testCase.input)
            XCTAssertEqual(legacy, testCase.expected, "legacy: \(testCase.name)")
            XCTAssertEqual(
                JSTSSignatureExtractor.normalizeSingleLine(testCase.input),
                legacy,
                testCase.name
            )
        }
    }

    func testJSTSSignatureNormalizerUnicodeUsesLegacyFallback() {
        let inputs = [
            "const café: Type = value;",
            "const value: Café = item;",
            "const\u{00A0}value: Type = item;",
            "const\u{2003}value: Type = item;",
            "const emoji = \"🙂  value;\";",
            "前  const value: Type;",
            "const value: Type;  後",
        ]
        let collector = CodeMapPerformanceCollector()

        for input in inputs {
            XCTAssertEqual(
                JSTSSignatureExtractor.normalizeSingleLine(
                    input,
                    perfStats: collector,
                    perfOptions: .countersOnly
                ),
                JSTSSignatureExtractor.normalizeSingleLineLegacy(input),
                String(reflecting: input)
            )
        }

        XCTAssertEqual(collector.jstsNormalizationASCIINoOpCount, 0)
        XCTAssertEqual(collector.jstsNormalizationASCIIRewriteCount, 0)
        XCTAssertEqual(collector.jstsNormalizationUnicodeFallbackCount, inputs.count)
        XCTAssertGreaterThanOrEqual(collector.jstsNormalizationLegacyFallbackDuration, 0)
    }

    func testJSTSSignatureNormalizerGeneratedASCIIEquivalenceAndCounters() {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_".utf8) + [
            0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
            0x22, 0x27, 0x60, 0x2F, 0x5C,
            0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x3C, 0x3E,
            0x3A, 0x3D, 0x2D, 0x2C, 0x2E, 0x3F, 0x21, 0x26, 0x7C, 0x3B,
        ]
        let caseCount = 2_000
        var state: UInt64 = 0xA5C1_17E5_51A6_0001
        let collector = CodeMapPerformanceCollector()

        func nextRandom() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }

        for caseIndex in 0 ..< caseCount {
            let input: String
            switch caseIndex {
            case 0:
                input = "function value(input: string): string"
            case 1:
                input = "  function\tvalue( input: string );  "
            default:
                let length = Int(nextRandom() % 161)
                var bytes: [UInt8] = []
                bytes.reserveCapacity(length)
                for _ in 0 ..< length {
                    bytes.append(alphabet[Int(nextRandom() % UInt64(alphabet.count))])
                }
                input = String(decoding: bytes, as: UTF8.self)
            }

            XCTAssertEqual(
                JSTSSignatureExtractor.normalizeSingleLine(
                    input,
                    perfStats: collector,
                    perfOptions: .countersOnly
                ),
                JSTSSignatureExtractor.normalizeSingleLineLegacy(input),
                "generated case \(caseIndex): \(String(reflecting: input))"
            )
        }

        XCTAssertGreaterThan(collector.jstsNormalizationASCIINoOpCount, 0)
        XCTAssertGreaterThan(collector.jstsNormalizationASCIIRewriteCount, 0)
        XCTAssertEqual(collector.jstsNormalizationUnicodeFallbackCount, 0)
        XCTAssertEqual(
            collector.jstsNormalizationASCIINoOpCount +
                collector.jstsNormalizationASCIIRewriteCount,
            caseCount
        )
        XCTAssertGreaterThanOrEqual(collector.jstsNormalizationASCIIFastPathDuration, 0)
        XCTAssertEqual(collector.jstsNormalizationLegacyFallbackDuration, 0)
    }

    func testJSTSSignatureNormalizerRoutesSharedJavaScriptTypeScriptAndTSXPipeline() throws {
        let cases: [(name: String, language: LanguageType, source: String)] = [
            (
                "javascript",
                .js,
                """
                export function run(value) { return value; }
                export const payload = value;
                """
            ),
            (
                "typescript",
                .ts,
                """
                export interface Example {
                    value: string;
                    run(input: string): Promise<string>;
                }
                export const transform = (input: string): string => input;
                """
            ),
            (
                "tsx",
                .tsx,
                """
                export interface Props {
                    title: string;
                }
                export function Card(props: Props): JSX.Element {
                    return <section>{props.title}</section>;
                }
                """
            ),
        ]

        for testCase in cases {
            let collector = CodeMapPerformanceCollector()
            _ = try build(
                source: testCase.source,
                language: testCase.language,
                options: .countersOnly,
                collector: collector
            )

            let extractorCalls = collector.jstsSignatureCallsFunctionLike +
                collector.jstsSignatureCallsStatementLike
            let normalizationRoutes = collector.jstsNormalizationASCIINoOpCount +
                collector.jstsNormalizationASCIIRewriteCount +
                collector.jstsNormalizationUnicodeFallbackCount
            XCTAssertGreaterThan(extractorCalls, 0, testCase.name)
            XCTAssertEqual(normalizationRoutes, extractorCalls, testCase.name)
            XCTAssertGreaterThan(
                collector.jstsNormalizationASCIINoOpCount +
                    collector.jstsNormalizationASCIIRewriteCount,
                0,
                testCase.name
            )
            XCTAssertEqual(collector.jstsNormalizationUnicodeFallbackCount, 0, testCase.name)
            XCTAssertGreaterThanOrEqual(collector.jstsNormalizationASCIIFastPathDuration, 0, testCase.name)
            XCTAssertEqual(collector.jstsNormalizationLegacyFallbackDuration, 0, testCase.name)
        }
    }

    func testSwiftSignatureWhitespaceNormalizerMatchesLegacyBehavior() {
        let cases: [(name: String, input: String)] = [
            ("space run", "func  value()"),
            ("tab", "func\tvalue()"),
            ("newline", "func\nvalue()"),
            ("vertical tab", "func\u{000B}value()"),
            ("form feed", "func\u{000C}value()"),
            ("carriage return", "func\rvalue()"),
            ("mixed whitespace run", "func \t\n\u{000B}\u{000C}\r value()"),
            ("already normalized", "func value(_ input: Int) -> String"),
            ("no whitespace", "funcValue()"),
            ("empty", ""),
            ("trimmed away", " \t\n\r "),
            ("string literal", #"func value(_ text: String = "a  b") -> String"#),
            ("line comment", "func value() -> Int //  comment"),
            ("block comment", "func value(/*  comment  */ _ input: Int)"),
            ("closure default", "func value(_ transform: (Int) -> Int = { value  in value })"),
            ("braces colons arrows", #"func value(_ text: String = "{  key:  -> }")"#),
            ("non-ASCII identifier", "func café(_ value: Int)"),
            ("nonbreaking space", "func\u{00A0}value()"),
            ("em space", "func\u{2003}value()"),
        ]

        for testCase in cases {
            let trimmed = testCase.input.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(
                SwiftCodeMapStrategy.normalizeSwiftSignatureWhitespace(
                    trimmed,
                    performanceCollector: nil
                ),
                Self.legacySwiftSignatureWhitespaceNormalization(testCase.input),
                testCase.name
            )
        }
    }

    func testSwiftSignatureWhitespaceNormalizerCounters() {
        let inputs = [
            "func value() -> Int",
            "func\tvalue(\n_ item: Int)",
            "func café(\u{2003}_ value: Int)",
        ]
        let collector = CodeMapPerformanceCollector()
        let outputs = inputs.map {
            SwiftCodeMapStrategy.normalizeSwiftSignatureWhitespace(
                $0,
                performanceCollector: collector
            )
        }

        XCTAssertEqual(outputs, inputs.map(Self.legacySwiftSignatureWhitespaceNormalization))
        XCTAssertEqual(collector.swiftSignatureNormalizationASCIINoOpCount, 1)
        XCTAssertEqual(collector.swiftSignatureNormalizationASCIIRewriteCount, 1)
        XCTAssertEqual(collector.swiftSignatureNormalizationUnicodeFallbackCount, 1)
        XCTAssertEqual(
            collector.swiftSignatureNormalizationASCIINoOpCount +
                collector.swiftSignatureNormalizationASCIIRewriteCount +
                collector.swiftSignatureNormalizationUnicodeFallbackCount,
            inputs.count
        )
        XCTAssertEqual(
            collector.swiftSignatureNormalizationInputUTF8ByteCount,
            inputs.reduce(0) { $0 + $1.utf8.count }
        )
        XCTAssertEqual(
            collector.swiftSignatureNormalizationOutputUTF8ByteCount,
            outputs.reduce(0) { $0 + $1.utf8.count }
        )
        XCTAssertLessThanOrEqual(
            collector.swiftSignatureNormalizationOutputUTF8ByteCount,
            collector.swiftSignatureNormalizationInputUTF8ByteCount
        )
    }

    func testSwiftParameterTypeASCIIFastPathMatchesLegacyBehavior() {
        let cases: [(name: String, input: String, expected: String?)] = [
            ("simple", "value: Int", "Int"),
            ("external local", "_ value: Int", "Int"),
            ("labeled generic", "label value: Result<String, Error>", "Result<String, Error>"),
            ("nested attribute colon", "@Wrapper(label: \"x:y\") value: Int = 42", "Int"),
            ("nested default", "value: [String: Int] = [\"x\": 1]", "[String: Int]"),
            ("tuple", "value: (Int, String)", "(Int, String)"),
            ("closure default", "handler: (Int) -> Void = { _ in }", "(Int) -> Void"),
            ("generic function type", "transform: (@escaping (Int) -> Result<String, Error>)?", "(@escaping (Int) -> Result<String, Error>)?"),
            ("nested collection", "value: [String: (Int, Bool)]", "[String: (Int, Bool)]"),
            ("raw string", ##"@Wrapper(text: #"x:y="#) value: Int = 42"##, "Int"),
            ("multi-pound raw string", ###"@Wrapper(text: ##"x:y="##) value: Int"###, "Int"),
            ("triple string", "@Wrapper(text: \"\"\"x:y=()[]{}\"\"\") value: String", "String"),
            ("escaped quote", ##"@Wrapper(text: "x\"y:z") value: Int"##, "Int"),
            ("line comment blindness", "value // note: marker: Int", "marker: Int"),
            ("block comment colon blindness", "value /* note: marker */: Int", "marker */: Int"),
            ("block comment equal blindness", "value: Int /* = default */", "Int /*"),
            ("unmatched closing paren", "value): Int", "Int"),
            ("unmatched opening paren", "value(: Int", nil),
            ("mismatched closing bracket", "value]: Int", "Int"),
            ("unclosed bracket", "value[: Int", nil),
            ("unterminated string", "\"unterminated: value: Int", nil),
            ("unterminated raw string", "##\"unterminated: value: Int", nil),
            ("unterminated triple string", "\"\"\"unterminated: value: Int", nil),
            ("isolated pound", "# value: Int", "Int"),
            ("two quotes", "\"\": Int", "Int"),
            ("missing colon", "value", nil),
            ("empty type", "value:", nil),
            ("whitespace type", "value: \t\n\u{000B}\u{000C}\r", nil),
            ("angle brackets stay untracked", "value: Result<A = B, C>", "Result<A"),
            ("nested equal", "value: (A = B)", "(A = B)"),
        ]

        for testCase in cases {
            let legacy = SwiftCodeMapStrategy.extractSwiftParamTypeLegacy(from: testCase.input)
            XCTAssertEqual(legacy, testCase.expected, "legacy: \(testCase.name)")
            XCTAssertEqual(
                SwiftCodeMapStrategy.extractSwiftParamType(from: testCase.input),
                legacy,
                testCase.name
            )
        }
    }

    func testSwiftParameterTypeASCIIFastPathGeneratedEquivalenceAndCounters() {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_".utf8) + [
            0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
            0x3A, 0x3D, 0x23, 0x22, 0x5C, 0x2F,
            0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D,
            0x3C, 0x3E, 0x2C, 0x2E, 0x2D, 0x2A,
        ]
        let caseCount = 2_000
        var state: UInt64 = 0x5F93_1049_D4C0_0400
        var totalUTF8ByteCount = 0
        let collector = CodeMapPerformanceCollector()

        func nextRandom() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }

        for index in 0 ..< caseCount {
            let length = Int(nextRandom() % 161)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(length)
            for _ in 0 ..< length {
                bytes.append(alphabet[Int(nextRandom() % UInt64(alphabet.count))])
            }
            let input = String(decoding: bytes, as: UTF8.self)
            totalUTF8ByteCount += input.utf8.count
            XCTAssertEqual(
                SwiftCodeMapStrategy.extractSwiftParamType(
                    from: input,
                    performanceCollector: collector
                ),
                SwiftCodeMapStrategy.extractSwiftParamTypeLegacy(from: input),
                "generated case \(index): \(String(reflecting: input))"
            )
        }

        XCTAssertEqual(collector.swiftParameterTypeFallbackParserCount, caseCount)
        XCTAssertEqual(collector.swiftParameterTypeASCIIFastPathCount, caseCount)
        XCTAssertEqual(collector.swiftParameterTypeUnicodeLegacyFallbackCount, 0)
        XCTAssertEqual(collector.swiftParameterTypeInputUTF8ByteCount, totalUTF8ByteCount)
    }

    func testSwiftParameterTypeUnicodeAlwaysUsesLegacyFallback() {
        let inputs = [
            "café: Type",
            "value: Café",
            "value:\u{00A0}Type",
            "value:\u{2003}Type",
            "@Wrapper(label: \"🙂:x\") value: Int",
            "café(: Int",
        ]
        let collector = CodeMapPerformanceCollector()

        for input in inputs {
            XCTAssertEqual(
                SwiftCodeMapStrategy.extractSwiftParamType(
                    from: input,
                    performanceCollector: collector
                ),
                SwiftCodeMapStrategy.extractSwiftParamTypeLegacy(from: input),
                String(reflecting: input)
            )
        }

        XCTAssertEqual(collector.swiftParameterTypeFallbackParserCount, inputs.count)
        XCTAssertEqual(collector.swiftParameterTypeASCIIFastPathCount, 0)
        XCTAssertEqual(collector.swiftParameterTypeUnicodeLegacyFallbackCount, inputs.count)
        XCTAssertEqual(
            collector.swiftParameterTypeInputUTF8ByteCount,
            inputs.reduce(0) { $0 + $1.utf8.count }
        )
        XCTAssertGreaterThanOrEqual(collector.swiftParameterTypeLegacyFallbackDuration, 0)
    }

    func testSwiftPropertyTypeASCIIFastPathMatchesLegacyBehavior() {
        let directCases: [(String, String, SwiftCodeMapStrategy.SwiftASCIIPropertyTypeResolution)] = [
            ("no type var", "var value", .noType),
            ("no type let", "let value \t", .noType),
            ("empty colon", "var value:", .noType),
            ("simple", "var value: Int", .type("Int")),
            ("bullet", "- let value: String", .type("String")),
            ("attribute", "@Published var value: String?", .type("String?")),
            ("attribute arguments", "@Option(flag: true) var value: Int!", .type("Int!")),
            ("generic", "let value: Result<String, Error>", .type("Result<String, Error>")),
            ("nested generic", "var value: Result<[String: (Int, Bool)], Error>", .type("Result<[String: (Int, Bool)], Error>")),
            ("tuple", "var value: (Int, String)", .type("(Int, String)")),
            ("function", "var handler: (@escaping (Int) -> Result<String, Error>)?", .type("(@escaping (Int) -> Result<String, Error>)?")),
            ("array", "var values: [String]", .type("[String]")),
            ("dictionary", "var values: [String: Int]", .type("[String: Int]")),
            ("existential", "var value: any Sendable", .type("any Sendable")),
            ("opaque", "var value: some Sequence", .type("some Sequence")),
            ("composition", "var value: P & Q", .type("P & Q")),
            ("initializer", "var value: Int = 42", .type("Int")),
            ("newline after colon", "var value:\n Int", .type("Int")),
            ("trailing newlines", "var value: Int\r\n", .type("Int")),
        ]

        for (name, declaration, expectedResolution) in directCases {
            let legacy = SwiftCodeMapStrategy.extractSwiftPropertyTypeLegacy(from: declaration)
            XCTAssertEqual(
                SwiftCodeMapStrategy.resolveSwiftASCIIPropertyType(in: declaration.utf8),
                expectedResolution,
                name
            )
            XCTAssertEqual(
                SwiftCodeMapStrategy.extractSwiftPropertyType(from: declaration),
                legacy,
                name
            )
        }

        let modifiers = [
            "private(set)", "public", "private", "internal", "fileprivate", "open",
            "class", "static", "final", "lazy", "override", "mutating", "actor", "inout",
            "required", "convenience", "indirect", "weak", "unowned", "dynamic", "distributed", "isolated",
        ]
        for modifier in modifiers {
            let declaration = "\(modifier) var value: Int"
            XCTAssertEqual(
                SwiftCodeMapStrategy.resolveSwiftASCIIPropertyType(in: declaration.utf8),
                .type("Int"),
                modifier
            )
            XCTAssertEqual(
                SwiftCodeMapStrategy.extractSwiftPropertyType(from: declaration),
                SwiftCodeMapStrategy.extractSwiftPropertyTypeLegacy(from: declaration),
                modifier
            )
        }

        let fallbackCases = [
            "var value: \t\r",
            "@Outer(inner(value)) var value: Int",
            "@Broken( var value: Int",
            "unknown var value: Int",
            "var value /* comment */: Int",
            "var value: /* comment */ Int",
            "var value: Int // comment",
            "var value: Int, other: String",
            "var value: Result<A = B, C>",
            "var value: (A = B)",
            "var value: Int == 42",
            "var value: Int { get }",
            "var value: Int = \"text\"",
            "var value: Result<String, Error",
            "var value: Int\nlet other: String",
            "var value): Int",
        ]
        for declaration in fallbackCases {
            XCTAssertEqual(
                SwiftCodeMapStrategy.resolveSwiftASCIIPropertyType(in: declaration.utf8),
                .fallback,
                String(reflecting: declaration)
            )
            XCTAssertEqual(
                SwiftCodeMapStrategy.extractSwiftPropertyType(from: declaration),
                SwiftCodeMapStrategy.extractSwiftPropertyTypeLegacy(from: declaration),
                String(reflecting: declaration)
            )
        }
    }

    func testSwiftPropertyTypeGeneratedASCIIEquivalenceAndCounters() {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_".utf8) + [
            0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
            0x3A, 0x3D, 0x23, 0x22, 0x5C, 0x2F, 0x40,
            0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D,
            0x3C, 0x3E, 0x2C, 0x2E, 0x2D, 0x2A, 0x3F, 0x21, 0x26,
        ]
        let directTypes = [
            "Int", "String?", "Result<String, Error>", "[String: Int]",
            "(Int, String)", "(Int) -> Void", "any Sendable", "P & Q",
        ]
        let caseCount = 2_000
        var state: UInt64 = 0x6006_5A17_C0DE_0060
        var totalUTF8ByteCount = 0
        let collector = CodeMapPerformanceCollector()

        func nextRandom() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }

        for caseIndex in 0 ..< caseCount {
            let input: String
            if caseIndex.isMultiple(of: 4) {
                let keyword = caseIndex.isMultiple(of: 8) ? "var" : "let"
                let type = directTypes[Int(nextRandom() % UInt64(directTypes.count))]
                input = "\(keyword) value\(caseIndex): \(type)"
            } else {
                let length = Int(nextRandom() % 161)
                var bytes: [UInt8] = []
                bytes.reserveCapacity(length)
                for _ in 0 ..< length {
                    bytes.append(alphabet[Int(nextRandom() % UInt64(alphabet.count))])
                }
                input = String(decoding: bytes, as: UTF8.self)
            }
            totalUTF8ByteCount += input.utf8.count

            let legacy = SwiftCodeMapStrategy.extractSwiftPropertyTypeLegacy(from: input)
            let direct = SwiftCodeMapStrategy.resolveSwiftASCIIPropertyType(in: input.utf8)
            switch direct {
            case let .type(type):
                XCTAssertEqual(type, legacy, "generated direct type \(caseIndex)")
            case .noType:
                XCTAssertNil(legacy, "generated direct nil \(caseIndex)")
            case .fallback:
                break
            }
            XCTAssertEqual(
                SwiftCodeMapStrategy.extractSwiftPropertyType(from: input, perfStats: collector),
                legacy,
                "generated case \(caseIndex): \(String(reflecting: input))"
            )
        }

        XCTAssertEqual(collector.swiftPropertyTypeResolutionCount, caseCount)
        XCTAssertGreaterThan(
            collector.swiftPropertyTypeASCIIDirectTypeCount +
                collector.swiftPropertyTypeASCIIDirectNilCount,
            0
        )
        XCTAssertEqual(
            collector.swiftPropertyTypeASCIIDirectTypeCount +
                collector.swiftPropertyTypeASCIIDirectNilCount +
                collector.swiftPropertyTypeLegacyFallbackCount,
            caseCount
        )
        XCTAssertEqual(
            collector.swiftPropertyTypeLegacyFallbackCount,
            collector.swiftPropertyTypeASCIIIneligibleFallbackCount
        )
        XCTAssertEqual(collector.swiftPropertyTypeUnicodeLegacyFallbackCount, 0)
        XCTAssertEqual(collector.swiftPropertyTypeInputUTF8ByteCount, totalUTF8ByteCount)
        XCTAssertGreaterThanOrEqual(
            collector.swiftPropertyTypeResolutionDuration,
            collector.swiftPropertyTypeASCIIFastPathDuration
        )
        XCTAssertGreaterThanOrEqual(
            collector.swiftPropertyTypeResolutionDuration,
            collector.swiftPropertyTypeLegacyFallbackDuration
        )
    }

    func testSwiftPropertyTypeUnicodeAlwaysUsesLegacyFallback() {
        let declarations = [
            "var café: Type",
            "var value: Café",
            "var value:\u{00A0}Type",
            "var value:\u{2003}Type",
            "@Wrapper(label: \"🙂\") var value: Int",
            "var value: String = \"🙂\"",
            "var mixed: Result<Café, Error>",
        ]
        let collector = CodeMapPerformanceCollector()

        for declaration in declarations {
            XCTAssertEqual(
                SwiftCodeMapStrategy.resolveSwiftASCIIPropertyType(in: declaration.utf8),
                .fallback
            )
            XCTAssertEqual(
                SwiftCodeMapStrategy.extractSwiftPropertyType(from: declaration, perfStats: collector),
                SwiftCodeMapStrategy.extractSwiftPropertyTypeLegacy(from: declaration),
                String(reflecting: declaration)
            )
        }

        XCTAssertEqual(collector.swiftPropertyTypeResolutionCount, declarations.count)
        XCTAssertEqual(collector.swiftPropertyTypeLegacyFallbackCount, declarations.count)
        XCTAssertEqual(collector.swiftPropertyTypeUnicodeLegacyFallbackCount, declarations.count)
        XCTAssertEqual(collector.swiftPropertyTypeASCIIIneligibleFallbackCount, 0)
        XCTAssertEqual(collector.swiftPropertyTypeASCIIDirectTypeCount, 0)
        XCTAssertEqual(collector.swiftPropertyTypeASCIIDirectNilCount, 0)
        XCTAssertEqual(
            collector.swiftPropertyTypeInputUTF8ByteCount,
            declarations.reduce(0) { $0 + $1.utf8.count }
        )
        XCTAssertGreaterThanOrEqual(
            collector.swiftPropertyTypeResolutionDuration,
            collector.swiftPropertyTypeLegacyFallbackDuration
        )
    }

    func testSwiftPropertyTypePipelineRoutesTopLevelMemberProtocolAndComputedDeclarations() throws {
        let source = """
        let globalValue: Int = 1
        struct Example {
            private(set) var memberValue: Result<String, Error> = .success(\"ok\")
            var computedValue: [String: Int] { [:] }
        }
        protocol Shape {
            var protocolValue: any Sendable { get }
        }
        """
        let collector = CodeMapPerformanceCollector()
        let artifact = try build(
            source: source,
            language: .swift,
            options: .countersOnly,
            collector: collector
        )

        let global = try XCTUnwrap(artifact.globalVars.first { $0.name.contains("globalValue") })
        XCTAssertEqual(global.typeName, "Int")
        let example = try XCTUnwrap(artifact.classes.first { $0.name == "Example" })
        XCTAssertEqual(example.properties.map(\.typeName), ["Result<String, Error>", "[String: Int]"])
        XCTAssertTrue(example.properties[1].name.contains("computedValue"))
        XCTAssertFalse(example.properties[1].name.contains("{"))
        let shape = try XCTUnwrap(artifact.interfaces.first { $0.name == "Shape" })
        XCTAssertEqual(shape.properties.map(\.typeName), ["any Sendable"])

        XCTAssertEqual(collector.swiftPropertyTypeResolutionCount, 4)
        XCTAssertEqual(collector.swiftPropertyTypeASCIIDirectTypeCount, 4)
        XCTAssertEqual(collector.swiftPropertyTypeASCIIDirectNilCount, 0)
        XCTAssertEqual(collector.swiftPropertyTypeLegacyFallbackCount, 0)
        XCTAssertEqual(collector.lteMatchAnyVariableCalls, 0)
        XCTAssertGreaterThan(collector.swiftPropertyTypeInputUTF8ByteCount, 0)
    }

    func testSwiftReferencedTypesDedupMatchesFreshInsertionAuthority() {
        let sequences: [(name: String, rawTypes: [String?])] = [
            ("exact duplicate", ["Result<Payload, Failure>", "Result<Payload, Failure>"]),
            ("trimmed duplicate", ["  Result<Payload, Failure>\n", "Result<Payload, Failure>"]),
            ("case-sensitive", ["Widget", "widget", "Widget"]),
            ("complex generics", [
                "Outer<Inner<Payload>, Result<Value, Failure>>",
                "Outer<Inner<Payload>, Result<Value, Failure>>",
            ]),
            ("functions", [
                "(Input, @escaping (Nested) -> Output) async throws -> Result<Value, Failure>",
                "(Input, @escaping (Nested) -> Output) async throws -> Result<Value, Failure>",
            ]),
            ("tuples arrays dictionaries", [
                "(Left, Right)",
                "[Element]",
                "[Key: Value]",
                "(Left, Right)",
            ]),
            ("compositions opaque existential", [
                "FirstProtocol & SecondProtocol",
                "some Shape",
                "any Shape",
                "FirstProtocol & SecondProtocol",
            ]),
            ("unicode", [
                "Résultat<Élément, Ошибка>",
                "Résultat<Élément, Ошибка>",
                "résultat<Élément, Ошибка>",
            ]),
            ("prefilter and empty", [nil, "", " \n\t", "Int", "Void", "Array", "Payload", "Payload"]),
        ]

        for sequence in sequences {
            assertSwiftReferencedTypesSequenceMatchesFreshAuthority(
                sequence.rawTypes,
                name: sequence.name
            )
        }

        let ordered: [String?] = [
            "Result<Payload, Failure>",
            "(Input) -> Output",
            "[Key: Value]",
            "FirstProtocol & SecondProtocol",
            "some Shape",
            "any Shape",
            "Résultat<Élément>",
            "Result<Payload, Failure>",
        ]
        assertSwiftReferencedTypesSequenceMatchesFreshAuthority(ordered, name: "forward order")
        assertSwiftReferencedTypesSequenceMatchesFreshAuthority(Array(ordered.reversed()), name: "reverse order")

        let manyRawTypes = ordered.compactMap { $0 }
        var individual = ReferencedTypesAccumulator(language: .swift)
        for rawType in manyRawTypes {
            individual.insert(rawType: rawType)
        }
        var many = ReferencedTypesAccumulator(language: .swift)
        many.insertMany(rawTypes: manyRawTypes)
        XCTAssertEqual(many.types, individual.types)
        XCTAssertEqual(many.finalizeSorted(), individual.finalizeSorted())
    }

    func testSwiftReferencedTypesDedupPreservesFirstSeenBehavior() {
        let raw = "Result<Payload, Failure>"
        let expected = Set(TypeCleaner.extractBaseTypes(from: raw, language: .swift)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        let collector = CodeMapPerformanceCollector()
        var accumulator = ReferencedTypesAccumulator(
            language: .swift,
            stats: collector,
            perfOptions: .countersOnly
        )

        accumulator.insert(rawType: raw)

        XCTAssertEqual(accumulator.types, expected)
        XCTAssertEqual(accumulator.finalizeSorted(), expected.sorted())
        XCTAssertEqual(collector.referencedTypesRawInsertions, 1)
        XCTAssertEqual(collector.referencedTypesSwiftDedupEligibleCount, 1)
        XCTAssertEqual(collector.referencedTypesSwiftFirstSeenCount, 1)
        XCTAssertEqual(collector.referencedTypesSwiftDuplicateSkipCount, 0)
        XCTAssertEqual(collector.referencedTypesSwiftDuplicateSkippedUTF8ByteCount, 0)
        XCTAssertGreaterThan(collector.typeCleanerExtractCalls, 0)
        XCTAssertEqual(
            collector.typeCleanerExtractCalls,
            collector.typeCleanerCacheHits + collector.typeCleanerCacheMisses
        )
        XCTAssertEqual(collector.referencedTypesEmptyResults, expected.isEmpty ? 1 : 0)
        XCTAssertEqual(collector.referencedTypesOutputTypeCount, expected.count)
        XCTAssertGreaterThanOrEqual(collector.referencedTypesSwiftRawTypeDedupDuration, 0)
    }

    func testSwiftReferencedTypesDedupSkipsExactTrimmedDuplicates() {
        let raw = "Result<Payload, Failure>"
        let collector = CodeMapPerformanceCollector()
        var accumulator = ReferencedTypesAccumulator(
            language: .swift,
            stats: collector,
            perfOptions: .countersOnly
        )
        accumulator.insert(rawType: raw)
        let firstTypes = accumulator.types
        let firstCleanerCalls = collector.typeCleanerExtractCalls
        let firstCacheHits = collector.typeCleanerCacheHits
        let firstCacheMisses = collector.typeCleanerCacheMisses
        let firstSwiftCalls = collector.typeCleanerSwiftCalls
        let firstEmptyResults = collector.referencedTypesEmptyResults
        let firstOutputTypes = collector.referencedTypesOutputTypeCount
        let firstDedupDuration = collector.referencedTypesSwiftRawTypeDedupDuration

        accumulator.insert(rawType: "  \(raw)\n")

        XCTAssertEqual(accumulator.types, firstTypes)
        XCTAssertEqual(accumulator.finalizeSorted(), firstTypes.sorted())
        XCTAssertEqual(collector.referencedTypesRawInsertions, 2)
        XCTAssertEqual(collector.referencedTypesSwiftDedupEligibleCount, 2)
        XCTAssertEqual(collector.referencedTypesSwiftFirstSeenCount, 1)
        XCTAssertEqual(collector.referencedTypesSwiftDuplicateSkipCount, 1)
        XCTAssertEqual(collector.referencedTypesSwiftDuplicateSkippedUTF8ByteCount, raw.utf8.count)
        XCTAssertEqual(collector.typeCleanerExtractCalls, firstCleanerCalls)
        XCTAssertEqual(collector.typeCleanerCacheHits, firstCacheHits)
        XCTAssertEqual(collector.typeCleanerCacheMisses, firstCacheMisses)
        XCTAssertEqual(collector.typeCleanerSwiftCalls, firstSwiftCalls)
        XCTAssertEqual(collector.referencedTypesEmptyResults, firstEmptyResults)
        XCTAssertEqual(collector.referencedTypesOutputTypeCount, firstOutputTypes)
        XCTAssertGreaterThanOrEqual(
            collector.referencedTypesSwiftRawTypeDedupDuration,
            firstDedupDuration
        )
    }

    func testSwiftReferencedTypesPrefilterRunsBeforeDedup() {
        let collector = CodeMapPerformanceCollector()
        var accumulator = ReferencedTypesAccumulator(
            language: .swift,
            stats: collector,
            perfOptions: .countersOnly
        )

        let rawTypes: [String?] = ["Int", "Int", "Void", "Array", nil, "", " \n\t"]
        for rawType in rawTypes {
            accumulator.insert(rawType: rawType)
        }

        XCTAssertEqual(accumulator.rawInsertions, 4)
        XCTAssertEqual(collector.referencedTypesRawInsertions, 4)
        XCTAssertEqual(collector.referencedTypesPrefilterSkips, 4)
        XCTAssertEqual(collector.referencedTypesEmptyResults, 4)
        XCTAssertEqual(collector.referencedTypesSwiftDedupEligibleCount, 0)
        XCTAssertEqual(collector.referencedTypesSwiftFirstSeenCount, 0)
        XCTAssertEqual(collector.referencedTypesSwiftDuplicateSkipCount, 0)
        XCTAssertEqual(collector.referencedTypesSwiftDuplicateSkippedUTF8ByteCount, 0)
        XCTAssertEqual(collector.referencedTypesSwiftRawTypeDedupDuration, 0)
        XCTAssertEqual(collector.typeCleanerExtractCalls, 0)
        XCTAssertTrue(accumulator.types.isEmpty)
    }

    func testNonSwiftReferencedTypeDuplicatesStillUseTypeCleanerCache() {
        for language: LanguageType in [.ts, .tsx] {
            let raw = "Promise<Payload>"
            let collector = CodeMapPerformanceCollector()
            var accumulator = ReferencedTypesAccumulator(
                language: language,
                stats: collector,
                perfOptions: .countersOnly
            )
            accumulator.insert(rawType: raw)
            let firstTypes = accumulator.types
            let firstCleanerCalls = collector.typeCleanerExtractCalls
            let firstCacheHits = collector.typeCleanerCacheHits
            let firstCacheMisses = collector.typeCleanerCacheMisses
            let firstOutputTypes = collector.referencedTypesOutputTypeCount
            let firstEmptyResults = collector.referencedTypesEmptyResults

            accumulator.insert(rawType: raw)

            XCTAssertEqual(accumulator.types, firstTypes, "language=\(language)")
            XCTAssertEqual(collector.typeCleanerExtractCalls, firstCleanerCalls + 1, "language=\(language)")
            XCTAssertEqual(collector.typeCleanerCacheHits, firstCacheHits + 1, "language=\(language)")
            XCTAssertEqual(collector.typeCleanerCacheMisses, firstCacheMisses, "language=\(language)")
            XCTAssertEqual(collector.referencedTypesOutputTypeCount, firstOutputTypes * 2, "language=\(language)")
            XCTAssertEqual(collector.referencedTypesEmptyResults, firstEmptyResults, "language=\(language)")
            XCTAssertEqual(collector.referencedTypesSwiftDedupEligibleCount, 0, "language=\(language)")
            XCTAssertEqual(collector.referencedTypesSwiftFirstSeenCount, 0, "language=\(language)")
            XCTAssertEqual(collector.referencedTypesSwiftDuplicateSkipCount, 0, "language=\(language)")
            XCTAssertEqual(collector.referencedTypesSwiftDuplicateSkippedUTF8ByteCount, 0, "language=\(language)")
            XCTAssertEqual(collector.referencedTypesSwiftRawTypeDedupDuration, 0, "language=\(language)")
        }
    }

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
            ("tsx", .tsx, Self.typeScriptXSource(declarationCount: 200)),
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
            if benchmark.language == .ts || benchmark.language == .tsx {
                XCTAssertEqual(
                    collector.jstsNormalizationASCIINoOpCount +
                        collector.jstsNormalizationASCIIRewriteCount +
                        collector.jstsNormalizationUnicodeFallbackCount,
                    collector.jstsSignatureCallsFunctionLike + collector.jstsSignatureCallsStatementLike
                )
                XCTAssertGreaterThan(
                    collector.jstsNormalizationASCIINoOpCount +
                        collector.jstsNormalizationASCIIRewriteCount,
                    0
                )
            }

            var record = [
                "CODEMAP_PREMATERIALIZED_GENERATOR_BENCHMARK",
                "language=\(benchmark.name)",
                "declarations=200",
                "raw_samples_ms=\(Self.formattedSamples(samplesMS))",
                "median_ms=\(Self.formattedMilliseconds(Self.median(samplesMS)))",
                "p95_ms=\(Self.formattedMilliseconds(Self.percentile95(samplesMS)))",
                "max_ms=\(Self.formattedMilliseconds(samplesMS.max() ?? 0))",
                "captures=\(captures.count)",
                "repeat_artifact_equality=\(repeatArtifactEquality)",
            ]
            record.append(contentsOf: Self.codeMapAttributionFields(collector))
            print(record.joined(separator: " "))
        }
    }

    func testSyntheticSwiftAndTypeScriptAttribution() throws {
        let cases: [(name: String, language: LanguageType, source: String)] = [
            ("swift", .swift, Self.swiftSource(declarationCount: 200)),
            ("typescript", .ts, Self.typeScriptSource(declarationCount: 200)),
            ("tsx", .tsx, Self.typeScriptXSource(declarationCount: 200)),
        ]

        for benchmark in cases {
            let expectedArtifact = try build(source: benchmark.source, language: benchmark.language)
            for _ in 0 ..< 2 {
                XCTAssertEqual(
                    try build(source: benchmark.source, language: benchmark.language),
                    expectedArtifact
                )
            }

            var samplesMS: [Double] = []
            samplesMS.reserveCapacity(5)
            for _ in 0 ..< 5 {
                let start = ProcessInfo.processInfo.systemUptime
                let artifact = try build(source: benchmark.source, language: benchmark.language)
                samplesMS.append((ProcessInfo.processInfo.systemUptime - start) * 1_000)
                XCTAssertEqual(artifact, expectedArtifact)
            }

            let collector = CodeMapPerformanceCollector(collectsCaptureNames: true)
            let attributedArtifact = try build(
                source: benchmark.source,
                language: benchmark.language,
                options: .countersOnly,
                collector: collector
            )
            let repeatArtifactEquality = attributedArtifact == expectedArtifact
            XCTAssertTrue(repeatArtifactEquality)
            XCTAssertEqual(collector.syntaxQueryExecutes, 1)
            XCTAssertGreaterThan(collector.syntaxCaptures, 0)
            if benchmark.language == .ts || benchmark.language == .tsx {
                XCTAssertEqual(
                    collector.jstsNormalizationASCIINoOpCount +
                        collector.jstsNormalizationASCIIRewriteCount +
                        collector.jstsNormalizationUnicodeFallbackCount,
                    collector.jstsSignatureCallsFunctionLike + collector.jstsSignatureCallsStatementLike
                )
                XCTAssertGreaterThan(
                    collector.jstsNormalizationASCIINoOpCount +
                        collector.jstsNormalizationASCIIRewriteCount,
                    0
                )
            }

            var record = [
                "CODEMAP_QUERY_BENCHMARK",
                "language=\(benchmark.name)",
                "declarations=200",
                "raw_samples_ms=\(Self.formattedSamples(samplesMS))",
                "median_ms=\(Self.formattedMilliseconds(Self.median(samplesMS)))",
                "p95_ms=\(Self.formattedMilliseconds(Self.percentile95(samplesMS)))",
                "max_ms=\(Self.formattedMilliseconds(samplesMS.max() ?? 0))",
                "captures=\(collector.syntaxCaptures)",
                "repeat_artifact_equality=\(repeatArtifactEquality)",
                "swift_bodies=\(collector.syntaxCaptureCountsByName["swift.function.body", default: 0])",
                "swift_returns=\(collector.syntaxCaptureCountsByName["swift.function.return_type", default: 0])",
                "swift_property_types=\(collector.syntaxCaptureCountsByName["swift.property.type", default: 0])",
                "ts_variables=\(collector.syntaxCaptureCountsByName["variable.global", default: 0])",
            ]
            record.append(contentsOf: Self.codeMapAttributionFields(collector))
            print(record.joined(separator: " "))
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
        XCTAssertEqual(swiftCollector.swiftPropertyTypeASCIIDirectTypeCount, 1)
        XCTAssertEqual(swiftCollector.swiftPropertyTypeLegacyFallbackCount, 0)
        XCTAssertEqual(swiftCollector.lteMatchAnyVariableCalls, 0)

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
        let collector = CodeMapPerformanceCollector()
        let artifact = try build(
            source: source,
            language: .swift,
            options: .countersOnly,
            collector: collector
        )
        let example = try XCTUnwrap(artifact.classes.first { $0.name == "Example" })
        let wrapped = try XCTUnwrap(example.methods.first { $0.name == "wrapped" })

        XCTAssertEqual(wrapped.parameters.map(\.localName), ["value"])
        XCTAssertEqual(wrapped.parameters.map(\.typeName), ["Int"])
        XCTAssertEqual(collector.swiftParameterTypeDirectCaptureCount, 0)
        XCTAssertEqual(collector.swiftParameterTypeFallbackParserCount, 1)
        XCTAssertEqual(collector.swiftParameterTypeASCIIFastPathCount, 1)
        XCTAssertEqual(collector.swiftParameterTypeUnicodeLegacyFallbackCount, 0)
        XCTAssertGreaterThan(collector.swiftParameterTypeInputUTF8ByteCount, 0)
        XCTAssertGreaterThanOrEqual(
            collector.swiftParameterTypeResolutionDuration,
            collector.swiftParameterTypeLegacyFallbackDuration
        )
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

    private func assertSwiftReferencedTypesSequenceMatchesFreshAuthority(
        _ rawTypes: [String?],
        name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var expected: Set<String> = []
        for rawType in rawTypes {
            var fresh = ReferencedTypesAccumulator(language: .swift)
            fresh.insert(rawType: rawType)
            expected.formUnion(fresh.types)
        }

        var accumulated = ReferencedTypesAccumulator(language: .swift)
        for rawType in rawTypes {
            accumulated.insert(rawType: rawType)
        }

        XCTAssertEqual(accumulated.types, expected, name, file: file, line: line)
        XCTAssertEqual(accumulated.finalizeSorted(), expected.sorted(), name, file: file, line: line)
    }

    private static func legacySwiftSignatureWhitespaceNormalization(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing(#/\s+/#, with: " ")
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

    private static func codeMapAttributionFields(_ collector: CodeMapPerformanceCollector) -> [String] {
        [
            "builder_total_ms=\(milliseconds(collector.builderTotalDuration))",
            "builder_generator_ms=\(milliseconds(collector.builderGeneratorDuration))",
            "syntax_total_ms=\(milliseconds(collector.syntaxTotalDuration))",
            "parse_ms=\(milliseconds(collector.syntaxParseDuration))",
            "query_ms=\(milliseconds(collector.syntaxQueryExecuteDuration))",
            "materialize_ms=\(milliseconds(collector.syntaxCaptureMaterializationDuration))",
            "capture_name_count_ms=\(milliseconds(collector.syntaxCaptureNameCountingDuration))",
            "capture_index_ms=\(milliseconds(collector.captureIndexDuration))",
            "ts_context_ms=\(milliseconds(collector.tsContextDuration))",
            "capture_loop_ms=\(milliseconds(collector.captureLoopDuration))",
            "ts_loop_ms=\(milliseconds(collector.captureLoopTSStrategyDuration))",
            "jsts_ms=\(milliseconds(collector.jstsSignatureDuration))",
            "jsts_normalization_ascii_ms=\(milliseconds(collector.jstsNormalizationASCIIFastPathDuration))",
            "jsts_normalization_legacy_ms=\(milliseconds(collector.jstsNormalizationLegacyFallbackDuration))",
            "lte_function_ms=\(milliseconds(collector.languageTypeExtractorFunctionDuration))",
            "lte_variable_ms=\(milliseconds(collector.languageTypeExtractorVariableDuration))",
            "type_cleaner_ms=\(milliseconds(collector.typeCleanerDuration))",
            "type_cleaner_ts_ms=\(milliseconds(collector.typeCleanerTSDuration))",
            "type_cleaner_tsx_ms=\(milliseconds(collector.typeCleanerTSXDuration))",
            "referenced_finalize_ms=\(milliseconds(collector.referencedTypesFinalizeDuration))",
            "artifact_finalize_ms=\(milliseconds(collector.artifactFinalizationDuration))",
            "captures_processed=\(collector.capturesProcessed)",
            "ts_strategy_handled=\(collector.tsStrategyHandled)",
            "jsts_function_calls=\(collector.jstsSignatureCallsFunctionLike)",
            "jsts_statement_calls=\(collector.jstsSignatureCallsStatementLike)",
            "jsts_normalization_ascii_noop=\(collector.jstsNormalizationASCIINoOpCount)",
            "jsts_normalization_ascii_rewrite=\(collector.jstsNormalizationASCIIRewriteCount)",
            "jsts_normalization_unicode_fallback=\(collector.jstsNormalizationUnicodeFallbackCount)",
            "lte_function_calls=\(collector.lteMatchAnyFunctionCalls)",
            "lte_variable_calls=\(collector.lteMatchAnyVariableCalls)",
            "ts_duplicate_suppressions=\(collector.tsDuplicateFunctionVariableSuppressions)",
            "ts_return_fast_path_hits=\(collector.tsReturnTypeFastPathHits)",
            "ts_type_annotation_fast_path_hits=\(collector.tsTypeAnnotationFastPathHits)",
            "ts_alias_rhs_fast_path_hits=\(collector.tsTypeAliasRhsFastPathHits)",
            "type_cleaner_calls=\(collector.typeCleanerExtractCalls)",
            "type_cleaner_cache_hits=\(collector.typeCleanerCacheHits)",
            "type_cleaner_cache_misses=\(collector.typeCleanerCacheMisses)",
            "type_cleaner_ts_calls=\(collector.typeCleanerTSCalls)",
            "type_cleaner_tsx_calls=\(collector.typeCleanerTSXCalls)",
            "referenced_raw_insertions=\(collector.referencedTypesRawInsertions)",
            "referenced_prefilter_skips=\(collector.referencedTypesPrefilterSkips)",
            "referenced_output_types=\(collector.referencedTypesOutputTypeCount)",
            "referenced_unique_types=\(collector.referencedTypesUniqueCount)",
            "memo_jsts_hits=\(collector.extractionMemoJSTSHits)",
            "memo_jsts_misses=\(collector.extractionMemoJSTSMisses)",
            "memo_function_hits=\(collector.extractionMemoFunctionHits)",
            "memo_function_misses=\(collector.extractionMemoFunctionMisses)",
            "memo_function_parsed_hits=\(collector.extractionMemoFunctionParsedHits)",
            "memo_function_parsed_misses=\(collector.extractionMemoFunctionParsedMisses)",
            "memo_variable_hits=\(collector.extractionMemoVariableHits)",
            "memo_variable_misses=\(collector.extractionMemoVariableMisses)",
            "memo_ts_fast_path_hits=\(collector.extractionMemoTSFastPathHits)",
            "memo_ts_fast_path_misses=\(collector.extractionMemoTSFastPathMisses)",
            "artifact_classes=\(collector.artifactFinalClassCount)",
            "artifact_interfaces=\(collector.artifactFinalInterfaceCount)",
            "artifact_functions=\(collector.artifactFinalFunctionCount)",
            "artifact_globals=\(collector.artifactFinalGlobalVariableCount)",
        ]
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

    private static func typeScriptXSource(declarationCount: Int) -> String {
        (0 ..< declarationCount).map { index in
            """
            export interface ViewProps\(index)<T extends { label: string }> {
                value\(index): Promise<Record<string, T>>;
                onSelect\(index)?: (value: T | { fallback: string }) => Promise<{ value: T }>;
            }
            export function View\(index)<T extends { label: string }>(props: ViewProps\(index)<T>): JSX.Element {
                return <section data-index={\(index)}><span>{props.value\(index).toString()}</span></section>;
            }
            export const Card\(index) = (props: { title: string; payload: Record<string, number>; render?: (value: number) => JSX.Element }) => (
                <article>{props.render?.(\(index)) ?? <strong>{props.title}</strong>}</article>
            );
            export const payload\(index): { primary: Record<string, number>; state: "ready" | "idle" } = {
                primary: { value: \(index) },
                state: "ready"
            };
            """
        }.joined(separator: "\n")
    }
}
