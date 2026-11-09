import AppKit
import Darwin
import SwiftUI

struct ActivitySettingsView: View {
    @EnvironmentObject private var windows: WindowStatesManager
    @State private var display = ActivityDisplay()
    @State private var copyStatus: String?
    @State private var sort: ActivityDisplay.Sort?

    var body: some View {
        SettingSection(title: "Activity", description: ActivityDisplay.caveat) {
            HStack {
                Text("CPU: \(display.cpu)")
                Spacer()
                Text("Memory: \(display.memory)")
            }
            .monospacedDigit()
            if display.rows.isEmpty {
                Text("No open windows.").foregroundStyle(.secondary)
            }
            if !display.rows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        ForEach(ActivityDisplay.Column.allCases, id: \.self) { column in
                            Button {
                                sort = ActivityDisplay.Sort(column: column, ascending: sort?.column == column ? !(sort?.ascending ?? true) : true)
                                display = display.sorted(by: sort)
                            } label: {
                                HStack(spacing: 3) {
                                    Text(column.rawValue)
                                    if sort?.column == column {
                                        Image(systemName: sort?.ascending == true ? "chevron.up" : "chevron.down")
                                            .imageScale(.small)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .fontWeight(.medium)
                    ForEach(display.rows) { row in
                        GridRow {
                            Text(row.window)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .hoverTooltip(row.window)
                            Text(row.rate)
                            Text(row.root).lineLimit(1).hoverTooltip(row.root)
                            Text(row.status)
                            Text(row.total)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .font(.caption)
                .monospacedDigit()
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
                }
                display = ActivityDisplay(cpu: cpu, memory: memory, rows: rows, sort: sort)
                previous = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.windowID, $0) })
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
}

struct ActivityDisplay {
    static let caveat = "Window figures cover file watching only; agent runs are not counted. Times include waiting, not drawing. CPU: 100% = one core."
    enum Column: String, CaseIterable {
        case window = "Window"
        case rate = "Watcher busy"
        case root = "Last busy folder"
        case status = "File watcher"
        case total = "Watcher busy total"
    }

    struct Sort {
        let column: Column
        let ascending: Bool
    }

    let capturedAt: Date
    let cpu: String
    let memory: String
    let rows: [Row]

    init(cpu: String = "Measuring…", memory: String = "Measuring…", rows: [Row] = [], capturedAt: Date = Date(), sort: Sort? = nil) {
        self.capturedAt = capturedAt
        self.cpu = cpu
        self.memory = memory
        self.rows = rows.sorted { lhs, rhs in
            let order: ComparisonResult
            switch sort?.column ?? .window {
            case .window: order = Self.compareText(lhs.title, rhs.title)
            case .root: order = Self.compareText(lhs.fullRoot, rhs.fullRoot)
            case .rate: order = Self.compare(lhs.rawRate ?? -1, rhs.rawRate ?? -1)
            case .total: order = Self.compare(lhs.snapshot?.busyTotal ?? 0, rhs.snapshot?.busyTotal ?? 0)
            case .status:
                let phase = Self.compare(lhs.watcherPhase, rhs.watcherPhase)
                order = phase == .orderedSame ? Self.compare(lhs.statusDuration, rhs.statusDuration) : phase
            }
            // A fixed ID tie-breaker prevents equal keys from jumping on refresh or reversal.
            return order == .orderedSame ? lhs.id < rhs.id
                : order == (sort?.ascending == false ? .orderedDescending : .orderedAscending)
        }
    }

    func sorted(by sort: Sort?) -> Self {
        Self(cpu: cpu, memory: memory, rows: rows, capturedAt: capturedAt, sort: sort)
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs == rhs ? .orderedSame : lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func compareText(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let locale = Locale(identifier: "en_US_POSIX")
        return lhs.folding(options: .caseInsensitive, locale: locale)
            .compare(rhs.folding(options: .caseInsensitive, locale: locale), options: .literal)
    }

    struct Row: Identifiable {
        let id: Int
        let title: String
        let window: String
        let rate: String
        let root: String
        let status: String
        let total: String
        let snapshot: WindowActivityLedger.Snapshot?
        let rawRate: Double?
        let fullRoot: String

        // Ascending: never recorded, idle, busy. Descending puts busy episodes first.
        var watcherPhase: Int {
            snapshot?.busySince != nil ? 2 : snapshot?.lastEnded != nil ? 1 : 0
        }

        var statusDuration: UInt64 {
            guard let snapshot, let start = snapshot.busySince ?? snapshot.lastEnded else { return 0 }
            return snapshot.sampledAt >= start ? snapshot.sampledAt - start : 0
        }

        init(id: Int, title: String, snapshot: WindowActivityLedger.Snapshot?, previous: WindowActivityLedger.Snapshot?) {
            self.id = id
            self.snapshot = snapshot
            let title = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            self.title = title
            window = title.isEmpty || title == WindowTitleFormatter.defaultTitle
                ? "Window \(id)" : "Window \(id): \(title)"
            fullRoot = snapshot?.root.map { $0 == "Multiple roots" ? "Multiple folders" : $0 } ?? "—"
            root = ActivityDisplay.label(fullRoot)
            total = ActivityDisplay.duration(snapshot?.busyTotal ?? 0)
            if let snapshot, let previous, snapshot.sampledAt > previous.sampledAt, snapshot.busyTotal >= previous.busyTotal {
                let fraction = Double(snapshot.busyTotal - previous.busyTotal) / Double(snapshot.sampledAt - previous.sampledAt)
                rawRate = fraction
                // Union time cannot exceed the interval; clamp its displayed percentage to 0...100.
                let percent = 100 * min(1, max(0, fraction))
                rate = percent > 0 && percent < 0.1 ? "<0.1%"
                    : ActivityDisplay.number(percent, decimals: percent > 0 && percent < 10 ? 1 : 0) + "%"
            } else {
                rawRate = nil
                rate = "Measuring…"
            }
            if let snapshot, let start = snapshot.busySince {
                status = "Busy \(ActivityDisplay.duration(snapshot.sampledAt >= start ? snapshot.sampledAt - start : 0))"
            } else if let snapshot, let end = snapshot.lastEnded {
                status = "Idle \(ActivityDisplay.duration(snapshot.sampledAt >= end ? snapshot.sampledAt - end : 0))"
            } else {
                status = "Not busy yet"
            }
        }
    }

    var report: String {
        let timestamp = ISO8601DateFormatter().string(from: capturedAt)
        let body = rows.map { row in
            """
            \(row.window)
              Watcher busy: \(row.rate)
              Last busy folder: \(row.root)
              File watcher: \(row.status)
              Watcher busy total: \(row.total)
            """
        }.joined(separator: "\n")
        return """
        RepoPrompt CE: Activity
        Captured: \(timestamp)
        CPU: \(cpu)
        Memory: \(memory)
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
        if nanoseconds == 0 { return "0 ms" }
        if nanoseconds < 100_000 { return "<0.1 ms" }
        if seconds == 0 { return number(Double(nanoseconds) / 1e6, decimals: 1) + " ms" }
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
