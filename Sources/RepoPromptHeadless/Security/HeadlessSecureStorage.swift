import RepoPromptCore
import RepoPromptCoreMacOS

enum HeadlessSecureStorage {
    static let namespace = HeadlessVersion.secureStorageNamespace

    static func makeService() -> SecureKeysService {
        SecureKeysService(secureStorage: KeychainService(serviceName: namespace))
    }
}
