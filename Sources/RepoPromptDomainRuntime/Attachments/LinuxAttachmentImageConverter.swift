#if os(Linux)
    import Dispatch
    import Foundation
    import Glibc

    enum LinuxAttachmentImageConverter {
        private static let limits = [
            "-limit", "memory", "256MiB", "-limit", "map", "256MiB",
            "-limit", "disk", "512MiB", "-limit", "time", "15",
            "-limit", "width", "16384", "-limit", "height", "16384",
            "-limit", "area", "67108864"
        ]

        static func normalize(
            _ bytes: Data,
            format: ConvertibleImageFormat,
            fileName: String
        ) throws(AttachmentClassificationError) -> AttachmentPayload {
            guard let commands = commands() else {
                throw .imageConverterUnavailable(fileName: fileName, format: format.rawValue)
            }
            let failure = AttachmentClassificationError.imageConversionFailed(fileName: fileName, format: format.rawValue)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("repoprompt-image-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
                )
                defer { try? FileManager.default.removeItem(at: directory) }
                let source = directory.appendingPathComponent("input.\(format.rawValue.lowercased())")
                try bytes.write(to: source)
                let metadata = directory.appendingPathComponent("metadata.txt")
                try run(
                    commands.identify,
                    arguments: commands.identifyArguments + limits + ["-ping", "-format", "%w %h %[channels]", format.rawValue + ":" + source.path + "[0]"],
                    output: metadata
                )
                let metadataBytes = try boundedRead(metadata, maximumBytes: 4096)
                let values = String(decoding: metadataBytes, as: UTF8.self).split(whereSeparator: \.isWhitespace)
                guard values.count == 3, let width = Int(values[0]), let height = Int(values[1]),
                      width > 0, height > 0
                else { throw failure }
                guard width <= AttachmentImageNormalizer.maxSourceDimension,
                      height <= AttachmentImageNormalizer.maxSourceDimension,
                      width <= AttachmentImageNormalizer.maxSourcePixelCount / height
                else { throw AttachmentClassificationError.imageTooLarge(fileName: fileName, format: format.rawValue) }
                let hasAlpha = values[2].lowercased().hasSuffix("a") || values[2].lowercased().contains("alpha")
                let output = directory.appendingPathComponent(hasAlpha ? "output.png" : "output.jpg")
                try run(
                    commands.convert,
                    arguments: limits + [format.rawValue + ":" + source.path + "[0]", "-auto-orient", "-strip", "-colorspace", "sRGB", "-quality", "90", output.path]
                )
                let result = try boundedRead(output, maximumBytes: OracleAttachmentLimits.production.maxBytesPerFile)
                let signature: [UInt8] = hasAlpha
                    ? [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
                    : [0xFF, 0xD8, 0xFF]
                guard result.starts(with: signature) else { throw failure }
                return .image(hasAlpha ? .png : .jpeg, result)
            } catch let error as AttachmentClassificationError {
                throw error
            } catch {
                throw failure
            }
        }

        private struct Commands {
            let identify: URL
            let identifyArguments: [String]
            let convert: URL
        }

        private static func commands() -> Commands? {
            if let magick = executable("magick") {
                return Commands(identify: magick, identifyArguments: ["identify"], convert: magick)
            }
            guard let identify = executable("identify"), let convert = executable("convert") else { return nil }
            return Commands(identify: identify, identifyArguments: [], convert: convert)
        }

        private static func executable(_ name: String) -> URL? {
            let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
            for entry in searchPath.split(separator: ":") where entry.hasPrefix("/") {
                let url = URL(fileURLWithPath: String(entry), isDirectory: true).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            }
            return nil
        }

        private static func boundedRead(_ url: URL, maximumBytes: Int) throws -> Data {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard try handle.seekToEnd() <= UInt64(maximumBytes) else { throw CocoaError(.fileReadTooLarge) }
            try handle.seek(toOffset: 0)
            var bytes = Data()
            while let chunk = try handle.read(upToCount: min(64 * 1024, maximumBytes - bytes.count + 1)), !chunk.isEmpty {
                guard chunk.count <= maximumBytes - bytes.count else { throw CocoaError(.fileReadTooLarge) }
                bytes.append(chunk)
            }
            return bytes
        }

        private static func run(_ executable: URL, arguments: [String], output: URL? = nil) throws {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var outputHandle: FileHandle?
            if let output {
                guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                outputHandle = try FileHandle(forWritingTo: output)
            }
            defer { try? outputHandle?.close() }
            process.standardOutput = outputHandle ?? FileHandle.nullDevice
            let completed = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in completed.signal() }
            try process.run()
            guard completed.wait(timeout: .now() + 20) == .success else {
                if process.isRunning {
                    let pid = process.processIdentifier
                    if getpgid(pid) == pid {
                        _ = kill(-pid, SIGKILL)
                    } else {
                        _ = kill(pid, SIGKILL)
                    }
                }
                _ = completed.wait(timeout: .now() + 1)
                throw CocoaError(.executableRuntimeMismatch)
            }
            guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
        }
    }
#endif
