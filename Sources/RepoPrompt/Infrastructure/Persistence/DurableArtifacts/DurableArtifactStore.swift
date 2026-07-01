import CryptoKit
import Darwin
import Foundation

struct DurableArtifactFamily: Hashable, RawRepresentable {
    let rawValue: String

    init?(rawValue: String) {
        let bytes = Array(rawValue.utf8)
        guard !bytes.isEmpty, bytes.count <= 64,
              bytes.allSatisfy({ (0x61 ... 0x7A).contains($0) || (0x30 ... 0x39).contains($0) || $0 == 0x2D }),
              bytes.first != 0x2D, bytes.last != 0x2D
        else { return nil }
        self.rawValue = rawValue
    }
}

struct DurableArtifactDigest: Hashable, CustomStringConvertible {
    let bytes: Data

    init(bytes: Data) throws {
        guard bytes.count == 32 else { throw DurableArtifactStoreError.invalidDigest }
        self.bytes = bytes
    }

    init(hex: String) throws {
        guard hex.utf8.count == 64 else { throw DurableArtifactStoreError.invalidDigest }
        var data = Data(capacity: 32)
        var index = hex.startIndex
        for _ in 0 ..< 32 {
            let next = hex.index(index, offsetBy: 2)
            let pair = hex[index ..< next]
            guard pair.allSatisfy({ $0.isNumber || ("a" ... "f").contains($0) }),
                  let byte = UInt8(pair, radix: 16)
            else { throw DurableArtifactStoreError.invalidDigest }
            data.append(byte)
            index = next
        }
        bytes = data
    }

    var hex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    var description: String {
        hex
    }
}

struct DurableArtifactObjectID: Hashable {
    let family: DurableArtifactFamily
    let digest: DurableArtifactDigest
}

struct DurableArtifactObjectExpectation: Hashable {
    let id: DurableArtifactObjectID
    let schemaVersion: UInt32
    let canonicalIdentity: Data
}

struct DurableArtifactFramingPolicy {
    static let `default` = DurableArtifactFramingPolicy()

    let maximumIdentityByteCount: UInt64
    let maximumRecordByteCount: UInt64
    let ioBufferByteCount: Int

    init(
        maximumIdentityByteCount: UInt64 = 4 * 1024 * 1024,
        maximumRecordByteCount: UInt64 = 64 * 1024 * 1024,
        ioBufferByteCount: Int = 64 * 1024
    ) {
        self.maximumIdentityByteCount = maximumIdentityByteCount
        self.maximumRecordByteCount = maximumRecordByteCount
        self.ioBufferByteCount = max(4096, ioBufferByteCount)
    }
}

struct DurableArtifactDiskPolicy {
    static let `default` = DurableArtifactDiskPolicy()

    let quotaBytes: UInt64
    let minimumFreeReserveBytes: UInt64
    let minimumOrphanAgeSeconds: UInt64
    let quarantineGraceSeconds: UInt64
    let abandonedWorkAgeSeconds: UInt64

    init(
        quotaBytes: UInt64 = 8 * 1024 * 1024 * 1024,
        minimumFreeReserveBytes: UInt64 = 512 * 1024 * 1024,
        minimumOrphanAgeSeconds: UInt64 = 60 * 60,
        quarantineGraceSeconds: UInt64 = 24 * 60 * 60,
        abandonedWorkAgeSeconds: UInt64 = 60 * 60
    ) {
        self.quotaBytes = quotaBytes
        self.minimumFreeReserveBytes = minimumFreeReserveBytes
        self.minimumOrphanAgeSeconds = minimumOrphanAgeSeconds
        self.quarantineGraceSeconds = quarantineGraceSeconds
        self.abandonedWorkAgeSeconds = abandonedWorkAgeSeconds
    }
}

enum DurableArtifactAdmissionReason: Equatable {
    case quota
    case minimumFreeReserve
    case declaredBoundExceeded
    case noSpace
}

enum DurableArtifactPublicationResult: Equatable {
    case published(id: DurableArtifactObjectID, byteCount: UInt64)
    case coalesced(id: DurableArtifactObjectID, byteCount: UInt64)
    case notAdmitted(DurableArtifactAdmissionReason)
    case busy
    case familyDisabled
}

enum DurableArtifactOpenResult {
    case available(DurableArtifactReadLease)
    case missing
    case busy
    case corruptQuarantined
    case corruptBusy
    case familyDisabled
}

struct DurableArtifactCatalogPointer: Equatable {
    let family: DurableArtifactFamily
    let target: DurableArtifactObjectID
    let revision: DurableArtifactDigest
    let predecessorRevision: DurableArtifactDigest?
}

enum DurableArtifactCatalogReadResult: Equatable {
    case available(DurableArtifactCatalogPointer)
    case missing
    case busy
    case corruptQuarantined
    case familyDisabled
}

enum DurableArtifactCatalogCASResult: Equatable {
    case published(DurableArtifactCatalogPointer)
    case deleted
    case unchanged(DurableArtifactCatalogPointer)
    case conflict(currentRevision: DurableArtifactDigest?)
    case notAdmitted(DurableArtifactAdmissionReason)
    case busy
    case familyDisabled
}

enum DurableArtifactStoreError: Error, Equatable {
    case invalidBuildFlavor
    case invalidFamily
    case invalidDigest
    case invalidFraming
    case framingOverflow
    case unsortedRecords
    case insecureEntry
    case identityMismatch
    case digestCollision
    case familyDisabled
    case simulatedCrash(DurableArtifactCrashPoint)
    case ioFailure(operation: String, code: Int32)
}

protocol DurableArtifactStore: AnyObject {
    var rootURL: URL { get }

    func repositoryNamespace(
        for commonDirectory: DurableArtifactCommonDirectoryIdentity
    ) throws -> WorkspaceDurableRepositoryNamespace

    func publishObject(
        family: DurableArtifactFamily,
        schemaVersion: UInt32,
        canonicalIdentity: Data,
        admittedByteUpperBound: UInt64,
        records: (DurableArtifactObjectWriter) throws -> Void
    ) throws -> DurableArtifactPublicationResult

    func openObject(_ expectation: DurableArtifactObjectExpectation) throws -> DurableArtifactOpenResult

    func loadCatalog(for family: DurableArtifactFamily) throws -> DurableArtifactCatalogReadResult

    func compareAndSwapCatalog(
        family: DurableArtifactFamily,
        expectedRevision: DurableArtifactDigest?,
        target: DurableArtifactObjectID?,
        admittedByteUpperBound: UInt64
    ) throws -> DurableArtifactCatalogCASResult

    func quarantineObject(using lease: DurableArtifactReadLease) throws -> Bool

    func garbageCollect(
        protecting objects: Set<DurableArtifactObjectID>,
        referenceEnumerator: DurableArtifactReferenceEnumerator?,
        policy: DurableArtifactGCPolicy
    ) throws -> DurableArtifactGCReport

    func deleteObsoleteVersions() throws -> DurableArtifactObsoleteDeletionReport
}

final class LocalDurableArtifactStore: DurableArtifactStore, @unchecked Sendable {
    let rootURL: URL
    let framingPolicy: DurableArtifactFramingPolicy
    let diskPolicy: DurableArtifactDiskPolicy
    let layout: DurableArtifactLayout
    let hooks: DurableArtifactStoreHooks
    private let installationIdentity: DurableArtifactInstallationIdentity

    private final class DisabledFamilyRegistry: @unchecked Sendable {
        let lock = NSLock()
        var families = Set<String>()
    }

    private static let disabledRegistry = DisabledFamilyRegistry()

    convenience init(
        applicationSupportURL: URL,
        buildFlavor: String,
        framingPolicy: DurableArtifactFramingPolicy = .default,
        diskPolicy: DurableArtifactDiskPolicy = .default
    ) throws {
        try self.init(
            applicationSupportURL: applicationSupportURL,
            buildFlavor: buildFlavor,
            framingPolicy: framingPolicy,
            diskPolicy: diskPolicy,
            hooks: .live
        )
    }

    init(
        applicationSupportURL: URL,
        buildFlavor: String,
        framingPolicy: DurableArtifactFramingPolicy,
        diskPolicy: DurableArtifactDiskPolicy,
        hooks: DurableArtifactStoreHooks
    ) throws {
        self.framingPolicy = framingPolicy
        self.diskPolicy = diskPolicy
        self.hooks = hooks
        layout = try DurableArtifactSecureIO.openLayout(
            applicationSupportURL: applicationSupportURL,
            buildFlavor: buildFlavor
        )
        rootURL = layout.rootURL
        installationIdentity = DurableArtifactInstallationIdentity(layout: layout, hooks: hooks)
    }

    func repositoryNamespace(
        for commonDirectory: DurableArtifactCommonDirectoryIdentity
    ) throws -> WorkspaceDurableRepositoryNamespace {
        try installationIdentity.repositoryNamespace(for: commonDirectory)
    }

    func publishObject(
        family: DurableArtifactFamily,
        schemaVersion: UInt32,
        canonicalIdentity: Data,
        admittedByteUpperBound: UInt64,
        records: (DurableArtifactObjectWriter) throws -> Void
    ) throws -> DurableArtifactPublicationResult {
        if familyIsDisabled(family) { return .familyDisabled }
        guard UInt64(canonicalIdentity.count) <= framingPolicy.maximumIdentityByteCount else {
            throw DurableArtifactStoreError.invalidFraming
        }
        let layoutLock = try DurableArtifactSecureIO.lockDescriptor(
            parent: layout.root,
            name: ".layout.lock",
            exclusive: false,
            nonBlocking: true
        )
        guard let layoutLock else { return .busy }
        defer { layoutLock.close() }
        try validateCurrentLayout()
        let maintenance = try DurableArtifactSecureIO.lockDescriptor(
            parent: layout.version,
            name: "maintenance.lock",
            exclusive: true,
            nonBlocking: true
        )
        guard let maintenance else { return .busy }
        defer { maintenance.close() }
        if let reason = try admissionFailure(for: admittedByteUpperBound) { return .notAdmitted(reason) }

        let temporaryName = ".tmp.\(hooks.token())"
        let temporary = try DurableArtifactSecureIO.createExclusiveFile(parent: layout.work, name: temporaryName)
        var temporaryIdentity: DurableArtifactFileIdentity? = try DurableArtifactSecureIO.validateRegularFile(
            descriptor: temporary.rawValue,
            parent: layout.work,
            name: temporaryName
        )
        var preserveTemporary = false
        var published = false
        defer {
            if !published, !preserveTemporary,
               let current = try? DurableArtifactSecureIO.validateRegularFile(
                   descriptor: temporary.rawValue,
                   parent: layout.work,
                   name: temporaryName
               )
            {
                _ = try? DurableArtifactSecureIO.removeIfSame(
                    parent: layout.work,
                    name: temporaryName,
                    descriptor: temporary.rawValue,
                    identity: current
                )
            }
            temporary.close()
        }
        do {
            let writer = try DurableArtifactObjectWriter(
                descriptor: temporary.rawValue,
                family: family,
                schemaVersion: schemaVersion,
                canonicalIdentity: canonicalIdentity,
                byteUpperBound: admittedByteUpperBound,
                policy: framingPolicy,
                hooks: hooks
            )
            try records(writer)
            let completed = try writer.finish()
            temporaryIdentity = try DurableArtifactSecureIO.validateRegularFile(
                descriptor: temporary.rawValue,
                parent: layout.work,
                name: temporaryName
            )
            try hooks.crash(.afterObjectTemporaryWrite)
            try DurableArtifactSecureIO.synchronize(temporary.rawValue, operation: "object-file-sync")
            let validated = try DurableArtifactObjectFrame.validate(
                descriptor: temporary.rawValue,
                expectedFileSize: temporaryIdentity!.size,
                expected: DurableArtifactObjectExpectation(
                    id: DurableArtifactObjectID(family: family, digest: completed.digest),
                    schemaVersion: schemaVersion,
                    canonicalIdentity: canonicalIdentity
                ),
                policy: framingPolicy,
                hooks: hooks,
                recordBody: nil
            )
            guard validated.digest == completed.digest else { throw DurableArtifactStoreError.invalidFraming }
            temporaryIdentity = try DurableArtifactSecureIO.validateRegularFile(
                descriptor: temporary.rawValue,
                parent: layout.work,
                name: temporaryName
            )
            try hooks.crash(.afterObjectFileSync)

            let id = DurableArtifactObjectID(family: family, digest: completed.digest)
            let destination = try objectDirectory(for: id, create: true)!
            let lockParent = try objectLockDirectory(for: id, create: true)!
            let objectLock = try DurableArtifactSecureIO.lockDescriptor(
                parent: lockParent,
                name: "\(id.digest.hex).lock",
                exclusive: true,
                nonBlocking: true
            )
            guard let objectLock else { return .busy }
            defer { objectLock.close() }
            if let existing = try DurableArtifactSecureIO.openRegularFile(parent: destination, name: id.digest.hex) {
                defer { existing.0.close() }
                do {
                    let existingMetadata = try DurableArtifactObjectFrame.validate(
                        descriptor: existing.0.rawValue,
                        expectedFileSize: existing.1.size,
                        expected: nil,
                        policy: framingPolicy,
                        hooks: hooks,
                        recordBody: nil
                    )
                    guard existingMetadata.digest == id.digest else {
                        throw DurableArtifactStoreError.invalidFraming
                    }
                    if try filesEqual(
                        lhs: temporary.rawValue,
                        lhsSize: temporaryIdentity!.size,
                        rhs: existing.0.rawValue,
                        rhsSize: existing.1.size
                    ) {
                        return .coalesced(id: id, byteCount: UInt64(existing.1.size))
                    }
                    try disable(family, collisionDigest: id.digest)
                    try quarantine(
                        parent: destination,
                        name: id.digest.hex,
                        descriptor: existing.0.rawValue,
                        identity: existing.1,
                        kind: "collision",
                        id: id
                    )
                    try quarantine(
                        parent: layout.work,
                        name: temporaryName,
                        descriptor: temporary.rawValue,
                        identity: temporaryIdentity!,
                        kind: "collision",
                        id: id
                    )
                    published = true
                    throw DurableArtifactStoreError.digestCollision
                } catch let error as DurableArtifactStoreError where error.isAuthenticatedCorruption {
                    try quarantine(
                        parent: destination,
                        name: id.digest.hex,
                        descriptor: existing.0.rawValue,
                        identity: existing.1,
                        kind: "corrupt",
                        id: id
                    )
                }
            }
            try hooks.crash(.beforeObjectInstall)
            guard let installed = try DurableArtifactSecureIO.installValidatedDescriptorNoReplace(
                sourceDescriptor: temporary.rawValue,
                sourceIdentity: temporaryIdentity!,
                destinationParent: destination,
                destinationName: id.digest.hex
            ) else {
                throw DurableArtifactStoreError.ioFailure(operation: "object-publish-race", code: EEXIST)
            }
            defer { installed.0.close() }
            do {
                try hooks.crash(.afterObjectInstallBeforeValidation)
                let installedMetadata = try DurableArtifactObjectFrame.validate(
                    descriptor: installed.0.rawValue,
                    expectedFileSize: installed.1.size,
                    expected: DurableArtifactObjectExpectation(
                        id: id,
                        schemaVersion: schemaVersion,
                        canonicalIdentity: canonicalIdentity
                    ),
                    policy: framingPolicy,
                    hooks: hooks,
                    recordBody: nil
                )
                guard installedMetadata.digest == id.digest,
                      try DurableArtifactSecureIO.identity(installed.0.rawValue) == installed.1,
                      try DurableArtifactSecureIO.pathIdentity(
                          parent: destination,
                          name: id.digest.hex
                      ) == installed.1
                else { throw DurableArtifactStoreError.insecureEntry }
            } catch let error as DurableArtifactStoreError {
                if case .simulatedCrash = error { throw error }
                let restorationError: Error?
                do {
                    try restoreDescriptorAfterFailedPostCheck(
                        sourceDescriptor: installed.0.rawValue,
                        sourceIdentity: installed.1,
                        destinationParent: destination,
                        destinationName: id.digest.hex,
                        quarantineID: id
                    )
                    restorationError = nil
                } catch {
                    restorationError = error
                }
                try disable(family, collisionDigest: id.digest)
                if let restorationError { throw restorationError }
                throw error
            }
            try hooks.crash(.afterObjectRename)
            try DurableArtifactSecureIO.synchronize(destination.descriptor.rawValue, operation: "object-directory-sync")
            try hooks.crash(.afterObjectDirectorySync)
            return .published(id: id, byteCount: UInt64(installed.1.size))
        } catch let error as DurableArtifactStoreError {
            if case .simulatedCrash = error { preserveTemporary = true }
            if case let .ioFailure(_, code) = error, code == ENOSPC || code == EDQUOT {
                return .notAdmitted(.noSpace)
            }
            if case let .ioFailure(operation, code) = error,
               operation == "declared-bound" || code == EFBIG
            {
                return .notAdmitted(.declaredBoundExceeded)
            }
            throw error
        }
    }

    func openObject(_ expectation: DurableArtifactObjectExpectation) throws -> DurableArtifactOpenResult {
        if familyIsDisabled(expectation.id.family) { return .familyDisabled }
        guard let objectParent = try objectDirectory(for: expectation.id, create: false) else { return .missing }
        let lockParent = try objectLockDirectory(for: expectation.id, create: true)!
        let layoutLock = try DurableArtifactSecureIO.lockDescriptor(
            parent: layout.root,
            name: ".layout.lock",
            exclusive: false,
            nonBlocking: true
        )
        guard let layoutLock else { return .busy }
        do {
            try validateCurrentLayout()
        } catch {
            layoutLock.close()
            throw error
        }
        let objectLock = try DurableArtifactSecureIO.lockDescriptor(
            parent: lockParent,
            name: "\(expectation.id.digest.hex).lock",
            exclusive: false,
            nonBlocking: true
        )
        guard let objectLock else {
            layoutLock.close()
            return .busy
        }
        guard let opened = try DurableArtifactSecureIO.openRegularFile(
            parent: objectParent,
            name: expectation.id.digest.hex
        ) else {
            objectLock.close()
            layoutLock.close()
            return .missing
        }
        do {
            let metadata = try DurableArtifactObjectFrame.validate(
                descriptor: opened.0.rawValue,
                expectedFileSize: opened.1.size,
                expected: expectation,
                policy: framingPolicy,
                hooks: hooks,
                recordBody: nil
            )
            guard try DurableArtifactSecureIO.identity(opened.0.rawValue) == opened.1,
                  try DurableArtifactSecureIO.pathIdentity(
                      parent: objectParent,
                      name: expectation.id.digest.hex
                  ) == opened.1
            else { throw DurableArtifactStoreError.insecureEntry }
            return .available(DurableArtifactReadLease(
                store: self,
                expectation: expectation,
                metadata: metadata,
                objectParent: objectParent,
                objectDescriptor: opened.0,
                objectIdentity: opened.1,
                objectLock: objectLock,
                layoutLock: layoutLock
            ))
        } catch {
            opened.0.close()
            objectLock.close()
            layoutLock.close()
            if error as? DurableArtifactStoreError == .identityMismatch { return .missing }
            if (error as? DurableArtifactStoreError)?.isAuthenticatedCorruption == true {
                return try quarantineCorruptObject(expectation.id) ? .corruptQuarantined : .corruptBusy
            }
            throw error
        }
    }

    func loadCatalog(for family: DurableArtifactFamily) throws -> DurableArtifactCatalogReadResult {
        if familyIsDisabled(family) { return .familyDisabled }
        let layoutLock = try DurableArtifactSecureIO.lockDescriptor(
            parent: layout.root,
            name: ".layout.lock",
            exclusive: false,
            nonBlocking: true
        )
        guard let layoutLock else { return .busy }
        defer { layoutLock.close() }
        try validateCurrentLayout()
        let lock = try DurableArtifactSecureIO.lockDescriptor(
            parent: layout.catalogLocks,
            name: "\(family.rawValue).lock",
            exclusive: false,
            nonBlocking: true
        )
        guard let lock else { return .busy }
        defer { lock.close() }
        guard let opened = try DurableArtifactSecureIO.openRegularFile(
            parent: layout.catalogs,
            name: "\(family.rawValue).catalog"
        ) else { return .missing }
        defer { opened.0.close() }
        do {
            let pointer = try readCatalog(descriptor: opened.0.rawValue, identity: opened.1, family: family)
            guard try DurableArtifactSecureIO.pathIdentity(
                parent: layout.catalogs,
                name: "\(family.rawValue).catalog"
            ) == opened.1 else { throw DurableArtifactStoreError.insecureEntry }
            return .available(pointer)
        } catch DurableArtifactStoreError.invalidFraming {
            lock.close()
            return try quarantineCatalog(family: family) ? .corruptQuarantined : .busy
        }
    }

    func compareAndSwapCatalog(
        family: DurableArtifactFamily,
        expectedRevision: DurableArtifactDigest?,
        target: DurableArtifactObjectID?,
        admittedByteUpperBound: UInt64
    ) throws -> DurableArtifactCatalogCASResult {
        if familyIsDisabled(family) { return .familyDisabled }
        if let target, target.family != family { throw DurableArtifactStoreError.identityMismatch }
        let layoutLock = try DurableArtifactSecureIO.lockDescriptor(
            parent: layout.root,
            name: ".layout.lock",
            exclusive: false,
            nonBlocking: true
        )
        guard let layoutLock else { return .busy }
        defer { layoutLock.close() }
        try validateCurrentLayout()
        let maintenance = try DurableArtifactSecureIO.lockDescriptor(
            parent: layout.version,
            name: "maintenance.lock",
            exclusive: true,
            nonBlocking: true
        )
        guard let maintenance else { return .busy }
        defer { maintenance.close() }
        let catalogLock = try DurableArtifactSecureIO.lockDescriptor(
            parent: layout.catalogLocks,
            name: "\(family.rawValue).lock",
            exclusive: true,
            nonBlocking: true
        )
        guard let catalogLock else { return .busy }
        defer { catalogLock.close() }

        let current: DurableArtifactCatalogPointer?
        let currentFile: (DurableArtifactDescriptor, DurableArtifactFileIdentity)?
        if let opened = try DurableArtifactSecureIO.openRegularFile(
            parent: layout.catalogs,
            name: "\(family.rawValue).catalog"
        ) {
            current = try readCatalog(descriptor: opened.0.rawValue, identity: opened.1, family: family)
            guard try DurableArtifactSecureIO.pathIdentity(
                parent: layout.catalogs,
                name: "\(family.rawValue).catalog"
            ) == opened.1 else {
                opened.0.close()
                throw DurableArtifactStoreError.insecureEntry
            }
            currentFile = opened
        } else {
            current = nil
            currentFile = nil
        }
        defer { currentFile?.0.close() }
        guard current?.revision == expectedRevision else {
            return .conflict(currentRevision: current?.revision)
        }
        guard let target else {
            guard let currentFile else { return .deleted }
            guard try DurableArtifactSecureIO.removeIfSame(
                parent: layout.catalogs,
                name: "\(family.rawValue).catalog",
                descriptor: currentFile.0.rawValue,
                identity: currentFile.1,
                beforeCapturedUnlink: { try self.hooks.crash(.beforeIdentitySafeRemoval) }
            ) else { return .busy }
            return .deleted
        }
        if current?.target == target, let current { return .unchanged(current) }
        let body = try catalogBody(family: family, target: target, predecessor: expectedRevision)
        let revision = try transformedDigest(Data(SHA256.hash(data: body)))
        var file = body
        file.append(revision.bytes)
        guard UInt64(file.count) <= admittedByteUpperBound else { return .notAdmitted(.declaredBoundExceeded) }
        if let reason = try admissionFailure(for: admittedByteUpperBound) { return .notAdmitted(reason) }
        let temporaryName = ".catalog.tmp.\(hooks.token())"
        let temporary = try DurableArtifactSecureIO.createExclusiveFile(parent: layout.work, name: temporaryName)
        var identity: DurableArtifactFileIdentity? = try DurableArtifactSecureIO.validateRegularFile(
            descriptor: temporary.rawValue,
            parent: layout.work,
            name: temporaryName
        )
        var preserve = false
        defer {
            if !preserve,
               let current = try? DurableArtifactSecureIO.validateRegularFile(
                   descriptor: temporary.rawValue,
                   parent: layout.work,
                   name: temporaryName
               )
            {
                _ = try? DurableArtifactSecureIO.removeIfSame(
                    parent: layout.work,
                    name: temporaryName,
                    descriptor: temporary.rawValue,
                    identity: current
                )
            }
            temporary.close()
        }
        do {
            try DurableArtifactSecureIO.writeAll(temporary.rawValue, data: file)
            try DurableArtifactSecureIO.synchronize(temporary.rawValue, operation: "catalog-file-sync")
            identity = try DurableArtifactSecureIO.validateRegularFile(
                descriptor: temporary.rawValue,
                parent: layout.work,
                name: temporaryName
            )
            _ = try readCatalog(descriptor: temporary.rawValue, identity: identity!, family: family)
            try hooks.crash(.afterCatalogFileSync)
            try hooks.crash(.beforeCatalogInstall)
            let catalogName = "\(family.rawValue).catalog"
            let installed: (DurableArtifactDescriptor, DurableArtifactFileIdentity)
            if let currentFile {
                let stageName = ".catalog-stage.\(hooks.token()).work"
                guard let stage = try DurableArtifactSecureIO.installValidatedDescriptorNoReplace(
                    sourceDescriptor: temporary.rawValue,
                    sourceIdentity: identity!,
                    destinationParent: layout.work,
                    destinationName: stageName
                ) else {
                    throw DurableArtifactStoreError.ioFailure(operation: "catalog-stage-exists", code: EEXIST)
                }
                installed = stage
                try DurableArtifactSecureIO.swapEntries(
                    firstParent: layout.work,
                    firstName: stageName,
                    secondParent: layout.catalogs,
                    secondName: catalogName
                )
                do {
                    try hooks.crash(.afterCatalogInstallBeforeValidation)
                    _ = try readCatalog(descriptor: stage.0.rawValue, identity: stage.1, family: family)
                    guard try DurableArtifactSecureIO.pathIdentity(
                        parent: layout.catalogs,
                        name: catalogName
                    ) == stage.1,
                        try DurableArtifactSecureIO.pathIdentity(
                            parent: layout.work,
                            name: stageName
                        ) == currentFile.1
                    else { throw DurableArtifactStoreError.insecureEntry }
                    try DurableArtifactSecureIO.synchronize(
                        layout.work.descriptor.rawValue,
                        operation: "catalog-work-swap-sync"
                    )
                    try DurableArtifactSecureIO.synchronize(
                        layout.catalogs.descriptor.rawValue,
                        operation: "catalog-directory-swap-sync"
                    )
                } catch let error as DurableArtifactStoreError {
                    if case .simulatedCrash = error { throw error }
                    let restorationError: Error?
                    do {
                        try restoreDescriptorAfterFailedPostCheck(
                            sourceDescriptor: currentFile.0.rawValue,
                            sourceIdentity: currentFile.1,
                            destinationParent: layout.catalogs,
                            destinationName: catalogName,
                            quarantineID: target
                        )
                        restorationError = nil
                    } catch {
                        restorationError = error
                    }
                    try disable(family, collisionDigest: target.digest)
                    if let restorationError { throw restorationError }
                    throw error
                }
            } else {
                guard let direct = try DurableArtifactSecureIO.installValidatedDescriptorNoReplace(
                    sourceDescriptor: temporary.rawValue,
                    sourceIdentity: identity!,
                    destinationParent: layout.catalogs,
                    destinationName: catalogName
                ) else {
                    throw DurableArtifactStoreError.ioFailure(operation: "catalog-publish-race", code: EEXIST)
                }
                installed = direct
                do {
                    try hooks.crash(.afterCatalogInstallBeforeValidation)
                    _ = try readCatalog(descriptor: direct.0.rawValue, identity: direct.1, family: family)
                    guard try DurableArtifactSecureIO.pathIdentity(
                        parent: layout.catalogs,
                        name: catalogName
                    ) == direct.1
                    else { throw DurableArtifactStoreError.insecureEntry }
                    try DurableArtifactSecureIO.synchronize(
                        layout.catalogs.descriptor.rawValue,
                        operation: "catalog-directory-publish-sync"
                    )
                } catch let error as DurableArtifactStoreError {
                    if case .simulatedCrash = error { throw error }
                    try retireUntrustedPathIfPresent(
                        parent: layout.catalogs,
                        name: catalogName,
                        id: target
                    )
                    try disable(family, collisionDigest: target.digest)
                    throw error
                }
            }
            defer { installed.0.close() }
            try hooks.crash(.afterCatalogRename)
            try DurableArtifactSecureIO.synchronize(layout.work.descriptor.rawValue, operation: "catalog-work-sync")
            try DurableArtifactSecureIO.synchronize(layout.catalogs.descriptor.rawValue, operation: "catalog-directory-sync")
            try hooks.crash(.afterCatalogDirectorySync)
            return .published(DurableArtifactCatalogPointer(
                family: family,
                target: target,
                revision: revision,
                predecessorRevision: expectedRevision
            ))
        } catch let error as DurableArtifactStoreError {
            if case .simulatedCrash = error { preserve = true }
            if case let .ioFailure(_, code) = error, code == ENOSPC || code == EDQUOT {
                return .notAdmitted(.noSpace)
            }
            throw error
        }
    }

    func quarantineObject(using lease: DurableArtifactReadLease) throws -> Bool {
        guard lease.store === self else { return false }
        let id = lease.expectation.id
        let expectedIdentity = lease.objectIdentity
        lease.close()
        let lockParent = try objectLockDirectory(for: id, create: true)!
        guard let lock = try DurableArtifactSecureIO.lockDescriptor(
            parent: lockParent,
            name: "\(id.digest.hex).lock",
            exclusive: true,
            nonBlocking: true
        ) else { return false }
        defer { lock.close() }
        guard let parent = try objectDirectory(for: id, create: false),
              let opened = try DurableArtifactSecureIO.openRegularFile(parent: parent, name: id.digest.hex)
        else { return false }
        defer { opened.0.close() }
        guard opened.1 == expectedIdentity else { return false }
        try quarantine(
            parent: parent,
            name: id.digest.hex,
            descriptor: opened.0.rawValue,
            identity: opened.1,
            kind: "domain",
            id: id
        )
        return true
    }

    func garbageCollect(
        protecting objects: Set<DurableArtifactObjectID> = [],
        referenceEnumerator: DurableArtifactReferenceEnumerator? = nil,
        policy: DurableArtifactGCPolicy = .default
    ) throws -> DurableArtifactGCReport {
        try DurableArtifactGarbageCollector(store: self).collect(
            protecting: objects,
            referenceEnumerator: referenceEnumerator,
            policy: policy
        )
    }

    func deleteObsoleteVersions() throws -> DurableArtifactObsoleteDeletionReport {
        try DurableArtifactGarbageCollector(store: self).deleteObsoleteVersions()
    }

    func transformedDigest(_ digest: Data) throws -> DurableArtifactDigest {
        try DurableArtifactDigest(bytes: hooks.transformDigest(digest))
    }

    func objectDirectory(
        for id: DurableArtifactObjectID,
        create: Bool
    ) throws -> DurableArtifactDirectory? {
        let family: DurableArtifactDirectory? = if create {
            try DurableArtifactSecureIO.ownedDirectory(
                parent: layout.objects,
                name: id.family.rawValue,
                create: true
            )
        } else {
            try DurableArtifactSecureIO.optionalOwnedDirectory(parent: layout.objects, name: id.family.rawValue)
        }
        guard let family else { return nil }
        let shardName = String(id.digest.hex.prefix(2))
        return create
            ? try DurableArtifactSecureIO.ownedDirectory(parent: family, name: shardName, create: true)
            : try DurableArtifactSecureIO.optionalOwnedDirectory(parent: family, name: shardName)
    }

    func objectLockDirectory(
        for id: DurableArtifactObjectID,
        create: Bool
    ) throws -> DurableArtifactDirectory? {
        let family: DurableArtifactDirectory? = if create {
            try DurableArtifactSecureIO.ownedDirectory(
                parent: layout.objectLocks,
                name: id.family.rawValue,
                create: true
            )
        } else {
            try DurableArtifactSecureIO.optionalOwnedDirectory(
                parent: layout.objectLocks,
                name: id.family.rawValue
            )
        }
        guard let family else { return nil }
        let shardName = String(id.digest.hex.prefix(2))
        return create
            ? try DurableArtifactSecureIO.ownedDirectory(parent: family, name: shardName, create: true)
            : try DurableArtifactSecureIO.optionalOwnedDirectory(parent: family, name: shardName)
    }

    func quarantine(
        parent: DurableArtifactDirectory,
        name: String,
        descriptor: Int32,
        identity: DurableArtifactFileIdentity,
        kind: String,
        id: DurableArtifactObjectID
    ) throws {
        guard try DurableArtifactSecureIO.identity(descriptor) == identity,
              try DurableArtifactSecureIO.pathIdentity(parent: parent, name: name) == identity
        else { throw DurableArtifactStoreError.insecureEntry }
        let destination = "\(kind).\(id.family.rawValue).\(id.digest.hex).\(hooks.now()).\(hooks.token())"
        guard try DurableArtifactSecureIO.noReplaceRename(
            fromParent: parent,
            from: name,
            toParent: layout.quarantine,
            to: destination
        ) else { throw DurableArtifactStoreError.ioFailure(operation: "quarantine-collision", code: EEXIST) }
        guard try DurableArtifactSecureIO.identity(descriptor) == identity,
              try DurableArtifactSecureIO.pathIdentity(
                  parent: layout.quarantine,
                  name: destination
              ) == identity
        else { throw DurableArtifactStoreError.insecureEntry }
        try hooks.crash(.afterQuarantineRename)
        try DurableArtifactSecureIO.synchronize(parent.descriptor.rawValue, operation: "quarantine-source-sync")
        try DurableArtifactSecureIO.synchronize(layout.quarantine.descriptor.rawValue, operation: "quarantine-sync")
    }

    private func restoreDescriptorAfterFailedPostCheck(
        sourceDescriptor: Int32,
        sourceIdentity: DurableArtifactFileIdentity,
        destinationParent: DurableArtifactDirectory,
        destinationName: String,
        quarantineID: DurableArtifactObjectID
    ) throws {
        try retireUntrustedPathIfPresent(
            parent: destinationParent,
            name: destinationName,
            id: quarantineID
        )
        guard let restored = try DurableArtifactSecureIO.installValidatedDescriptorNoReplace(
            sourceDescriptor: sourceDescriptor,
            sourceIdentity: sourceIdentity,
            destinationParent: destinationParent,
            destinationName: destinationName
        ) else { throw DurableArtifactStoreError.insecureEntry }
        defer { restored.0.close() }
        guard try DurableArtifactSecureIO.identity(restored.0.rawValue) == restored.1,
              try DurableArtifactSecureIO.pathIdentity(
                  parent: destinationParent,
                  name: destinationName
              ) == restored.1
        else { throw DurableArtifactStoreError.insecureEntry }
        try DurableArtifactSecureIO.synchronize(
            destinationParent.descriptor.rawValue,
            operation: "post-check-restore-sync"
        )
    }

    private func retireUntrustedPathIfPresent(
        parent: DurableArtifactDirectory,
        name: String,
        id: DurableArtifactObjectID
    ) throws {
        do {
            let destination = "untrusted.\(id.family.rawValue).\(id.digest.hex).\(hooks.now()).\(hooks.token())"
            guard try DurableArtifactSecureIO.noReplaceRename(
                fromParent: parent,
                from: name,
                toParent: layout.quarantine,
                to: destination
            ) else { throw DurableArtifactStoreError.ioFailure(operation: "untrusted-retire", code: EEXIST) }
            try DurableArtifactSecureIO.synchronize(parent.descriptor.rawValue, operation: "untrusted-source-sync")
            try DurableArtifactSecureIO.synchronize(
                layout.quarantine.descriptor.rawValue,
                operation: "untrusted-quarantine-sync"
            )
        } catch DurableArtifactStoreError.ioFailure(_, ENOENT) {
            return
        }
    }

    func readCatalog(
        descriptor: Int32,
        identity: DurableArtifactFileIdentity,
        family: DurableArtifactFamily
    ) throws -> DurableArtifactCatalogPointer {
        guard identity.size >= 0, let size = Int(exactly: identity.size), size <= 4096 else {
            throw DurableArtifactStoreError.invalidFraming
        }
        let data = try DurableArtifactSecureIO.preadExactly(descriptor, offset: 0, count: size)
        guard data.count >= 32 else { throw DurableArtifactStoreError.invalidFraming }
        let body = Data(data.dropLast(32))
        let footer = Data(data.suffix(32))
        let revision = try transformedDigest(Data(SHA256.hash(data: body)))
        guard footer == revision.bytes else { throw DurableArtifactStoreError.invalidFraming }
        var reader = DurableArtifactBinaryReader(data: body)
        guard try reader.read(count: 8) == Data("RPDACAT1".utf8),
              try reader.readUInt32() == 1
        else { throw DurableArtifactStoreError.invalidFraming }
        let familyLength = try reader.readUInt32()
        guard familyLength <= 64,
              let decodedFamily = try String(data: reader.read(count: Int(familyLength)), encoding: .utf8),
              decodedFamily == family.rawValue
        else { throw DurableArtifactStoreError.invalidFraming }
        let target = try DurableArtifactDigest(bytes: reader.read(count: 32))
        let predecessorFlag = try reader.readUInt8()
        let predecessor: DurableArtifactDigest?
        switch predecessorFlag {
        case 0: predecessor = nil
        case 1: predecessor = try DurableArtifactDigest(bytes: reader.read(count: 32))
        default: throw DurableArtifactStoreError.invalidFraming
        }
        guard reader.offset == body.count else { throw DurableArtifactStoreError.invalidFraming }
        guard try DurableArtifactSecureIO.identity(descriptor) == identity else {
            throw DurableArtifactStoreError.insecureEntry
        }
        return DurableArtifactCatalogPointer(
            family: family,
            target: DurableArtifactObjectID(family: family, digest: target),
            revision: revision,
            predecessorRevision: predecessor
        )
    }

    func catalogBody(
        family: DurableArtifactFamily,
        target: DurableArtifactObjectID,
        predecessor: DurableArtifactDigest?
    ) throws -> Data {
        guard target.family == family else { throw DurableArtifactStoreError.identityMismatch }
        var writer = DurableArtifactBinaryWriter()
        writer.append(Data("RPDACAT1".utf8))
        writer.append(UInt32(1))
        writer.append(UInt32(family.rawValue.utf8.count))
        writer.append(Data(family.rawValue.utf8))
        writer.append(target.digest.bytes)
        if let predecessor {
            writer.append(UInt8(1))
            writer.append(predecessor.bytes)
        } else {
            writer.append(UInt8(0))
        }
        return writer.data
    }

    func validateCurrentLayout() throws {
        try DurableArtifactSecureIO.validateDirectoryPath(layout.root, parent: layout.parent, name: layout.rootName)
        try DurableArtifactSecureIO.validateDirectoryPath(layout.version, parent: layout.root, name: "v1")
    }

    func admissionFailure(for upperBound: UInt64) throws -> DurableArtifactAdmissionReason? {
        let used = try managedByteCount()
        let (quotaTotal, quotaOverflow) = used.addingReportingOverflow(upperBound)
        if quotaOverflow || quotaTotal > diskPolicy.quotaBytes { return .quota }
        let available = try DurableArtifactSecureIO.availableBytes(layout.version)
        let (required, reserveOverflow) = diskPolicy.minimumFreeReserveBytes.addingReportingOverflow(upperBound)
        if reserveOverflow || available < required { return .minimumFreeReserve }
        return nil
    }

    func managedByteCount() throws -> UInt64 {
        var total: UInt64 = 0
        for directory in [layout.objects, layout.catalogs, layout.quarantine, layout.work] {
            try accumulateBytes(directory: directory, total: &total, depth: 0)
        }
        return total
    }

    private func accumulateBytes(
        directory: DurableArtifactDirectory,
        total: inout UInt64,
        depth: Int
    ) throws {
        guard depth <= 16 else { throw DurableArtifactStoreError.insecureEntry }
        try DurableArtifactSecureIO.forEachEntry(in: directory) { name in
            let value = try DurableArtifactSecureIO.pathIdentity(parent: directory, name: name)
            if value.isDirectory {
                let child = try DurableArtifactSecureIO.ownedDirectory(parent: directory, name: name, create: false)
                try accumulateBytes(directory: child, total: &total, depth: depth + 1)
            } else {
                guard value.isRegular, value.owner == geteuid(), value.permissions == 0o600,
                      value.linkCount == 1, value.device == directory.identity.device, value.size >= 0
                else { throw DurableArtifactStoreError.insecureEntry }
                let (next, overflow) = total.addingReportingOverflow(UInt64(value.size))
                if overflow { throw DurableArtifactStoreError.framingOverflow }
                total = next
            }
        }
    }

    private func filesEqual(
        lhs: Int32,
        lhsSize: off_t,
        rhs: Int32,
        rhsSize: off_t
    ) throws -> Bool {
        guard lhsSize == rhsSize, lhsSize >= 0 else { return false }
        var offset: off_t = 0
        while offset < lhsSize {
            let count = min(framingPolicy.ioBufferByteCount, Int(lhsSize - offset))
            let left = try DurableArtifactSecureIO.preadExactly(lhs, offset: offset, count: count)
            let right = try DurableArtifactSecureIO.preadExactly(rhs, offset: offset, count: count)
            if left != right { return false }
            offset += off_t(count)
        }
        return true
    }

    private func quarantineCorruptObject(_ id: DurableArtifactObjectID) throws -> Bool {
        let lockParent = try objectLockDirectory(for: id, create: true)!
        guard let lock = try DurableArtifactSecureIO.lockDescriptor(
            parent: lockParent,
            name: "\(id.digest.hex).lock",
            exclusive: true,
            nonBlocking: true
        ) else { return false }
        defer { lock.close() }
        guard let parent = try objectDirectory(for: id, create: false),
              let opened = try DurableArtifactSecureIO.openRegularFile(parent: parent, name: id.digest.hex)
        else { return true }
        defer { opened.0.close() }
        try quarantine(
            parent: parent,
            name: id.digest.hex,
            descriptor: opened.0.rawValue,
            identity: opened.1,
            kind: "corrupt",
            id: id
        )
        return true
    }

    private func quarantineCatalog(family: DurableArtifactFamily) throws -> Bool {
        guard let lock = try DurableArtifactSecureIO.lockDescriptor(
            parent: layout.catalogLocks,
            name: "\(family.rawValue).lock",
            exclusive: true,
            nonBlocking: true
        ) else { return false }
        defer { lock.close() }
        let name = "\(family.rawValue).catalog"
        guard let opened = try DurableArtifactSecureIO.openRegularFile(parent: layout.catalogs, name: name) else {
            return true
        }
        defer { opened.0.close() }
        let digest = try DurableArtifactDigest(bytes: Data(SHA256.hash(data: Data(family.rawValue.utf8))))
        try quarantine(
            parent: layout.catalogs,
            name: name,
            descriptor: opened.0.rawValue,
            identity: opened.1,
            kind: "catalog",
            id: DurableArtifactObjectID(family: family, digest: digest)
        )
        return true
    }

    private func disabledKey(_ family: DurableArtifactFamily) -> String {
        "\(layout.root.identity.device):\(layout.root.identity.inode):\(family.rawValue)"
    }

    private func familyIsDisabled(_ family: DurableArtifactFamily) -> Bool {
        Self.disabledRegistry.lock.lock()
        let processDisabled = Self.disabledRegistry.families.contains(disabledKey(family))
        Self.disabledRegistry.lock.unlock()
        if processDisabled { return true }

        var status = stat()
        if fstatat(
            layout.disabled.descriptor.rawValue,
            "\(family.rawValue).disabled",
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            Self.disabledRegistry.lock.lock()
            Self.disabledRegistry.families.insert(disabledKey(family))
            Self.disabledRegistry.lock.unlock()
            return true
        }
        return errno != ENOENT
    }

    private func disable(
        _ family: DurableArtifactFamily,
        collisionDigest: DurableArtifactDigest
    ) throws {
        Self.disabledRegistry.lock.lock()
        Self.disabledRegistry.families.insert(disabledKey(family))
        Self.disabledRegistry.lock.unlock()

        let name = "\(family.rawValue).disabled"
        if let existing = try DurableArtifactSecureIO.openRegularFile(parent: layout.disabled, name: name) {
            existing.0.close()
            return
        }
        let marker: DurableArtifactDescriptor
        do {
            marker = try DurableArtifactSecureIO.createExclusiveFile(parent: layout.disabled, name: name)
        } catch let error as DurableArtifactStoreError {
            if case let .ioFailure(_, code) = error, code == EEXIST { return }
            throw error
        }
        defer { marker.close() }
        var writer = DurableArtifactBinaryWriter()
        writer.append(Data("RPDDIS01".utf8))
        writer.append(UInt32(family.rawValue.utf8.count))
        writer.append(Data(family.rawValue.utf8))
        writer.append(collisionDigest.bytes)
        try DurableArtifactSecureIO.writeAll(marker.rawValue, data: writer.data)
        try DurableArtifactSecureIO.synchronize(marker.rawValue, operation: "family-disable-file-sync")
        _ = try DurableArtifactSecureIO.validateRegularFile(
            descriptor: marker.rawValue,
            parent: layout.disabled,
            name: name
        )
        try DurableArtifactSecureIO.synchronize(
            layout.disabled.descriptor.rawValue,
            operation: "family-disable-directory-sync"
        )
        try hooks.crash(.afterFamilyDisableSync)
    }
}

private extension DurableArtifactStoreError {
    var isAuthenticatedCorruption: Bool {
        switch self {
        case .invalidFraming, .framingOverflow, .unsortedRecords:
            true
        default:
            false
        }
    }
}

final class DurableArtifactObjectWriter {
    private let descriptor: Int32
    private let byteUpperBound: UInt64
    private let policy: DurableArtifactFramingPolicy
    private let hooks: DurableArtifactStoreHooks
    private var hasher = SHA256()
    private var previousRecord: Data?
    private var finished = false
    private(set) var recordCount: UInt64 = 0
    private(set) var payloadByteCount: UInt64 = 0
    private(set) var writtenByteCount: UInt64 = 0

    init(
        descriptor: Int32,
        family: DurableArtifactFamily,
        schemaVersion: UInt32,
        canonicalIdentity: Data,
        byteUpperBound: UInt64,
        policy: DurableArtifactFramingPolicy,
        hooks: DurableArtifactStoreHooks
    ) throws {
        self.descriptor = descriptor
        self.byteUpperBound = byteUpperBound
        self.policy = policy
        self.hooks = hooks
        var header = DurableArtifactBinaryWriter()
        header.append(Data("RPDART01".utf8))
        header.append(UInt32(1))
        header.append(schemaVersion)
        header.append(UInt32(family.rawValue.utf8.count))
        header.append(UInt64(canonicalIdentity.count))
        header.append(Data(family.rawValue.utf8))
        header.append(canonicalIdentity)
        try writeAuthenticated(header.data)
    }

    func appendRecord(_ canonicalBytes: Data) throws {
        guard !finished else { throw DurableArtifactStoreError.invalidFraming }
        guard UInt64(canonicalBytes.count) <= policy.maximumRecordByteCount else {
            throw DurableArtifactStoreError.invalidFraming
        }
        if let previousRecord, !previousRecord.lexicographicallyPrecedes(canonicalBytes) {
            throw DurableArtifactStoreError.unsortedRecords
        }
        var frame = DurableArtifactBinaryWriter()
        frame.append(UInt8(1))
        frame.append(UInt64(canonicalBytes.count))
        frame.append(canonicalBytes)
        try writeAuthenticated(frame.data)
        let (nextCount, countOverflow) = recordCount.addingReportingOverflow(1)
        let (nextPayload, payloadOverflow) = payloadByteCount.addingReportingOverflow(UInt64(canonicalBytes.count))
        if countOverflow || payloadOverflow { throw DurableArtifactStoreError.framingOverflow }
        recordCount = nextCount
        payloadByteCount = nextPayload
        previousRecord = canonicalBytes
    }

    func finish() throws -> (digest: DurableArtifactDigest, byteCount: UInt64) {
        guard !finished else { throw DurableArtifactStoreError.invalidFraming }
        finished = true
        let rawDigest = Data(hasher.finalize())
        let digest = try DurableArtifactDigest(bytes: hooks.transformDigest(rawDigest))
        var footer = DurableArtifactBinaryWriter()
        footer.append(UInt8(0xFF))
        footer.append(recordCount)
        footer.append(payloadByteCount)
        footer.append(digest.bytes)
        try writeUnauthenticated(footer.data)
        return (digest, writtenByteCount)
    }

    private func writeAuthenticated(_ data: Data) throws {
        hasher.update(data: data)
        try writeUnauthenticated(data)
    }

    private func writeUnauthenticated(_ data: Data) throws {
        let (next, overflow) = writtenByteCount.addingReportingOverflow(UInt64(data.count))
        guard !overflow, next <= byteUpperBound else {
            throw DurableArtifactStoreError.ioFailure(operation: "declared-bound", code: EFBIG)
        }
        try DurableArtifactSecureIO.writeAll(descriptor, data: data)
        writtenByteCount = next
    }
}

struct DurableArtifactObjectMetadata {
    let family: DurableArtifactFamily
    let schemaVersion: UInt32
    let canonicalIdentity: Data
    let digest: DurableArtifactDigest
    let recordCount: UInt64
    let payloadByteCount: UInt64
    let fileByteCount: UInt64
}

enum DurableArtifactObjectFrame {
    static func validate(
        descriptor: Int32,
        expectedFileSize: off_t,
        expected: DurableArtifactObjectExpectation?,
        policy: DurableArtifactFramingPolicy,
        hooks: DurableArtifactStoreHooks,
        recordBody: ((Data) throws -> Void)?
    ) throws -> DurableArtifactObjectMetadata {
        guard expectedFileSize >= 0 else { throw DurableArtifactStoreError.invalidFraming }
        var offset: off_t = 0
        var hasher = SHA256()
        func read(_ count: Int, authenticated: Bool = true) throws -> Data {
            let (nextOffset, overflow) = offset.addingReportingOverflow(off_t(count))
            guard count >= 0, !overflow, nextOffset <= expectedFileSize else {
                throw DurableArtifactStoreError.invalidFraming
            }
            let data = try DurableArtifactSecureIO.preadExactly(descriptor, offset: offset, count: count)
            offset = nextOffset
            if authenticated { hasher.update(data: data) }
            return data
        }
        var fixed = try DurableArtifactBinaryReader(data: read(28))
        guard try fixed.read(count: 8) == Data("RPDART01".utf8),
              try fixed.readUInt32() == 1
        else { throw DurableArtifactStoreError.invalidFraming }
        let schema = try fixed.readUInt32()
        let familyLength = try fixed.readUInt32()
        let identityLength = try fixed.readUInt64()
        guard familyLength > 0, familyLength <= 64,
              identityLength <= policy.maximumIdentityByteCount,
              let identityCount = Int(exactly: identityLength)
        else { throw DurableArtifactStoreError.invalidFraming }
        let familyData = try read(Int(familyLength))
        guard let familyString = String(data: familyData, encoding: .utf8),
              let family = DurableArtifactFamily(rawValue: familyString)
        else { throw DurableArtifactStoreError.invalidFraming }
        let canonicalIdentity = try read(identityCount)
        if let expected {
            guard expected.schemaVersion == schema,
                  expected.id.family == family,
                  expected.canonicalIdentity == canonicalIdentity
            else { throw DurableArtifactStoreError.identityMismatch }
        }
        var previous: Data?
        var recordCount: UInt64 = 0
        var payloadBytes: UInt64 = 0
        while true {
            let tag = try read(1, authenticated: false)
            if tag[0] == 0xFF { break }
            guard tag[0] == 1 else { throw DurableArtifactStoreError.invalidFraming }
            hasher.update(data: tag)
            var lengthReader = try DurableArtifactBinaryReader(data: read(8))
            let length = try lengthReader.readUInt64()
            guard length <= policy.maximumRecordByteCount, let count = Int(exactly: length) else {
                throw DurableArtifactStoreError.invalidFraming
            }
            let record = try read(count)
            if let previous, !previous.lexicographicallyPrecedes(record) {
                throw DurableArtifactStoreError.invalidFraming
            }
            let (nextCount, countOverflow) = recordCount.addingReportingOverflow(1)
            let (nextPayload, payloadOverflow) = payloadBytes.addingReportingOverflow(length)
            if countOverflow || payloadOverflow { throw DurableArtifactStoreError.framingOverflow }
            recordCount = nextCount
            payloadBytes = nextPayload
            previous = record
            try recordBody?(record)
        }
        var footer = try DurableArtifactBinaryReader(data: read(48, authenticated: false))
        let declaredCount = try footer.readUInt64()
        let declaredPayload = try footer.readUInt64()
        let digest = try DurableArtifactDigest(bytes: footer.read(count: 32))
        guard declaredCount == recordCount, declaredPayload == payloadBytes,
              offset == expectedFileSize
        else { throw DurableArtifactStoreError.invalidFraming }
        let computed = try DurableArtifactDigest(bytes: hooks.transformDigest(Data(hasher.finalize())))
        guard computed == digest, expected?.id.digest == nil || expected?.id.digest == digest else {
            throw DurableArtifactStoreError.invalidFraming
        }
        return DurableArtifactObjectMetadata(
            family: family,
            schemaVersion: schema,
            canonicalIdentity: canonicalIdentity,
            digest: digest,
            recordCount: recordCount,
            payloadByteCount: payloadBytes,
            fileByteCount: UInt64(expectedFileSize)
        )
    }
}
