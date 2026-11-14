import Darwin
@testable import RepoPromptDomainRuntime
import XCTest

final class HostDescriptorSamplerTests: XCTestCase {
    private let stride = MemoryLayout<proc_fdinfo>.stride

    private func capacity(open: Int?, limit: Int = 4096, cached: HostResourceCapacity? = nil) -> HostResourceCapacity {
        HostResourceCapacity.resolve(HostResourceSample(
            logicalCores: 8, performanceCores: 4, memoryBytes: 24 * 1024 * 1024 * 1024,
            descriptorLimit: limit, openDescriptors: open
        ), cachedCapacity: cached)
    }

    func testBurstBeyondSizingSlackRetriesGeometricallyUntilComplete() {
        let sampler = HostDescriptorSampler()
        var counts: [Int] = []
        let count = sampler.sample { buffer, bytes in
            guard buffer != nil else { return Int32(2 * self.stride) }
            let capacity = Int(bytes) / self.stride
            counts.append(capacity)
            return Int32(min(90, capacity) * self.stride)
        }
        XCTAssertEqual(counts, [3, 6, 12, 24, 48, 96])
        XCTAssertEqual(count, 90)
        XCTAssertEqual(capacity(open: count).io, 8)
        XCTAssertEqual(capacity(open: count).subprocess, 8)
    }

    func testFailureCarriesForwardLastCountIncludingRealExhaustion() {
        for goodCount in [64, 4094, 4096] {
            let sampler = HostDescriptorSampler()
            XCTAssertEqual(sampler.sample { buffer, _ in
                Int32((buffer == nil ? goodCount + 1 : goodCount) * self.stride)
            }, goodCount)
            let expected = capacity(open: goodCount)
            // Failure during either syscall must not invent exhaustion OR free space.
            XCTAssertEqual(capacity(open: sampler.sample { _, _ in -1 }), expected)
            XCTAssertEqual(capacity(open: sampler.sample { buffer, _ in
                buffer == nil ? Int32(100 * self.stride) : -1
            }), expected)
            XCTAssertEqual(capacity(open: sampler.sample { _, _ in 0 }), expected)
        }
    }

    func testFailureAfterTruncationAlsoCarriesForwardCount() {
        let sampler = HostDescriptorSampler()
        XCTAssertEqual(sampler.sample { _, _ in Int32(64 * self.stride) }, 64)
        var fills = 0
        let result = sampler.sample { buffer, bytes in
            guard buffer != nil else { return Int32(self.stride) }
            fills += 1
            return fills == 1 ? bytes : -1
        }
        XCTAssertEqual(fills, 2)
        XCTAssertEqual(result, 64)
    }

    func testFirstFailurePreservesCachedEnvelopeAndStillHonorsLowerSoftLimit() {
        let sampler = HostDescriptorSampler()
        let unknown = sampler.sample { _, _ in -1 }
        XCTAssertNil(unknown)
        for cached in [capacity(open: 64), capacity(open: 4094), capacity(open: 4096)] {
            XCTAssertEqual(capacity(open: unknown, cached: cached), cached)
        }
        let lowered = capacity(open: unknown, limit: 3, cached: capacity(open: 64))
        XCTAssertEqual(lowered.io, 0)
        XCTAssertEqual(lowered.subprocess, 0)
        XCTAssertLessThanOrEqual(lowered.descriptorBudget, 3)
        XCTAssertGreaterThan(lowered.cpu, 0)
    }

    func testAllocationCeilingIsLowerBoundNotSoftLimitExhaustion() {
        let sampler = HostDescriptorSampler()
        var counts: [Int] = []
        let result = sampler.sample { buffer, bytes in
            guard buffer != nil else { return Int32(self.stride) }
            counts.append(Int(bytes) / self.stride)
            return bytes // every buffer fills, including the final bounded allocation
        }
        XCTAssertEqual(counts, (1 ... 16).map { 1 << $0 })
        XCTAssertEqual(result, 65536)
        XCTAssertEqual(capacity(open: result, limit: 262_144).io, 8)
        let scarce = capacity(open: result, limit: 65540)
        XCTAssertEqual(scarce.io, 1)
        XCTAssertEqual(scarce.subprocess, 0)
        XCTAssertEqual(scarce.descriptorBudget, 4)
        let exhausted = capacity(open: result, limit: 65536)
        XCTAssertEqual(exhausted.io, 0)
        XCTAssertEqual(exhausted.subprocess, 0)
        XCTAssertEqual(exhausted.descriptorBudget, 0)
        XCTAssertEqual(sampler.sample { _, _ in -1 }, result)
        // A later complete observation must recover from the lower bound.
        XCTAssertEqual(sampler.sample { buffer, _ in
            Int32((buffer == nil ? 65 : 64) * self.stride)
        }, 64)
    }
}
