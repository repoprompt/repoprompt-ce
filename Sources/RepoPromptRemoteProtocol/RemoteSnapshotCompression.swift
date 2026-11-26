import Compression
import Foundation

enum RemoteSnapshotCompression {
    static func encode(_ source: Data) -> Data? {
        let capacity = source.count
        guard (1 ... RemoteWireProtocol.maximumSnapshotJSONBytes).contains(capacity) else { return nil }
        var destination = Data(count: capacity)
        let written = destination.withUnsafeMutableBytes { output in
            source.withUnsafeBytes { input in
                guard let output = output.bindMemory(to: UInt8.self).baseAddress,
                      let input = input.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_encode_buffer(output, capacity, input, source.count, nil, COMPRESSION_LZFSE)
            }
        }
        // Leave room for the extra metadata and keep small or incompressible responses in the old format.
        guard written > 0, written + 32 < capacity else { return nil }
        destination.count = written
        return destination
    }

    static func decode(_ source: Data, expectedBytes: Int) throws -> Data {
        guard (1 ... RemoteWireProtocol.maximumSnapshotJSONBytes).contains(expectedBytes),
              !source.isEmpty, source.count < expectedBytes
        else { throw RemoteWireContractError.malformedPayload }

        // One spare byte distinguishes an exact decode from filling a truncated destination buffer.
        let capacity = expectedBytes + 1
        var destination = Data(count: capacity)
        let written = destination.withUnsafeMutableBytes { output in
            source.withUnsafeBytes { input in
                guard let output = output.bindMemory(to: UInt8.self).baseAddress,
                      let input = input.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(output, capacity, input, source.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written == expectedBytes else { throw RemoteWireContractError.malformedPayload }
        destination.count = written
        return destination
    }
}
