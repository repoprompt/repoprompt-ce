import Crypto
import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

enum OperatorPasswordHasher {
    static let iterations = 210_000
    static let saltSize = 16
    static let keySize = 32
    static let minimumPasswordLength = 8
    static let maximumPasswordLength = 1024

    static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: saltSize)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return Data(bytes)
    }

    static func validate(_ password: String) throws {
        let count = password.utf8.count
        guard count >= minimumPasswordLength, count <= maximumPasswordLength else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "Operator password must be between \(minimumPasswordLength) and \(maximumPasswordLength) characters"
            )
        }
    }

    static func hash(password: String, salt: Data, iterations: Int = iterations) throws -> Data {
        try validate(password)
        guard salt.count == saltSize, iterations >= 10_000 else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Operator password hash parameters are invalid", retryable: false)
        }
        return pbkdf2HMACSHA256(password: Data(password.utf8), salt: salt, iterations: iterations, derivedKeyLength: keySize)
    }

    static func verify(_ password: String, salt: Data, hash: Data, iterations: Int) -> Bool {
        guard let computed = try? self.hash(password: password, salt: salt, iterations: iterations) else { return false }
        return constantTimeEquals(computed, hash)
    }

    private static func pbkdf2HMACSHA256(password: Data, salt: Data, iterations: Int, derivedKeyLength: Int) -> Data {
        let blockCount = Int(ceil(Double(derivedKeyLength) / 32.0))
        var derived = Data()
        derived.reserveCapacity(blockCount * 32)
        let key = SymmetricKey(data: password)
        for block in 1 ... blockCount {
            var saltBlock = salt
            var index = UInt32(block).bigEndian
            withUnsafeBytes(of: &index) { saltBlock.append(contentsOf: $0) }
            var u = Data(HMAC<SHA256>.authenticationCode(for: saltBlock, using: key))
            var t = u
            if iterations > 1 {
                for _ in 2 ... iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for byteIndex in t.indices {
                        t[byteIndex] ^= u[byteIndex]
                    }
                }
            }
            derived.append(t)
        }
        return derived.prefix(derivedKeyLength)
    }

    static func constantTimeEquals(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 4, limitedBy: hex.endIndex) ?? hex.endIndex
            return String(hex[start..<end])
        }.joined(separator: "-")
    }
}
