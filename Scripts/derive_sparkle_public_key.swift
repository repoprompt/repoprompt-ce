import CryptoKit
import Darwin
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}

let encoded = try String(
    contentsOfFile: CommandLine.arguments[1],
    encoding: .utf8
).trimmingCharacters(in: .whitespacesAndNewlines)
guard let secret = Data(base64Encoded: encoded) else {
    fail("Sparkle private key is not valid base64")
}
guard secret.count == 32 else {
    fail("Sparkle private key must decode to a modern 32-byte seed")
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
print(key.publicKey.rawRepresentation.base64EncodedString())
