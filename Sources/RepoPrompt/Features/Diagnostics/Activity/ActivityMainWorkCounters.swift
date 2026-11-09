import Darwin
import SwiftUI

extension EnvironmentValues {
    @Entry var activityMainWork: ActivityMainWorkCounters?
}

/// Window-owned, non-observable scalars. Only the visible Activity refresh reads them.
@MainActor
final class ActivityMainWorkCounters {
    enum Kind: String, CaseIterable {
        case selection = "Stored selection"
        case markdown = "Markdown presentation"
        case routing = "Session routing"
    }

    struct Snapshot: Equatable {
        var selection: UInt64 = 0
        var markdown: UInt64 = 0
        var routing: UInt64 = 0
        var union: UInt64 = 0

        func total(for kind: Kind) -> UInt64 {
            switch kind {
            case .selection: selection
            case .markdown: markdown
            case .routing: routing
            }
        }
    }

    struct Counter {
        var depth = 0
        var started: UInt64 = 0
        var total: UInt64 = 0

        mutating func begin(_ now: UInt64) {
            if depth == 0 { started = now }
            depth += 1
        }

        mutating func end(_ now: UInt64) {
            guard depth > 0 else { return }
            depth -= 1
            if depth == 0 { total &+= now >= started ? now - started : 0 }
        }
    }

    private(set) var selection = Counter()
    private(set) var markdown = Counter()
    private(set) var routing = Counter()
    private(set) var union = Counter()

    /// Categories are inclusive; their sum is not a total when different kinds nest.
    var snapshot: Snapshot {
        Snapshot(selection: selection.total, markdown: markdown.total, routing: routing.total, union: union.total)
    }

    func begin(_ kind: Kind) {
        begin(kind, at: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
    }

    func end(_ kind: Kind) {
        end(kind, at: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
    }

    func begin(_ kind: Kind, at now: UInt64) {
        union.begin(now)
        switch kind {
        case .selection: selection.begin(now)
        case .markdown: markdown.begin(now)
        case .routing: routing.begin(now)
        }
    }

    func end(_ kind: Kind, at now: UInt64) {
        switch kind {
        case .selection: selection.end(now)
        case .markdown: markdown.end(now)
        case .routing: routing.end(now)
        }
        union.end(now)
    }
}
