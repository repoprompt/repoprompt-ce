@testable import RepoPromptApp
import XCTest

final class StartupPhaseLogTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private let ticks: [TimeInterval]
        private var tickIndex = 0
        private(set) var emissions: [String] = []

        init(ticks: [TimeInterval]) {
            self.ticks = ticks
        }

        func uptime() -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            defer { tickIndex += 1 }
            return ticks[min(tickIndex, ticks.count - 1)]
        }

        func emit(_ message: String) {
            lock.lock()
            emissions.append(message)
            lock.unlock()
        }
    }

    override func tearDown() {
        StartupPhaseLog.resetForTesting()
        super.tearDown()
    }

    /// The only values that may reach the unified log are the phase name, boundary,
    /// window ordinal, elapsed/span milliseconds and integer fields -- nothing
    /// user-identifying can appear because no string values are ever rendered.
    func testEmittedMarkersCarryOnlyPhaseDurationsOrdinalsAndCounts() {
        let recorder = Recorder(ticks: [125.0, 125.25, 125.25, 126.0])
        StartupPhaseLog.installForTesting(
            StartupPhaseLog.Runtime(
                uptime: { recorder.uptime() },
                processStartUptime: 100.0,
                emit: { recorder.emit($0) }
            )
        )

        StartupPhaseLog.mark(.windowAttached, window: 2)
        let span = StartupPhaseLog.begin(.windowComposition, window: 2)
        span.end(extraFields: ["entries": 42, "loaded": 40])

        let marker = #/^phase=[a-zA-Z]+ boundary=(begin|end|event)( window=\d+)? elapsed_ms=\d+( span_ms=\d+)?( [a-zA-Z0-9_]+=\d+)*$/#
        let knownPhases = Set(StartupPhaseLog.Phase.allCases.map(\.rawValue))
        var elapsed: [Int] = []
        for line in recorder.emissions {
            XCTAssertNotNil(line.wholeMatch(of: marker), "unexpected marker content: \(line)")
            let phase = line.components(separatedBy: " ")
                .first { $0.hasPrefix("phase=") }
                .map { String($0.dropFirst("phase=".count)) }
            XCTAssertEqual(phase.flatMap { knownPhases.contains($0) ? $0 : nil }, phase)
            let elapsedText = line.components(separatedBy: " ")
                .first { $0.hasPrefix("elapsed_ms=") }?
                .dropFirst("elapsed_ms=".count)
            elapsed.append(elapsedText.flatMap { Int($0) } ?? -1)
        }
        XCTAssertEqual(recorder.emissions.count, 3)
        XCTAssertEqual(elapsed, [25000, 25250, 26000])
        XCTAssertEqual(elapsed, elapsed.sorted())
        XCTAssertEqual(
            recorder.emissions.last,
            "phase=windowComposition boundary=end window=2 elapsed_ms=26000 span_ms=750 entries=42 loaded=40"
        )
    }

    /// A regressed or imprecise start anchor must never emit negative timings.
    func testElapsedAndSpanMillisecondsClampToNonNegative() {
        XCTAssertEqual(StartupPhaseLog.elapsedMilliseconds(now: 42.0, processStart: 100.0), 0)
        XCTAssertEqual(StartupPhaseLog.elapsedMilliseconds(now: 100.4, processStart: 100.0), 400)
        XCTAssertEqual(StartupPhaseLog.spanMilliseconds(from: 10.5, to: 10.0), 0)
        XCTAssertEqual(StartupPhaseLog.spanMilliseconds(from: 10.0, to: 10.75), 750)
    }

    /// The span clock starts after begin emission returns, so a cold or descheduled
    /// emitter is charged to the marker path, not the measured phase. Here emission
    /// consumes 4.4s of the scripted clock; span_ms must exclude it while the begin
    /// line still records the request-time elapsed_ms.
    func testSpanClockStartsAfterBeginEmission() {
        let recorder = Recorder(ticks: [125.0, 129.4, 131.0])
        StartupPhaseLog.installForTesting(
            StartupPhaseLog.Runtime(
                uptime: { recorder.uptime() },
                processStartUptime: 100.0,
                emit: { recorder.emit($0) }
            )
        )

        let span = StartupPhaseLog.begin(.appInit)
        span.end()

        XCTAssertEqual(
            recorder.emissions,
            [
                "phase=appInit boundary=begin elapsed_ms=25000",
                "phase=appInit boundary=end elapsed_ms=31000 span_ms=1600"
            ]
        )
    }

    /// Phase names are fixed enum raw values -- letters only -- so no call site can
    /// interpolate names or identifiers into a marker.
    func testPhaseRawValuesAreFixedLetterOnlyNames() {
        for phase in StartupPhaseLog.Phase.allCases {
            XCTAssertNotNil(
                phase.rawValue.wholeMatch(of: #/^[a-zA-Z]+$/#),
                "phase name must be letters only: \(phase.rawValue)"
            )
        }
    }

    /// The restore span records the switch request's actual outcome as a bounded
    /// integer code, not a discarded result or a logged string.
    func testSwitchOutcomeMappingCoversEverySwitchResult() {
        XCTAssertEqual(StartupPhaseLog.SwitchOutcome(.switched), .accepted)
        XCTAssertEqual(StartupPhaseLog.SwitchOutcome(.blocked("busy")), .blocked)
        XCTAssertEqual(StartupPhaseLog.SwitchOutcome(.cancelled("superseded")), .cancelled)
        XCTAssertEqual(
            Set(
                [
                    StartupPhaseLog.SwitchOutcome.accepted.rawValue,
                    StartupPhaseLog.SwitchOutcome.blocked.rawValue,
                    StartupPhaseLog.SwitchOutcome.cancelled.rawValue
                ]
            ).count,
            3
        )
    }
}
