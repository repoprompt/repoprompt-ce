import AppKit
import Darwin
import SwiftUI

struct ActivitySettingsView: View {
    @EnvironmentObject private var windows: WindowStatesManager
    @State private var display = ActivityDisplay()
    @State private var copyStatus: String?

    var body: some View {
        SettingSection(title: "Activity", description: ActivityDisplay.caveat) {
            HStack {
                Text("Process CPU: \(display.cpu)")
                Spacer()
                Text("Memory (resident): \(display.memory)")
            }
            .monospacedDigit()
            if display.rows.isEmpty {
                Text("No open windows.").foregroundStyle(.secondary)
            }
            ForEach(display.rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.window).fontWeight(.medium)
                    Text("File watching: \(row.rate) (s/s, last interval)")
                    Text("Root: \(row.root)")
                    Text("Status: \(row.status)")
                    Text("Busy total since window opened: \(row.total)")
                }
                .monospacedDigit()
                .accessibilityElement(children: .combine)
            }
            HStack {
                Button("Copy report") {
                    NSPasteboard.general.clearContents()
                    copyStatus = NSPasteboard.general.setString(display.report, forType: .string)
                        ? "Copied" : "Could not copy report"
                }
                if let copyStatus { Text(copyStatus).foregroundStyle(.secondary) }
            }
        }
        .task {
            var previous: [Int: WindowActivityLedger.Snapshot] = [:]
            var process = ActivityProcessSampler()
            while !Task.isCancelled {
                let snapshots = windows.activityLedger.snapshot()
                let cpu = process.readCPU()
                let memory = ActivityProcessSampler.residentMiB()
                let rows = windows.allWindows.filter { !$0.isClosing && !$0.isPreparedSessionOwner }.map { window in
                    let snapshot = snapshots.first { $0.windowID == window.windowID }
                    return ActivityDisplay.Row(
                        id: window.windowID, title: window.displayedWindowTitle,
                        snapshot: snapshot, previous: previous[window.windowID]
                    )
                }.sorted { $0.id < $1.id }
                display = ActivityDisplay(cpu: cpu, memory: memory, rows: rows)
                previous = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.windowID, $0) })
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
}

struct ActivityDisplay {
    static let caveat = "100% CPU = one core. Window job time includes waits, not CPU; drawing and other work are unattributed."
    let capturedAt: Date
    let cpu: String
    let memory: String
    let rows: [Row]

    init(cpu: String = "Measuring…", memory: String = "Measuring…", rows: [Row] = [], capturedAt: Date = Date()) {
        self.capturedAt = capturedAt
        self.cpu = cpu
        self.memory = memory
        self.rows = rows
    }

    struct Row: Identifiable {
        let id: Int
        let window: String
        let rate: String
        let root: String
        let status: String
        let total: String

        init(id: Int, title: String, snapshot: WindowActivityLedger.Snapshot?, previous: WindowActivityLedger.Snapshot?) {
            self.id = id
            let title = ActivityDisplay.label(title)
            window = title.isEmpty || title == WindowTitleFormatter.defaultTitle
                ? "Window \(id)" : "Window \(id) — \(title)"
            root = snapshot?.root.map(ActivityDisplay.label) ?? "—"
            total = ActivityDisplay.duration(snapshot?.busyTotal ?? 0)
            if let snapshot, let previous, snapshot.sampledAt > previous.sampledAt, snapshot.busyTotal >= previous.busyTotal {
                let fraction = Double(snapshot.busyTotal - previous.busyTotal) / Double(snapshot.sampledAt - previous.sampledAt)
                rate = ActivityDisplay.number(min(1, max(0, fraction)), decimals: 2)
            } else {
                rate = "Measuring…"
            }
            if let snapshot, let start = snapshot.busySince {
                status = "running for \(ActivityDisplay.duration(snapshot.sampledAt >= start ? snapshot.sampledAt - start : 0))"
            } else if let snapshot, let end = snapshot.lastEnded {
                status = "idle, last active \(ActivityDisplay.duration(snapshot.sampledAt >= end ? snapshot.sampledAt - end : 0)) ago"
            } else {
                status = "No activity recorded"
            }
        }
    }

    var report: String {
        let timestamp = ISO8601DateFormatter().string(from: capturedAt)
        let body = rows.map { row in
            """
            \(row.window)
              File watching: \(row.rate) (s/s, last interval)
              Root: \(row.root)
              Status: \(row.status)
              Busy total since window opened: \(row.total)
            """
        }.joined(separator: "\n")
        return """
        RepoPrompt CE — Activity
        Captured: \(timestamp)
        Process CPU: \(cpu)
        Memory (resident): \(memory)
        \(Self.caveat)
        \(rows.isEmpty ? "No open windows." : body)
        """
    }

    static func label(_ text: String) -> String {
        let value = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return value.count > 80 ? String(value.prefix(79)) + "…" : value
    }

    static func number(_ value: Double, decimals: Int) -> String {
        String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), decimals, value)
    }

    static func duration(_ nanoseconds: UInt64) -> String {
        let seconds = nanoseconds / 1_000_000_000
        if seconds < 60 { return number(Double(nanoseconds) / 1e9, decimals: 1) + " s" }
        if seconds < 3600 { return "\(seconds / 60) m \(String(format: "%02d", Int(seconds % 60))) s" }
        if seconds < 86400 { return "\(seconds / 3600) h \(String(format: "%02d", Int(seconds / 60 % 60))) m" }
        return "\(seconds / 86400) d \(String(format: "%02d", Int(seconds / 3600 % 24))) h"
    }
}

struct ActivityProcessSampler {
    struct CPUCounters {
        let user: UInt64
        let system: UInt64
        let now: UInt64
    }

    private var previous: CPUCounters?
    private let numer: UInt32
    private let denom: UInt32

    init(numer: UInt32? = nil, denom: UInt32? = nil) {
        var timebase = mach_timebase_info_data_t()
        let result = mach_timebase_info(&timebase)
        self.numer = numer ?? (result == KERN_SUCCESS ? timebase.numer : 0)
        self.denom = denom ?? (result == KERN_SUCCESS ? timebase.denom : 0)
    }

    mutating func cpuText(_ counters: CPUCounters?) -> String {
        guard let counters, numer > 0, denom > 0 else {
            previous = nil
            return "Unavailable"
        }
        let baseline = previous
        previous = counters
        guard let baseline else { return "Measuring…" }
        guard counters.now > baseline.now, counters.user >= baseline.user, counters.system >= baseline.system else {
            previous = nil
            return "Unavailable"
        }
        let cpuNs = (Double(counters.user - baseline.user) + Double(counters.system - baseline.system)) * Double(numer) / Double(denom)
        return ActivityDisplay.number(100 * cpuNs / Double(counters.now - baseline.now), decimals: 1) + "%"
    }

    mutating func readCPU() -> String {
        var info = task_absolutetime_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_ABSOLUTETIME_INFO), $0, &count)
            }
        }
        return cpuText(result == KERN_SUCCESS ? CPUCounters(
            user: info.total_user, system: info.total_system, now: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        ) : nil)
    }

    static func residentMiB() -> String {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "Unavailable" }
        return ActivityDisplay.number(Double(info.resident_size) / 1_048_576, decimals: 0) + " MiB"
    }
}
