#if DEBUG
    import Darwin
    import Foundation

    struct DebugProcessMemorySnapshot {
        let timestampMS: Double
        let residentBytes: UInt64
        let physicalFootprintBytes: UInt64?
        let userCPUTimeMS: Double
        let systemCPUTimeMS: Double

        var cpuUsage: DebugProcessCPUUsage {
            DebugProcessCPUUsage(userMS: userCPUTimeMS, systemMS: systemCPUTimeMS)
        }

        var residentMB: Double {
            Self.megabytes(residentBytes)
        }

        var physicalFootprintMB: Double? {
            physicalFootprintBytes.map(Self.megabytes)
        }

        func payload() -> [String: Any] {
            [
                "timestamp_ms": Self.round(timestampMS),
                "resident_bytes": NSNumber(value: residentBytes),
                "resident_mb": Self.round(residentMB),
                "physical_footprint_bytes": physicalFootprintBytes.map { NSNumber(value: $0) } ?? NSNull(),
                "physical_footprint_mb": physicalFootprintMB.map(Self.round) ?? NSNull(),
                "cumulative_user_cpu_ms": Self.round(userCPUTimeMS),
                "cumulative_system_cpu_ms": Self.round(systemCPUTimeMS),
                "cumulative_cpu_ms": Self.round(cpuUsage.totalMS)
            ]
        }

        static func megabytes(_ bytes: UInt64) -> Double {
            Double(bytes) / 1_048_576.0
        }

        static func round(_ value: Double) -> Double {
            (value * 10.0).rounded() / 10.0
        }
    }

    struct DebugProcessCPUUsage: Equatable {
        let userMS: Double
        let systemMS: Double

        var totalMS: Double {
            userMS + systemMS
        }

        func delta(since baseline: DebugProcessCPUUsage) -> DebugProcessCPUUsage? {
            let userDelta = userMS - baseline.userMS
            let systemDelta = systemMS - baseline.systemMS
            guard userDelta >= 0, systemDelta >= 0 else { return nil }
            return DebugProcessCPUUsage(userMS: userDelta, systemMS: systemDelta)
        }
    }

    struct DebugProcessCPUIntervalTracker {
        private(set) var previousSnapshot: DebugProcessMemorySnapshot
        private(set) var peakCoreUtilizationPercent: Double?

        init(baseline: DebugProcessMemorySnapshot) {
            previousSnapshot = baseline
            peakCoreUtilizationPercent = nil
        }

        mutating func record(_ snapshot: DebugProcessMemorySnapshot) {
            if let utilization = snapshot.coreUtilizationPercent(since: previousSnapshot) {
                peakCoreUtilizationPercent = max(peakCoreUtilizationPercent ?? utilization, utilization)
            }
            previousSnapshot = snapshot
        }
    }

    extension DebugProcessMemorySnapshot {
        func coreUtilizationPercent(since baseline: DebugProcessMemorySnapshot) -> Double? {
            let elapsedMS = timestampMS - baseline.timestampMS
            guard elapsedMS > 0, let cpuDelta = cpuUsage.delta(since: baseline.cpuUsage) else { return nil }
            return cpuDelta.totalMS / elapsedMS * 100.0
        }
    }

    struct DebugProcessMemoryMark {
        let name: String
        let timestampMS: Double
        let sampleIndex: Int
        let snapshot: DebugProcessMemorySnapshot

        func payload() -> [String: Any] {
            [
                "name": name,
                "timestamp_ms": DebugProcessMemorySnapshot.round(timestampMS),
                "sample_index": sampleIndex,
                "resident_mb": DebugProcessMemorySnapshot.round(snapshot.residentMB),
                "physical_footprint_mb": snapshot.physicalFootprintMB.map(DebugProcessMemorySnapshot.round) ?? NSNull()
            ]
        }
    }

    actor DebugProcessMemorySampler {
        static let shared = DebugProcessMemorySampler()

        private let maxSamples = 20000
        private var activeSession: ActiveSession?
        private var sampleTask: Task<Void, Never>?
        private var lastCompletedSession: CompletedSession?

        func start(
            label: String,
            intervalMS: Int,
            reset: Bool,
            benchmarkGate: Bool = false
        ) async -> DebugMemorySamplerResponse {
            let gateGeneration: UInt64?
            if benchmarkGate {
                do {
                    gateGeneration = try WorktreeStartupBenchmarkGate.shared.requireEnabled { $0 }
                } catch {
                    return .error(code: "disabled", message: "Benchmark diagnostics are disabled.")
                }
            } else {
                gateGeneration = nil
            }
            let effectiveLabel = label
            if activeSession != nil {
                return .error(
                    code: "already_running",
                    message: "A large workspace memory sampling session is already running; ownership cannot be taken over."
                )
            }

            guard let baseline = Self.captureSnapshot() else {
                return .error(code: "memory_snapshot_failed", message: "Unable to capture current process memory.")
            }

            let session = ActiveSession(
                id: UUID(),
                label: effectiveLabel,
                intervalMS: intervalMS,
                startedMS: baseline.timestampMS,
                baseline: baseline,
                peak: baseline,
                peakPhysicalFootprint: baseline.physicalFootprintBytes == nil ? nil : baseline,
                final: baseline,
                samples: [baseline],
                marks: [],
                firstSwitchReturnedPeak: nil,
                firstSwitchReturnedPeakPhysicalFootprint: nil,
                cpuIntervalTracker: DebugProcessCPUIntervalTracker(baseline: baseline),
                benchmarkGateGeneration: gateGeneration
            )
            activeSession = session
            lastCompletedSession = nil

            let sessionID = session.id
            sampleTask = Task { [weak self] in
                await self?.runSamplingLoop(sessionID: sessionID, intervalMS: intervalMS)
            }

            return .payload(payload(for: session, action: "start", running: true, includeSamplesLimit: 1))
        }

        func mark(_ name: String) async -> DebugMemorySamplerResponse {
            guard revokeStaleBenchmarkSessionIfNeeded() else {
                return .error(code: "disabled", message: "Benchmark diagnostics were revoked.")
            }
            guard var session = activeSession else {
                return .error(code: "no_active_session", message: "No large workspace memory sampling session is active.")
            }
            guard let snapshot = Self.captureSnapshot() else {
                return .error(code: "memory_snapshot_failed", message: "Unable to capture current process memory.")
            }

            record(snapshot: snapshot, in: &session)
            let mark = DebugProcessMemoryMark(
                name: name,
                timestampMS: snapshot.timestampMS,
                sampleIndex: session.totalSampleCount - 1,
                snapshot: snapshot
            )
            session.marks.append(mark)
            if name == "switch_returned", session.firstSwitchReturnedPeak == nil {
                session.firstSwitchReturnedPeak = session.peak
                session.firstSwitchReturnedPeakPhysicalFootprint = session.peakPhysicalFootprint
            }
            activeSession = session

            var result = payload(for: session, action: "mark", running: true, includeSamplesLimit: 1)
            result["mark"] = mark.payload()
            return .payload(result)
        }

        func stop(sessionID: UUID, settleSeconds: Double) async -> DebugMemorySamplerResponse {
            guard revokeStaleBenchmarkSessionIfNeeded() else {
                return .error(code: "disabled", message: "Benchmark diagnostics were revoked.")
            }
            guard var session = activeSession else {
                if let lastCompletedSession, lastCompletedSession.id == sessionID {
                    return .payload(payload(for: lastCompletedSession, action: "stop", running: false, includeSamplesLimit: 50))
                }
                return .error(
                    code: "no_matching_active_session",
                    message: "No matching large workspace memory sampling session is active."
                )
            }
            guard session.id == sessionID else {
                return .error(
                    code: "session_mismatch",
                    message: "The requested memory sampling session does not own the active sampler."
                )
            }

            if settleSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000.0))
                guard let updated = activeSession, updated.id == sessionID else {
                    return .error(
                        code: "session_no_longer_active",
                        message: "The owned memory sampling session is no longer active."
                    )
                }
                session = updated
            }

            if let finalSnapshot = Self.captureSnapshot() {
                record(snapshot: finalSnapshot, in: &session)
                session.final = finalSnapshot
            }

            sampleTask?.cancel()
            sampleTask = nil
            activeSession = nil

            let completed = CompletedSession(session: session)
            lastCompletedSession = completed
            return .payload(payload(for: completed, action: "stop", running: false, includeSamplesLimit: 50))
        }

        func snapshot(limit: Int) async -> DebugMemorySamplerResponse {
            guard revokeStaleBenchmarkSessionIfNeeded() else {
                return .error(code: "disabled", message: "Benchmark diagnostics were revoked.")
            }
            if let activeSession {
                return .payload(payload(for: activeSession, action: "snapshot", running: true, includeSamplesLimit: limit))
            }
            if let lastCompletedSession {
                return .payload(payload(for: lastCompletedSession, action: "snapshot", running: false, includeSamplesLimit: limit))
            }
            return .error(code: "no_session", message: "No active or completed large workspace memory sampling session is available.")
        }

        func current(limit: Int) async -> DebugMemorySamplerResponse {
            guard revokeStaleBenchmarkSessionIfNeeded() else {
                return .error(code: "disabled", message: "Benchmark diagnostics were revoked.")
            }
            guard let snapshot = Self.captureSnapshot() else {
                return .error(code: "memory_snapshot_failed", message: "Unable to capture current process memory.")
            }
            var result: [String: Any] = [
                "ok": true,
                "op": "large_workspace_memory",
                "action": "current",
                "running": activeSession != nil,
                "current": snapshot.payload(),
                "phys_footprint_available": snapshot.physicalFootprintBytes != nil
            ]
            if let activeSession {
                result["session_id"] = activeSession.id.uuidString
                result["session"] = sessionPayload(for: activeSession, running: true)
                result["metrics"] = metricsPayload(for: activeSession)
                result["recent_samples"] = activeSession.samples.suffix(limit).map { $0.payload() }
            } else if let lastCompletedSession {
                result["last_completed_session"] = sessionPayload(for: lastCompletedSession, running: false)
            }
            return .payload(result)
        }

        func reset() async -> DebugMemorySamplerResponse {
            guard activeSession == nil else {
                return .error(
                    code: "already_running",
                    message: "An active memory sampling session cannot be reset or taken over."
                )
            }
            lastCompletedSession = nil
            return .payload([
                "ok": true,
                "op": "large_workspace_memory",
                "action": "reset",
                "running": false
            ])
        }

        private func runSamplingLoop(sessionID: UUID, intervalMS: Int) async {
            let intervalNanoseconds = UInt64(intervalMS) * 1_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                if Task.isCancelled { break }
                recordPeriodicSample(sessionID: sessionID)
            }
        }

        private func recordPeriodicSample(sessionID: UUID) {
            guard var session = activeSession, session.id == sessionID else { return }
            if let generation = session.benchmarkGateGeneration,
               !WorktreeStartupBenchmarkGate.shared.isCurrentEnabledGeneration(generation)
            {
                sampleTask?.cancel()
                sampleTask = nil
                activeSession = nil
                lastCompletedSession = nil
                return
            }
            guard let snapshot = Self.captureSnapshot() else { return }
            record(snapshot: snapshot, in: &session)
            activeSession = session
        }

        @discardableResult
        private func revokeStaleBenchmarkSessionIfNeeded() -> Bool {
            let generations = [activeSession?.benchmarkGateGeneration, lastCompletedSession?.benchmarkGateGeneration]
                .compactMap(\.self)
            guard generations.allSatisfy({ WorktreeStartupBenchmarkGate.shared.isCurrentEnabledGeneration($0) }) else {
                sampleTask?.cancel()
                sampleTask = nil
                activeSession = nil
                lastCompletedSession = nil
                return false
            }
            return true
        }

        private func record(snapshot: DebugProcessMemorySnapshot, in session: inout ActiveSession) {
            session.totalSampleCount += 1
            session.cpuIntervalTracker.record(snapshot)
            session.final = snapshot
            if snapshot.residentBytes > session.peak.residentBytes {
                session.peak = snapshot
            }
            if let snapshotFootprint = snapshot.physicalFootprintBytes {
                if let peakFootprint = session.peakPhysicalFootprint?.physicalFootprintBytes {
                    if snapshotFootprint > peakFootprint {
                        session.peakPhysicalFootprint = snapshot
                    }
                } else {
                    session.peakPhysicalFootprint = snapshot
                }
            }
            session.samples.append(snapshot)
            if session.samples.count > maxSamples {
                session.samples.removeFirst(session.samples.count - maxSamples)
            }
        }

        private func payload(for session: ActiveSession, action: String, running: Bool, includeSamplesLimit: Int) -> [String: Any] {
            [
                "ok": true,
                "op": "large_workspace_memory",
                "action": action,
                "running": running,
                "session_id": session.id.uuidString,
                "session": sessionPayload(for: session, running: running),
                "metrics": metricsPayload(for: session),
                "baseline": session.baseline.payload(),
                "peak": session.peak.payload(),
                "peak_physical_footprint": session.peakPhysicalFootprint?.payload() ?? NSNull(),
                "final": session.final.payload(),
                "marks": session.marks.map { $0.payload() },
                "recent_samples": session.samples.suffix(includeSamplesLimit).map { $0.payload() }
            ]
        }

        private func payload(for session: CompletedSession, action: String, running: Bool, includeSamplesLimit: Int) -> [String: Any] {
            [
                "ok": true,
                "op": "large_workspace_memory",
                "action": action,
                "running": running,
                "session_id": session.id.uuidString,
                "session": sessionPayload(for: session, running: running),
                "metrics": metricsPayload(for: session),
                "baseline": session.baseline.payload(),
                "peak": session.peak.payload(),
                "peak_physical_footprint": session.peakPhysicalFootprint?.payload() ?? NSNull(),
                "final": session.final.payload(),
                "marks": session.marks.map { $0.payload() },
                "recent_samples": session.samples.suffix(includeSamplesLimit).map { $0.payload() }
            ]
        }

        private func sessionPayload(for session: ActiveSession, running: Bool) -> [String: Any] {
            [
                "id": session.id.uuidString,
                "label": session.label,
                "interval_ms": session.intervalMS,
                "started_ms": DebugProcessMemorySnapshot.round(session.startedMS),
                "duration_seconds": DebugProcessMemorySnapshot.round((session.final.timestampMS - session.startedMS) / 1000.0),
                "sample_count": session.totalSampleCount,
                "stored_sample_count": session.samples.count,
                "running": running,
                "phys_footprint_available": session.physicalFootprintAvailable
            ]
        }

        private func sessionPayload(for session: CompletedSession, running: Bool) -> [String: Any] {
            [
                "id": session.id.uuidString,
                "label": session.label,
                "interval_ms": session.intervalMS,
                "started_ms": DebugProcessMemorySnapshot.round(session.startedMS),
                "duration_seconds": DebugProcessMemorySnapshot.round((session.final.timestampMS - session.startedMS) / 1000.0),
                "sample_count": session.totalSampleCount,
                "stored_sample_count": session.samples.count,
                "running": running,
                "phys_footprint_available": session.physicalFootprintAvailable
            ]
        }

        private func metricsPayload(for session: ActiveSession) -> [String: Any] {
            metricsPayload(
                baseline: session.baseline,
                peak: session.peak,
                peakPhysicalFootprint: session.peakPhysicalFootprint,
                final: session.final,
                marks: session.marks,
                firstSwitchReturnedPeak: session.firstSwitchReturnedPeak,
                firstSwitchReturnedPeakPhysicalFootprint: session.firstSwitchReturnedPeakPhysicalFootprint,
                sampleCount: session.totalSampleCount,
                durationSeconds: (session.final.timestampMS - session.startedMS) / 1000.0,
                physFootprintAvailable: session.physicalFootprintAvailable,
                peakIntervalCoreUtilizationPercent: session.cpuIntervalTracker.peakCoreUtilizationPercent
            )
        }

        private func metricsPayload(for session: CompletedSession) -> [String: Any] {
            metricsPayload(
                baseline: session.baseline,
                peak: session.peak,
                peakPhysicalFootprint: session.peakPhysicalFootprint,
                final: session.final,
                marks: session.marks,
                firstSwitchReturnedPeak: session.firstSwitchReturnedPeak,
                firstSwitchReturnedPeakPhysicalFootprint: session.firstSwitchReturnedPeakPhysicalFootprint,
                sampleCount: session.totalSampleCount,
                durationSeconds: (session.final.timestampMS - session.startedMS) / 1000.0,
                physFootprintAvailable: session.physicalFootprintAvailable,
                peakIntervalCoreUtilizationPercent: session.peakIntervalCoreUtilizationPercent
            )
        }

        private func metricsPayload(
            baseline: DebugProcessMemorySnapshot,
            peak: DebugProcessMemorySnapshot,
            peakPhysicalFootprint: DebugProcessMemorySnapshot?,
            final: DebugProcessMemorySnapshot,
            marks: [DebugProcessMemoryMark],
            firstSwitchReturnedPeak: DebugProcessMemorySnapshot?,
            firstSwitchReturnedPeakPhysicalFootprint: DebugProcessMemorySnapshot?,
            sampleCount: Int,
            durationSeconds: Double,
            physFootprintAvailable: Bool,
            peakIntervalCoreUtilizationPercent: Double?
        ) -> [String: Any] {
            var metrics: [String: Any] = [
                "baseline_resident_mb": DebugProcessMemorySnapshot.round(baseline.residentMB),
                "peak_resident_mb": DebugProcessMemorySnapshot.round(peak.residentMB),
                "peak_resident_delta_mb": DebugProcessMemorySnapshot.round(peak.residentMB - baseline.residentMB),
                "final_resident_mb": DebugProcessMemorySnapshot.round(final.residentMB),
                "retained_resident_delta_mb": DebugProcessMemorySnapshot.round(final.residentMB - baseline.residentMB),
                "sample_count": sampleCount,
                "duration_seconds": DebugProcessMemorySnapshot.round(durationSeconds),
                "phys_footprint_available": physFootprintAvailable
            ]

            let sessionCPU = final.cpuUsage.delta(since: baseline.cpuUsage)
            metrics["session_user_cpu_ms"] = sessionCPU.map { DebugProcessMemorySnapshot.round($0.userMS) } ?? NSNull()
            metrics["session_system_cpu_ms"] = sessionCPU.map { DebugProcessMemorySnapshot.round($0.systemMS) } ?? NSNull()
            metrics["session_cpu_ms"] = sessionCPU.map { DebugProcessMemorySnapshot.round($0.totalMS) } ?? NSNull()
            metrics["average_core_utilization_percent"] = final.coreUtilizationPercent(since: baseline)
                .map(DebugProcessMemorySnapshot.round) ?? NSNull()
            metrics["peak_interval_core_utilization_percent"] = peakIntervalCoreUtilizationPercent
                .map(DebugProcessMemorySnapshot.round) ?? NSNull()

            let firstSwitchReturnedSnapshot = marks.first { $0.name == "switch_returned" }?.snapshot
            if let firstSwitchReturnedSnapshot {
                metrics["switch_returned_resident_mb"] = DebugProcessMemorySnapshot.round(firstSwitchReturnedSnapshot.residentMB)
                metrics["switch_returned_resident_delta_mb"] = DebugProcessMemorySnapshot.round(firstSwitchReturnedSnapshot.residentMB - baseline.residentMB)
                metrics["post_switch_retained_resident_delta_mb"] = DebugProcessMemorySnapshot.round(final.residentMB - firstSwitchReturnedSnapshot.residentMB)
            } else {
                metrics["switch_returned_resident_mb"] = NSNull()
                metrics["switch_returned_resident_delta_mb"] = NSNull()
                metrics["post_switch_retained_resident_delta_mb"] = NSNull()
            }

            if let firstSwitchReturnedPeak {
                metrics["peak_until_switch_returned_resident_mb"] = DebugProcessMemorySnapshot.round(firstSwitchReturnedPeak.residentMB)
                metrics["peak_until_switch_returned_resident_delta_mb"] = DebugProcessMemorySnapshot.round(firstSwitchReturnedPeak.residentMB - baseline.residentMB)
            } else {
                metrics["peak_until_switch_returned_resident_mb"] = NSNull()
                metrics["peak_until_switch_returned_resident_delta_mb"] = NSNull()
            }

            addPhysicalFootprintMetrics(
                to: &metrics,
                baseline: baseline,
                peakPhysicalFootprint: peakPhysicalFootprint,
                final: final,
                firstSwitchReturnedSnapshot: firstSwitchReturnedSnapshot,
                firstSwitchReturnedPeakPhysicalFootprint: firstSwitchReturnedPeakPhysicalFootprint
            )
            return metrics
        }

        private func addPhysicalFootprintMetrics(
            to metrics: inout [String: Any],
            baseline: DebugProcessMemorySnapshot,
            peakPhysicalFootprint: DebugProcessMemorySnapshot?,
            final: DebugProcessMemorySnapshot,
            firstSwitchReturnedSnapshot: DebugProcessMemorySnapshot?,
            firstSwitchReturnedPeakPhysicalFootprint: DebugProcessMemorySnapshot?
        ) {
            guard let baselineFootprint = baseline.physicalFootprintMB,
                  let peakFootprint = peakPhysicalFootprint?.physicalFootprintMB,
                  let finalFootprint = final.physicalFootprintMB
            else {
                metrics["baseline_physical_footprint_mb"] = NSNull()
                metrics["peak_physical_footprint_mb"] = NSNull()
                metrics["peak_physical_footprint_delta_mb"] = NSNull()
                metrics["final_physical_footprint_mb"] = NSNull()
                metrics["retained_physical_footprint_delta_mb"] = NSNull()
                metrics["switch_returned_physical_footprint_mb"] = NSNull()
                metrics["switch_returned_physical_footprint_delta_mb"] = NSNull()
                metrics["post_switch_retained_physical_footprint_delta_mb"] = NSNull()
                metrics["peak_until_switch_returned_physical_footprint_mb"] = NSNull()
                metrics["peak_until_switch_returned_physical_footprint_delta_mb"] = NSNull()
                return
            }

            metrics["baseline_physical_footprint_mb"] = DebugProcessMemorySnapshot.round(baselineFootprint)
            metrics["peak_physical_footprint_mb"] = DebugProcessMemorySnapshot.round(peakFootprint)
            metrics["peak_physical_footprint_delta_mb"] = DebugProcessMemorySnapshot.round(peakFootprint - baselineFootprint)
            metrics["final_physical_footprint_mb"] = DebugProcessMemorySnapshot.round(finalFootprint)
            metrics["retained_physical_footprint_delta_mb"] = DebugProcessMemorySnapshot.round(finalFootprint - baselineFootprint)

            if let firstSwitchReturnedFootprint = firstSwitchReturnedSnapshot?.physicalFootprintMB {
                metrics["switch_returned_physical_footprint_mb"] = DebugProcessMemorySnapshot.round(firstSwitchReturnedFootprint)
                metrics["switch_returned_physical_footprint_delta_mb"] = DebugProcessMemorySnapshot.round(firstSwitchReturnedFootprint - baselineFootprint)
                metrics["post_switch_retained_physical_footprint_delta_mb"] = DebugProcessMemorySnapshot.round(finalFootprint - firstSwitchReturnedFootprint)
            } else {
                metrics["switch_returned_physical_footprint_mb"] = NSNull()
                metrics["switch_returned_physical_footprint_delta_mb"] = NSNull()
                metrics["post_switch_retained_physical_footprint_delta_mb"] = NSNull()
            }

            if let firstSwitchReturnedFootprint = firstSwitchReturnedPeakPhysicalFootprint?.physicalFootprintMB {
                metrics["peak_until_switch_returned_physical_footprint_mb"] = DebugProcessMemorySnapshot.round(firstSwitchReturnedFootprint)
                metrics["peak_until_switch_returned_physical_footprint_delta_mb"] = DebugProcessMemorySnapshot.round(firstSwitchReturnedFootprint - baselineFootprint)
            } else {
                metrics["peak_until_switch_returned_physical_footprint_mb"] = NSNull()
                metrics["peak_until_switch_returned_physical_footprint_delta_mb"] = NSNull()
            }
        }

        private static func captureSnapshot() -> DebugProcessMemorySnapshot? {
            let nowMS = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000.0
            guard let residentBytes = captureResidentBytes() else { return nil }
            guard let cpuUsage = captureCPUUsage() else { return nil }
            return DebugProcessMemorySnapshot(
                timestampMS: nowMS,
                residentBytes: residentBytes,
                physicalFootprintBytes: capturePhysicalFootprintBytes(),
                userCPUTimeMS: cpuUsage.userMS,
                systemCPUTimeMS: cpuUsage.systemMS
            )
        }

        private static func captureCPUUsage() -> DebugProcessCPUUsage? {
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
            return DebugProcessCPUUsage(
                userMS: milliseconds(usage.ru_utime),
                systemMS: milliseconds(usage.ru_stime)
            )
        }

        private static func milliseconds(_ value: timeval) -> Double {
            Double(value.tv_sec) * 1000.0 + Double(value.tv_usec) / 1000.0
        }

        private static func captureResidentBytes() -> UInt64? {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return UInt64(info.resident_size)
        }

        private static func capturePhysicalFootprintBytes() -> UInt64? {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return nil }
            return UInt64(info.phys_footprint)
        }

        enum DebugMemorySamplerResponse: @unchecked Sendable {
            case payload([String: Any])
            case error(code: String, message: String)
        }

        private struct ActiveSession {
            let id: UUID
            let label: String
            let intervalMS: Int
            let startedMS: Double
            let baseline: DebugProcessMemorySnapshot
            var peak: DebugProcessMemorySnapshot
            var peakPhysicalFootprint: DebugProcessMemorySnapshot?
            var final: DebugProcessMemorySnapshot
            var samples: [DebugProcessMemorySnapshot]
            var marks: [DebugProcessMemoryMark]
            var firstSwitchReturnedPeak: DebugProcessMemorySnapshot?
            var firstSwitchReturnedPeakPhysicalFootprint: DebugProcessMemorySnapshot?
            var cpuIntervalTracker: DebugProcessCPUIntervalTracker
            let benchmarkGateGeneration: UInt64?
            var totalSampleCount: Int = 1

            var physicalFootprintAvailable: Bool {
                baseline.physicalFootprintBytes != nil && samples.contains { $0.physicalFootprintBytes != nil }
            }
        }

        private struct CompletedSession {
            let id: UUID
            let label: String
            let intervalMS: Int
            let startedMS: Double
            let baseline: DebugProcessMemorySnapshot
            let peak: DebugProcessMemorySnapshot
            let peakPhysicalFootprint: DebugProcessMemorySnapshot?
            let final: DebugProcessMemorySnapshot
            let samples: [DebugProcessMemorySnapshot]
            let marks: [DebugProcessMemoryMark]
            let firstSwitchReturnedPeak: DebugProcessMemorySnapshot?
            let firstSwitchReturnedPeakPhysicalFootprint: DebugProcessMemorySnapshot?
            let peakIntervalCoreUtilizationPercent: Double?
            let totalSampleCount: Int
            let physicalFootprintAvailable: Bool
            let benchmarkGateGeneration: UInt64?

            init(session: ActiveSession) {
                id = session.id
                label = session.label
                intervalMS = session.intervalMS
                startedMS = session.startedMS
                baseline = session.baseline
                peak = session.peak
                peakPhysicalFootprint = session.peakPhysicalFootprint
                final = session.final
                samples = session.samples
                marks = session.marks
                firstSwitchReturnedPeak = session.firstSwitchReturnedPeak
                firstSwitchReturnedPeakPhysicalFootprint = session.firstSwitchReturnedPeakPhysicalFootprint
                peakIntervalCoreUtilizationPercent = session.cpuIntervalTracker.peakCoreUtilizationPercent
                totalSampleCount = session.totalSampleCount
                physicalFootprintAvailable = session.physicalFootprintAvailable
                benchmarkGateGeneration = session.benchmarkGateGeneration
            }
        }
    }
#endif
