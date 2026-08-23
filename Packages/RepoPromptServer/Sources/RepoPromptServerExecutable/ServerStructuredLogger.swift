import Foundation

func writeOwnerOnlySecret(_ data: Data, to destination: URL) throws {
    let fileManager = FileManager.default
    let temporary = destination.deletingLastPathComponent()
        .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    var published = false
    defer {
        if !published { try? fileManager.removeItem(at: temporary) }
    }
    guard fileManager.createFile(
        atPath: temporary.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let handle = try FileHandle(forWritingTo: temporary)
    defer { try? handle.close() }
    try handle.write(contentsOf: data)
    try handle.synchronize()
    guard let temporaryMode = try fileManager.attributesOfItem(atPath: temporary.path)[.posixPermissions] as? NSNumber,
          temporaryMode.intValue & 0o777 == 0o600
    else {
        throw CocoaError(.fileWriteNoPermission)
    }
    if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
    }
    try fileManager.moveItem(at: temporary, to: destination)
    published = true
}

enum ServerStructuredLogger {
    private struct Entry: Encodable {
        let timestamp: Date
        let level: String
        let event: String
        let outcome: String
        let fields: [String: String]
    }

    static func write(
        level: String = "info",
        event: String,
        outcome: String,
        fields: [String: String] = [:]
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(Entry(
            timestamp: Date(),
            level: level,
            event: event,
            outcome: outcome,
            fields: fields
        )) else { return }
        data.append(0x0A)
        FileHandle.standardError.write(data)
    }
}
