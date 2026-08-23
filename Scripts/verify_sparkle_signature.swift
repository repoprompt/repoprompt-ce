import CryptoKit
import Darwin
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}

let encodedPublicKey = try String(
    contentsOfFile: CommandLine.arguments[1],
    encoding: .utf8
).trimmingCharacters(in: .whitespacesAndNewlines)
let encodedSignature = CommandLine.arguments[2]
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))

guard let publicKeyData = Data(base64Encoded: encodedPublicKey) else {
    fail("Sparkle public key is not valid base64")
}
guard let signature = Data(base64Encoded: encodedSignature) else {
    fail("Sparkle signature is not valid base64")
}

let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
guard publicKey.isValidSignature(signature, for: archive) else {
    fail("Sparkle signature does not verify against the committed public key")
}
