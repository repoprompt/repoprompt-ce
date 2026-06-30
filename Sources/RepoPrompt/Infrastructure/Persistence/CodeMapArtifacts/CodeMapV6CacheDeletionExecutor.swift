import CoreFoundation
import Darwin
import Foundation

struct CodeMapV6CacheDeletionReport: Equatable {
    var attemptCount = 0
    var examinedCount = 0
    var eligibleV6Count = 0
    var deletedCount = 0
    var missingOrRacedCount = 0
    var retainedUnrecognizedCount = 0
    var retryableFailureCount = 0
    var lockContentionCount = 0
    var completionWrittenCount = 0
    var durationMilliseconds: UInt64 = 0
}

enum CodeMapV6CacheDeletionSynchronizationOperation: Equatable {
    case completionFile
    case maintenanceDirectory
}

struct CodeMapV6CacheDeletionExecutorHooks: @unchecked Sendable {
    var beforeRemoval: ((String) throws -> Void)?
    var secureRemovalHooks: CodeMapSecureFileRemovalHooks?
    var didAcquireLock: (() -> Void)?
    var beforeCompletionPublication: (() throws -> Void)?
    var synchronize: (Int32, CodeMapV6CacheDeletionSynchronizationOperation) -> Int32
    var nowNanoseconds: () -> UInt64

    init(
        beforeRemoval: ((String) throws -> Void)? = nil,
        secureRemovalHooks: CodeMapSecureFileRemovalHooks? = nil,
        didAcquireLock: (() -> Void)? = nil,
        beforeCompletionPublication: (() throws -> Void)? = nil,
        synchronize: @escaping (Int32, CodeMapV6CacheDeletionSynchronizationOperation) -> Int32 = {
            descriptor,
            _ in fsync(descriptor)
        },
        nowNanoseconds: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.beforeRemoval = beforeRemoval
        self.secureRemovalHooks = secureRemovalHooks
        self.didAcquireLock = didAcquireLock
        self.beforeCompletionPublication = beforeCompletionPublication
        self.synchronize = synchronize
        self.nowNanoseconds = nowNanoseconds
    }

    static let none = CodeMapV6CacheDeletionExecutorHooks()
}

struct CodeMapV6CacheDeletionExecutor {
    private static let privateDirectoryMode = mode_t(S_IRWXU)
    private static let privateFileMode = mode_t(S_IRUSR | S_IWUSR)
    private static let maximumCompletionByteCount: off_t = 4 * 1024

    private let planner: CodeMapV6CacheDeletionPlanner
    private let hooks: CodeMapV6CacheDeletionExecutorHooks

    init(
        planner: CodeMapV6CacheDeletionPlanner = CodeMapV6CacheDeletionPlanner(),
        hooks: CodeMapV6CacheDeletionExecutorHooks = .none
    ) {
        self.planner = planner
        self.hooks = hooks
    }

    func execute(target: CodeMapV6CacheDeletionTarget) -> CodeMapV6CacheDeletionReport {
        let startedAt = hooks.nowNanoseconds()
        var report = CodeMapV6CacheDeletionReport(attemptCount: 1)
        do {
            try executeAttempt(target: target, report: &report)
        } catch ExecutorError.lockContention {
            report.lockContentionCount += 1
            report.retryableFailureCount += 1
        } catch {
            report.retryableFailureCount += 1
        }
        let finishedAt = hooks.nowNanoseconds()
        report.durationMilliseconds = finishedAt >= startedAt
            ? (finishedAt - startedAt) / 1_000_000
            : 0
        return report
    }

    private func executeAttempt(
        target: CodeMapV6CacheDeletionTarget,
        report: inout CodeMapV6CacheDeletionReport
    ) throws {
        let applicationSupportDescriptor = Darwin.open(
            target.applicationSupportRootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard applicationSupportDescriptor >= 0 else { throw ExecutorError.retryable }
        defer { Darwin.close(applicationSupportDescriptor) }
        let applicationSupportIdentity = try CodeMapV6CacheDeletionPlanner.identity(
            descriptor: applicationSupportDescriptor
        )
        guard applicationSupportIdentity.isOwnerControlledDirectory else {
            throw ExecutorError.retryable
        }

        let maintenanceDescriptor = try openMaintenanceDirectory(
            applicationSupportDescriptor: applicationSupportDescriptor,
            applicationSupportDevice: applicationSupportIdentity.device
        )
        defer { Darwin.close(maintenanceDescriptor) }
        let maintenanceIdentity = try CodeMapV6CacheDeletionPlanner.identity(
            descriptor: maintenanceDescriptor
        )
        try acquireNonblockingExclusiveLock(maintenanceDescriptor)
        defer { _ = flock(maintenanceDescriptor, LOCK_UN) }

        let lockDescriptor = try openLockFile(
            maintenanceDescriptor: maintenanceDescriptor,
            expectedDevice: applicationSupportIdentity.device
        )
        defer { Darwin.close(lockDescriptor) }
        try acquireNonblockingExclusiveLock(lockDescriptor)
        defer { _ = flock(lockDescriptor, LOCK_UN) }
        try validateHeldLockFile(
            lockDescriptor: lockDescriptor,
            maintenanceDescriptor: maintenanceDescriptor,
            expectedDevice: applicationSupportIdentity.device
        )
        try validateHeldPrivateDirectory(
            applicationSupportDescriptor: applicationSupportDescriptor,
            maintenanceDescriptor: maintenanceDescriptor,
            expectedIdentity: maintenanceIdentity
        )
        hooks.didAcquireLock?()

        switch try completionState(
            maintenanceDescriptor: maintenanceDescriptor,
            expectedDevice: applicationSupportIdentity.device
        ) {
        case .complete:
            try synchronize(maintenanceDescriptor, operation: .maintenanceDirectory)
            return
        case .missing:
            break
        case .invalid:
            throw ExecutorError.retryable
        }

        let plan = try planner.plan(target: target)
        guard plan.applicationSupportIdentity.isSameObject(as: applicationSupportIdentity),
              plan.applicationSupportIdentity.isOwnerControlledDirectory
        else { throw ExecutorError.retryable }
        report.examinedCount += plan.classification.examinedCount
        report.eligibleV6Count += plan.classification.eligibleV6Count
        report.missingOrRacedCount += plan.classification.missingOrRacedCount
        report.retainedUnrecognizedCount += plan.classification.retainedUnrecognizedCount
        report.retryableFailureCount += plan.classification.retryableFailureCount

        if let cacheDescriptor = plan.cacheDescriptor,
           let cacheIdentity = plan.cacheIdentity
        {
            for candidate in plan.candidates {
                do {
                    try validateHeldCacheDirectory(
                        applicationSupportDescriptor: applicationSupportDescriptor,
                        cacheDescriptor: cacheDescriptor,
                        expectedIdentity: cacheIdentity
                    )
                    guard try CodeMapV6CacheDeletionPlanner.identity(
                        descriptor: candidate.descriptor
                    ) == candidate.identity else {
                        report.missingOrRacedCount += 1
                        continue
                    }
                    try hooks.beforeRemoval?(candidate.name)
                    try validateHeldLockFile(
                        lockDescriptor: lockDescriptor,
                        maintenanceDescriptor: maintenanceDescriptor,
                        expectedDevice: applicationSupportIdentity.device
                    )
                    if try CodeMapSecureFileRemoval.remove(
                        parentDescriptor: cacheDescriptor,
                        expectedDevice: cacheIdentity.device,
                        name: candidate.name,
                        heldDescriptor: candidate.descriptor,
                        hooks: hooks.secureRemovalHooks
                    ) {
                        report.deletedCount += 1
                    } else {
                        report.missingOrRacedCount += 1
                    }
                } catch CodeMapSecureFileRemovalError.insecureEntry {
                    report.missingOrRacedCount += 1
                } catch {
                    report.retryableFailureCount += 1
                }
            }

            try validateHeldCacheDirectory(
                applicationSupportDescriptor: applicationSupportDescriptor,
                cacheDescriptor: cacheDescriptor,
                expectedIdentity: cacheIdentity
            )
        }

        let finalPlan = try planner.plan(target: target)
        guard finalPlan.applicationSupportIdentity.isSameObject(as: applicationSupportIdentity),
              finalPlan.applicationSupportIdentity.isOwnerControlledDirectory
        else { throw ExecutorError.retryable }
        if let originalCacheIdentity = plan.cacheIdentity {
            guard let finalCacheIdentity = finalPlan.cacheIdentity,
                  finalCacheIdentity.isSameObject(as: originalCacheIdentity),
                  finalCacheIdentity.isOwnerControlledDirectory
            else { throw ExecutorError.retryable }
        }

        if finalPlan.classification.eligibleV6Count > 0 {
            report.retryableFailureCount += finalPlan.classification.eligibleV6Count
        }
        report.retryableFailureCount += finalPlan.classification.retryableFailureCount
        guard report.retryableFailureCount == 0 else { return }

        try validateHeldPrivateDirectory(
            applicationSupportDescriptor: applicationSupportDescriptor,
            maintenanceDescriptor: maintenanceDescriptor,
            expectedIdentity: maintenanceIdentity
        )
        try hooks.beforeCompletionPublication?()
        try validateHeldLockFile(
            lockDescriptor: lockDescriptor,
            maintenanceDescriptor: maintenanceDescriptor,
            expectedDevice: applicationSupportIdentity.device
        )
        let wroteCompletion = try publishCompletion(
            maintenanceDescriptor: maintenanceDescriptor,
            expectedDevice: applicationSupportIdentity.device
        )
        try validateHeldLockFile(
            lockDescriptor: lockDescriptor,
            maintenanceDescriptor: maintenanceDescriptor,
            expectedDevice: applicationSupportIdentity.device
        )
        report.completionWrittenCount = wroteCompletion ? 1 : 0
    }

    private func acquireNonblockingExclusiveLock(_ descriptor: Int32) throws {
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            if errno == EWOULDBLOCK || errno == EAGAIN {
                throw ExecutorError.lockContention
            }
            throw ExecutorError.retryable
        }
    }

    private func validateHeldLockFile(
        lockDescriptor: Int32,
        maintenanceDescriptor: Int32,
        expectedDevice: dev_t
    ) throws {
        try validateSecureFile(
            descriptor: lockDescriptor,
            parentDescriptor: maintenanceDescriptor,
            name: CodeMapV6CacheDeletionPolicy.lockFileName,
            expectedDevice: expectedDevice,
            maximumByteCount: nil
        )
    }

    private func openMaintenanceDirectory(
        applicationSupportDescriptor: Int32,
        applicationSupportDevice: dev_t
    ) throws -> Int32 {
        if mkdirat(
            applicationSupportDescriptor,
            CodeMapV6CacheDeletionPolicy.maintenanceDirectoryName,
            Self.privateDirectoryMode
        ) != 0, errno != EEXIST {
            throw ExecutorError.retryable
        }
        let descriptor = openat(
            applicationSupportDescriptor,
            CodeMapV6CacheDeletionPolicy.maintenanceDirectoryName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw ExecutorError.retryable }
        do {
            let identity = try CodeMapV6CacheDeletionPlanner.identity(descriptor: descriptor)
            let pathIdentity = try CodeMapV6CacheDeletionPlanner.pathIdentity(
                parentDescriptor: applicationSupportDescriptor,
                name: CodeMapV6CacheDeletionPolicy.maintenanceDirectoryName
            )
            guard identity.device == applicationSupportDevice,
                  identity.owner == getuid(),
                  identity.type == mode_t(S_IFDIR),
                  identity.permissions == Self.privateDirectoryMode,
                  pathIdentity == identity
            else { throw ExecutorError.retryable }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openLockFile(
        maintenanceDescriptor: Int32,
        expectedDevice: dev_t
    ) throws -> Int32 {
        let descriptor = openat(
            maintenanceDescriptor,
            CodeMapV6CacheDeletionPolicy.lockFileName,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            Self.privateFileMode
        )
        guard descriptor >= 0 else { throw ExecutorError.retryable }
        do {
            try validateSecureFile(
                descriptor: descriptor,
                parentDescriptor: maintenanceDescriptor,
                name: CodeMapV6CacheDeletionPolicy.lockFileName,
                expectedDevice: expectedDevice,
                maximumByteCount: nil
            )
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func validateHeldCacheDirectory(
        applicationSupportDescriptor: Int32,
        cacheDescriptor: Int32,
        expectedIdentity: CodeMapV6CacheFileIdentity
    ) throws {
        let heldIdentity = try CodeMapV6CacheDeletionPlanner.identity(descriptor: cacheDescriptor)
        let pathIdentity = try CodeMapV6CacheDeletionPlanner.pathIdentity(
            parentDescriptor: applicationSupportDescriptor,
            name: CodeMapV6CacheDeletionPolicy.cacheDirectoryName
        )
        guard heldIdentity.isSameObject(as: expectedIdentity),
              pathIdentity.isSameObject(as: expectedIdentity),
              heldIdentity.isOwnerControlledDirectory,
              pathIdentity.isOwnerControlledDirectory
        else { throw ExecutorError.retryable }
    }

    private func validateHeldPrivateDirectory(
        applicationSupportDescriptor: Int32,
        maintenanceDescriptor: Int32,
        expectedIdentity: CodeMapV6CacheFileIdentity
    ) throws {
        let heldIdentity = try CodeMapV6CacheDeletionPlanner.identity(descriptor: maintenanceDescriptor)
        let pathIdentity = try CodeMapV6CacheDeletionPlanner.pathIdentity(
            parentDescriptor: applicationSupportDescriptor,
            name: CodeMapV6CacheDeletionPolicy.maintenanceDirectoryName
        )
        guard heldIdentity.isSameObject(as: expectedIdentity),
              pathIdentity.isSameObject(as: expectedIdentity),
              heldIdentity.owner == getuid(),
              heldIdentity.type == mode_t(S_IFDIR),
              heldIdentity.permissions == Self.privateDirectoryMode,
              pathIdentity.owner == getuid(),
              pathIdentity.type == mode_t(S_IFDIR),
              pathIdentity.permissions == Self.privateDirectoryMode
        else { throw ExecutorError.retryable }
    }

    private func validateSecureFile(
        descriptor: Int32,
        parentDescriptor: Int32,
        name: String,
        expectedDevice: dev_t,
        maximumByteCount: off_t?
    ) throws {
        let identity = try CodeMapV6CacheDeletionPlanner.identity(descriptor: descriptor)
        let pathIdentity = try CodeMapV6CacheDeletionPlanner.pathIdentity(
            parentDescriptor: parentDescriptor,
            name: name
        )
        guard identity.device == expectedDevice,
              identity.owner == getuid(),
              identity.type == mode_t(S_IFREG),
              identity.permissions == Self.privateFileMode,
              identity.linkCount == 1,
              identity.size >= 0,
              maximumByteCount.map({ identity.size <= $0 }) ?? true,
              pathIdentity == identity
        else { throw ExecutorError.retryable }
    }

    private func completionState(
        maintenanceDescriptor: Int32,
        expectedDevice: dev_t
    ) throws -> CompletionState {
        let descriptor = openat(
            maintenanceDescriptor,
            CodeMapV6CacheDeletionPolicy.completionFileName,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT { return .missing }
        guard descriptor >= 0 else { return .invalid }
        defer { Darwin.close(descriptor) }
        do {
            try validateSecureFile(
                descriptor: descriptor,
                parentDescriptor: maintenanceDescriptor,
                name: CodeMapV6CacheDeletionPolicy.completionFileName,
                expectedDevice: expectedDevice,
                maximumByteCount: Self.maximumCompletionByteCount
            )
            let identity = try CodeMapV6CacheDeletionPlanner.identity(descriptor: descriptor)
            let data = try readExact(descriptor: descriptor, byteCount: Int(identity.size))
            guard try CodeMapV6CacheDeletionPlanner.identity(descriptor: descriptor) == identity else {
                return .invalid
            }
            return Self.isMatchingCompletion(data) ? .complete : .invalid
        } catch {
            return .invalid
        }
    }

    private func publishCompletion(
        maintenanceDescriptor: Int32,
        expectedDevice: dev_t
    ) throws -> Bool {
        let temporaryName = ".\(CodeMapV6CacheDeletionPolicy.completionFileName).tmp.\(UUID().uuidString.lowercased())"
        let descriptor = openat(
            maintenanceDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            Self.privateFileMode
        )
        guard descriptor >= 0 else { throw ExecutorError.retryable }
        defer {
            Darwin.close(descriptor)
            unlinkat(maintenanceDescriptor, temporaryName, 0)
        }

        let data = Data(
            "{\"schemaVersion\":1,\"deletionEpoch\":\"\(CodeMapV6CacheDeletionPolicy.deletionEpoch)\"}\n".utf8
        )
        try writeAll(data, descriptor: descriptor)
        try validateSecureFile(
            descriptor: descriptor,
            parentDescriptor: maintenanceDescriptor,
            name: temporaryName,
            expectedDevice: expectedDevice,
            maximumByteCount: Self.maximumCompletionByteCount
        )
        try synchronize(descriptor, operation: .completionFile)

        let wroteCompletion: Bool
        if renameatx_np(
            maintenanceDescriptor,
            temporaryName,
            maintenanceDescriptor,
            CodeMapV6CacheDeletionPolicy.completionFileName,
            UInt32(RENAME_EXCL)
        ) != 0 {
            guard errno == EEXIST,
                  try completionState(
                      maintenanceDescriptor: maintenanceDescriptor,
                      expectedDevice: expectedDevice
                  ) == .complete
            else { throw ExecutorError.retryable }
            wroteCompletion = false
        } else {
            wroteCompletion = true
        }
        try synchronize(maintenanceDescriptor, operation: .maintenanceDirectory)
        return wroteCompletion
    }

    private func synchronize(
        _ descriptor: Int32,
        operation: CodeMapV6CacheDeletionSynchronizationOperation
    ) throws {
        while hooks.synchronize(descriptor, operation) != 0 {
            if errno == EINTR { continue }
            throw ExecutorError.retryable
        }
    }

    private func readExact(descriptor: Int32, byteCount: Int) throws -> Data {
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
            guard count > 0 else { throw ExecutorError.retryable }
            offset += count
        }
        return data
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return 0 }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ExecutorError.retryable }
            offset += count
        }
    }

    private static func isMatchingCompletion(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              dictionary.count == 2,
              Set(dictionary.keys) == Set(["schemaVersion", "deletionEpoch"]),
              let schema = dictionary["schemaVersion"] as? NSNumber,
              isIntegerNumber(schema),
              schema.intValue == CodeMapV6CacheDeletionPolicy.completionSchemaVersion,
              dictionary["deletionEpoch"] as? String == CodeMapV6CacheDeletionPolicy.deletionEpoch
        else { return false }
        return true
    }

    private static func isIntegerNumber(_ number: NSNumber) -> Bool {
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"]
            .contains(String(cString: number.objCType))
    }

    private enum CompletionState: Equatable {
        case missing
        case complete
        case invalid
    }

    private enum ExecutorError: Error {
        case lockContention
        case retryable
    }
}
