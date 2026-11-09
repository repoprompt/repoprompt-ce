import Darwin
import Foundation

/// Owns one send right captured on the main thread; never enumerates or suspends threads.
actor ActivityMainThreadSampler {
    private let mainThread: thread_act_t
    private var previous: Counters?

    struct Counters {
        let cpuNs: UInt64
        let sampledAt: UInt64
    }

    init(mainThread: thread_act_t) {
        self.mainThread = mainThread
    }

    deinit {
        mach_port_deallocate(mach_task_self_, mainThread)
    }

    func read() -> String {
        var info = thread_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(mainThread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        guard result == KERN_SUCCESS else {
            previous = nil
            return "Unavailable"
        }
        let cpuNs = (UInt64(info.user_time.seconds) + UInt64(info.system_time.seconds)) * 1_000_000_000
            + (UInt64(info.user_time.microseconds) + UInt64(info.system_time.microseconds)) * 1000
        let current = Counters(cpuNs: cpuNs, sampledAt: now)
        let text = Self.cpuText(previous: previous, current: current)
        previous = current
        return text
    }

    static func cpuText(previous: Counters?, current: Counters) -> String {
        guard let previous else { return "Measuring…" }
        guard current.sampledAt > previous.sampledAt, current.cpuNs >= previous.cpuNs else { return "Unavailable" }
        return ActivityDisplay.number(100 * Double(current.cpuNs - previous.cpuNs) / Double(current.sampledAt - previous.sampledAt), decimals: 1) + "%"
    }
}

/// The caller's SwiftUI task owns cancellation. Hidden views never activate the sampling closure.
@MainActor
enum ActivityRefreshLoop {
    static func run(
        visible: Bool,
        tick: () async -> Void,
        sleep: () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }
    ) async {
        guard visible, !Task.isCancelled else { return }
        while !Task.isCancelled {
            await tick()
            guard !Task.isCancelled else { return }
            do { try await sleep() } catch { return }
        }
    }
}
