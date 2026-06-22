import Foundation

enum HeadlessOutput {
    static func stdout(_ message: String = "") {
        write(message, to: .standardOutput)
    }

    static func stderr(_ message: String = "") {
        write(message, to: .standardError)
    }

    private static func write(_ message: String, to handle: FileHandle) {
        let line = message.hasSuffix("\n") ? message : "\(message)\n"
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
    }
}

enum HeadlessJSONFormatting {
    static func encoder(prettyPrinted: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = [.sortedKeys]
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func string(_ value: some Encodable, prettyPrinted: Bool = true) throws -> String {
        let data = try encoder(prettyPrinted: prettyPrinted).encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
