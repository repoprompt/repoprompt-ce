import Foundation
@testable import RepoPromptApp

#if DEBUG
    /// Finite headless diagnostic invoked only by testMeasurementMatrix's explicit opt-in.
    @MainActor
    enum WorkspaceProjectionDecodeMatrix {
        private typealias Diagnostics = WorkspaceProjectionDecodeDiagnostics
        private typealias Fixture = WorkspaceProjectionDecodeFixture

        private enum Scenario: String, CaseIterable, Codable {
            case newRevision, changedDigest, dirtySequence, failureCorrection

            var revisions: [Int] {
                switch self {
                case .newRevision: [1]
                case .changedDigest: [2]
                case .dirtySequence: [2, 3, 4, 5]
                case .failureCorrection: [0, 2] // zero denotes injected malformed bytes
                }
            }
        }

        private struct Trial: Encodable {
            let ordinal: Int
            let decodeAttempts: Int
            let failures: Int
            let normalizationCount: Int
            let normalizationMutations: Int
            let inputBytes: Int
            let decodeTotalNS: UInt64
            let decodeP50NS: UInt64
            let decodeP95NS: UInt64
            let normalizationTotalNS: UInt64
            let mainActorTotalNS: UInt64
            let deliveryTotalNS: UInt64
            let projectionCacheEntries = 0
            let projectionCacheEstimatedBytes = 0
            let cacheResult = "notImplemented"
            let diagnosticSamples: Int
            let diagnosticEstimatedBytes: Int
            let peakConsumerEntries: Int
            let settledConsumerEntries: Int
            let peakConsumerSerializedBytes: Int
            let settledConsumerSerializedBytes: Int
            let releasedConsumerEntries = 0
            let rssBefore: UInt64
            let rssPeakBoundary: UInt64
            let rssSettled: UInt64
            let rssAfterRelease: UInt64
            let footprintBefore: UInt64
            let footprintPeakBoundary: UInt64
            let footprintSettled: UInt64
            let footprintAfterRelease: UInt64
            let processCPUIntervalMS: Double
        }

        private struct Cell {
            let workload: Fixture.Workload
            let consumers: Int
            let scenario: Scenario
            var trials: [Trial] = []
        }

        private struct Report: Encodable {
            let protocolVersion = 1
            let configuration = "debug"
            let scope = "presentationDecodeHelper"
            let workload: Fixture.Workload
            let consumers: Int
            let scenario: Scenario
            let fixtureBytes: Int
            let trialCount: Int
            let decodeTotalP50NS: UInt64
            let decodeTotalP95NS: UInt64
            let trials: [Trial]
        }

        private enum InvalidTrial: Error {
            case missingResourceCounters, incorrectValue, mutationAliasing, unexpectedFailure
            case droppedRecords, incorrectCounts, incorrectScope, invalidTiming, retainedConsumers
        }

        static func run() throws {
            var cells = Fixture.Workload.allCases.flatMap { workload in
                [1, 5, 20].flatMap { count in
                    Scenario.allCases.map { Cell(workload: workload, consumers: count, scenario: $0) }
                }
            }
            // Freeze all encoded fixtures before warmups or measurement.
            let fixtures = try Dictionary(uniqueKeysWithValues: Fixture.Workload.allCases.map { workload in
                let fixture = Fixture(workload: workload)
                let bytes = try (1 ... 5).map { try fixture.bytes(revision: $0) }
                let models = (1 ... 5).map { fixture.model(revision: $0) }
                return (workload, (fixture, [Data("{".utf8)] + bytes, models))
            })
            for cell in cells {
                let (fixture, bytes, models) = fixtures[cell.workload]!
                for _ in 0 ..< 5 {
                    _ = try trial(cell, ordinal: -1, fixture: fixture, bytes: bytes, models: models)
                }
            }
            for block in 0 ..< 3 {
                for offset in cells.indices {
                    let index = (offset + block * 13) % cells.count
                    let cell = cells[index]
                    let (fixture, bytes, models) = fixtures[cell.workload]!
                    for repetition in 0 ..< 10 {
                        let sample = try trial(
                            cell,
                            ordinal: block * 10 + repetition,
                            fixture: fixture,
                            bytes: bytes,
                            models: models
                        )
                        cells[index].trials.append(sample)
                    }
                }
            }
            for cell in cells {
                let totals = cell.trials.map(\.decodeTotalNS)
                try emit(Report(
                    workload: cell.workload, consumers: cell.consumers, scenario: cell.scenario,
                    fixtureBytes: fixtures[cell.workload]!.1[1].count, trialCount: cell.trials.count,
                    decodeTotalP50NS: percentile(totals, 0.5), decodeTotalP95NS: percentile(totals, 0.95),
                    trials: cell.trials
                ))
            }
            // This is a hard evidence boundary, not an inference from Debug timing.
            try emit([
                "gate": "inconclusive", "configuration": "debug", "cells": "36", "trialsPerCell": "30",
                "reason": "optimized_timing_full_projection_and_workload_realism_not_established"
            ])
        }

        private static func trial(
            _ cell: Cell, ordinal: Int, fixture: Fixture, bytes: [Data], models: [WorkspaceModel]
        ) throws -> Trial {
            var values = [WorkspaceModel?](repeating: nil, count: cell.consumers)
            if cell.scenario != .newRevision {
                for index in values.indices {
                    values[index] = try fixture.decode(bytes[1])
                }
            }
            let recorder = Diagnostics.Recorder()
            let before = try resourceSnapshot()
            var peakRSS = before.residentBytes
            var peakFootprint = before.physicalFootprintBytes!
            var peakSerializedBytes = values.compactMap(\.self).count * bytes[1].count
            var currentRevision = 1
            var deliveryNS: UInt64 = 0
            for revision in cell.scenario.revisions {
                let start = DispatchTime.now().uptimeNanoseconds
                for index in values.indices {
                    do {
                        values[index] = try Diagnostics.$context.withValue(.init(
                            recorder: recorder, contentOrdinal: revision, consumerOrdinal: index + 1,
                            revision: UInt64(revision), schemaVersion: 1, onMainActor: true
                        )) { try fixture.decode(bytes[revision]) }
                        if revision == 0 { throw InvalidTrial.unexpectedFailure }
                    } catch {
                        guard revision == 0, error is DecodingError else { throw error }
                    }
                }
                deliveryNS += DispatchTime.now().uptimeNanoseconds - start
                if revision != 0 { currentRevision = revision }
                guard values.allSatisfy({ $0 == models[currentRevision - 1] }) else {
                    throw InvalidTrial.incorrectValue
                }
                let memory = try resourceSnapshot()
                peakRSS = max(peakRSS, memory.residentBytes)
                peakFootprint = max(peakFootprint, memory.physicalFootprintBytes!)
                peakSerializedBytes = max(peakSerializedBytes, cell.consumers * bytes[currentRevision].count)
            }
            let settled = try resourceSnapshot()
            guard let cpu = settled.cpuUsage.delta(since: before.cpuUsage), cpu.totalMS.isFinite else {
                throw InvalidTrial.missingResourceCounters
            }
            // Exercise deep value isolation outside timing, including a fresh subsequent decode.
            values[0]?.composeTabs[0].promptText = "consumer-local edit"
            values[0]?.composeTabs[0].selection = StoredSelection(selectedPaths: ["consumer-local selection"])
            values[0]?.presets[0].selectedFilePaths.removeAll()
            guard values.dropFirst().allSatisfy({ $0 == models[currentRevision - 1] }),
                  try fixture.decode(bytes[currentRevision]) == models[currentRevision - 1]
            else { throw InvalidTrial.mutationAliasing }
            values.removeAll(keepingCapacity: false)
            guard values.isEmpty else { throw InvalidTrial.retainedConsumers }
            let released = try resourceSnapshot()
            let snapshot = recorder.snapshot()
            guard snapshot.droppedCount == 0 else { throw InvalidTrial.droppedRecords }
            let samples = snapshot.samples
            let failures = samples.count(where: { !$0.succeeded })
            let normalizations = samples.reduce(0) { $0 + $1.normalizationCount }
            let expectedFailures = cell.scenario == .failureCorrection ? cell.consumers : 0
            guard samples.count == cell.consumers * cell.scenario.revisions.count,
                  failures == expectedFailures,
                  normalizations == (samples.count - failures) * 2
            else { throw InvalidTrial.incorrectCounts }
            guard samples.allSatisfy({ sample in
                sample.consumerOrdinal >= 1 && sample.consumerOrdinal <= cell.consumers
                    && cell.scenario.revisions.contains(sample.contentOrdinal)
                    && sample.revision == UInt64(sample.contentOrdinal)
                    && sample.schemaVersion == 1 && sample.normalizationVersion == Diagnostics.normalizationVersion
                    && sample.inputBytes == bytes[sample.contentOrdinal].count
                    && sample.mainActorNanoseconds == sample.wallNanoseconds
            }) else { throw InvalidTrial.incorrectScope }
            let totalNS = samples.reduce(UInt64(0)) { $0 + $1.wallNanoseconds }
            guard totalNS > 0, deliveryNS >= totalNS else { throw InvalidTrial.invalidTiming }
            return Trial(
                ordinal: ordinal, decodeAttempts: samples.count, failures: failures, normalizationCount: normalizations,
                normalizationMutations: samples.reduce(0) { $0 + $1.normalizationMutationCount },
                inputBytes: samples.reduce(0) { $0 + $1.inputBytes }, decodeTotalNS: totalNS,
                decodeP50NS: percentile(samples.map(\.wallNanoseconds), 0.5),
                decodeP95NS: percentile(samples.map(\.wallNanoseconds), 0.95),
                normalizationTotalNS: samples.reduce(0) { $0 + $1.normalizationNanoseconds },
                mainActorTotalNS: totalNS, deliveryTotalNS: deliveryNS,
                diagnosticSamples: samples.count,
                diagnosticEstimatedBytes: samples.count * MemoryLayout<Diagnostics.Sample>.stride,
                peakConsumerEntries: cell.consumers, settledConsumerEntries: cell.consumers,
                peakConsumerSerializedBytes: peakSerializedBytes,
                settledConsumerSerializedBytes: cell.consumers * bytes[currentRevision].count,
                rssBefore: before.residentBytes, rssPeakBoundary: peakRSS,
                rssSettled: settled.residentBytes, rssAfterRelease: released.residentBytes,
                footprintBefore: before.physicalFootprintBytes!, footprintPeakBoundary: peakFootprint,
                footprintSettled: settled.physicalFootprintBytes!, footprintAfterRelease: released.physicalFootprintBytes!,
                processCPUIntervalMS: cpu.totalMS
            )
        }

        private static func resourceSnapshot() throws -> DebugProcessMemorySnapshot {
            guard let snapshot = DebugProcessMemorySampler.captureSnapshot(),
                  snapshot.residentBytes > 0, let footprint = snapshot.physicalFootprintBytes, footprint > 0
            else { throw InvalidTrial.missingResourceCounters }
            return snapshot
        }

        /// Nearest-rank percentiles; never average percentiles from separate trials.
        private static func percentile(_ values: [UInt64], _ fraction: Double) -> UInt64 {
            let ordered = values.sorted()
            return ordered[max(0, Int(ceil(Double(ordered.count) * fraction)) - 1)]
        }

        private static func emit(_ value: some Encodable) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(value)
            print("WORKSPACE_DECODE_MATRIX " + String(decoding: data, as: UTF8.self))
        }
    }
#endif
