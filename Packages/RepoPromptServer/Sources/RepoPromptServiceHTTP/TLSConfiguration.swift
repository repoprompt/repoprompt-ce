import HummingbirdTLS
import NIOSSL

public enum RepoPromptTLSConfiguration {
    public static func mutualTLS13(certificatePath: String, privateKeyPath: String, trustRootsPath: String) throws -> TLSConfiguration {
        let certificates = try NIOSSLCertificate.fromPEMFile(certificatePath).map { NIOSSLCertificateSource.certificate($0) }
        let privateKey = try NIOSSLPrivateKey(file: privateKeyPath, format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(certificateChain: certificates, privateKey: .privateKey(privateKey))
        configuration.trustRoots = .file(trustRootsPath)
        // The server validates the client chain here; route-role identity is
        // enforced from clientAuth EKU + SAN by CertificateIdentityRoleResolver.
        // Full verification additionally hostname-matches the client certificate
        // against its socket address, which incorrectly rejects role identities.
        configuration.certificateVerification = .noHostnameVerification
        configuration.minimumTLSVersion = .tlsv13
        configuration.maximumTLSVersion = .tlsv13
        return configuration
    }
}
