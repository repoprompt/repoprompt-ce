import Darwin
import Foundation

/// A single visible sample owns the kernel's thread rights and array only until capture returns.
enum ActivityThreadSampler {
    static let caveat = "Top five other threads by interval CPU; threads are not windows or agents. New or exited threads have incomplete intervals."
    struct Counters {
        let cpuNs: UInt64
        let sampledAt: UInt64
    }

    struct Row: Identifiable {
        let id: UInt64
        let name: String
        let cpu: Double

        var label: String {
            "\(name) (thread \(id))"
        }

        var cpuText: String {
            ActivityDisplay.number(cpu, decimals: 1) + "%"
        }
    }

    struct Report {
        let rows: [Row]
        let incomplete: Int
        let otherThreadCount: Int

        var summary: String {
            "\(otherThreadCount) other threads; \(incomplete) incomplete intervals"
        }
    }

    struct Capture {
        let counters: [UInt64: Counters]
        let report: Report
    }

    struct Ranking {
        let rates: [(id: UInt64, cpu: Double)]
        let incomplete: Int
    }

    static func rank(current: [UInt64: Counters], previous: [UInt64: Counters], excluding mainID: UInt64) -> Ranking {
        var rates: [(id: UInt64, cpu: Double)] = []
        var incomplete = previous.keys.count(where: { $0 != mainID && current[$0] == nil })
        for (id, now) in current where id != mainID {
            guard let before = previous[id], now.cpuNs >= before.cpuNs, now.sampledAt > before.sampledAt else {
                incomplete += 1
                continue
            }
            rates.append((id, 100 * Double(now.cpuNs - before.cpuNs) / Double(now.sampledAt - before.sampledAt)))
        }
        rates.sort { $0.cpu == $1.cpu ? $0.id < $1.id : $0.cpu > $1.cpu }
        return Ranking(rates: Array(rates.prefix(5)), incomplete: incomplete)
    }

    static func capture(mainThread: thread_act_t, previous: [UInt64: Counters]) -> Capture? {
        var main = thread_identifier_info_data_t()
        guard read(mainThread, flavor: THREAD_IDENTIFIER_INFO, into: &main) else { return nil }
        var ports: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &ports, &count) == KERN_SUCCESS, let ports else { return nil }
        defer {
            for index in 0 ..< Int(count) {
                let result = mach_port_deallocate(mach_task_self_, ports[index])
                assert(result == KERN_SUCCESS, "Thread sample send right was not released")
            }
            let result = vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: ports)), vm_size_t(count) * vm_size_t(MemoryLayout<thread_act_t>.stride))
            assert(result == KERN_SUCCESS, "Thread sample VM array was not released")
        }
        var current: [UInt64: Counters] = [:]
        var byID: [UInt64: thread_act_t] = [:]
        current.reserveCapacity(Int(count))
        byID.reserveCapacity(Int(count))
        var failed = 0
        for index in 0 ..< Int(count) {
            let port = ports[index]
            var identity = thread_identifier_info_data_t()
            var basic = thread_basic_info_data_t()
            guard read(port, flavor: THREAD_IDENTIFIER_INFO, into: &identity),
                  read(port, flavor: THREAD_BASIC_INFO, into: &basic),
                  basic.user_time.seconds >= 0, basic.system_time.seconds >= 0,
                  basic.user_time.microseconds >= 0, basic.system_time.microseconds >= 0
            else {
                failed += 1
                continue
            }
            let cpu = (UInt64(basic.user_time.seconds) + UInt64(basic.system_time.seconds)) * 1_000_000_000
                + (UInt64(basic.user_time.microseconds) + UInt64(basic.system_time.microseconds)) * 1000
            current[identity.thread_id] = Counters(cpuNs: cpu, sampledAt: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
            byID[identity.thread_id] = port
        }
        let ranking = rank(current: current, previous: previous, excluding: main.thread_id)
        let rows = ranking.rates.map { value in
            var name = "Unnamed"
            if let port = byID[value.id] {
                var extended = thread_extended_info_data_t()
                if read(port, flavor: THREAD_EXTENDED_INFO, into: &extended) {
                    let text = withUnsafeBytes(of: &extended.pth_name) {
                        String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
                    }.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                    if !text.isEmpty { name = text }
                }
            }
            return Row(id: value.id, name: name, cpu: value.cpu)
        }
        return Capture(counters: current, report: Report(rows: rows, incomplete: ranking.incomplete + failed, otherThreadCount: max(0, Int(count) - 1)))
    }

    private static func read<T>(_ port: thread_act_t, flavor: Int32, into value: inout T) -> Bool {
        var count = mach_msg_type_number_t(MemoryLayout<T>.size / MemoryLayout<integer_t>.size)
        return withUnsafeMutablePointer(to: &value) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(flavor), $0, &count) == KERN_SUCCESS
            }
        }
    }
}
