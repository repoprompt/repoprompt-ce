import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Queue-owned newline framing shared by app and CLI transports. An incomplete frame's
/// prefix is searched only once, rather than again after every socket chunk or pump pass.
package struct MCPNewlineFrameBuffer {
    private var storage = Data()
    private var searchedPrefixCount = 0
    private let delimiter: UInt8
    #if DEBUG
        /// Deterministic amortized-work oracle, not a timing budget.
        package private(set) var inspectedByteCount = 0
    #endif

    package init(delimiter: UInt8 = 0x0A, capacity: Int = 0) {
        self.delimiter = delimiter
        storage.reserveCapacity(capacity)
    }

    package var isEmpty: Bool {
        storage.isEmpty
    }

    package var count: Int {
        storage.count
    }

    package mutating func append(_ bytes: UnsafePointer<UInt8>, count: Int) {
        storage.append(bytes, count: count)
    }

    package mutating func append(contentsOf bytes: some Sequence<UInt8>) {
        storage.append(contentsOf: bytes)
    }

    package mutating func nextFrame() -> Data? {
        guard searchedPrefixCount < storage.count else { return nil }
        let offset: Int? = storage.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress,
                  let found = memchr(base.advanced(by: searchedPrefixCount), Int32(delimiter), bytes.count - searchedPrefixCount)
            else { return nil }
            return base.distance(to: UnsafeRawPointer(found))
        }
        #if DEBUG
            inspectedByteCount += offset.map { $0 + 1 - searchedPrefixCount } ?? (storage.count - searchedPrefixCount)
        #endif
        guard let offset else {
            searchedPrefixCount = storage.count
            return nil
        }
        let newline = storage.index(storage.startIndex, offsetBy: offset)
        let frame = Data(storage[..<newline])
        storage.removeSubrange(..<storage.index(after: newline))
        searchedPrefixCount = 0
        return frame
    }

    package mutating func removeAll(keepingCapacity: Bool) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        searchedPrefixCount = 0
        #if DEBUG
            inspectedByteCount = 0
        #endif
    }
}
