import RepoPromptCoreMacOS

enum HeadlessSecureStorage {
    static let namespace = HeadlessVersion.secureStorageNamespace

    static func makeService() -> KeychainService {
        KeychainService(serviceName: namespace)
    }
}
