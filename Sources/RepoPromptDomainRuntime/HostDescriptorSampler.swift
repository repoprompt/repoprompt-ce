import Darwin
import Foundation

/// The sizing syscall is only an estimate: descriptors can open before the fill call.
/// Confine retries and cached observations to this lock; never probe on leaf acquisition.
final class HostDescriptorSampler: @unchecked Sendable {
    typealias Query = (UnsafeMutableRawPointer?, Int32) -> Int32
    static let shared = HostDescriptorSampler()
    private let lock = NSLock()
    private var previousCount: Int?
    private static let maximumCount = 65536

    func sample(query: Query = { buffer, size in
        proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, buffer, size)
    }) -> Int? {
        lock.withLock {
            let stride = MemoryLayout<proc_fdinfo>.stride
            let estimateBytes = query(nil, 0)
            guard estimateBytes > 0 else { return previousCount }
            // An extra entry distinguishes a complete, unchanged count from truncation.
            var count = min(Self.maximumCount, Int(estimateBytes) / stride + 1)
            while true {
                var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
                let bytes = buffer.withUnsafeMutableBytes { query($0.baseAddress, Int32($0.count)) }
                guard bytes > 0, Int(bytes) % stride == 0 else { return previousCount }
                if Int(bytes) < count * stride {
                    previousCount = Int(bytes) / stride
                    return previousCount
                }
                if count == Self.maximumCount {
                    // At the allocation ceiling the populated buffer proves only a lower
                    // bound, not RLIMIT_NOFILE exhaustion. Never discard a higher prior
                    // observation (which could correctly indicate scarce descriptors).
                    previousCount = max(count, previousCount ?? 0)
                    return previousCount
                }
                count = min(Self.maximumCount, count * 2)
            }
        }
    }
}
