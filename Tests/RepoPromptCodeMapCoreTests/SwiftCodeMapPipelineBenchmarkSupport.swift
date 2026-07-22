#if RPCE_BENCHMARK_TESTS
    import CryptoKit
    import Darwin
    import Foundation
    @testable import RepoPromptCodeMapCore

    /// Opt-in, serial source-to-CodeMap benchmark support. This file is excluded
    /// unless the package is built with RPCE_ENABLE_BENCHMARK_TESTS=1.
    enum SwiftCodeMapPipelineBenchmarkSupport {
        static let runtimeGateKey = "RP_RUN_SWIFT_CODEMAP_PIPELINE_BENCHMARK"
        static let referenceModeKey = "RP_SWIFT_CODEMAP_REFERENCE_MODE"
        static let referencePathKey = "RP_SWIFT_CODEMAP_REFERENCE_PATH"
        static let allowedRemovedCaptureNamesKey = "RP_SWIFT_CODEMAP_ALLOWED_REMOVED_CAPTURES"
        static let defaultReferencePath = "/tmp/rpce-swift-codemap-bdc8ba10c.json"
        static let referenceSemanticBase = "bdc8ba10c"

        // Filled from the deterministic corpus and intentionally fixed after setup.
        static let expectedContentDigest = "972bc2e36fd6e177096800089c782576972d56675b10f6c934407face1f2af7e"
        static let expectedArtifactDigest = "5befe73ca42db203c0825b133a4eeeed018b5cd65f41597644b93f1b35858664"
        static let expectedCaptureDigestsByQuerySHA = [
            "c99914bc4c89f0c588a0717dfca902b2f25be24e3cca8720d0b026c250791448":
                "9e82ba5a2ae5fec1b494f424a2fdcf24bfe5061167b93c5fc3f7b0dc8bf7254c"
        ]

        struct CorpusFile {
            let logicalPath: String
            let source: String
            let snapshot: CodeMapCoreSourceSnapshot
        }

        struct ArtifactRecord: Codable, Equatable {
            let logicalPath: String
            let canonicalJSON: Data
        }

        struct CaptureRecord: Codable, Equatable {
            let logicalPath: String
            let name: String
            let location: Int
            let length: Int
        }

        struct ReferenceRecord: Codable, Equatable {
            let schemaVersion: Int
            let semanticBase: String
            let fileCount: Int
            let querySHA256: String
            let contentDigest: String
            let captureDigest: String
            let artifactDigest: String
            let artifacts: [ArtifactRecord]
            let captures: [CaptureRecord]
        }

        struct Evidence {
            let reference: ReferenceRecord
            let artifacts: [CodeMapSyntaxArtifact]
        }

        enum ReferenceComparisonMode: Equatable {
            case exact
            case allowingCaptureRemovals(named: Set<String>)
        }

        enum SupportError: Error, CustomStringConvertible {
            case artifactNotReady(String, CodeMapSyntaxArtifactOutcome)
            case queryNotReady(String, CodeMapSyntaxQueryOutcome)
            case referenceAlreadyExists(String)
            case referenceMismatch(String)
            case invalidCaptureRemovalAllowlist(String)
            case shortWrite(String)
            case unexpectedDigest(kind: String, expected: String, actual: String)
            case unsupportedReferenceMode(String)

            var description: String {
                switch self {
                case let .artifactNotReady(path, outcome):
                    "Artifact was not ready for \(path): \(outcome)"
                case let .queryNotReady(path, outcome):
                    "Query was not ready for \(path): \(outcome)"
                case let .referenceAlreadyExists(path):
                    "Reference already exists and was not overwritten: \(path)"
                case let .referenceMismatch(detail):
                    "Reference mismatch: \(detail)"
                case let .invalidCaptureRemovalAllowlist(key):
                    "Candidate capture-removal comparison requires a nonempty comma-separated \(key)"
                case let .shortWrite(path):
                    "Could not write the complete reference: \(path)"
                case let .unexpectedDigest(kind, expected, actual):
                    "Unexpected \(kind) digest; expected \(expected), got \(actual)"
                case let .unsupportedReferenceMode(mode):
                    "Unsupported reference mode: \(mode)"
                }
            }
        }

        static var isRuntimeEnabled: Bool {
            ProcessInfo.processInfo.environment[runtimeGateKey] == "1"
        }

        static var referencePath: String {
            ProcessInfo.processInfo.environment[referencePathKey] ?? defaultReferencePath
        }

        static var referenceMode: String {
            ProcessInfo.processInfo.environment[referenceModeKey] ?? "compare"
        }

        static func configuredReferenceComparisonMode() throws -> ReferenceComparisonMode {
            switch referenceMode {
            case "write", "compare":
                return .exact
            case "compare-capture-removals":
                let names = Set(
                    (ProcessInfo.processInfo.environment[allowedRemovedCaptureNamesKey] ?? "")
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
                guard !names.isEmpty else {
                    throw SupportError.invalidCaptureRemovalAllowlist(allowedRemovedCaptureNamesKey)
                }
                return .allowingCaptureRemovals(named: names)
            default:
                throw SupportError.unsupportedReferenceMode(referenceMode)
            }
        }

        static func makeCorpus() -> [CorpusFile] {
            var entries: [(String, String)] = []
            entries.reserveCapacity(64)

            for index in 0 ..< 40 {
                entries.append((
                    String(format: "Sources/Small/Small%02d.swift", index),
                    smallSource(index: index)
                ))
            }
            for index in 0 ..< 16 {
                entries.append((
                    String(format: "Sources/Medium/Medium%02d.swift", index),
                    mediumSource(index: index)
                ))
            }
            for (index, source) in pathologicalSources().enumerated() {
                entries.append((
                    String(format: "Sources/Pathological/Pathological%02d.swift", index),
                    source
                ))
            }

            precondition(entries.count == 64)
            return entries.sorted { $0.0 < $1.0 }.map { path, source in
                CorpusFile(
                    logicalPath: path,
                    source: source,
                    snapshot: CodeMapFixtureRunner.makeSourceSnapshot(content: source)
                )
            }
        }

        static func buildArtifacts(
            files: [CorpusFile],
            performanceCollector: CodeMapPerformanceCollector? = nil
        ) throws -> [CodeMapSyntaxArtifact] {
            var artifacts: [CodeMapSyntaxArtifact] = []
            artifacts.reserveCapacity(files.count)
            let options: CodeMapPerfOptions = performanceCollector == nil ? .disabled : .countersOnly
            for file in files {
                let outcome = try CodeMapSyntaxArtifactBuilder.build(
                    source: file.snapshot,
                    language: .swift,
                    performanceOptions: options,
                    performanceCollector: performanceCollector
                )
                guard case let .ready(artifact) = outcome else {
                    throw SupportError.artifactNotReady(file.logicalPath, outcome)
                }
                artifacts.append(artifact)
            }
            return artifacts
        }

        static func makeEvidence(
            files: [CorpusFile],
            artifacts: [CodeMapSyntaxArtifact]
        ) throws -> Evidence {
            precondition(files.count == artifacts.count)
            let identity = try CodeMapSyntaxEngine.shared.pipelineIdentity(
                for: .swift,
                decoderPolicy: .workspaceAutomaticV1
            )
            let querySHA = identity.codeMapQuerySHA256.lowercaseHex
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]

            var artifactRecords: [ArtifactRecord] = []
            artifactRecords.reserveCapacity(files.count)
            var captureRecords: [CaptureRecord] = []
            for (file, artifact) in zip(files, artifacts) {
                try artifactRecords.append(ArtifactRecord(
                    logicalPath: file.logicalPath,
                    canonicalJSON: encoder.encode(artifact)
                ))
                let outcome = try CodeMapSyntaxEngine.shared.codeMap(
                    content: file.source,
                    language: .swift
                )
                guard case let .captures(captures) = outcome else {
                    throw SupportError.queryNotReady(file.logicalPath, outcome)
                }
                captureRecords.append(contentsOf: captures.map {
                    CaptureRecord(
                        logicalPath: file.logicalPath,
                        name: $0.name,
                        location: $0.range.location,
                        length: $0.range.length
                    )
                })
            }
            captureRecords.sort(by: captureLessThan)

            let contentDigest = contentDigest(files)
            let captureDigest = captureDigest(
                queryDigestBytes: identity.codeMapQuerySHA256.bytes,
                captures: captureRecords
            )
            let artifactDigest = artifactDigest(artifactRecords)
            let reference = ReferenceRecord(
                schemaVersion: 1,
                semanticBase: referenceSemanticBase,
                fileCount: files.count,
                querySHA256: querySHA,
                contentDigest: contentDigest,
                captureDigest: captureDigest,
                artifactDigest: artifactDigest,
                artifacts: artifactRecords,
                captures: captureRecords
            )
            return Evidence(reference: reference, artifacts: artifacts)
        }

        static func validateFixedDigests(
            _ reference: ReferenceRecord,
            comparisonMode: ReferenceComparisonMode = .exact
        ) throws {
            guard reference.contentDigest == expectedContentDigest else {
                throw SupportError.unexpectedDigest(
                    kind: "content",
                    expected: expectedContentDigest,
                    actual: reference.contentDigest
                )
            }
            guard reference.artifactDigest == expectedArtifactDigest else {
                throw SupportError.unexpectedDigest(
                    kind: "artifact",
                    expected: expectedArtifactDigest,
                    actual: reference.artifactDigest
                )
            }
            switch comparisonMode {
            case .exact:
                guard let expectedCapture = expectedCaptureDigestsByQuerySHA[reference.querySHA256] else {
                    throw SupportError.unexpectedDigest(
                        kind: "capture for query \(reference.querySHA256)",
                        expected: "registered query digest",
                        actual: reference.captureDigest
                    )
                }
                guard reference.captureDigest == expectedCapture else {
                    throw SupportError.unexpectedDigest(
                        kind: "capture",
                        expected: expectedCapture,
                        actual: reference.captureDigest
                    )
                }
            case let .allowingCaptureRemovals(names):
                guard !names.isEmpty else {
                    throw SupportError.invalidCaptureRemovalAllowlist(allowedRemovedCaptureNamesKey)
                }
            }
        }

        static func applyReferenceMode(to reference: ReferenceRecord) throws {
            switch referenceMode {
            case "write":
                try writeReferenceExclusively(reference, path: referencePath)
            case "compare", "compare-capture-removals":
                let expected = try readReference(path: referencePath)
                try compareReference(
                    expected: expected,
                    actual: reference,
                    comparisonMode: configuredReferenceComparisonMode()
                )
            default:
                throw SupportError.unsupportedReferenceMode(referenceMode)
            }
        }

        static func compareReference(
            expected: ReferenceRecord,
            actual: ReferenceRecord,
            comparisonMode: ReferenceComparisonMode = .exact
        ) throws {
            switch comparisonMode {
            case .exact:
                guard expected == actual else {
                    throw SupportError.referenceMismatch(referenceDifference(expected: expected, actual: actual))
                }
            case let .allowingCaptureRemovals(allowedNames):
                guard !allowedNames.isEmpty else {
                    throw SupportError.invalidCaptureRemovalAllowlist(allowedRemovedCaptureNamesKey)
                }
                try compareReferenceAuthority(expected: expected, actual: actual)
                guard expected.querySHA256 != actual.querySHA256 else {
                    throw SupportError.referenceMismatch("candidate query SHA did not change")
                }
                guard expected.captureDigest != actual.captureDigest else {
                    throw SupportError.referenceMismatch("candidate capture digest did not change")
                }

                var actualIndex = 0
                var removedCount = 0
                for expectedCapture in expected.captures {
                    if actualIndex < actual.captures.count,
                       actual.captures[actualIndex] == expectedCapture
                    {
                        actualIndex += 1
                        continue
                    }
                    guard allowedNames.contains(expectedCapture.name) else {
                        throw SupportError.referenceMismatch(
                            "removed or modified non-allowlisted capture tuple \(captureDescription(expectedCapture))"
                        )
                    }
                    removedCount += 1
                }
                guard actualIndex == actual.captures.count else {
                    throw SupportError.referenceMismatch(
                        "added or modified capture tuple \(captureDescription(actual.captures[actualIndex]))"
                    )
                }
                guard removedCount > 0 else {
                    throw SupportError.referenceMismatch("candidate removed no allowlisted capture tuples")
                }
            }
        }

        static func printDigestRecord(_ reference: ReferenceRecord) {
            print([
                "SWIFT_CODEMAP_PIPELINE_DIGESTS",
                "files=\(reference.fileCount)",
                "semantic_base=\(reference.semanticBase)",
                "query_sha256=\(reference.querySHA256)",
                "content_sha256=\(reference.contentDigest)",
                "capture_sha256=\(reference.captureDigest)",
                "artifact_sha256=\(reference.artifactDigest)",
                "captures=\(reference.captures.count)",
                "reference_mode=\(referenceMode)",
                "reference_path=\(referencePath)"
            ].joined(separator: " "))
        }

        static func attributionRecord(
            collector: CodeMapPerformanceCollector,
            reference: ReferenceRecord
        ) -> String {
            let declarations = collector.swiftTypeDeclarationCount +
                collector.swiftProtocolDeclarationCount +
                collector.swiftTopLevelFunctionCount +
                collector.swiftMethodFunctionCount +
                collector.swiftProtocolMethodCount +
                collector.swiftPropertyIdentifierCount
            let indexVisits = collector.captureIndexFirstContainedCandidateVisits +
                collector.captureIndexAllContainedCandidateVisits +
                collector.captureIndexSmallestContainingCandidateVisits
            let visitsPerCapture = ratio(indexVisits, max(1, collector.captureIndexInputCaptureCount))
            let visitsPerDeclaration = ratio(indexVisits, max(1, declarations))
            let histogram = collector.syntaxCaptureCountsByName.keys.sorted().map {
                "\($0):\(collector.syntaxCaptureCountsByName[$0, default: 0])"
            }.joined(separator: ",")

            return [
                "SWIFT_CODEMAP_PIPELINE_ATTRIBUTION",
                "files=\(reference.fileCount)",
                "query_sha256=\(reference.querySHA256)",
                "content_sha256=\(reference.contentDigest)",
                "capture_sha256=\(reference.captureDigest)",
                "artifact_sha256=\(reference.artifactDigest)",
                "builder_total_ms=\(milliseconds(collector.builderTotalDuration))",
                "builder_generator_ms=\(milliseconds(collector.builderGeneratorDuration))",
                "syntax_total_ms=\(milliseconds(collector.syntaxTotalDuration))",
                "oversize_guard_ms=\(milliseconds(collector.syntaxOversizeGuardDuration))",
                "language_lookup_ms=\(milliseconds(collector.syntaxLanguageLookupDuration))",
                "parser_create_ms=\(milliseconds(collector.syntaxParserCreateDuration))",
                "set_language_ms=\(milliseconds(collector.syntaxSetLanguageDuration))",
                "parse_ms=\(milliseconds(collector.syntaxParseDuration))",
                "query_lookup_ms=\(milliseconds(collector.syntaxCodeMapQueryLookupDuration))",
                "query_execute_ms=\(milliseconds(collector.syntaxQueryExecuteDuration))",
                "capture_materialize_ms=\(milliseconds(collector.syntaxCaptureMaterializationDuration))",
                "capture_name_count_ms=\(milliseconds(collector.syntaxCaptureNameCountingDuration))",
                "capture_index_ms=\(milliseconds(collector.captureIndexDuration))",
                "swift_context_ms=\(milliseconds(collector.swiftContextDuration))",
                "swift_type_name_map_ms=\(milliseconds(collector.swiftTypeNameMappingDuration))",
                "swift_protocol_name_map_ms=\(milliseconds(collector.swiftProtocolNameMappingDuration))",
                "swift_boundaries_ms=\(milliseconds(collector.swiftBoundaryConstructionDuration))",
                "swift_function_assembly_ms=\(milliseconds(collector.swiftFunctionCaptureAssemblyDuration))",
                "capture_loop_ms=\(milliseconds(collector.captureLoopDuration))",
                "capture_loop_line_advance_ms=\(milliseconds(collector.captureLoopLineAdvanceDuration))",
                "swift_loop_ms=\(milliseconds(collector.captureLoopSwiftStrategyDuration))",
                "ts_loop_ms=\(milliseconds(collector.captureLoopTSStrategyDuration))",
                "interface_heuristic_ms=\(milliseconds(collector.captureLoopInterfaceHeuristicDuration))",
                "import_export_ms=\(milliseconds(collector.captureLoopImportExportDuration))",
                "type_alias_ms=\(milliseconds(collector.captureLoopTypeAliasDuration))",
                "enum_macro_ms=\(milliseconds(collector.captureLoopEnumMacroDuration))",
                "fallback_function_ms=\(milliseconds(collector.captureLoopFunctionDuration))",
                "fallback_variable_ms=\(milliseconds(collector.captureLoopVariableDuration))",
                "skipped_ms=\(milliseconds(collector.captureLoopSkippedDuration))",
                "unclassified_ms=\(milliseconds(collector.captureLoopUnclassifiedDuration))",
                "swift_signature_ms=\(milliseconds(collector.swiftStrategyFunctionSignatureDuration))",
                "swift_signature_scan_ms=\(milliseconds(collector.swiftSignatureEndScanDuration))",
                "swift_signature_normalize_ms=\(milliseconds(collector.swiftSignatureNormalizationDuration))",
                "swift_name_lookup_ms=\(milliseconds(collector.swiftStrategyFunctionNameLookupDuration))",
                "swift_parameters_ms=\(milliseconds(collector.swiftStrategyParameterExtractionDuration))",
                "swift_return_type_ms=\(milliseconds(collector.swiftStrategyReturnTypeExtractionDuration))",
                "swift_property_ms=\(milliseconds(collector.swiftStrategyPropertyDeclarationDuration))",
                "swift_property_lookup_ms=\(milliseconds(collector.swiftPropertyDeclarationLookupDuration))",
                "swift_property_substring_ms=\(milliseconds(collector.swiftPropertyDeclarationSubstringDuration))",
                "swift_property_initializer_ms=\(milliseconds(collector.swiftPropertyInitializerStripDuration))",
                "swift_property_type_ms=\(milliseconds(collector.swiftStrategyPropertyTypeExtractionDuration))",
                "swift_enclosing_type_ms=\(milliseconds(collector.swiftStrategyEnclosingTypeLookupDuration))",
                "swift_model_insert_ms=\(milliseconds(collector.swiftStrategyModelInsertionDuration))",
                "swift_context_only_ms=\(milliseconds(collector.swiftStrategyContextOnlyDuration))",
                "referenced_finalize_ms=\(milliseconds(collector.referencedTypesFinalizeDuration))",
                "type_cleaner_ms=\(milliseconds(collector.typeCleanerDuration))",
                "type_cleaner_swift_ms=\(milliseconds(collector.typeCleanerSwiftDuration))",
                "type_cleaner_preclean_ms=\(milliseconds(collector.typeCleanerPrecleanDuration))",
                "type_cleaner_non_ts_ms=\(milliseconds(collector.typeCleanerNonTSLogicDuration))",
                "type_cleaner_filter_ms=\(milliseconds(collector.typeCleanerFilterDuration))",
                "type_cleaner_dedup_ms=\(milliseconds(collector.typeCleanerDedupDuration))",
                "artifact_finalize_ms=\(milliseconds(collector.artifactFinalizationDuration))",
                "artifact_meaningful_ms=\(milliseconds(collector.artifactMeaningfulContentCheckDuration))",
                "artifact_init_ms=\(milliseconds(collector.fileAPIInitDuration))",
                "syntax_calls=\(collector.syntaxCalls)",
                "parser_creates=\(collector.syntaxParserCreates)",
                "query_executes=\(collector.syntaxQueryExecutes)",
                "query_successful_lookups=\(collector.syntaxCodeMapQuerySuccessfulLookups)",
                "captures=\(collector.syntaxCaptures)",
                "captures_processed=\(collector.capturesProcessed)",
                "swift_strategy_handled=\(collector.swiftStrategyHandled)",
                "ts_strategy_handled=\(collector.tsStrategyHandled)",
                "fallback_handled=\(collector.fallbackHandled)",
                "line_advance_count=\(collector.captureLoopLineAdvanceCount)",
                "swift_loop_count=\(collector.captureLoopSwiftStrategyCount)",
                "ts_loop_count=\(collector.captureLoopTSStrategyCount)",
                "interface_heuristic_count=\(collector.captureLoopInterfaceHeuristicCount)",
                "import_export_count=\(collector.captureLoopImportExportCount)",
                "type_alias_count=\(collector.captureLoopTypeAliasCount)",
                "enum_macro_count=\(collector.captureLoopEnumMacroCount)",
                "fallback_function_count=\(collector.captureLoopFunctionCount)",
                "fallback_variable_count=\(collector.captureLoopVariableCount)",
                "skipped_count=\(collector.captureLoopSkippedCount)",
                "unclassified_count=\(collector.captureLoopUnclassifiedCount)",
                "capture_index_inputs=\(collector.captureIndexInputCaptureCount)",
                "capture_index_buckets=\(collector.captureIndexBucketCount)",
                "capture_index_first_lookups=\(collector.captureIndexFirstContainedLookupCount)",
                "capture_index_first_visits=\(collector.captureIndexFirstContainedCandidateVisits)",
                "capture_index_all_lookups=\(collector.captureIndexAllContainedLookupCount)",
                "capture_index_all_visits=\(collector.captureIndexAllContainedCandidateVisits)",
                "capture_index_smallest_lookups=\(collector.captureIndexSmallestContainingLookupCount)",
                "capture_index_smallest_visits=\(collector.captureIndexSmallestContainingCandidateVisits)",
                "capture_index_visits=\(indexVisits)",
                "capture_index_max_visits=\(collector.captureIndexMaximumCandidateVisits)",
                "capture_index_visits_per_capture=\(visitsPerCapture)",
                "capture_index_visits_per_declaration=\(visitsPerDeclaration)",
                "swift_declarations=\(declarations)",
                "swift_type_declarations=\(collector.swiftTypeDeclarationCount)",
                "swift_protocol_declarations=\(collector.swiftProtocolDeclarationCount)",
                "swift_top_level_functions=\(collector.swiftTopLevelFunctionCount)",
                "swift_methods=\(collector.swiftMethodFunctionCount)",
                "swift_protocol_methods=\(collector.swiftProtocolMethodCount)",
                "swift_parameter_nodes=\(collector.swiftParameterNodeCount)",
                "swift_property_declarations=\(collector.swiftPropertyDeclarationCount)",
                "swift_protocol_property_declarations=\(collector.swiftProtocolPropertyDeclarationCount)",
                "swift_property_identifiers=\(collector.swiftPropertyIdentifierCount)",
                "swift_type_boundaries=\(collector.swiftTypeBoundaryCount)",
                "swift_signature_code_units=\(collector.swiftSignatureCodeUnitVisits)",
                "swift_nested_containment_lookups=\(collector.swiftNestedFunctionContainmentLookupCount)",
                "swift_nested_containment_visits=\(collector.swiftNestedFunctionContainmentCandidateVisits)",
                "swift_enclosing_type_visits=\(collector.swiftEnclosingTypeCandidateVisits)",
                "swift_function_duplicate_checks=\(collector.swiftFunctionDuplicateCheckCount)",
                "swift_function_duplicate_visits=\(collector.swiftFunctionDuplicateCandidateVisits)",
                "swift_property_duplicate_checks=\(collector.swiftPropertyDuplicateCheckCount)",
                "swift_property_duplicate_visits=\(collector.swiftPropertyDuplicateCandidateVisits)",
                "swift_signature_count=\(collector.swiftStrategyFunctionSignatureCount)",
                "swift_name_lookup_count=\(collector.swiftStrategyFunctionNameLookupCount)",
                "swift_parameter_extraction_count=\(collector.swiftStrategyParameterExtractionCount)",
                "swift_return_type_count=\(collector.swiftStrategyReturnTypeExtractionCount)",
                "swift_property_declaration_count=\(collector.swiftStrategyPropertyDeclarationCount)",
                "swift_property_type_count=\(collector.swiftStrategyPropertyTypeExtractionCount)",
                "swift_enclosing_type_count=\(collector.swiftStrategyEnclosingTypeLookupCount)",
                "swift_model_insertion_count=\(collector.swiftStrategyModelInsertionCount)",
                "swift_context_only_count=\(collector.swiftStrategyContextOnlyCount)",
                "swift_functions_handled=\(collector.swiftStrategyHandledFunctionCount)",
                "swift_properties_handled=\(collector.swiftStrategyHandledPropertyCount)",
                "referenced_raw_insertions=\(collector.referencedTypesRawInsertions)",
                "referenced_prefilter_skips=\(collector.referencedTypesPrefilterSkips)",
                "referenced_empty_results=\(collector.referencedTypesEmptyResults)",
                "referenced_output_types=\(collector.referencedTypesOutputTypeCount)",
                "referenced_unique_types=\(collector.referencedTypesUniqueCount)",
                "type_cleaner_calls=\(collector.typeCleanerExtractCalls)",
                "type_cleaner_cache_hits=\(collector.typeCleanerCacheHits)",
                "type_cleaner_cache_misses=\(collector.typeCleanerCacheMisses)",
                "type_cleaner_swift_calls=\(collector.typeCleanerSwiftCalls)",
                "type_cleaner_ts_calls=\(collector.typeCleanerTSCalls)",
                "type_cleaner_tsx_calls=\(collector.typeCleanerTSXCalls)",
                "type_cleaner_js_calls=\(collector.typeCleanerJSCalls)",
                "type_cleaner_other_language_calls=\(collector.typeCleanerOtherLanguageCalls)",
                "type_cleaner_preclean_count=\(collector.typeCleanerPrecleanCount)",
                "type_cleaner_ts_logic_count=\(collector.typeCleanerTSLogicCount)",
                "type_cleaner_non_ts_logic_count=\(collector.typeCleanerNonTSLogicCount)",
                "type_cleaner_ts_object_literal_count=\(collector.typeCleanerTSObjectLiteralCount)",
                "type_cleaner_filter_count=\(collector.typeCleanerFilterCount)",
                "type_cleaner_dedup_count=\(collector.typeCleanerDedupCount)",
                "artifact_classes=\(collector.artifactFinalClassCount)",
                "artifact_interfaces=\(collector.artifactFinalInterfaceCount)",
                "artifact_functions=\(collector.artifactFinalFunctionCount)",
                "artifact_globals=\(collector.artifactFinalGlobalVariableCount)",
                "oversized=\(collector.syntaxOversized)",
                "unsupported=\(collector.syntaxUnsupported)",
                "nil_trees=\(collector.syntaxParseNilTree)",
                "nil_roots=\(collector.syntaxParseNilRoot)",
                "capture_histogram=\(histogram)"
            ].joined(separator: " ")
        }

        static func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let middle = sorted.count / 2
            if sorted.count.isMultiple(of: 2) {
                return (sorted[middle - 1] + sorted[middle]) / 2
            }
            return sorted[middle]
        }

        static func formattedSamples(_ samples: [Double]) -> String {
            "[\(samples.map { String(format: "%.3f", $0) }.joined(separator: ","))]"
        }

        static func milliseconds(_ duration: TimeInterval) -> String {
            String(format: "%.3f", duration * 1000)
        }

        private static func ratio(_ numerator: Int, _ denominator: Int) -> String {
            String(format: "%.3f", Double(numerator) / Double(denominator))
        }

        private static func contentDigest(_ files: [CorpusFile]) -> String {
            var framed = Data()
            for file in files {
                appendFrame(Data(file.logicalPath.utf8), to: &framed)
                appendFrame(Data(file.source.utf8), to: &framed)
            }
            return sha256Hex(framed)
        }

        private static func captureDigest(
            queryDigestBytes: Data,
            captures: [CaptureRecord]
        ) -> String {
            var framed = Data(queryDigestBytes)
            for capture in captures {
                appendFrame(Data(capture.logicalPath.utf8), to: &framed)
                appendFrame(Data(capture.name.utf8), to: &framed)
                appendUInt64(UInt64(capture.location), to: &framed)
                appendUInt64(UInt64(capture.length), to: &framed)
            }
            return sha256Hex(framed)
        }

        private static func artifactDigest(_ records: [ArtifactRecord]) -> String {
            var framed = Data()
            for record in records {
                appendFrame(Data(record.logicalPath.utf8), to: &framed)
                appendFrame(record.canonicalJSON, to: &framed)
            }
            return sha256Hex(framed)
        }

        private static func appendFrame(_ bytes: Data, to data: inout Data) {
            appendUInt64(UInt64(bytes.count), to: &data)
            data.append(bytes)
        }

        private static func appendUInt64(_ value: UInt64, to data: inout Data) {
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        }

        private static func sha256Hex(_ data: Data) -> String {
            Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
        }

        private static func captureLessThan(_ lhs: CaptureRecord, _ rhs: CaptureRecord) -> Bool {
            if lhs.logicalPath != rhs.logicalPath { return lhs.logicalPath < rhs.logicalPath }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            if lhs.location != rhs.location { return lhs.location < rhs.location }
            return lhs.length < rhs.length
        }

        private static func writeReferenceExclusively(
            _ reference: ReferenceRecord,
            path: String
        ) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(reference)

            let descriptor: Int32
            while true {
                let result = open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
                if result >= 0 {
                    descriptor = result
                    break
                }
                if errno == EINTR { continue }
                if errno == EEXIST { throw SupportError.referenceAlreadyExists(path) }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            var completed = false
            defer {
                _ = close(descriptor)
                if !completed {
                    removeIncompleteReference(path: path)
                }
            }
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else {
                    throw SupportError.shortWrite(path)
                }
                var total = 0
                while total < buffer.count {
                    let result = Darwin.write(descriptor, base.advanced(by: total), buffer.count - total)
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    guard result > 0 else { throw SupportError.shortWrite(path) }
                    total += result
                }
            }
            completed = true
        }

        private static func removeIncompleteReference(path: String) {
            while unlink(path) < 0, errno == EINTR {}
        }

        private static func readReference(path: String) throws -> ReferenceRecord {
            try JSONDecoder().decode(ReferenceRecord.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }

        private static func compareReferenceAuthority(
            expected: ReferenceRecord,
            actual: ReferenceRecord
        ) throws {
            if expected.schemaVersion != actual.schemaVersion {
                throw SupportError.referenceMismatch("schema version")
            }
            if expected.semanticBase != actual.semanticBase {
                throw SupportError.referenceMismatch("semantic base")
            }
            if expected.fileCount != actual.fileCount {
                throw SupportError.referenceMismatch("file count")
            }
            if expected.contentDigest != actual.contentDigest {
                throw SupportError.referenceMismatch("content digest")
            }
            if expected.artifactDigest != actual.artifactDigest {
                throw SupportError.referenceMismatch("artifact digest")
            }
            if expected.artifacts != actual.artifacts {
                throw SupportError.referenceMismatch("canonical artifact bytes")
            }
        }

        private static func captureDescription(_ capture: CaptureRecord) -> String {
            "\(capture.logicalPath):\(capture.name)@\(capture.location)+\(capture.length)"
        }

        private static func referenceDifference(
            expected: ReferenceRecord,
            actual: ReferenceRecord
        ) -> String {
            if expected.schemaVersion != actual.schemaVersion { return "schema version" }
            if expected.semanticBase != actual.semanticBase { return "semantic base" }
            if expected.fileCount != actual.fileCount { return "file count" }
            if expected.querySHA256 != actual.querySHA256 { return "query SHA" }
            if expected.contentDigest != actual.contentDigest { return "content digest" }
            if expected.captureDigest != actual.captureDigest { return "capture digest" }
            if expected.artifactDigest != actual.artifactDigest { return "artifact digest" }
            if expected.artifacts != actual.artifacts { return "canonical artifact bytes" }
            if expected.captures != actual.captures { return "canonical capture tuples" }
            return "unknown"
        }

        private static func smallSource(index: Int) -> String {
            """
            import Foundation

            protocol SmallContract\(index) {
                associatedtype Value\(index)
                func load\(index)(_ key: String) async throws -> Value\(index)
            }

            struct SmallType\(index)<Payload>: Sendable where Payload: Sendable {
                let value\(index): Payload
                var metadata\(index): [String: Int] = [:]

                func transform\(index)<Output>(
                    _ input: Payload,
                    using body: (Payload) throws -> Output
                ) rethrows -> Output {
                    try body(input)
                }
            }

            extension SmallType\(index) {
                func labeled\(index)(_ first: Int, first second: Int = 0) -> Int {
                    first + second
                }
            }

            func smallTopLevel\(index)(_ value: Int) -> Result<Int, Error> {
                .success(value)
            }
            """
        }

        private static func mediumSource(index: Int) -> String {
            let records = (0 ..< 4).map { record in
                """
                struct MediumRecord\(index)_\(record)<Element>: Sendable where Element: Sendable {
                    let id: UUID
                    var elements: [Element]
                    var lookup: [String: Result<Element, MediumError\(index)>] = [:]

                    func map<Output: Sendable>(
                        _ transform: @Sendable (Element) async throws -> Output
                    ) async rethrows -> [Output] {
                        var output: [Output] = []
                        for element in elements { output.append(try await transform(element)) }
                        return output
                    }

                    func resolve(
                        _ key: String,
                        default fallback: @autoclosure () -> Element
                    ) -> Element {
                        (try? lookup[key]?.get()) ?? fallback()
                    }
                }
                """
            }.joined(separator: "\n")
            return """
            import Foundation

            enum MediumError\(index): Error { case missing(String), invalid(Int) }

            protocol MediumService\(index): Sendable {
                associatedtype Item: Sendable
                var identifier: String { get }
                func fetch(_ id: UUID) async throws -> Item
                func update(_ item: Item, for id: UUID) async throws
            }

            \(records)

            actor MediumStore\(index)<Value: Sendable> {
                private var values: [UUID: Value] = [:]
                func value(for id: UUID) -> Value? { values[id] }
                func set(_ value: Value, for id: UUID) { values[id] = value }
            }

            final class MediumCoordinator\(index)<Service: MediumService\(index)> {
                let service: Service
                init(service: Service) { self.service = service }
                func run(ids: [UUID]) async throws -> [Service.Item] {
                    try await ids.asyncMap { try await service.fetch($0) }
                }
            }

            extension Array {
                func asyncMap<Output>(_ transform: (Element) async throws -> Output) async rethrows -> [Output] {
                    var output: [Output] = []
                    for element in self { output.append(try await transform(element)) }
                    return output
                }
            }

            func mediumTopLevel\(index)<T: Sendable>(_ value: T) async -> T { value }
            func mediumTopLevel\(index)(_ value: Int) -> String { String(value) }
            func mediumFactory\(index)<T>(_ body: () throws -> T) rethrows -> T { try body() }
            """
        }

        private static func pathologicalSources() -> [String] {
            [
                """
                import Foundation

                @available(macOS 14, *)
                public final class AttributedBox<Value>: @unchecked Sendable where Value: Sendable {
                    @MainActor public private(set) var value: Value
                    public init(
                        value: Value
                    ) where Value: Codable {
                        self.value = value
                    }
                }
                """,
                """
                protocol NestedProtocol {
                    associatedtype Element
                    func transform<T, U>(
                        _ value: T,
                        using body: (T) throws -> U
                    ) rethrows -> U where T: Collection, T.Element == Element, U: Sendable
                }

                struct Outer<T> {
                    struct Inner<U> { let value: U }
                    enum State { case idle, running(progress: Double) }
                    func nested(_ value: T) {
                        func local(_ input: T, completion: (T) -> Void = { _ in }) { completion(input) }
                        local(value)
                    }
                }

                extension Outer where T: Sendable {
                    func send(_ value: T) async -> T { value }
                }
                """,
                """
                struct Overloads {
                    func render(_ value: Int) -> String { String(value) }
                    func render(_ value: String) -> String { value }
                    func label(_ value: Int, value other: Int) -> Int { value + other }
                    func underscore(_ value: Int, _ second: Int = 1) -> Int { value + second }
                }

                func globalOverload(_ value: Int) -> Int { value }
                func globalOverload(_ value: String) -> String { value }
                """,
                """
                struct PackBox<each Element> {
                    let values: (repeat each Element)
                    init(_ values: repeat each Element) { self.values = (repeat each values) }
                    func apply<each Output>(
                        _ transforms: repeat (each Element) -> each Output
                    ) -> (repeat each Output) {
                        (repeat (each transforms)(each values))
                    }
                }
                """,
                [
                    "struct LiteralCases {",
                    "    let raw = #\"raw { : -> // not comment }\"#",
                    "    let multiline = \"\"\"",
                    "    text { with : arrows -> and // markers",
                    "    \"\"\"",
                    "    /* outer /* nested */ block */",
                    "    func render(_ value: String = #\"default } : ->\"#) -> String {",
                    "        // { ignored comment",
                    "        value + raw + multiline",
                    "    }",
                    "}"
                ].joined(separator: "\n"),
                """
                struct DefaultClosures {
                    var handler: (Result<Int, Error>) -> Void = { result in
                        if case let .success(value) = result { print("value: \\(value) -> }") }
                    }

                    func execute(
                        values: [Int] = [1, 2, 3],
                        transform: (Int) -> String = { value in "{\\(value): ->}" },
                        completion: ([String]) -> Void = { _ in }
                    ) {
                        completion(values.map(transform))
                    }
                }
                """,
                """
                final class AccessorCases {
                    let stored: Int = 1
                    var observed: Int = 0 {
                        willSet { print(newValue) }
                        didSet { print(oldValue) }
                    }
                    var computed: String { String(observed) }
                    var expanded: Int {
                        get { observed }
                        set { observed = newValue }
                    }
                    subscript(index: Int) -> Int {
                        get { observed + index }
                        set { observed = newValue - index }
                    }
                }
                """,
                """
                public protocol Repository<Key, Value> where Key: Hashable, Value: Sendable {
                    associatedtype Key
                    associatedtype Value
                    func value(for key: Key) async throws -> Value?
                    func set(_ value: Value?, for key: Key) async throws
                }

                public actor AnyRepository<K: Hashable & Sendable, V: Sendable>: Repository {
                    public typealias Key = K
                    public typealias Value = V
                    private var storage: [K: V] = [:]
                    public func value(for key: K) async throws -> V? { storage[key] }
                    public func set(_ value: V?, for key: K) async throws { storage[key] = value }
                }
                """
            ]
        }
    }
#endif
