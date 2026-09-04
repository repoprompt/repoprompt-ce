//
//  KeychainService.swift
//  RepoPrompt
//
//  Secure Keychain-based storage for sensitive data
//

import Foundation
import Security

/// Controls whether a Keychain operation may display macOS authentication/approval UI.
enum KeychainAccessMode: Equatable {
    case interactive
    case nonInteractive(reason: KeychainAccessReason)

    var isNonInteractive: Bool {
        if case .nonInteractive = self {
            return true
        }
        return false
    }
}

/// Sanitized reason metadata for noninteractive Keychain access.
enum KeychainAccessReason: Equatable {
    case launch
    case bulkSettingsLoad
    case permissionDecision
    case backgroundAvailabilityCheck
    case test
}

protocol SecItemClient {
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus
    func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

struct SystemSecItemClient: SecItemClient {
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func add(_ query: CFDictionary, _ result: UnsafeMutablePointer<AnyObject?>?) -> OSStatus {
        SecItemAdd(query, result)
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

protocol KeychainItemCreationAttributeProvider {
    func attributesForNewItem() throws -> [String: Any]
}

protocol KeychainItemAccessValidator {
    func validate(_ access: AnyObject) throws
}

protocol SecKeychainItemAccessProvider {
    func copyAccess(from result: AnyObject) throws -> AnyObject
}

enum KeychainItemAccessProviderError: Error, LocalizedError, Equatable {
    case invalidItemReference
    case accessCopyFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidItemReference:
            "The Keychain item reference is invalid"
        case let .accessCopyFailed(status):
            "Could not copy the Keychain access policy (status \(status))"
        }
    }
}

struct SystemSecKeychainItemAccessProvider: SecKeychainItemAccessProvider {
    func copyAccess(from result: AnyObject) throws -> AnyObject {
        guard CFGetTypeID(result as CFTypeRef) == SecKeychainItemGetTypeID() else {
            throw KeychainItemAccessProviderError.invalidItemReference
        }
        let item = unsafeBitCast(result, to: SecKeychainItem.self)
        var access: SecAccess?
        let status = SecKeychainItemCopyAccess(item, &access)
        guard status == errSecSuccess, let access else {
            throw KeychainItemAccessProviderError.accessCopyFailed(status: status)
        }
        return access
    }
}

enum KeychainItemCreationAttributeError: Error, LocalizedError, Equatable {
    case trustedApplicationCreationFailed(path: String, status: OSStatus)
    case trustedApplicationValidationFailed(path: String)
    case accessCreationFailed(status: OSStatus)
    case referenceItemLookupFailed(status: OSStatus)
    case referenceItemInvalid
    case referenceItemAccessFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case let .trustedApplicationCreationFailed(path, status):
            "Could not create a Keychain trusted-application requirement for \(path) (status \(status))"
        case let .trustedApplicationValidationFailed(path):
            "The Keychain trusted application failed code-signing validation: \(path)"
        case let .accessCreationFailed(status):
            "Could not create the Keychain access policy (status \(status))"
        case let .referenceItemLookupFailed(status):
            "Could not find the Keychain access-policy reference item (status \(status))"
        case .referenceItemInvalid:
            "The Keychain access-policy reference item is invalid"
        case let .referenceItemAccessFailed(status):
            "Could not copy the Keychain access policy from the reference item (status \(status))"
        }
    }
}

/// Builds a classic macOS Keychain ACL from exact code requirements after validating
/// the corresponding signed executables. The migration preparer supplies its current
/// executable plus an embedded executable signed for the successor identity; no
/// credential data or authorization prompt is involved in constructing this policy.
struct TrustedApplicationCodeRequirement {
    let trustedApplicationPath: String
    let codeURL: URL
    let requirementSource: String
}

enum KeychainACLPrincipal: Equatable {
    case requirement(Data)
    case wildcard
    case malformed
}

enum KeychainACLValidationError: Error, LocalizedError, Equatable {
    case invalidExpectedPrincipalPolicy
    case invalidAccess
    case decryptACLListMissing
    case unexpectedDecryptACLCount(Int)
    case accessACLTypeInvalid
    case accessACLContentsCopyFailed(status: OSStatus)
    case wildcardPrincipal
    case missingPrincipal
    case extraPrincipal
    case duplicatePrincipal
    case malformedPrincipal
    case trustedApplicationRequirementCopyFailed(status: OSStatus)
    case trustedApplicationRequirementMissing
    case requirementDataCopyFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidExpectedPrincipalPolicy:
            "The Keychain ACL principal policy is invalid"
        case .invalidAccess:
            "The Keychain access policy is invalid"
        case .decryptACLListMissing:
            "The Keychain access policy has no decrypt ACL"
        case let .unexpectedDecryptACLCount(count):
            "The Keychain access policy has an unexpected number of decrypt ACLs (\(count))"
        case .accessACLTypeInvalid:
            "The Keychain access-control list contains an invalid ACL"
        case let .accessACLContentsCopyFailed(status):
            "Could not inspect Keychain ACL contents (status \(status))"
        case .wildcardPrincipal:
            "The Keychain access policy contains a wildcard principal"
        case .missingPrincipal:
            "The Keychain access policy is missing an expected principal"
        case .extraPrincipal:
            "The Keychain access policy contains an unexpected principal"
        case .duplicatePrincipal:
            "The Keychain access policy contains a duplicate principal"
        case .malformedPrincipal:
            "The Keychain access policy contains a malformed principal"
        case let .trustedApplicationRequirementCopyFailed(status):
            "Could not inspect a Keychain trusted-application requirement (status \(status))"
        case .trustedApplicationRequirementMissing:
            "The Keychain trusted application has no code requirement"
        case let .requirementDataCopyFailed(status):
            "Could not serialize a Keychain trusted-application requirement (status \(status))"
        }
    }
}

/// Security.framework exports these SPIs on macOS, and its implementation is the
/// only API that creates and exposes the code requirement carried by a
/// SecTrustedApplication.
/// SecTrustedApplicationCopyData is deliberately not used: Apple documents that
/// payload as opaque, and current Security sources return the principal description
/// (normally a path), not the requirement that grants access.
@_silgen_name("SecTrustedApplicationCopyRequirement")
private func SecTrustedApplicationCopyRequirementSPI(
    _ application: SecTrustedApplication,
    _ requirement: UnsafeMutablePointer<SecRequirement?>
) -> OSStatus

@_silgen_name("SecTrustedApplicationCreateFromRequirement")
private func SecTrustedApplicationCreateFromRequirementSPI(
    _ description: UnsafePointer<CChar>?,
    _ requirement: SecRequirement,
    _ application: UnsafeMutablePointer<SecTrustedApplication?>
) -> OSStatus

/// Authenticates the one ACL that can decrypt a classic Keychain item. Every
/// trusted application in that ACL must carry one of the exact expected designated
/// requirements, with no wildcard, duplicate, missing, or additional principal.
struct ClassicKeychainACLValidator: KeychainItemAccessValidator {
    private let expectedPrincipalData: [Data]

    init(requirementSources: [String]) throws {
        guard !requirementSources.isEmpty else {
            throw KeychainACLValidationError.invalidExpectedPrincipalPolicy
        }
        let principalData = requirementSources.compactMap(RuntimeCodeSigningDetector.requirementData(from:))
        guard principalData.count == requirementSources.count,
              Set(principalData).count == principalData.count
        else {
            throw KeychainACLValidationError.invalidExpectedPrincipalPolicy
        }
        expectedPrincipalData = principalData
    }

    func validate(_ access: AnyObject) throws {
        guard CFGetTypeID(access as CFTypeRef) == SecAccessGetTypeID() else {
            throw KeychainACLValidationError.invalidAccess
        }
        let access = unsafeBitCast(access, to: SecAccess.self)
        guard let aclList = SecAccessCopyMatchingACLList(
            access,
            kSecACLAuthorizationDecrypt
        ) else {
            throw KeychainACLValidationError.decryptACLListMissing
        }
        let aclCount = CFArrayGetCount(aclList)
        guard aclCount == 1 else {
            throw KeychainACLValidationError.unexpectedDecryptACLCount(aclCount)
        }

        var principals: [KeychainACLPrincipal] = []
        let aclValue = CFArrayGetValueAtIndex(aclList, 0)
        let aclObject: CFTypeRef = unsafeBitCast(aclValue, to: CFTypeRef.self)
        guard CFGetTypeID(aclObject) == SecACLGetTypeID() else {
            throw KeychainACLValidationError.accessACLTypeInvalid
        }
        let acl = unsafeBitCast(aclValue, to: SecACL.self)
        var applications: CFArray?
        var description: CFString?
        var promptSelector = SecKeychainPromptSelector(rawValue: 0)
        let contentsStatus = SecACLCopyContents(
            acl,
            &applications,
            &description,
            &promptSelector
        )
        guard contentsStatus == errSecSuccess else {
            throw KeychainACLValidationError.accessACLContentsCopyFailed(status: contentsStatus)
        }
        guard let applications else {
            throw KeychainACLValidationError.wildcardPrincipal
        }
        guard CFArrayGetCount(applications) > 0 else {
            throw KeychainACLValidationError.missingPrincipal
        }
        for applicationIndex in 0 ..< CFArrayGetCount(applications) {
            let applicationValue = CFArrayGetValueAtIndex(applications, applicationIndex)
            let applicationObject: CFTypeRef = unsafeBitCast(
                applicationValue,
                to: CFTypeRef.self
            )
            guard CFGetTypeID(applicationObject) == SecTrustedApplicationGetTypeID() else {
                principals.append(.malformed)
                continue
            }
            let application = unsafeBitCast(
                applicationValue,
                to: SecTrustedApplication.self
            )
            var requirement: SecRequirement?
            let requirementStatus = SecTrustedApplicationCopyRequirementSPI(
                application,
                &requirement
            )
            guard requirementStatus == errSecSuccess else {
                throw KeychainACLValidationError.trustedApplicationRequirementCopyFailed(
                    status: requirementStatus
                )
            }
            guard let requirement else {
                throw KeychainACLValidationError.trustedApplicationRequirementMissing
            }
            var data: CFData?
            let dataStatus = SecRequirementCopyData(requirement, [], &data)
            guard dataStatus == errSecSuccess else {
                throw KeychainACLValidationError.requirementDataCopyFailed(status: dataStatus)
            }
            guard let data, CFDataGetLength(data) > 0 else {
                principals.append(.malformed)
                continue
            }
            principals.append(.requirement(data as Data))
        }

        try Self.validate(principals: principals, expected: expectedPrincipalData)
    }

    static func validate(
        principals: [KeychainACLPrincipal],
        expected: [Data]
    ) throws {
        guard !expected.isEmpty,
              Set(expected).count == expected.count
        else {
            throw KeychainACLValidationError.invalidExpectedPrincipalPolicy
        }

        var seen: Set<Data> = []
        for principal in principals {
            switch principal {
            case .wildcard:
                throw KeychainACLValidationError.wildcardPrincipal
            case .malformed:
                throw KeychainACLValidationError.malformedPrincipal
            case let .requirement(data):
                guard !data.isEmpty else {
                    throw KeychainACLValidationError.malformedPrincipal
                }
                guard expected.contains(data) else {
                    throw KeychainACLValidationError.extraPrincipal
                }
                guard seen.insert(data).inserted else {
                    throw KeychainACLValidationError.duplicatePrincipal
                }
            }
        }
        guard seen == Set(expected) else {
            throw KeychainACLValidationError.missingPrincipal
        }
    }
}

struct KeychainAccessAuthority {
    let creationAttributeProvider: TrustedApplicationsKeychainAttributeProvider
    let accessValidator: ClassicKeychainACLValidator

    init(
        descriptor: String,
        applications: [TrustedApplicationCodeRequirement]
    ) throws {
        guard applications.count == 2 else {
            throw KeychainACLValidationError.invalidExpectedPrincipalPolicy
        }
        creationAttributeProvider = TrustedApplicationsKeychainAttributeProvider(
            descriptor: descriptor,
            applications: applications
        )
        accessValidator = try ClassicKeychainACLValidator(
            requirementSources: applications.map(\.requirementSource)
        )
    }
}

final class TrustedApplicationsKeychainAttributeProvider: KeychainItemCreationAttributeProvider {
    let descriptor: String
    let applications: [TrustedApplicationCodeRequirement]

    private let lock = NSRecursiveLock()
    private var cachedAttributes: [String: Any]?

    init(descriptor: String, applications: [TrustedApplicationCodeRequirement]) {
        self.descriptor = descriptor
        self.applications = applications
    }

    func attributesForNewItem() throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedAttributes { return cachedAttributes }

        var trustedApplications: [SecTrustedApplication] = []
        trustedApplications.reserveCapacity(applications.count)

        for application in applications {
            guard RuntimeCodeSigningDetector.validatesStaticCode(
                at: application.codeURL,
                requirementSource: application.requirementSource
            ) else {
                throw KeychainItemCreationAttributeError.trustedApplicationValidationFailed(
                    path: application.trustedApplicationPath
                )
            }
            guard let requirement = RuntimeCodeSigningDetector.requirement(
                from: application.requirementSource
            ) else {
                throw KeychainACLValidationError.invalidExpectedPrincipalPolicy
            }
            var trustedApplication: SecTrustedApplication?
            let status = application.trustedApplicationPath.withCString { description in
                SecTrustedApplicationCreateFromRequirementSPI(
                    description,
                    requirement,
                    &trustedApplication
                )
            }
            guard status == errSecSuccess, let trustedApplication else {
                throw KeychainItemCreationAttributeError.trustedApplicationCreationFailed(
                    path: application.trustedApplicationPath,
                    status: status
                )
            }
            guard RuntimeCodeSigningDetector.validatesStaticCode(
                at: application.codeURL,
                requirementSource: application.requirementSource
            ) else {
                throw KeychainItemCreationAttributeError.trustedApplicationValidationFailed(
                    path: application.trustedApplicationPath
                )
            }
            trustedApplications.append(trustedApplication)
        }

        var access: SecAccess?
        let status = SecAccessCreate(descriptor as CFString, trustedApplications as CFArray, &access)
        guard status == errSecSuccess, let access else {
            throw KeychainItemCreationAttributeError.accessCreationFailed(status: status)
        }
        let attributes = [kSecAttrAccess as String: access]
        cachedAttributes = attributes
        return attributes
    }
}

/// Reuses the ACL from a bridge manifest whose creation was committed by the legacy
/// preparer. This lets later legacy builds create additional bridge records without
/// carrying a new successor-signed anchor in every package.
struct ExistingKeychainItemAccessAttributeProvider: KeychainItemCreationAttributeProvider {
    let serviceName: String
    let account: String
    let itemIdentityAttributes: [String: Any]
    let accessValidator: KeychainItemAccessValidator
    let itemAccessProvider: SecKeychainItemAccessProvider
    let secItemClient: SecItemClient

    init(
        serviceName: String,
        account: String,
        itemIdentityAttributes: [String: Any] = [:],
        accessValidator: KeychainItemAccessValidator,
        itemAccessProvider: SecKeychainItemAccessProvider = SystemSecKeychainItemAccessProvider(),
        secItemClient: SecItemClient = SystemSecItemClient()
    ) {
        self.serviceName = serviceName
        self.account = account
        self.itemIdentityAttributes = itemIdentityAttributes
        self.accessValidator = accessValidator
        self.itemAccessProvider = itemAccessProvider
        self.secItemClient = secItemClient
    }

    func attributesForNewItem() throws -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        query.merge(itemIdentityAttributes) { _, replacement in replacement }

        var result: AnyObject?
        let lookupStatus = secItemClient.copyMatching(query as CFDictionary, &result)
        guard lookupStatus == errSecSuccess else {
            throw KeychainItemCreationAttributeError.referenceItemLookupFailed(status: lookupStatus)
        }
        guard let result else {
            throw KeychainItemCreationAttributeError.referenceItemInvalid
        }

        let access = try itemAccessProvider.copyAccess(from: result)
        try accessValidator.validate(access)
        return [kSecAttrAccess as String: access]
    }
}

/// Secure storage service for one explicitly selected CE macOS Keychain domain.
final class KeychainService: SecureKeyValueStorageBackend, @unchecked Sendable {
    static let legacyCanonicalServiceName = "com.pvncher.repoprompt.ce.keychain"
    static let officialV2ServiceName = "com.pvncher.repoprompt.ce.developer-id.keychain.v2"
    static let identityMigrationBridgeServiceNamePrefix = "com.repoprompt.ce.identity-migration.keychain.v1."
    static let identityMigrationLegacyStateServiceName = "com.pvncher.repoprompt.ce.identity-migration.state.v2"
    static let localSelfSignedServiceNamePrefix = "com.pvncher.repoprompt.ce.local-self-signed."
    static let debugServiceName = "com.pvncher.repoprompt.ce.debug.keychain"

    static let officialV2Shared = KeychainService(serviceName: officialV2ServiceName)
    static let debugShared = KeychainService(serviceName: debugServiceName)

    static func localSelfSignedServiceName(fingerprint: String, generation: Int) -> String {
        let normalizedFingerprint = fingerprint.filter(\.isHexDigit).lowercased()
        precondition(normalizedFingerprint.count == 64, "Local certificate fingerprint must be SHA-256")
        precondition(generation > 0, "Local secure-storage generation must be positive")
        return "\(localSelfSignedServiceNamePrefix)\(normalizedFingerprint).keychain.v\(generation)"
    }

    static func localSelfSigned(fingerprint: String, generation: Int) -> KeychainService {
        KeychainService(serviceName: localSelfSignedServiceName(fingerprint: fingerprint, generation: generation))
    }

    static func legacyRepairSource(secItemClient: SecItemClient = SystemSecItemClient()) -> KeychainService {
        KeychainService(serviceName: legacyCanonicalServiceName, secItemClient: secItemClient)
    }

    static func identityMigrationBridgeServiceName(for attemptIdentifier: String) -> String? {
        guard let uuid = UUID(uuidString: attemptIdentifier),
              uuid.uuidString.lowercased() == attemptIdentifier
        else {
            return nil
        }
        return "\(identityMigrationBridgeServiceNamePrefix)\(attemptIdentifier)"
    }

    let serviceName: String
    private let secItemClient: SecItemClient
    private let itemCreationAttributeProvider: KeychainItemCreationAttributeProvider?
    private let itemIdentityAttributes: [String: Any]
    private let itemAccessValidator: KeychainItemAccessValidator?
    private let itemAccessProvider: SecKeychainItemAccessProvider
    private let operationLock = NSRecursiveLock()

    let persistsValuesAcrossLaunches = true

    init(
        serviceName: String = KeychainService.officialV2ServiceName,
        secItemClient: SecItemClient = SystemSecItemClient(),
        itemCreationAttributeProvider: KeychainItemCreationAttributeProvider? = nil,
        itemIdentityAttributes: [String: Any] = [:],
        itemAccessValidator: KeychainItemAccessValidator? = nil,
        itemAccessProvider: SecKeychainItemAccessProvider = SystemSecKeychainItemAccessProvider()
    ) {
        self.serviceName = serviceName
        self.secItemClient = secItemClient
        self.itemCreationAttributeProvider = itemCreationAttributeProvider
        self.itemIdentityAttributes = itemIdentityAttributes
        self.itemAccessValidator = itemAccessValidator
        self.itemAccessProvider = itemAccessProvider
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try body()
    }

    private func query(_ values: [String: Any], accessMode: KeychainAccessMode) -> [String: Any] {
        var query = values
        query.merge(itemIdentityAttributes) { _, replacement in replacement }
        if accessMode.isNonInteractive {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }
        return query
    }

    private func validateExistingItem(
        for key: String,
        accessMode: KeychainAccessMode
    ) throws {
        guard let itemAccessValidator else { return }
        let referenceQuery = query([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ], accessMode: accessMode)
        var result: AnyObject?
        let status = secItemClient.copyMatching(referenceQuery as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw keychainError(for: status)
        }
        guard let result else {
            throw KeychainItemAccessProviderError.invalidItemReference
        }
        let access = try itemAccessProvider.copyAccess(from: result)
        try itemAccessValidator.validate(access)
    }

    private func keychainError(for status: OSStatus) -> KeychainError {
        switch status {
        case errSecItemNotFound:
            .itemNotFound
        case errSecDuplicateItem:
            .duplicateItem
        case errSecInteractionNotAllowed:
            .interactionNotAllowed
        case errSecUserCanceled:
            .userInteractionCancelled
        case errSecAuthFailed:
            .authenticationFailed
        default:
            .unexpectedStatus(status)
        }
    }

    enum KeychainError: Error, LocalizedError, Equatable {
        case itemNotFound
        case duplicateItem
        case invalidData
        case interactionNotAllowed
        case userInteractionCancelled
        case authenticationFailed
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .itemNotFound:
                "Item not found in keychain"
            case .duplicateItem:
                "Item already exists"
            case .invalidData:
                "Invalid data format"
            case .interactionNotAllowed:
                "Keychain interaction is not allowed in the current access mode"
            case .userInteractionCancelled:
                "Keychain interaction was cancelled"
            case .authenticationFailed:
                "Keychain authentication failed"
            case let .unexpectedStatus(status):
                "Keychain error: \(status)"
            }
        }
    }

    // MARK: - Save to Keychain

    /// Save a UTF-8 string to this service only.
    func save(
        _ value: String,
        for key: String,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        try withLock {
            guard let data = value.data(using: .utf8) else {
                throw KeychainError.invalidData
            }

            if itemAccessValidator != nil {
                do {
                    try validateExistingItem(for: key, accessMode: accessMode)
                } catch KeychainError.itemNotFound {
                    // The atomic add below establishes the ACL for a new item.
                }
            }

            let itemQuery = query([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key
            ], accessMode: accessMode)

            let attributes: [String: Any] = [
                kSecValueData as String: data
            ]

            let updateStatus = secItemClient.update(itemQuery as CFDictionary, attributes as CFDictionary)
            switch updateStatus {
            case errSecSuccess:
                if itemAccessValidator != nil {
                    try validateExistingItem(for: key, accessMode: accessMode)
                }
                return
            case errSecItemNotFound:
                break
            default:
                throw keychainError(for: updateStatus)
            }

            try add(data, for: key, accessMode: accessMode)
        }
    }

    /// Atomically creates a UTF-8 value without falling back to an update. The
    /// migration bridge uses this to avoid retaining an unproven existing ACL.
    func create(
        _ value: String,
        for key: String,
        accessMode: KeychainAccessMode = .interactive
    ) throws {
        try withLock {
            guard let data = value.data(using: .utf8) else {
                throw KeychainError.invalidData
            }
            try add(data, for: key, accessMode: accessMode)
        }
    }

    private func add(
        _ data: Data,
        for key: String,
        accessMode: KeychainAccessMode
    ) throws {
        // kSecAttrAccess is the classic file-based Keychain ACL. Apple documents
        // kSecAttrAccessible as a data-protection-Keychain-only attribute on macOS.
        // A login Keychain may ignore kSecAttrAccessible here, but omitting an
        // inapplicable attribute keeps the item model explicit and portable.
        var newItem: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        if let itemCreationAttributeProvider {
            try newItem.merge(itemCreationAttributeProvider.attributesForNewItem()) { _, replacement in
                replacement
            }
        }
        let addQuery = query(newItem, accessMode: accessMode)

        let addStatus = secItemClient.add(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw keychainError(for: addStatus)
        }
        if itemAccessValidator != nil {
            try validateExistingItem(for: key, accessMode: accessMode)
        }
    }

    // MARK: - Retrieve from Keychain

    /// Retrieve a UTF-8 string from this service only.
    func get(
        for key: String,
        accessMode: KeychainAccessMode = .interactive
    ) throws -> String {
        let data = try withLock {
            try validateExistingItem(for: key, accessMode: accessMode)
            let itemQuery = query([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ], accessMode: accessMode)

            var result: AnyObject?
            let status = secItemClient.copyMatching(itemQuery as CFDictionary, &result)

            guard status == errSecSuccess else {
                throw keychainError(for: status)
            }

            guard let data = result as? Data else {
                throw KeychainError.invalidData
            }
            return data
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    // MARK: - Delete from Keychain

    /// Delete an item from this service only.
    func delete(for key: String, accessMode: KeychainAccessMode = .interactive) throws {
        try withLock {
            if itemAccessValidator != nil {
                do {
                    try validateExistingItem(for: key, accessMode: accessMode)
                } catch KeychainError.itemNotFound {
                    return
                }
            }
            let itemQuery = query([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: key
            ], accessMode: accessMode)

            let status = secItemClient.delete(itemQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw keychainError(for: status)
            }
        }
    }
}
