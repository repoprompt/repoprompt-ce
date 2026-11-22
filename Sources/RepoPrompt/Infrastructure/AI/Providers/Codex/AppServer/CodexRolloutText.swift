import CCodexZstdDecoder
import Foundation

/// Read-only access for RepoPrompt's local command-status reconciliation. Codex owns
/// every rollout write, including compression and materialization before append.
enum CodexRolloutText {
    static func read(atPath path: String) -> String? {
        let requested = URL(fileURLWithPath: path)
        let plain = path.hasSuffix(".jsonl.zst") ? requested.deletingPathExtension() : requested
        // Codex prefers the plain file if both exist during publication or after resume.
        // Retry the plain path when materialization wins the race with opening .zst.
        do {
            return try String(contentsOf: plain, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            guard plain.pathExtension == "jsonl" else { return nil }
        } catch {
            return nil
        }

        do {
            let compressed = try Data(contentsOf: plain.appendingPathExtension("zst"))
            return decode(compressed)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return try? String(contentsOf: plain, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func decode(_ compressed: Data) -> String? {
        guard !compressed.isEmpty, let stream = ZSTD_createDCtx() else { return nil }
        defer { ZSTD_freeDCtx(stream) }

        return compressed.withUnsafeBytes { source in
            var input = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
            var scratch = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
            var decoded = Data()
            while true {
                let previousInputPosition = input.pos
                let (remaining, count) = scratch.withUnsafeMutableBytes { bytes in
                    var output = ZSTD_outBuffer(dst: bytes.baseAddress, size: bytes.count, pos: 0)
                    let remaining = ZSTD_decompressStream(stream, &output, &input)
                    return (remaining, output.pos)
                }
                guard ZSTD_isError(remaining) == 0 else { return nil }
                decoded.append(contentsOf: scratch.prefix(count))
                if input.pos == input.size, remaining == 0 {
                    return String(data: decoded, encoding: .utf8)
                }
                guard count > 0 || input.pos > previousInputPosition else { return nil }
            }
        }
    }
}
