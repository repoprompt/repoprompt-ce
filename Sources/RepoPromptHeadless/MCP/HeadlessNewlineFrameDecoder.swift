import Foundation

struct HeadlessNewlineFrameDecoder {
    enum Event: Equatable {
        case frame(Data)
        case parseError(message: String)
    }

    static let defaultMaximumFrameBytes = 1024 * 1024

    private let maximumFrameBytes: Int
    private var pendingFrame = Data()
    private var isDiscardingOversizedFrame = false

    init(maximumFrameBytes: Int = Self.defaultMaximumFrameBytes) {
        precondition(maximumFrameBytes > 0)
        self.maximumFrameBytes = maximumFrameBytes
    }

    mutating func append(_ data: Data) -> [Event] {
        var events: [Event] = []
        for byte in data {
            if isDiscardingOversizedFrame {
                if byte == 0x0A {
                    isDiscardingOversizedFrame = false
                }
                continue
            }

            if byte == 0x0A {
                if pendingFrame.last == 0x0D {
                    pendingFrame.removeLast()
                }
                if !pendingFrame.isEmpty {
                    events.append(.frame(pendingFrame))
                }
                pendingFrame.removeAll(keepingCapacity: true)
                continue
            }

            guard pendingFrame.count < maximumFrameBytes else {
                events.append(.parseError(message: oversizedFrameMessage))
                pendingFrame.removeAll(keepingCapacity: true)
                isDiscardingOversizedFrame = true
                continue
            }
            pendingFrame.append(byte)
        }
        return events
    }

    mutating func finish() -> [Event] {
        defer {
            pendingFrame.removeAll(keepingCapacity: false)
            isDiscardingOversizedFrame = false
        }

        guard !isDiscardingOversizedFrame, !pendingFrame.isEmpty else {
            return []
        }
        guard !pendingFrame.allSatisfy(Self.isASCIIWhitespace) else {
            return []
        }
        return [.parseError(message: "Incomplete newline-delimited JSON-RPC frame at EOF.")]
    }

    private var oversizedFrameMessage: String {
        "JSON-RPC frame exceeds headless maximum of \(maximumFrameBytes) bytes."
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (0x09 ... 0x0D).contains(byte)
    }
}
