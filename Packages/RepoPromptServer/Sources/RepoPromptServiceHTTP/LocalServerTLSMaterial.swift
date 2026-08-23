import Crypto
import Foundation
import NIOSSL
import X509

public enum LocalServerTLSMaterial {
    public static func ensure(certificatePath: String, privateKeyPath: String) throws {
        if FileManager.default.fileExists(atPath: certificatePath), FileManager.default.fileExists(atPath: privateKeyPath) {
            return
        }
        let certificateURL = URL(fileURLWithPath: certificatePath)
        let keyURL = URL(fileURLWithPath: privateKeyPath)
        try FileManager.default.createDirectory(at: certificateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let key = P256.Signing.PrivateKey()
        let name = try DistinguishedName { CommonName("RepoPrompt Server") }
        var extensionList: [Certificate.Extension] = [
            try Certificate.Extension(ExtendedKeyUsage([.serverAuth]), critical: false),
            try Certificate.Extension(SubjectAlternativeNames([.dnsName("localhost"), .dnsName("repoprompt")]), critical: false)
        ]
        let extensions = try Certificate.Extensions(extensionList)
        let certificate = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(key.publicKey),
            notValidBefore: Date().addingTimeInterval(-60),
            notValidAfter: Date().addingTimeInterval(365 * 24 * 60 * 60),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: .init(key)
        )
        try Data(certificate.serializeAsPEM().pemString.utf8).write(to: certificateURL, options: .atomic)
        try Data(key.pemRepresentation.utf8).write(to: keyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: certificatePath)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyPath)
    }
}

extension RepoPromptTLSConfiguration {
    public static func serverTLS13(certificatePath: String, privateKeyPath: String) throws -> TLSConfiguration {
        let certificates = try NIOSSLCertificate.fromPEMFile(certificatePath).map { NIOSSLCertificateSource.certificate($0) }
        let privateKey = try NIOSSLPrivateKey(file: privateKeyPath, format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: certificates, privateKey: .privateKey(privateKey))
        configuration.certificateVerification = .none
        configuration.minimumTLSVersion = .tlsv13
        configuration.maximumTLSVersion = .tlsv13
        return configuration
    }
}
