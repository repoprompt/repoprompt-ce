import Compression
import Foundation
import zlib

/// ZIP central-directory admission before ditto sees any paths. Archive bytes
/// have already passed size, digest and Sparkle-signature checks. Keep this
/// parser deliberately narrow: reject encryption, split archives and ZIP64
/// rather than guessing at unsupported structures.
enum TipHistoryArchive {
    static let appName = "RepoPrompt CE.app"
    static let maximumEntries = 100_000
    static let maximumExpandedBytes: UInt64 = 8_589_934_592

    private struct Record {
        let path: String
        let parts: [String]
        let size: UInt64
        let compressed: UInt64
        let method: UInt16
        let flags: UInt16
        let localOffset: UInt64
        let isLink: Bool
        let isDirectory: Bool
    }

    @discardableResult
    static func validate(at url: URL, declaredExpandedSize: Int64) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length >= 22 else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
        let tailLength = min(length, 65557)
        try handle.seek(toOffset: length - tailLength)
        let tail = try read(handle, count: Int(tailLength))
        var end: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            if u32(tail, index) == 0x0605_4B50, index + 22 + Int(u16(tail, index + 20)) == tail.count {
                end = index
                break
            }
        }
        guard let end, u16(tail, end + 4) == 0, u16(tail, end + 6) == 0,
              u16(tail, end + 8) == u16(tail, end + 10)
        else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
        let count = Int(u16(tail, end + 10))
        let centralSize = UInt64(u32(tail, end + 12))
        let centralOffset = UInt64(u32(tail, end + 16))
        let endOffset = length - tailLength + UInt64(end)
        guard count > 0, count < 65535, count <= maximumEntries,
              centralOffset + centralSize == endOffset, centralSize <= 32 * 1024 * 1024,
              declaredExpandedSize > 0
        else { throw TipHistoryDownloadError.archiveLimitExceeded }
        try handle.seek(toOffset: centralOffset)
        let central = try read(handle, count: Int(centralSize))
        var position = 0
        var expanded: UInt64 = 0
        var records: [Record] = []
        var paths = Set<String>()
        for _ in 0 ..< count {
            try Task.checkCancellation()
            guard position + 46 <= central.count, u32(central, position) == 0x0201_4B50 else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            let flags = u16(central, position + 8)
            let method = u16(central, position + 10)
            let compressed = UInt64(u32(central, position + 20))
            let size = UInt64(u32(central, position + 24))
            let nameLength = Int(u16(central, position + 28))
            let extraLength = Int(u16(central, position + 30))
            let commentLength = Int(u16(central, position + 32))
            let attributes = u32(central, position + 38)
            let localOffset = UInt64(u32(central, position + 42))
            let next = position + 46 + nameLength + extraLength + commentLength
            guard next <= central.count, nameLength > 0, flags & ~UInt16(0x080E) == 0, method == 0 || method == 8,
                  u16(central, position + 34) == 0, localOffset < centralOffset,
                  let path = String(data: central.subdata(in: position + 46 ..< position + 46 + nameLength), encoding: .utf8)
            else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            try validateExtra(central.subdata(in: position + 46 + nameLength ..< position + 46 + nameLength + extraLength))
            let directory = path.hasSuffix("/")
            let normalized = directory ? String(path.dropLast()) : path
            guard path.utf8.count <= 1024, !path.hasPrefix("/"), !path.contains("\\"),
                  path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
                  paths.insert(canonicalPath(normalized)).inserted
            else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            let parts = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.first == appName, parts.count <= 128, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), parts.count > 1 || directory else {
                throw TipHistoryDownloadError.unexpectedArchiveLayout
            }
            let mode = (attributes >> 16) & 0xF000
            guard mode == 0 || mode == 0x8000 || mode == 0x4000 || mode == 0xA000 else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            let link = mode == 0xA000
            guard !link || (!directory && size > 0 && size <= 4096 && compressed > 0 && compressed <= 65536) else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            expanded += size
            guard expanded <= maximumExpandedBytes, expanded <= UInt64(declaredExpandedSize) else { throw TipHistoryDownloadError.archiveLimitExceeded }
            records.append(Record(path: normalized, parts: parts, size: size, compressed: compressed, method: method, flags: flags, localOffset: localOffset, isLink: link, isDirectory: directory))
            position = next
        }
        guard position == central.count else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
        var links: [String: String] = [:]
        let files = Set(records.filter { !$0.isDirectory && !$0.isLink }.map(\.path))
        var occupiedRanges: [(UInt64, UInt64)] = []
        for record in records {
            try Task.checkCancellation()
            // No regular file may be an ancestor of another archive path.
            for depth in 1 ..< record.parts.count {
                let ancestor = record.parts.prefix(depth).joined(separator: "/")
                guard !files.contains(ancestor) else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            }
            try handle.seek(toOffset: record.localOffset)
            let header = try read(handle, count: 30)
            guard u32(header, 0) == 0x0403_4B50, u16(header, 8) == record.method, u16(header, 6) == record.flags else {
                throw TipHistoryDownloadError.unexpectedArchiveLayout
            }
            // Without a trailing data descriptor, local sizes must agree with
            // the central directory ditto may otherwise interpret differently.
            guard record.flags & 8 != 0 || (UInt64(u32(header, 18)) == record.compressed && UInt64(u32(header, 22)) == record.size) else {
                throw TipHistoryDownloadError.unexpectedArchiveLayout
            }
            let localNameSize = Int(u16(header, 26))
            let extraSize = Int(u16(header, 28))
            let localName = try read(handle, count: localNameSize)
            let localExtra = try read(handle, count: extraSize)
            try validateExtra(localExtra)
            guard String(data: localName, encoding: .utf8) == record.path + (record.isDirectory ? "/" : "") else {
                throw TipHistoryDownloadError.unexpectedArchiveLayout
            }
            let start = record.localOffset + 30 + UInt64(localNameSize + extraSize)
            let finish = start + record.compressed
            guard finish <= centralOffset else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            occupiedRanges.append((record.localOffset, finish))
            if record.method == 0 {
                guard record.compressed == record.size else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            } else {
                // Metadata alone cannot bound ditto's actual output. System
                // unzip -t accepts some forged uncompressed lengths, so count
                // raw DEFLATE output ourselves into a fixed discard buffer.
                try handle.seek(toOffset: start)
                try validateDeflate(handle, compressed: record.compressed, expected: record.size)
            }
            if record.isLink {
                try handle.seek(toOffset: start)
                let data = try read(handle, count: Int(record.compressed))
                let decoded: Data
                if record.method == 0 { decoded = data }
                else {
                    var output = [UInt8](repeating: 0, count: Int(record.size) + 1)
                    let capacity = output.count
                    // Apple's COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), as ZIP requires.
                    // https://developer.apple.com/documentation/compression/compression_zlib
                    let size = data.withUnsafeBytes { bytes in
                        compression_decode_buffer(&output, capacity, bytes.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
                    }
                    guard size == Int(record.size) else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
                    decoded = Data(output.prefix(size))
                }
                guard decoded.count == Int(record.size), let target = String(data: decoded, encoding: .utf8),
                      !target.isEmpty, target.utf8.count <= 1024, !target.hasPrefix("/"), !target.contains("\\"),
                      target.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
                else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
                links[canonicalPath(record.path)] = target
            }
        }
        occupiedRanges.sort { $0.0 < $1.0 }
        for index in 1 ..< occupiedRanges.count {
            try Task.checkCancellation()
            guard occupiedRanges[index - 1].1 <= occupiedRanges[index].0 else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
        }
        // Resolve every path through the complete symlink graph, including links
        // used as parent directories. Reject cycles and out-of-app resolutions.
        var filesystemPaths = Set<String>()
        var physicalFiles = Set<String>()
        for record in records {
            try Task.checkCancellation()
            let resolved = try validateResolution(record.parts, links: links)
            for path in [record.parts, resolved] {
                for depth in 1 ... path.count {
                    filesystemPaths.insert(canonicalPath(path.prefix(depth).joined(separator: "/")))
                    guard filesystemPaths.count <= maximumEntries else { throw TipHistoryDownloadError.archiveLimitExceeded }
                }
            }
            if !record.isDirectory, !record.isLink {
                guard physicalFiles.insert(canonicalPath(resolved.joined(separator: "/"))).inserted else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            }
        }
        return filesystemPaths.count
    }

    private static func validateResolution(_ original: [String], links: [String: String]) throws -> [String] {
        var pending = original
        var resolved: [String] = []
        var expansions = 0
        while !pending.isEmpty {
            try Task.checkCancellation()
            guard pending.count + resolved.count <= 4096 else { throw TipHistoryDownloadError.archiveLimitExceeded }
            let part = pending.removeFirst()
            if part == "." || part.isEmpty { continue }
            if part == ".." {
                guard resolved.count > 1 else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
                resolved.removeLast()
                continue
            }
            resolved.append(part)
            guard resolved.count <= 128 else { throw TipHistoryDownloadError.archiveLimitExceeded }
            if let target = links[canonicalPath(resolved.joined(separator: "/"))] {
                expansions += 1
                guard expansions <= 40 else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
                resolved.removeLast()
                pending = target.split(separator: "/", omittingEmptySubsequences: false).map(String.init) + pending
            }
            guard resolved.isEmpty || resolved.first == appName else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
        }
        guard resolved.first == appName, resolved.count <= 128, resolved.joined(separator: "/").utf8.count <= 1024 else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
        return resolved
    }

    private static func validateDeflate(_ handle: FileHandle, compressed: UInt64, expected: UInt64) throws {
        guard compressed > 0 else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
        let capacity = 65536
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { output.deallocate() }
        // Unlike Compression.framework's decoder, zlib preserves unused input
        // at Z_STREAM_END. That is necessary to reject trailing/concatenated
        // streams rather than merely establishing the decoded output length.
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw TipHistoryDownloadError.unexpectedArchiveLayout
        }
        defer { inflateEnd(&stream) }
        var remaining = compressed
        var expanded: UInt64 = 0
        var ended = false
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try read(handle, count: Int(min(remaining, UInt64(capacity))))
            remaining -= UInt64(chunk.count)
            try chunk.withUnsafeBytes { bytes in
                stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress!)
                stream.avail_in = uInt(chunk.count)
                repeat {
                    try Task.checkCancellation()
                    let previousSource = stream.avail_in
                    stream.next_out = output
                    stream.avail_out = uInt(capacity)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    let produced = capacity - Int(stream.avail_out)
                    expanded += UInt64(produced)
                    guard expanded <= expected else { throw TipHistoryDownloadError.archiveLimitExceeded }
                    if status == Z_STREAM_END {
                        guard remaining == 0, stream.avail_in == 0 else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
                        ended = true
                        break
                    }
                    guard status == Z_OK, produced > 0 || stream.avail_in < previousSource else {
                        throw TipHistoryDownloadError.unexpectedArchiveLayout
                    }
                } while stream.avail_in > 0 || remaining == 0
            }
            if ended { break }
        }
        guard ended, expanded == expected else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
    }

    private static func validateExtra(_ data: Data) throws {
        // Only timestamp/owner metadata is admitted. In particular reject path
        // overrides, hard-link fields, alternate streams and ZIP64 extensions.
        // Formats: Info-ZIP proginfo/extrafld.txt; ditto --norsrc emits 0x5855.
        var index = 0
        var seen = Set<UInt16>()
        while index < data.count {
            guard index + 4 <= data.count else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            let kind = u16(data, index)
            let size = Int(u16(data, index + 2))
            guard seen.insert(kind).inserted, index + 4 + size <= data.count else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            switch kind {
            case 0x5855:
                guard size == 8 || size == 12 else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            case 0x7855:
                guard size == 0 || size == 4 else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            case 0x5455:
                guard [1, 5, 9, 13].contains(size), data[index + 4] & 0xF8 == 0 else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            case 0x7875:
                guard size >= 3, data[index + 4] == 1 else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
                let uidSize = Int(data[index + 5])
                guard uidSize > 0, uidSize <= 8, 2 + uidSize < size else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
                let gidSize = Int(data[index + 6 + uidSize])
                guard gidSize > 0, gidSize <= 8, size == 3 + uidSize + gidSize else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            default:
                throw TipHistoryDownloadError.unexpectedArchiveLayout
            }
            index += 4 + size
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func read(_ handle: FileHandle, count: Int) throws -> Data {
        let bytes = try handle.read(upToCount: count) ?? Data()
        guard bytes.count == count else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
        return bytes
    }

    private static func u16(_ data: Data, _ index: Int) -> UInt16 {
        UInt16(data[index]) | UInt16(data[index + 1]) << 8
    }

    private static func u32(_ data: Data, _ index: Int) -> UInt32 {
        UInt32(u16(data, index)) | UInt32(u16(data, index + 2)) << 16
    }
}
