import Foundation

package enum AttachmentClassificationError: Error, Equatable, LocalizedError {
    case imageConversionFailed(fileName: String, format: String)
    case imageTooLarge(fileName: String, format: String)

    package var errorDescription: String? {
        switch self {
        case let .imageConversionFailed(fileName, format):
            "\(fileName) is a \(format) image that could not be converted to JPEG or PNG."
        case let .imageTooLarge(fileName, format):
            "\(fileName) is a \(format) image whose dimensions are too large to convert."
        }
    }
}

/// Classification reads content only. The extension is never consulted, so a `.png` holding PDF bytes
/// is a PDF.
package enum AttachmentClassifier {
    package static let textProbeByteCount = 8 * 1024

    private static let pdfSignature = Array("%PDF-".utf8)
    private static let headerByteCount = 256

    /// - Parameter fileName: Only used to name the file in a conversion error.
    /// - Throws: `AttachmentClassificationError` when an HEIC, TIFF, BMP, or AVIF image cannot be
    ///   converted. A failed conversion never degrades to `.binary`.
    package static func classify(
        bytes: Data,
        fileName: String
    ) throws(AttachmentClassificationError) -> AttachmentPayload {
        let header = bytes.prefix(headerByteCount)
        if let image = sniffImage(of: bytes) {
            switch image {
            case let .native(mediaType):
                return .image(mediaType, bytes)
            case let .convertible(format):
                return try AttachmentImageNormalizer.normalize(bytes, format: format, fileName: fileName)
            }
        }
        if header.starts(with: pdfSignature) {
            return .pdf(bytes)
        }
        if let text = decodeText(bytes) {
            return .text(text, bytes)
        }
        return .binary(bytes)
    }

    /// The kind `classify` produces, without converting anything, so intake can name a file's kind
    /// cheaply.
    package static func kind(of bytes: Data) -> AttachmentKind {
        if sniffImage(of: bytes) != nil { return .image }
        if bytes.prefix(headerByteCount).starts(with: pdfSignature) { return .pdf }
        return decodeText(bytes) != nil ? .text : .binary
    }

    private static func decodeText(_ bytes: Data) -> String? {
        guard !bytes.prefix(textProbeByteCount).contains(0) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    enum SniffedImage: Equatable {
        case native(ImageMediaType)
        case convertible(ConvertibleImageFormat)
    }

    static func sniffImage(of bytes: Data) -> SniffedImage? {
        let data = Data(bytes.prefix(headerByteCount))
        let totalByteCount = bytes.count
        if totalByteCount >= 33,
           data.count >= 16,
           data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
           String(data: data[12 ..< 16], encoding: .ascii) == "IHDR"
        {
            return .native(.png)
        }
        if totalByteCount >= 4,
           data.starts(with: [0xFF, 0xD8, 0xFF])
        {
            return .native(.jpeg)
        }
        if totalByteCount >= 10,
           data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8))
        {
            let width = Int(data[6]) | (Int(data[7]) << 8)
            let height = Int(data[8]) | (Int(data[9]) << 8)
            if width > 0, height > 0 { return .native(.gif) }
        }
        if totalByteCount >= 16,
           String(data: data[0 ..< 4], encoding: .ascii) == "RIFF",
           String(data: data[8 ..< 12], encoding: .ascii) == "WEBP",
           let chunk = String(data: data[12 ..< 16], encoding: .ascii),
           ["VP8 ", "VP8L", "VP8X"].contains(chunk)
        {
            return .native(.webp)
        }
        if let format = sniffISOBaseMedia(data) ?? sniffTIFF(data) ?? sniffBMP(data, totalByteCount: totalByteCount) {
            return .convertible(format)
        }
        return nil
    }

    private static let heicBrands: Set<String> = ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs"]
    private static let avifBrands: Set<String> = ["avif", "avis"]
    private static let genericImageBrands: Set<String> = ["mif1", "msf1"]

    /// HEIC and AVIF share the ISO base media `ftyp` box and differ only by brand.
    private static func sniffISOBaseMedia(_ data: Data) -> ConvertibleImageFormat? {
        guard data.count >= 16, String(data: data[4 ..< 8], encoding: .ascii) == "ftyp" else { return nil }
        let boxSize = Int(data[0]) << 24 | Int(data[1]) << 16 | Int(data[2]) << 8 | Int(data[3])
        let boxEnd = min(max(boxSize, 16), data.count)
        var brands = [String(decoding: data[8 ..< 12], as: UTF8.self)]
        var offset = 16
        while offset + 4 <= boxEnd {
            brands.append(String(decoding: data[offset ..< offset + 4], as: UTF8.self))
            offset += 4
        }
        if brands.contains(where: avifBrands.contains) { return .avif }
        if brands.contains(where: heicBrands.contains) { return .heic }
        if genericImageBrands.contains(brands[0]) { return .heic }
        return nil
    }

    private static func sniffTIFF(_ data: Data) -> ConvertibleImageFormat? {
        guard data.count >= 8 else { return nil }
        let littleEndian = data.starts(with: [0x49, 0x49, 0x2A, 0x00])
        let bigEndian = data.starts(with: [0x4D, 0x4D, 0x00, 0x2A])
        return littleEndian || bigEndian ? .tiff : nil
    }

    /// "BM" alone is two printable bytes that plain text can start with, so the header fields
    /// must also be self-consistent.
    private static func sniffBMP(_ data: Data, totalByteCount: Int) -> ConvertibleImageFormat? {
        guard data.count >= 26, data[0] == 0x42, data[1] == 0x4D else { return nil }
        func littleEndian32(_ offset: Int) -> Int {
            Int(data[offset]) | Int(data[offset + 1]) << 8 | Int(data[offset + 2]) << 16 | Int(data[offset + 3]) << 24
        }
        let reservedIsZero = littleEndian32(6) == 0
        let pixelOffset = littleEndian32(10)
        let headerSize = littleEndian32(14)
        let knownHeaderSizes: Set = [12, 40, 52, 56, 64, 108, 124]
        guard reservedIsZero,
              knownHeaderSizes.contains(headerSize),
              pixelOffset >= 14 + headerSize,
              pixelOffset <= totalByteCount
        else { return nil }
        return .bmp
    }
}
