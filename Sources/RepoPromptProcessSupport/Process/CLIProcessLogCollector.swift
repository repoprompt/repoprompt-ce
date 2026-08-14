import Foundation

package enum CLIProcessLogCollectorError: Error {
    case noEntries
    case downloadsDirectoryUnavailable
}

package final class CLIProcessLogCollector {
    package init() {}
    private struct Entry {
        let timestamp: Date
        let message: String
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private let queue = DispatchQueue(label: "com.repoprompt.cli-log-collector", attributes: .concurrent)
    private var entries: [Entry] = []

    package var isEmpty: Bool {
        queue.sync { entries.isEmpty }
    }

    package func reset() {
        queue.async(flags: .barrier) {
            self.entries.removeAll()
        }
    }

    package func append(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = Entry(timestamp: Date(), message: trimmed)
        queue.async(flags: .barrier) {
            self.entries.append(entry)
        }
    }

    package func appendSection(title: String, content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let block = "\(title)\n```\n\(trimmed)\n```"
        append(block)
    }

    package func appendDataSection(title: String, data: Data) {
        guard !data.isEmpty else { return }
        if let string = String(data: data, encoding: .utf8), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendSection(title: title, content: string)
        } else {
            let base64 = data.base64EncodedString()
            appendSection(title: title, content: "(binary data, \(data.count) bytes)\nBase64: \(base64)")
        }
    }

    package func makeMarkdown(title: String) throws -> String {
        let snapshot = queue.sync { entries }
        guard !snapshot.isEmpty else { throw CLIProcessLogCollectorError.noEntries }
        var output = "# \(title)\n\n"
        for entry in snapshot {
            let timestamp = Self.timestampFormatter.string(from: entry.timestamp)
            output.append("## \(timestamp)\n\n\(entry.message)\n\n")
        }
        return output
    }

    package func writeMarkdownToDownloads(baseFilename: String, title: String, timestamp: Date = Date()) throws -> URL {
        let markdown = try makeMarkdown(title: title)
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw CLIProcessLogCollectorError.downloadsDirectoryUnavailable
        }
        let filename = "\(baseFilename)-\(Self.filenameFormatter.string(from: timestamp)).md"
        let fileURL = downloads.appendingPathComponent(filename)
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
