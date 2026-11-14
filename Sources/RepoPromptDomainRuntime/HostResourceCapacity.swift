import Darwin
import Foundation

package struct HostResourceSample: Equatable {
    package enum Pressure: Int { case normal, warning, critical }
    package let logicalCores: Int
    package let performanceCores: Int
    package let memoryBytes: UInt64
    package let memoryPressure: Pressure
    package let thermalPressure: Pressure
    package let descriptorLimit: Int
    package let openDescriptors: Int
    /// Free + inactive pages: reclaimable/compressible estimate, not guaranteed free RAM.
    package let availableMemoryBytes: UInt64?
    package let memoryGrowthBytesPerSecond: UInt64

    package init(
        logicalCores: Int,
        performanceCores: Int,
        memoryBytes: UInt64,
        memoryPressure: Pressure = .normal,
        thermalPressure: Pressure = .normal,
        descriptorLimit: Int,
        openDescriptors: Int,
        availableMemoryBytes: UInt64? = nil,
        memoryGrowthBytesPerSecond: UInt64 = 0
    ) {
        self.logicalCores = logicalCores
        self.performanceCores = performanceCores
        self.memoryBytes = memoryBytes
        self.memoryPressure = memoryPressure
        self.thermalPressure = thermalPressure
        self.descriptorLimit = descriptorLimit
        self.openDescriptors = openDescriptors
        self.availableMemoryBytes = availableMemoryBytes
        self.memoryGrowthBytesPerSecond = memoryGrowthBytesPerSecond
    }
}

/// Resource envelopes, not independent per-call pools. All leaf kinds also consume `total`.
package struct HostResourceCapacity: Equatable {
    package let total: Int
    package let cpu: Int
    package let io: Int
    package let subprocess: Int
    package let background: Int
    package let connections: Int
    package let descriptorBudget: Int
    package let retainedContent: Int

    // A headless read can own a slot fd plus path-walk/read descriptors. Git can
    // transiently own both ends of three pipes before spawn closes child ends.
    package static let ioDescriptorCost = 4
    package static let subprocessDescriptorCost = 6

    /// Outer fan-out ignores transient pressure and open descriptors; only hardware/soft
    /// descriptor limits shape lifetime defaults. Live headroom is enforced at leaves.
    package static let baseline = resolve(HostResourceMonitor.sample(memoryPressure: .normal, unpressured: true))

    package static func resolve(_ sample: HostResourceSample) -> Self {
        // Foreground bursts may use logical cores, but never multiply across callers.
        // Performance-core count shapes the background share, not an artificial foreground cap.
        let logical = max(1, sample.logicalCores)
        let critical = sample.memoryPressure == .critical || sample.thermalPressure == .critical
        let cpu = critical ? 1 : sample.thermalPressure == .warning ? max(1, logical / 2) : logical
        // Warning alone is informational. Apply measured headroom and recent compression /
        // swapout growth instead. Do not credit unused reservations as resident memory:
        // doing so would defeat backoff while a busy process is on a stressed host.
        let staticBudget = sample.memoryBytes / 4
        let available = sample.availableMemoryBytes ?? staticBudget
        let memoryReserve = sample.memoryBytes / 32
        let debt = min(sample.memoryGrowthBytesPerSecond, sample.memoryBytes) * 2
        let estimated = min(sample.memoryBytes, available)
        let usable = estimated > memoryReserve + debt ? estimated - memoryReserve - debt : 0
        let workingBudget = min(staticBudget, usable)
        let memorySlots = max(1, Int(clamping: workingBudget / 2 / (64 * 1024 * 1024)))
        // Leave descriptor headroom for transports, persistence and the UI. A process needs
        // stdin/stdout/stderr pipes plus temporary/spool files; reads need fewer descriptors.
        let reserve = max(64, sample.descriptorLimit / 8)
        let freeDescriptors = max(0, sample.descriptorLimit - sample.openDescriptors)
        let headroom = max(0, freeDescriptors - reserve)
        // Preserve progress inside the reserve when there is physically enough space.
        // Zero is reserved for actual exhaustion, not a conservative slack estimate.
        let ioSlots = freeDescriptors >= ioDescriptorCost ? max(1, headroom / ioDescriptorCost) : 0
        let processSlots = freeDescriptors >= subprocessDescriptorCost ? max(1, headroom / subprocessDescriptorCost) : 0
        let effectiveTotal = critical ? 1 : min(logical, memorySlots)
        let effectiveCPU = min(effectiveTotal, cpu)
        return Self(
            total: effectiveTotal,
            cpu: effectiveCPU,
            io: min(effectiveTotal, ioSlots),
            subprocess: min(effectiveCPU, processSlots),
            background: critical ? 0 : max(1, min(effectiveTotal - 1, sample.performanceCores, effectiveCPU / 2)),
            // One live transport descriptor/connection, plus the shared reserve above.
            // Retain the existing 128-client ingress/flood ceiling until larger client
            // populations are measured; CPU scaling is not grounds to multiply clients.
            connections: max(1, min(
                128, Int(clamping: sample.memoryBytes / 16 / (1024 * 1024)),
                max(0, sample.descriptorLimit - reserve)
            )),
            // Descriptor classes also share this weighted envelope; independent class
            // limits must not each spend the same remaining descriptor headroom.
            descriptorBudget: max(headroom, min(freeDescriptors, subprocessDescriptorCost)),
            // A newline-heavy 10 MB file can build ~320 MB of line-index arrays
            // (NSRange + UTF-16/UTF-8 starts). Retain a 512 MiB envelope per search
            // pipeline, separately from the smaller physical-read working envelope.
            retainedContent: critical ? 1 : max(1, Int(clamping: workingBudget / 2 / (512 * 1024 * 1024)))
        )
    }
}

/// One event source for memory pressure and a low-frequency descriptor/thermal refresh.
/// No polling tasks are created per waiter. An exhausted descriptor class suspends until
/// headroom recovers, while CPU-only work remains able to progress.
final class HostResourceMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "repoprompt.host-resource-capacity", qos: .utility)
    private let memorySource: DispatchSourceMemoryPressure
    private let timer: DispatchSourceTimer
    private var pressure = HostResourceMonitor.currentMemoryPressure(fallback: .normal) // confined to queue
    private var recovery = HostResourceRecovery()
    private let activityLock = NSLock()
    private var busy = false
    private var refreshPending = false
    private var lastRefresh = DispatchTime.now().uptimeNanoseconds
    private var previousMemory: (time: UInt64, pages: UInt64)? // confined to queue
    private var previousGrowth: UInt64 = 0 // confined to queue

    init(onChange: @escaping @Sendable (HostResourceCapacity) -> Void) {
        memorySource = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        timer = DispatchSource.makeTimerSource(queue: queue)
        memorySource.setEventHandler { [weak self] in
            guard let self else { return }
            let event = memorySource.data
            pressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            refresh(onChange)
        }
        timer.setEventHandler { [weak self] in
            guard let self, activityLock.withLock({ busy || refreshPending }) else { return }
            refresh(onChange)
        }
        // One cheap activity check every two seconds; expensive probes skip idle periods.
        // No dispatch submission, timer re-arm or sysctl on the normal acquire/release path.
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2), leeway: .milliseconds(250))
        memorySource.resume()
        timer.resume()
    }

    /// Called only on budget busy/idle edges. Queue submission is nonblocking;
    /// the budget serializes edge publication under its own lock.
    func setBusy(_ next: Bool) {
        activityLock.withLock {
            busy = next
            // Coalesce a stale reactivation with the next timer tick. Memory events remain
            // immediate while idle. The first burst is bounded by the cached envelope.
            if next, DispatchTime.now().uptimeNanoseconds - lastRefresh >= 2_000_000_000 {
                refreshPending = true
            }
        }
    }

    deinit {
        memorySource.cancel()
        timer.cancel()
    }

    private func refresh(_ onChange: @Sendable (HostResourceCapacity) -> Void) {
        pressure = Self.currentMemoryPressure(fallback: pressure)
        let now = DispatchTime.now().uptimeNanoseconds
        let memory = Self.memorySnapshot()
        if let memory {
            let elapsed = previousMemory.map { now - $0.time }
            if let previousMemory, let elapsed, elapsed >= 1_000_000_000, elapsed <= 5_000_000_000 {
                let delta = memory.growthPages >= previousMemory.pages ? memory.growthPages - previousMemory.pages : 0
                previousGrowth = UInt64(min(Double(ProcessInfo.processInfo.physicalMemory), Double(delta) * Double(Self.pageBytes) * 1_000_000_000 / Double(elapsed)))
            } else if elapsed == nil || (elapsed ?? 0) > 5_000_000_000 {
                previousGrowth = 0
            }
            // Closely spaced pressure events reuse the previous rate, rather than
            // amplifying a sub-second compression spike into two seconds of debt.
            if elapsed == nil || (elapsed ?? 0) >= 1_000_000_000 { previousMemory = (now, memory.growthPages) }
        }
        let next = HostResourceCapacity.resolve(Self.sample(memoryPressure: pressure, memory: memory, growth: previousGrowth))
        onChange(recovery.ingest(next, now: now))
        activityLock.withLock { lastRefresh = now
            refreshPending = false
        }
    }

    static func currentMemoryPressure(fallback: HostResourceSample.Pressure) -> HostResourceSample.Pressure {
        var raw: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &raw, &size, nil, 0) == 0 else { return fallback }
        let event = DispatchSource.MemoryPressureEvent(rawValue: UInt(raw))
        return event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
    }

    private static let pageBytes: UInt64 = {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var size: vm_size_t = 0
        return host_page_size(host, &size) == KERN_SUCCESS ? UInt64(size) : UInt64(max(1, sysconf(_SC_PAGESIZE)))
    }()

    struct MemorySnapshot {
        let available: UInt64
        let growthPages: UInt64
    }

    static func memorySnapshot() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        // Speculative pages are ALREADY in free_count. Inactive includes compressible
        // anonymous pages, so this is only an estimate; growth debt and critical events
        // cover the case where reclaiming those pages is itself stressing the host.
        return MemorySnapshot(
            available: (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * pageBytes,
            growthPages: stats.compressions &+ stats.swapouts
        )
    }

    static func sample(
        memoryPressure: HostResourceSample.Pressure,
        unpressured: Bool = false,
        memory: MemorySnapshot? = nil,
        growth: UInt64 = 0
    ) -> HostResourceSample {
        let info = ProcessInfo.processInfo
        var performanceCores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &performanceCores, &size, nil, 0) != 0 {
            performanceCores = Int32(clamping: info.activeProcessorCount)
        }
        var descriptors = rlimit()
        let limit = getrlimit(RLIMIT_NOFILE, &descriptors) == 0 ? Int(clamping: descriptors.rlim_cur) : 256
        // The nil-buffer call returns an allocation estimate, NOT the number of open fds.
        // Use the populated buffer's returned byte count. Bound allocation even if the
        // process has an exceptionally large soft limit; uncertainty throttles safely.
        let descriptorBytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        let stride = MemoryLayout<proc_fdinfo>.stride
        let bufferCount = min(65536, max(32, Int(max(0, descriptorBytes)) / stride + 32))
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: bufferCount)
        let actualBytes = buffer.withUnsafeMutableBytes { bytes in
            proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, bytes.baseAddress, Int32(clamping: bytes.count))
        }
        let openCount = actualBytes > 0 && Int(actualBytes) < bufferCount * stride
            ? Int(actualBytes) / stride : limit // Unknown/truncated headroom must not manufacture free fds.
        let thermal: HostResourceSample.Pressure = switch info.thermalState {
        case .nominal, .fair: .normal
        case .serious: .warning
        case .critical: .critical
        @unknown default: .warning
        }
        return HostResourceSample(
            logicalCores: info.activeProcessorCount, performanceCores: max(1, Int(performanceCores)),
            memoryBytes: info.physicalMemory, memoryPressure: memoryPressure,
            thermalPressure: unpressured ? .normal : thermal, descriptorLimit: limit,
            openDescriptors: unpressured ? 0 : openCount,
            availableMemoryBytes: unpressured ? nil : (memory ?? memorySnapshot())?.available,
            memoryGrowthBytesPerSecond: unpressured ? 0 : growth
        )
    }
}
