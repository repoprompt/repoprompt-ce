import Crypto
import Foundation
import RepoPromptRuntimeModel

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public enum RepoPromptAuthorityServingMode: String, Codable, Sendable {
    case server
    case directHeadless
}

public struct AuthorityNamespaceDescriptor: Codable, Hashable, Sendable {
    public let storageRoot: String
    public let databasePath: String
    public let profile: String
    public let servingMode: RepoPromptAuthorityServingMode
    public let namespaceID: String

    private enum CodingKeys: String, CodingKey {
        case storageRoot
        case databasePath
        case profile
        case servingMode
        case namespaceID
    }

    public init(
        storageRoot: String,
        databasePath: String,
        profile: String,
        servingMode: RepoPromptAuthorityServingMode
    ) throws {
        try self.init(
            storageRoot: storageRoot,
            databasePath: databasePath,
            profile: profile,
            servingMode: servingMode,
            reservedDesktopAuthorityRoots: Self.defaultReservedDesktopAuthorityRoots
        )
    }

    init(
        storageRoot: String,
        databasePath: String,
        profile: String,
        servingMode: RepoPromptAuthorityServingMode,
        reservedDesktopAuthorityRoots: [String]
    ) throws {
        guard storageRoot.hasPrefix("/"), databasePath.hasPrefix("/") else {
            throw ServiceAPIError(code: .invalidRequest, message: "Authority namespace paths must be absolute")
        }
        let canonicalRoot = Self.canonicalPath(storageRoot, isDirectory: true)
        let canonicalDatabase = Self.canonicalDatabasePath(databasePath)
        let canonicalDatabaseParent = URL(fileURLWithPath: canonicalDatabase)
            .deletingLastPathComponent().path
        guard canonicalDatabaseParent == canonicalRoot else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "Authority database must be directly owned by its canonical storage root"
            )
        }
        try Self.validateProductPurpose(
            storageRoot: canonicalRoot,
            databasePath: canonicalDatabase,
            reservedDesktopAuthorityRoots: reservedDesktopAuthorityRoots
        )
        let canonicalProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !canonicalProfile.isEmpty else {
            throw ServiceAPIError(code: .invalidRequest, message: "Authority profile must not be empty")
        }
        self.storageRoot = canonicalRoot
        self.databasePath = canonicalDatabase
        self.profile = canonicalProfile
        self.servingMode = servingMode
        var parentInfo = stat()
        let parentIdentity: String
        if stat(canonicalRoot, &parentInfo) == 0 {
            parentIdentity = "\(parentInfo.st_dev):\(parentInfo.st_ino)"
        } else {
            parentIdentity = "unresolved-parent"
        }
        let material = [canonicalRoot, canonicalDatabase, canonicalProfile, parentIdentity]
            .joined(separator: "\u{0}")
        namespaceID = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedNamespaceID = try container.decodeIfPresent(String.self, forKey: .namespaceID)
        try self.init(
            storageRoot: container.decode(String.self, forKey: .storageRoot),
            databasePath: container.decode(String.self, forKey: .databasePath),
            profile: container.decode(String.self, forKey: .profile),
            servingMode: container.decode(RepoPromptAuthorityServingMode.self, forKey: .servingMode)
        )
        if let encodedNamespaceID, encodedNamespaceID != namespaceID {
            throw DecodingError.dataCorruptedError(
                forKey: .namespaceID,
                in: container,
                debugDescription: "Authority namespace identity does not match its canonical paths"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storageRoot, forKey: .storageRoot)
        try container.encode(databasePath, forKey: .databasePath)
        try container.encode(profile, forKey: .profile)
        try container.encode(servingMode, forKey: .servingMode)
        try container.encode(namespaceID, forKey: .namespaceID)
    }

    public var leasePath: String { databasePath + ".authority.lock" }
    public var ownerPath: String { databasePath + ".authority-owner.json" }
    public var purposePath: String { databasePath + ".authority-purpose.json" }

    private static var defaultReservedDesktopAuthorityRoots: [String] {
        #if os(macOS)
            [FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/RepoPrompt CE/AgentAuthority", isDirectory: true)
                .path]
        #else
            []
        #endif
    }

    private static func validateProductPurpose(
        storageRoot: String,
        databasePath: String,
        reservedDesktopAuthorityRoots: [String]
    ) throws {
        for configuredRoot in reservedDesktopAuthorityRoots {
            let reservedRoot = canonicalPath(configuredRoot, isDirectory: true)
            let rootComponents = URL(fileURLWithPath: storageRoot, isDirectory: true).pathComponents
            let reservedComponents = URL(fileURLWithPath: reservedRoot, isDirectory: true).pathComponents
            let insideReservedRoot = rootComponents.starts(with: reservedComponents)
            let reservedDatabase = URL(fileURLWithPath: reservedRoot, isDirectory: true)
                .appendingPathComponent("repoprompt.sqlite", isDirectory: false).path
            if insideReservedRoot || sameFilesystemNode(databasePath, reservedDatabase) {
                throw ServiceAPIError(
                    code: .authorityPurposeMismatch,
                    message: "Server authority storage must not use the reserved Desktop authority root"
                )
            }
        }
    }

    private static func canonicalPath(_ path: String, isDirectory: Bool) -> String {
        URL(fileURLWithPath: path, isDirectory: isDirectory)
            .standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func canonicalDatabasePath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().path
        }
        let parent = canonicalPath(url.deletingLastPathComponent().path, isDirectory: true)
        return URL(fileURLWithPath: parent, isDirectory: true)
            .appendingPathComponent(url.lastPathComponent, isDirectory: false).path
    }

    private static func sameFilesystemNode(_ lhs: String, _ rhs: String) -> Bool {
        var left = stat()
        var right = stat()
        guard stat(lhs, &left) == 0, stat(rhs, &right) == 0 else { return false }
        return left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }
}

public struct AuthorityNamespaceOwner: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let namespaceID: String
    public let servingMode: RepoPromptAuthorityServingMode
    public let pid: Int32
    public let hostname: String
    public let acquiredAt: Date
}

public struct AuthorityLeaseAcquisition: Sendable {
    public let lease: AuthorityNamespaceLease
    public let recoveredStaleOwner: Bool
}

/// Process- and host-exclusive authority lease. The descriptor registry closes
/// the same-process flock hole; the kernel lock closes cross-process races.
public final class AuthorityNamespaceLease: @unchecked Sendable {
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var heldNamespaces: Set<String> = []

    public let descriptor: AuthorityNamespaceDescriptor
    public let owner: AuthorityNamespaceOwner
    private let descriptorFD: Int32
    private let stateLock = NSLock()
    nonisolated(unsafe) private var released = false

    private init(descriptor: AuthorityNamespaceDescriptor, owner: AuthorityNamespaceOwner, descriptorFD: Int32) {
        self.descriptor = descriptor
        self.owner = owner
        self.descriptorFD = descriptorFD
    }

    deinit { release() }

    public static func acquire(_ descriptor: AuthorityNamespaceDescriptor) throws -> AuthorityLeaseAcquisition {
        try acquire(descriptor, localFilesystemProbe: supportsLocalAdvisoryLocking)
    }

    static func acquire(
        _ descriptor: AuthorityNamespaceDescriptor,
        localFilesystemProbe: (String) -> Bool
    ) throws -> AuthorityLeaseAcquisition {
        guard localFilesystemProbe(descriptor.storageRoot) else {
            throw ServiceAPIError(
                code: .authorityHostConflict,
                message: "Authority namespace filesystem does not provide supported local advisory locking"
            )
        }
        registryLock.lock()
        guard !heldNamespaces.contains(descriptor.namespaceID) else {
            registryLock.unlock()
            throw ServiceAPIError(code: .authorityHostConflict, message: "Authority namespace is already hosted in this process")
        }
        heldNamespaces.insert(descriptor.namespaceID)
        registryLock.unlock()

        var shouldUnregister = true
        defer {
            if shouldUnregister {
                registryLock.lock()
                heldNamespaces.remove(descriptor.namespaceID)
                registryLock.unlock()
            }
        }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: descriptor.storageRoot, isDirectory: true),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validateExistingLockNode(path: descriptor.leasePath)
        let fd = open(descriptor.leasePath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else {
            throw ServiceAPIError(code: .authorityHostConflict, message: "Unable to open authority namespace lease")
        }
        var keepFD = false
        defer { if !keepFD { _ = close(fd) } }
        try validateOpenLockDescriptor(fd)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw ServiceAPIError(code: .authorityHostConflict, message: "Authority namespace is already hosted by another process")
        }
        let recoveredStaleOwner = FileManager.default.fileExists(atPath: descriptor.ownerPath)
        var hostnameBuffer = [CChar](repeating: 0, count: 256)
        _ = gethostname(&hostnameBuffer, hostnameBuffer.count)
        let hostname = String(cString: hostnameBuffer)
        let owner = AuthorityNamespaceOwner(
            schemaVersion: 1,
            namespaceID: descriptor.namespaceID,
            servingMode: descriptor.servingMode,
            pid: getpid(),
            hostname: hostname,
            acquiredAt: Date()
        )
        try writeOwner(owner, path: descriptor.ownerPath)
        let lease = AuthorityNamespaceLease(descriptor: descriptor, owner: owner, descriptorFD: fd)
        keepFD = true
        shouldUnregister = false
        return AuthorityLeaseAcquisition(lease: lease, recoveredStaleOwner: recoveredStaleOwner)
    }

    private static func supportsLocalAdvisoryLocking(_ path: String) -> Bool {
        #if canImport(Darwin)
            var information = statfs()
            guard statfs(path, &information) == 0 else { return false }
            return (UInt32(information.f_flags) & UInt32(MNT_LOCAL)) != 0
        #elseif canImport(Glibc)
            return linuxFilesystemIsLocal(path)
        #else
            return false
        #endif
    }

    #if canImport(Glibc)
        /// Linux's Glibc module does not expose `statfs` consistently across supported
        /// toolchains. Mountinfo is kernel-owned and lets us fail closed while still
        /// distinguishing local container filesystems such as overlayfs from remote mounts.
        private static func linuxFilesystemIsLocal(_ path: String) -> Bool {
            guard let mountInfo = try? String(contentsOfFile: "/proc/self/mountinfo", encoding: .utf8) else {
                return false
            }
            let canonicalPath = URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath().path
            var bestMatch: (mountPoint: String, filesystemType: String)?
            for line in mountInfo.split(separator: "\n") {
                let sections = String(line).components(separatedBy: " - ")
                guard sections.count == 2 else { continue }
                let leftFields = sections[0].split(separator: " ")
                let rightFields = sections[1].split(separator: " ")
                guard leftFields.count >= 5, let filesystemType = rightFields.first else { continue }
                let mountPoint = decodeLinuxMountInfoPath(String(leftFields[4]))
                let matches = canonicalPath == mountPoint
                    || (mountPoint == "/" ? canonicalPath.hasPrefix("/") : canonicalPath.hasPrefix(mountPoint + "/"))
                guard matches, mountPoint.count > (bestMatch?.mountPoint.count ?? -1) else { continue }
                bestMatch = (mountPoint, String(filesystemType).lowercased())
            }
            guard let filesystemType = bestMatch?.filesystemType else { return false }
            let remoteTypes: Set<String> = ["9p", "afs", "ceph", "cifs", "nfs", "nfs4", "smb3", "sshfs"]
            return !remoteTypes.contains(filesystemType) && !filesystemType.hasPrefix("fuse")
        }

        private static func decodeLinuxMountInfoPath(_ path: String) -> String {
            path
                .replacingOccurrences(of: "\\040", with: " ")
                .replacingOccurrences(of: "\\011", with: "\t")
                .replacingOccurrences(of: "\\012", with: "\n")
                .replacingOccurrences(of: "\\134", with: "\\")
        }
    #endif

    public func release() {
        stateLock.lock()
        guard !released else { stateLock.unlock(); return }
        released = true
        stateLock.unlock()
        try? FileManager.default.removeItem(atPath: descriptor.ownerPath)
        _ = flock(descriptorFD, LOCK_UN)
        _ = close(descriptorFD)
        Self.registryLock.lock()
        Self.heldNamespaces.remove(descriptor.namespaceID)
        Self.registryLock.unlock()
    }

    private static func validateExistingLockNode(path: String) throws {
        var info = stat()
        if lstat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == geteuid(),
                  (info.st_mode & 0o777) == 0o600
            else {
                throw ServiceAPIError(code: .authorityHostConflict, message: "Authority lease file has unsafe owner, type, or mode")
            }
        } else if errno != ENOENT {
            throw ServiceAPIError(code: .authorityHostConflict, message: "Unable to inspect authority namespace lease")
        }
    }

    private static func validateOpenLockDescriptor(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              (info.st_mode & 0o777) == 0o600
        else {
            throw ServiceAPIError(code: .authorityHostConflict, message: "Authority lease descriptor failed safety validation")
        }
    }

    private static func writeOwner(_ owner: AuthorityNamespaceOwner, path: String) throws {
        let data = try JSONEncoder().encode(owner)
        let temporary = path + ".tmp-" + UUID().uuidString
        try data.write(to: URL(fileURLWithPath: temporary), options: .atomic)
        guard chmod(temporary, mode_t(0o600)) == 0 else {
            try? FileManager.default.removeItem(atPath: temporary)
            throw ServiceAPIError(code: .authorityHostConflict, message: "Unable to protect authority owner metadata")
        }
        if rename(temporary, path) != 0 {
            try? FileManager.default.removeItem(atPath: temporary)
            throw ServiceAPIError(code: .authorityHostConflict, message: "Unable to publish authority owner metadata")
        }
    }
}
