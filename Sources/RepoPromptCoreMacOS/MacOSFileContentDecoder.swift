import Cuchardet
import Foundation
import RepoPromptCore
import UniversalCharsetDetection

package struct MacOSFileContentDecoder: FileContentDecoding {
    package init() {}

    package func decode(_ data: Data) -> DecodedFileContent? {
        if data.isEmpty {
            return DecodedFileContent(string: "", encodingRawValue: String.Encoding.utf8.rawValue)
        }
        if let string = String(data: data, encoding: .utf8) {
            return DecodedFileContent(string: string, encodingRawValue: String.Encoding.utf8.rawValue)
        }
        let encoding = String.Encoding(
            rawValue: detectEncodingRawValue(in: data) ?? String.Encoding.utf8.rawValue
        )
        guard let string = String(data: data, encoding: encoding) else { return nil }
        return DecodedFileContent(string: string, encodingRawValue: encoding.rawValue)
    }

    package func detectEncodingRawValue(in data: Data) -> UInt? {
        if let label = data.detectedCharacterEncoding {
            return Self.encoding(forIANACharsetName: label).rawValue
        }
        var lossy = ObjCBool(false)
        let guess = NSString.stringEncoding(
            for: data,
            encodingOptions: [:],
            convertedString: nil,
            usedLossyConversion: &lossy
        )
        return guess == 0 ? nil : guess
    }

    package func isProbablyBinary(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let sample = data.prefix(8192)
        if sample.contains(0) { return true }

        var controls = 0
        var printable = 0
        for byte in sample {
            switch byte {
            case 0x09, 0x0A, 0x0D, 0x20 ... 0x7E:
                printable += 1
            case 0x01 ... 0x08, 0x0B ... 0x0C, 0x0E ... 0x1F:
                controls += 1
            default:
                printable += 1
            }
        }
        let total = controls + printable
        return total > 0 && Double(controls) / Double(total) > 0.30
    }

    package func makeEncodingDetectionSession() -> any FileContentEncodingDetectionSession {
        MacOSEncodingDetectionSession()
    }

    package static func encoding(forIANACharsetName name: String) -> String.Encoding {
        let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        return String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)
        )
    }
}

private final class MacOSEncodingDetectionSession: FileContentEncodingDetectionSession {
    private let detector = CharacterEncodingDetector()

    func analyzeNextChunk(_ data: Data) -> Bool {
        detector.analyzeNextChunk(data)
    }

    func finishEncodingRawValue() -> UInt? {
        detector.finish().map(MacOSFileContentDecoder.encoding(forIANACharsetName:)).map(\.rawValue)
    }
}
