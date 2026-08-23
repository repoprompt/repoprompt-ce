import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

/// A deterministic PackBits-style codec used for immutable archive segments.
/// Literal blocks and repeated-byte blocks are bounded to 128 bytes, which keeps
/// decoding allocation-bounded and avoids a platform compression dependency.
enum EventArchiveCompression {
    static let algorithm = "packbits-v1"
    static let maximumDecodedBytes = 512 * 1024 * 1024

    /// PackBits emits at most one control byte for each 128-byte literal block.
    /// Repeated-byte blocks are smaller, so this is a strict format bound.
    static func maximumCompressedBytes(forInputBytes inputBytes: Int) -> Int {
        guard inputBytes > 0 else { return 0 }
        return inputBytes + ((inputBytes + 127) / 128)
    }

    static func compress(_ input: Data) -> Data {
        let bytes = [UInt8](input)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            var run = 1
            while index + run < bytes.count, bytes[index + run] == bytes[index], run < 128 {
                run += 1
            }
            if run >= 3 {
                output.append(UInt8(257 - run))
                output.append(bytes[index])
                index += run
                continue
            }
            let literalStart = index
            index += run
            while index < bytes.count, index - literalStart < 128 {
                var nextRun = 1
                while index + nextRun < bytes.count, bytes[index + nextRun] == bytes[index], nextRun < 128 {
                    nextRun += 1
                }
                if nextRun >= 3 || index + nextRun - literalStart > 128 { break }
                index += nextRun
            }
            let literalCount = index - literalStart
            output.append(UInt8(literalCount - 1))
            output.append(contentsOf: bytes[literalStart ..< literalStart + literalCount])
        }
        return Data(output)
    }

    static func decompress(_ input: Data, maximumBytes: Int = maximumDecodedBytes) throws -> Data {
        let bytes = [UInt8](input)
        var output: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let control = Int(bytes[index])
            index += 1
            if control <= 127 {
                let count = control + 1
                guard index + count <= bytes.count else { throw archiveError("literal block is truncated") }
                guard output.count <= maximumBytes - count else { throw archiveError("decoded archive exceeds limit") }
                output.append(contentsOf: bytes[index ..< index + count])
                index += count
            } else if control >= 129 {
                let count = 257 - control
                guard index < bytes.count else { throw archiveError("repeat block is truncated") }
                guard output.count <= maximumBytes - count else { throw archiveError("decoded archive exceeds limit") }
                output.append(contentsOf: repeatElement(bytes[index], count: count))
                index += 1
            }
        }
        return Data(output)
    }

    private static func archiveError(_ detail: String) -> ServiceAPIError {
        ServiceAPIError(code: .persistenceUnavailable, message: "Compressed event archive is invalid: \(detail)", retryable: false)
    }
}

public struct EventRetentionPolicy: Hashable, Sendable {
    public let minimumLiveEventCount: Int64
    public let minimumLiveAge: TimeInterval
    public let maximumArchiveBatch: Int

    public init(
        minimumLiveEventCount: Int64 = 100_000,
        minimumLiveAge: TimeInterval = 30 * 24 * 60 * 60,
        maximumArchiveBatch: Int = 10_000
    ) {
        self.minimumLiveEventCount = max(0, minimumLiveEventCount)
        self.minimumLiveAge = max(0, minimumLiveAge)
        self.maximumArchiveBatch = max(1, maximumArchiveBatch)
    }

    /// Events are eligible only when they fall outside both the count and age windows.
    public func eligibleThrough(latestSequence: Int64, ageEligibleThrough: Int64, replayFloor: Int64) -> Int64? {
        let countEligibleThrough = latestSequence - minimumLiveEventCount
        let eligible = min(countEligibleThrough, ageEligibleThrough)
        guard eligible > replayFloor else { return nil }
        return min(eligible, replayFloor + Int64(maximumArchiveBatch))
    }
}
