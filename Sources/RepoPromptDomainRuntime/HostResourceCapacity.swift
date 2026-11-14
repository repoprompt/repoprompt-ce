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

    package init(
        logicalCores: Int,
        performanceCores: Int,
        memoryBytes: UInt64,
        memoryPressure: Pressure = .normal,
        thermalPressure: Pressure = .normal,
        descriptorLimit: Int,
        openDescriptors: Int
    ) {
        self.logicalCores = logicalCores
        self.performanceCores = performanceCores
        self.memoryBytes = memoryBytes
        self.memoryPressure = memoryPressure
        self.thermalPressure = thermalPressure
        self.descriptorLimit = descriptorLimit
        self.openDescriptors = openDescriptors
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
        // Leave one logical processor for the UI/OS; performance cores are the CPU-work ceiling.
        let logical = max(1, sample.logicalCores)
        let total = max(1, logical - 1)
        let cpu = max(1, min(total, sample.performanceCores))
        // A 10 MB file may coexist as bytes, decoded text, line index and rendered output.
        // Reserve at most 1/16 of physical RAM for these 64 MiB active-work envelopes.
        let memorySlots = max(1, Int(clamping: sample.memoryBytes / 16 / (64 * 1024 * 1024)))
        // Leave descriptor headroom for transports, persistence and the UI. A process needs
        // stdin/stdout/stderr pipes plus temporary/spool files; reads need fewer descriptors.
        let reserve = max(64, sample.descriptorLimit / 8)
        let freeDescriptors = max(0, sample.descriptorLimit - sample.openDescriptors)
        let headroom = max(0, freeDescriptors - reserve)
        // Preserve progress inside the reserve when there is physically enough space.
        // Zero is reserved for actual exhaustion, not a conservative slack estimate.
        let ioSlots = freeDescriptors >= ioDescriptorCost ? max(1, headroom / ioDescriptorCost) : 0
        let processSlots = freeDescriptors >= subprocessDescriptorCost ? max(1, headroom / subprocessDescriptorCost) : 0
        let pressure = max(sample.memoryPressure.rawValue, sample.thermalPressure.rawValue)
        func reduced(_ value: Int) -> Int {
            switch pressure {
            case 0: max(1, value)
            case 1: max(1, value / 2)
            default: 1 // Continue bounded foreground progress; never revoke physical work.
            }
        }
        let effectiveTotal = reduced(min(total, memorySlots))
        let effectiveCPU = min(effectiveTotal, reduced(cpu))
        return Self(
            total: effectiveTotal,
            cpu: effectiveCPU,
            io: min(effectiveTotal, ioSlots),
            subprocess: min(effectiveCPU, processSlots),
            background: pressure == HostResourceSample.Pressure.critical.rawValue
                ? 0 : max(1, min(effectiveTotal - 1, effectiveCPU / 2)),
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
            retainedContent: reduced(max(1, Int(clamping: sample.memoryBytes / 16 / (512 * 1024 * 1024))))
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

    init(onChange: @escaping @Sendable (HostResourceCapacity) -> Void) {
        memorySource = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        timer = DispatchSource.makeTimerSource(queue: queue)
        memorySource.setEventHandler { [weak self] in
            guard let self else { return }
            let event = memorySource.data
            pressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            refresh(onChange)
        }
        timer.setEventHandler { [weak self] in self?.refresh(onChange) }
        timer.schedule(deadline: .distantFuture)
        memorySource.resume()
        timer.resume()
    }

    /// Called only on budget busy/idle edges. Queue submission is nonblocking;
    /// the budget serializes edge publication under its own lock.
    func setBusy(_ busy: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if busy {
                timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(250))
            } else {
                timer.schedule(deadline: .distantFuture)
            }
        }
    }

    deinit {
        memorySource.cancel()
        timer.cancel()
    }

    private func refresh(_ onChange: @Sendable (HostResourceCapacity) -> Void) {
        pressure = Self.currentMemoryPressure(fallback: pressure)
        let next = HostResourceCapacity.resolve(Self.sample(memoryPressure: pressure))
        onChange(recovery.ingest(next, now: DispatchTime.now().uptimeNanoseconds))
    }

    static func currentMemoryPressure(fallback: HostResourceSample.Pressure) -> HostResourceSample.Pressure {
        var raw: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &raw, &size, nil, 0) == 0 else { return fallback }
        let event = DispatchSource.MemoryPressureEvent(rawValue: UInt(raw))
        return event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
    }

    static func sample(memoryPressure: HostResourceSample.Pressure, unpressured: Bool = false) -> HostResourceSample {
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
            ? Int(actualBytes) / stride : limit / 2
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
            openDescriptors: unpressured ? 0 : openCount
        )
    }
}
