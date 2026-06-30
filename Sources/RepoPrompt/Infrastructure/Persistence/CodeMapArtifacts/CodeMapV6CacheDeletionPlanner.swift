import Darwin
import Foundation

struct CodeMapV6CacheDeletionTarget {
    let applicationSupportRootURL: URL
}

enum CodeMapV6CacheDeletionPolicy {
    static let cacheDirectoryName = "CodeMapCaches"
    static let maintenanceDirectoryName = "CodeMapMaintenance"
    static let maximumCandidateByteCount: off_t = 64 * 1024 * 1024
    static let completionSchemaVersion = 1
    static let deletionEpoch = "legacy-v6-root-cache-v1"
    static let lockFileName = "\(deletionEpoch).lock"
    static let completionFileName = "legacy-cache-deletion.json"
}

enum CodeMapV6CacheDeletionPlannerError: Error, Equatable {
    case insecureDirectory
    case ioFailure(operation: String, code: Int32)
}

struct CodeMapV6CacheDeletionPlannerHooks: @unchecked Sendable {
    var candidateStatusTransform: ((String, stat) -> stat)?

    init(candidateStatusTransform: ((String, stat) -> stat)? = nil) {
        self.candidateStatusTransform = candidateStatusTransform
    }

    static let none = CodeMapV6CacheDeletionPlannerHooks()
}

struct CodeMapV6CacheDeletionClassification: Equatable {
    var examinedCount = 0
    var eligibleV6Count = 0
    var missingOrRacedCount = 0
    var retainedUnrecognizedCount = 0
    var retryableFailureCount = 0
}

struct CodeMapV6CacheFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let owner: uid_t
    let type: mode_t
    let permissions: mode_t
    let linkCount: nlink_t
    let size: off_t
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        owner = status.st_uid
        type = status.st_mode & mode_t(S_IFMT)
        permissions = status.st_mode & mode_t(0o777)
        linkCount = status.st_nlink
        size = status.st_size
        modificationSeconds = Int64(status.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(status.st_mtimespec.tv_nsec)
        statusChangeSeconds = Int64(status.st_ctimespec.tv_sec)
        statusChangeNanoseconds = Int64(status.st_ctimespec.tv_nsec)
    }

    var isOwnerControlledDirectory: Bool {
        owner == getuid() && type == mode_t(S_IFDIR) && permissions & mode_t(S_IWGRP | S_IWOTH) == 0
    }

    func isSecureCandidate(on expectedDevice: dev_t) -> Bool {
        device == expectedDevice && owner == getuid() && type == mode_t(S_IFREG) &&
            permissions == mode_t(S_IRUSR | S_IWUSR) && linkCount == 1 &&
            size >= 0 && size <= CodeMapV6CacheDeletionPolicy.maximumCandidateByteCount
    }

    func isSameObject(as other: CodeMapV6CacheFileIdentity) -> Bool {
        device == other.device && inode == other.inode
    }
}

struct CodeMapV6CacheDeletionCandidate {
    let name: String
    let descriptor: Int32
    let identity: CodeMapV6CacheFileIdentity
}

final class CodeMapV6CacheDeletionPlan: @unchecked Sendable {
    let applicationSupportDescriptor: Int32
    let applicationSupportIdentity: CodeMapV6CacheFileIdentity
    let cacheDescriptor: Int32?
    let cacheIdentity: CodeMapV6CacheFileIdentity?
    let candidates: [CodeMapV6CacheDeletionCandidate]
    let classification: CodeMapV6CacheDeletionClassification

    init(
        applicationSupportDescriptor: Int32,
        applicationSupportIdentity: CodeMapV6CacheFileIdentity,
        cacheDescriptor: Int32?,
        cacheIdentity: CodeMapV6CacheFileIdentity?,
        candidates: [CodeMapV6CacheDeletionCandidate],
        classification: CodeMapV6CacheDeletionClassification
    ) {
        self.applicationSupportDescriptor = applicationSupportDescriptor
        self.applicationSupportIdentity = applicationSupportIdentity
        self.cacheDescriptor = cacheDescriptor
        self.cacheIdentity = cacheIdentity
        self.candidates = candidates
        self.classification = classification
    }

    deinit {
        for candidate in candidates {
            Darwin.close(candidate.descriptor)
        }
        if let cacheDescriptor {
            Darwin.close(cacheDescriptor)
        }
        Darwin.close(applicationSupportDescriptor)
    }
}

struct CodeMapV6CacheDeletionPlanner {
    private let hooks: CodeMapV6CacheDeletionPlannerHooks

    init(hooks: CodeMapV6CacheDeletionPlannerHooks = .none) {
        self.hooks = hooks
    }

    func plan(target: CodeMapV6CacheDeletionTarget) throws -> CodeMapV6CacheDeletionPlan {
        let applicationSupportDescriptor = Darwin.open(
            target.applicationSupportRootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard applicationSupportDescriptor >= 0 else { throw Self.ioError("application-support-open") }
        var ownsApplicationSupportDescriptor = true
        defer {
            if ownsApplicationSupportDescriptor {
                Darwin.close(applicationSupportDescriptor)
            }
        }

        let applicationSupportIdentity = try Self.identity(descriptor: applicationSupportDescriptor)
        guard applicationSupportIdentity.isOwnerControlledDirectory else {
            throw CodeMapV6CacheDeletionPlannerError.insecureDirectory
        }

        let cacheDescriptor = openat(
            applicationSupportDescriptor,
            CodeMapV6CacheDeletionPolicy.cacheDirectoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        if cacheDescriptor < 0, errno == ENOENT {
            ownsApplicationSupportDescriptor = false
            return CodeMapV6CacheDeletionPlan(
                applicationSupportDescriptor: applicationSupportDescriptor,
                applicationSupportIdentity: applicationSupportIdentity,
                cacheDescriptor: nil,
                cacheIdentity: nil,
                candidates: [],
                classification: CodeMapV6CacheDeletionClassification()
            )
        }
        guard cacheDescriptor >= 0 else { throw Self.ioError("cache-directory-open") }
        var ownsCacheDescriptor = true
        defer {
            if ownsCacheDescriptor {
                Darwin.close(cacheDescriptor)
            }
        }

        let cacheIdentity = try Self.identity(descriptor: cacheDescriptor)
        guard cacheIdentity.isOwnerControlledDirectory,
              cacheIdentity.device == applicationSupportIdentity.device,
              try Self.pathIdentity(
                  parentDescriptor: applicationSupportDescriptor,
                  name: CodeMapV6CacheDeletionPolicy.cacheDirectoryName
              ) == cacheIdentity
        else {
            throw CodeMapV6CacheDeletionPlannerError.insecureDirectory
        }

        let enumerationDescriptor = fcntl(cacheDescriptor, F_DUPFD_CLOEXEC, 0)
        guard enumerationDescriptor >= 0 else { throw Self.ioError("cache-directory-duplicate") }
        guard let directory = fdopendir(enumerationDescriptor) else {
            let code = errno
            Darwin.close(enumerationDescriptor)
            throw Self.ioError("cache-directory-enumerate", code: code)
        }
        defer { closedir(directory) }

        var candidates: [CodeMapV6CacheDeletionCandidate] = []
        var classification = CodeMapV6CacheDeletionClassification()
        do {
            while true {
                errno = 0
                guard let entry = readdir(directory) else {
                    if errno != 0 { throw Self.ioError("cache-directory-read") }
                    break
                }
                let name = Self.directoryEntryName(entry)
                guard Self.isCandidateName(name) else { continue }
                classification.examinedCount += 1

                let descriptor = openat(
                    cacheDescriptor,
                    name,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
                if descriptor < 0 {
                    if errno == ENOENT {
                        classification.missingOrRacedCount += 1
                    } else if errno == ELOOP {
                        classification.retainedUnrecognizedCount += 1
                    } else {
                        classification.retryableFailureCount += 1
                    }
                    continue
                }
                var ownsDescriptor = true
                defer {
                    if ownsDescriptor {
                        Darwin.close(descriptor)
                    }
                }

                var candidateStatus = stat()
                guard fstat(descriptor, &candidateStatus) == 0 else {
                    classification.retryableFailureCount += 1
                    continue
                }
                candidateStatus = hooks.candidateStatusTransform?(name, candidateStatus) ?? candidateStatus
                let candidateIdentity = CodeMapV6CacheFileIdentity(candidateStatus)
                guard candidateIdentity.isSecureCandidate(on: cacheIdentity.device) else {
                    classification.retainedUnrecognizedCount += 1
                    continue
                }

                let pathIdentity: CodeMapV6CacheFileIdentity
                do {
                    pathIdentity = try Self.pathIdentity(parentDescriptor: cacheDescriptor, name: name)
                } catch let CodeMapV6CacheDeletionPlannerError.ioFailure(_, code) where code == ENOENT {
                    classification.missingOrRacedCount += 1
                    continue
                } catch {
                    classification.retryableFailureCount += 1
                    continue
                }
                guard pathIdentity.isSameObject(as: candidateIdentity) else {
                    classification.missingOrRacedCount += 1
                    continue
                }

                let data: Data
                do {
                    data = try Self.readBoundedCandidate(
                        descriptor: descriptor,
                        expectedIdentity: candidateIdentity
                    )
                } catch {
                    classification.retryableFailureCount += 1
                    continue
                }
                guard Self.isVersionSixDeletionCandidate(data) else {
                    classification.retainedUnrecognizedCount += 1
                    continue
                }

                candidates.append(
                    CodeMapV6CacheDeletionCandidate(
                        name: name,
                        descriptor: descriptor,
                        identity: candidateIdentity
                    )
                )
                classification.eligibleV6Count += 1
                ownsDescriptor = false
            }
        } catch {
            for candidate in candidates {
                Darwin.close(candidate.descriptor)
            }
            throw error
        }

        ownsApplicationSupportDescriptor = false
        ownsCacheDescriptor = false
        return CodeMapV6CacheDeletionPlan(
            applicationSupportDescriptor: applicationSupportDescriptor,
            applicationSupportIdentity: applicationSupportIdentity,
            cacheDescriptor: cacheDescriptor,
            cacheIdentity: cacheIdentity,
            candidates: candidates,
            classification: classification
        )
    }

    private static func readBoundedCandidate(
        descriptor: Int32,
        expectedIdentity: CodeMapV6CacheFileIdentity
    ) throws -> Data {
        guard expectedIdentity.size >= 0,
              expectedIdentity.size <= CodeMapV6CacheDeletionPolicy.maximumCandidateByteCount,
              let byteCount = Int(exactly: expectedIdentity.size)
        else { throw CodeMapV6CacheDeletionPlannerError.insecureDirectory }

        var data = Data(count: byteCount)
        var offset = 0
        while offset < byteCount {
            let count = data.withUnsafeMutableBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    byteCount - offset,
                    off_t(offset)
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw Self.ioError("candidate-read") }
            offset += count
        }

        guard try Self.identity(descriptor: descriptor) == expectedIdentity else {
            throw CodeMapV6CacheDeletionPlannerError.insecureDirectory
        }
        return data
    }

    private static func isVersionSixDeletionCandidate(_ data: Data) -> Bool {
        struct DeletionHeader: Decodable {
            let version: Int
        }
        guard let header = try? JSONDecoder().decode(DeletionHeader.self, from: data) else {
            return false
        }
        return header.version == 6
    }

    private static func isCandidateName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count == 69 else { return false }
        guard Array(bytes[64...]) == Array(".json".utf8) else { return false }
        return bytes[..<64].allSatisfy { byte in
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) ||
                (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
        }
    }

    private static func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        withUnsafePointer(to: &entry.pointee.d_name) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(cString: $0)
            }
        }
    }

    static func identity(descriptor: Int32) throws -> CodeMapV6CacheFileIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw ioError("descriptor-stat") }
        return CodeMapV6CacheFileIdentity(status)
    }

    static func pathIdentity(
        parentDescriptor: Int32,
        name: String
    ) throws -> CodeMapV6CacheFileIdentity {
        var status = stat()
        guard fstatat(parentDescriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ioError("path-stat")
        }
        return CodeMapV6CacheFileIdentity(status)
    }

    static func ioError(
        _ operation: String,
        code: Int32 = errno
    ) -> CodeMapV6CacheDeletionPlannerError {
        .ioFailure(operation: operation, code: code)
    }
}
