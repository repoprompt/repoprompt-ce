import Foundation

public struct MCPNewlineFrameTooLargeError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public let maximumByteCount: Int
    public let accumulatedByteCount: Int

    public init(maximumByteCount: Int, accumulatedByteCount: Int) {
        self.maximumByteCount = maximumByteCount
        self.accumulatedByteCount = accumulatedByteCount
    }

    public var description: String {
        "MCP newline-delimited frame exceeds byte limit (accumulated=\(accumulatedByteCount), maximum=\(maximumByteCount))"
    }

    public var errorDescription: String? {
        description
    }
}

/// Cursor-based storage for newline-delimited MCP frames.
/// Returned frames are independent `Data` values copied from the accumulator storage.
public struct MCPNewlineFrameAccumulator: Sendable {
    /// MCP responses can contain complete files or Git output. This ceiling is deliberately
    /// above the repository's 128 MiB legitimate Git-output limits plus JSON framing overhead.
    public static let defaultMaximumFrameByteCount = 256 * 1024 * 1024

    public static let defaultCompactionThresholdByteCount = 64 * 1024

    public let maximumFrameByteCount: Int
    private let delimiter: UInt8
    private let bufferReservation: Int
    private let compactionThreshold: Int

    private var buffer: Data
    private var frameStartOffset = 0
    private var searchStartOffset = 0

    public init(
        delimiter: UInt8 = UInt8(ascii: "\n"),
        maximumFrameByteCount: Int = Self.defaultMaximumFrameByteCount,
        bufferReservation: Int = 64 * 1024,
        compactionThreshold: Int = Self.defaultCompactionThresholdByteCount
    ) {
        self.delimiter = delimiter
        self.maximumFrameByteCount = max(1, maximumFrameByteCount)
        self.bufferReservation = max(0, bufferReservation)
        self.compactionThreshold = max(1, compactionThreshold)
        buffer = Data(capacity: max(0, bufferReservation))
    }

    public var residualByteCount: Int {
        buffer.count - frameStartOffset
    }

    public var hasResidualData: Bool {
        residualByteCount > 0
    }

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func append(_ byte: UInt8) {
        buffer.append(byte)
    }

    public mutating func append(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let baseAddress = bytes.baseAddress, !bytes.isEmpty else { return }
        buffer.append(baseAddress, count: bytes.count)
    }

    /// Returns the next complete payload without its delimiter.
    /// A missing delimiter is accepted while the residual payload is at or below the cap.
    public mutating func nextFrame() throws -> Data? {
        let searchStart = buffer.index(buffer.startIndex, offsetBy: searchStartOffset)
        if let delimiterIndex = buffer[searchStart...].firstIndex(of: delimiter) {
            let frameByteCount = buffer.distance(
                from: buffer.index(buffer.startIndex, offsetBy: frameStartOffset),
                to: delimiterIndex
            )
            guard frameByteCount <= maximumFrameByteCount else {
                throw MCPNewlineFrameTooLargeError(
                    maximumByteCount: maximumFrameByteCount,
                    accumulatedByteCount: frameByteCount
                )
            }

            let frameStart = buffer.index(buffer.startIndex, offsetBy: frameStartOffset)
            let frame = buffer.subdata(in: frameStart ..< delimiterIndex)
            let nextStart = buffer.index(after: delimiterIndex)
            frameStartOffset = buffer.distance(from: buffer.startIndex, to: nextStart)
            searchStartOffset = frameStartOffset
            compactIfNeeded()
            return frame
        }

        searchStartOffset = buffer.count
        let accumulatedByteCount = residualByteCount
        guard accumulatedByteCount <= maximumFrameByteCount else {
            throw MCPNewlineFrameTooLargeError(
                maximumByteCount: maximumFrameByteCount,
                accumulatedByteCount: accumulatedByteCount
            )
        }
        return nil
    }

    public mutating func reset(keepingCapacity: Bool = true) {
        if keepingCapacity {
            buffer.removeAll(keepingCapacity: true)
        } else {
            buffer = Data(capacity: bufferReservation)
        }
        frameStartOffset = 0
        searchStartOffset = 0
    }

    private mutating func compactIfNeeded() {
        guard frameStartOffset > 0 else { return }
        if frameStartOffset == buffer.count {
            reset(keepingCapacity: frameStartOffset < compactionThreshold)
            return
        }

        let remainingByteCount = residualByteCount
        guard frameStartOffset >= compactionThreshold,
              frameStartOffset >= remainingByteCount
        else {
            return
        }

        let remainingStart = buffer.index(buffer.startIndex, offsetBy: frameStartOffset)
        buffer = buffer.subdata(in: remainingStart ..< buffer.endIndex)
        frameStartOffset = 0
        searchStartOffset = 0
    }

    var storageByteCount: Int {
        buffer.count
    }

    var consumedPrefixByteCount: Int {
        frameStartOffset
    }
}
