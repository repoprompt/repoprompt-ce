import Darwin
import Foundation

struct DurableArtifactReferenceEnumerator {
    let enumerate: (
        DurableArtifactObjectID,
        (DurableArtifactObjectID) throws -> Void
    ) throws -> Void

    init(references: @escaping (DurableArtifactObjectID) throws -> [DurableArtifactObjectID]) {
        enumerate = { source, emit in
            for reference in try references(source) {
                try emit(reference)
            }
        }
    }

    init(
        enumerating: @escaping (
            DurableArtifactObjectID,
            (DurableArtifactObjectID) throws -> Void
        ) throws -> Void
    ) {
        enumerate = enumerating
    }
}

struct DurableArtifactGCPolicy {
    static let `default` = DurableArtifactGCPolicy()

    let quotaBytes: UInt64?
    let minimumOrphanAgeSeconds: UInt64?
    let quarantineGraceSeconds: UInt64?
    let abandonedWorkAgeSeconds: UInt64?

    init(
        quotaBytes: UInt64? = nil,
        minimumOrphanAgeSeconds: UInt64? = nil,
        quarantineGraceSeconds: UInt64? = nil,
        abandonedWorkAgeSeconds: UInt64? = nil
    ) {
        self.quotaBytes = quotaBytes
        self.minimumOrphanAgeSeconds = minimumOrphanAgeSeconds
        self.quarantineGraceSeconds = quarantineGraceSeconds
        self.abandonedWorkAgeSeconds = abandonedWorkAgeSeconds
    }
}

struct DurableArtifactGCReport: Equatable {
    var markedCount: UInt64 = 0
    var examinedObjectCount: UInt64 = 0
    var quarantinedObjectCount: UInt64 = 0
    var quarantinedByteCount: UInt64 = 0
    var deletedQuarantineCount: UInt64 = 0
    var abandonedWorkRemovedCount: UInt64 = 0
    var busyObjectCount: UInt64 = 0
    var busy = false
}

struct DurableArtifactObsoleteDeletionReport: Equatable {
    var renamedVersionCount: UInt64 = 0
    var deletedVersionCount: UInt64 = 0
    var unsafeVersionCount: UInt64 = 0
    var candidateCount: UInt64 = 0
    var candidateSpillRunCount: UInt64 = 0
    var peakResidentCandidateCount: UInt64 = 0
    var peakResidentCandidateByteCount = 0
    var busy = false
}

final class DurableArtifactGarbageCollector {
    private let store: LocalDurableArtifactStore

    init(store: LocalDurableArtifactStore) {
        self.store = store
    }

    func collect(
        protecting objects: Set<DurableArtifactObjectID>,
        referenceEnumerator: DurableArtifactReferenceEnumerator?,
        policy: DurableArtifactGCPolicy
    ) throws -> DurableArtifactGCReport {
        var report = DurableArtifactGCReport()
        guard let layoutLock = try DurableArtifactSecureIO.lockDescriptor(
            parent: store.layout.root,
            name: ".layout.lock",
            exclusive: false,
            nonBlocking: true
        ) else {
            report.busy = true
            return report
        }
        defer { layoutLock.close() }
        guard let maintenance = try DurableArtifactSecureIO.lockDescriptor(
            parent: store.layout.version,
            name: "maintenance.lock",
            exclusive: true,
            nonBlocking: true
        ) else {
            report.busy = true
            return report
        }
        defer { maintenance.close() }
        try store.validateCurrentLayout()

        let now = store.hooks.now()
        let quota = policy.quotaBytes ?? store.diskPolicy.quotaBytes
        let orphanAge = policy.minimumOrphanAgeSeconds ?? store.diskPolicy.minimumOrphanAgeSeconds
        let quarantineGrace = policy.quarantineGraceSeconds ?? store.diskPolicy.quarantineGraceSeconds
        let workAge = policy.abandonedWorkAgeSeconds ?? store.diskPolicy.abandonedWorkAgeSeconds

        let marks = try DurableArtifactGCMarkFile(
            parent: store.layout.work,
            name: ".gc-marks.\(store.hooks.token()).work"
        )
        let frontier = try DurableArtifactGCMarkFile(
            parent: store.layout.work,
            name: ".gc-frontier.\(store.hooks.token()).work"
        )
        defer {
            try? marks.remove()
            try? frontier.remove()
        }
        func mark(_ id: DurableArtifactObjectID) throws {
            guard try !marks.contains(id) else { return }
            try marks.append(id)
            try frontier.append(id)
            let (next, overflow) = report.markedCount.addingReportingOverflow(1)
            if overflow { throw DurableArtifactStoreError.framingOverflow }
            report.markedCount = next
        }
        for object in objects {
            try mark(object)
        }
        try DurableArtifactSecureIO.forEachEntry(in: store.layout.catalogs) { name in
            guard name.hasSuffix(".catalog") else { throw DurableArtifactStoreError.insecureEntry }
            let rawFamily = String(name.dropLast(".catalog".count))
            guard let family = DurableArtifactFamily(rawValue: rawFamily),
                  let opened = try DurableArtifactSecureIO.openRegularFile(
                      parent: store.layout.catalogs,
                      name: name
                  )
            else { throw DurableArtifactStoreError.insecureEntry }
            defer { opened.0.close() }
            let pointer = try store.readCatalog(
                descriptor: opened.0.rawValue,
                identity: opened.1,
                family: family
            )
            guard try DurableArtifactSecureIO.pathIdentity(
                parent: store.layout.catalogs,
                name: name
            ) == opened.1 else { throw DurableArtifactStoreError.insecureEntry }
            try mark(pointer.target)
        }
        if let referenceEnumerator {
            var offset: off_t = 0
            while let source = try frontier.next(offset: &offset) {
                try referenceEnumerator.enumerate(source) { reference in
                    try mark(reference)
                }
            }
        }
        try marks.synchronize()

        var totalObjectBytes: UInt64 = 0
        try forEachObject { _, identity, _, _ in
            let (next, overflow) = totalObjectBytes.addingReportingOverflow(UInt64(identity.size))
            if overflow { throw DurableArtifactStoreError.framingOverflow }
            totalObjectBytes = next
        }
        var quotaPressure = totalObjectBytes > quota
        try forEachObject { id, identity, parent, name in
            report.examinedObjectCount &+= 1
            guard try !marks.contains(id) else { return }
            let age = now >= UInt64(max(0, identity.modificationSeconds))
                ? now - UInt64(max(0, identity.modificationSeconds))
                : 0
            guard age >= orphanAge || quotaPressure else { return }
            let lockParent = try store.objectLockDirectory(for: id, create: true)!
            guard let objectLock = try DurableArtifactSecureIO.lockDescriptor(
                parent: lockParent,
                name: "\(id.digest.hex).lock",
                exclusive: true,
                nonBlocking: true
            ) else {
                report.busyObjectCount &+= 1
                return
            }
            defer { objectLock.close() }
            guard let opened = try DurableArtifactSecureIO.openRegularFile(parent: parent, name: name) else { return }
            defer { opened.0.close() }
            guard opened.1 == identity else { return }
            try store.quarantine(
                parent: parent,
                name: name,
                descriptor: opened.0.rawValue,
                identity: opened.1,
                kind: "gc",
                id: id
            )
            report.quarantinedObjectCount &+= 1
            report.quarantinedByteCount &+= UInt64(identity.size)
            totalObjectBytes = totalObjectBytes >= UInt64(identity.size)
                ? totalObjectBytes - UInt64(identity.size)
                : 0
            quotaPressure = totalObjectBytes > quota
        }

        try marks.remove()
        try frontier.remove()
        try deleteExpiredQuarantine(now: now, grace: quarantineGrace, report: &report)
        try removeAbandonedWork(now: now, age: workAge, report: &report)
        return report
    }

    func deleteObsoleteVersions(
        candidateMemoryByteBudget: Int = 64 * 1024
    ) throws -> DurableArtifactObsoleteDeletionReport {
        var report = DurableArtifactObsoleteDeletionReport()
        guard let layoutLock = try DurableArtifactSecureIO.lockDescriptor(
            parent: store.layout.root,
            name: ".layout.lock",
            exclusive: true,
            nonBlocking: true
        ) else {
            report.busy = true
            return report
        }
        defer { layoutLock.close() }
        try DurableArtifactSecureIO.validateDirectoryPath(
            store.layout.root,
            parent: store.layout.parent,
            name: store.layout.rootName
        )

        let candidates = try DurableArtifactNameSpool(
            parent: store.layout.work,
            name: ".obsolete-list.\(store.hooks.token()).work",
            memoryByteBudget: candidateMemoryByteBudget
        )
        defer { try? candidates.remove() }
        try DurableArtifactSecureIO.forEachEntry(in: store.layout.root) { name in
            if classifyObsoleteCandidate(name) != nil {
                try candidates.append(name)
            }
        }

        try candidates.synchronize()
        report.candidateCount = candidates.candidateCount
        report.candidateSpillRunCount = candidates.spillRunCount
        report.peakResidentCandidateCount = candidates.peakResidentCandidateCount
        report.peakResidentCandidateByteCount = candidates.peakResidentCandidateByteCount
        var candidateOffset: off_t = 0
        while let candidate = try candidates.next(offset: &candidateOffset) {
            let deletionName: String
            guard let classification = classifyObsoleteCandidate(candidate) else {
                throw DurableArtifactStoreError.invalidFraming
            }
            switch classification {
            case .raw:
                let old = try DurableArtifactSecureIO.ownedDirectory(
                    parent: store.layout.root,
                    name: candidate,
                    create: false
                )
                try DurableArtifactSecureIO.validateDirectoryPath(
                    old,
                    parent: store.layout.root,
                    name: candidate
                )
                deletionName = ".obsolete.\(candidate).\(store.hooks.token())"
                guard try DurableArtifactSecureIO.noReplaceRename(
                    fromParent: store.layout.root,
                    from: candidate,
                    toParent: store.layout.root,
                    to: deletionName
                ) else { throw DurableArtifactStoreError.ioFailure(operation: "obsolete-rename", code: EEXIST) }
                guard let moved = try DurableArtifactSecureIO.optionalOwnedDirectory(
                    parent: store.layout.root,
                    name: deletionName
                ),
                    moved.identity.isSameSecureDirectory(as: old.identity)
                else { throw DurableArtifactStoreError.insecureEntry }
                try store.hooks.crash(.afterObsoleteVersionRename)
                try DurableArtifactSecureIO.synchronize(
                    store.layout.root.descriptor.rawValue,
                    operation: "obsolete-parent-sync"
                )
                report.renamedVersionCount &+= 1
            case .retired:
                deletionName = candidate
            }
            do {
                try removeSecureTree(parent: store.layout.root, name: deletionName, depth: 0)
                report.deletedVersionCount &+= 1
            } catch DurableArtifactStoreError.insecureEntry {
                report.unsafeVersionCount &+= 1
            }
        }
        return report
    }

    private func forEachObject(
        _ body: (
            DurableArtifactObjectID,
            DurableArtifactFileIdentity,
            DurableArtifactDirectory,
            String
        ) throws -> Void
    ) throws {
        try DurableArtifactSecureIO.forEachEntry(in: store.layout.objects) { familyName in
            guard let family = DurableArtifactFamily(rawValue: familyName) else {
                throw DurableArtifactStoreError.insecureEntry
            }
            let familyDirectory = try DurableArtifactSecureIO.ownedDirectory(
                parent: store.layout.objects,
                name: familyName,
                create: false
            )
            try DurableArtifactSecureIO.forEachEntry(in: familyDirectory) { shardName in
                guard shardName.count == 2,
                      shardName.allSatisfy({ $0.isNumber || ("a" ... "f").contains($0) })
                else { throw DurableArtifactStoreError.insecureEntry }
                let shard = try DurableArtifactSecureIO.ownedDirectory(
                    parent: familyDirectory,
                    name: shardName,
                    create: false
                )
                try DurableArtifactSecureIO.forEachEntry(in: shard) { digestName in
                    let digest = try DurableArtifactDigest(hex: digestName)
                    guard digestName.hasPrefix(shardName) else { throw DurableArtifactStoreError.insecureEntry }
                    let identity = try DurableArtifactSecureIO.pathIdentity(parent: shard, name: digestName)
                    guard identity.isRegular, identity.owner == geteuid(), identity.permissions == 0o600,
                          identity.linkCount == 1, identity.device == shard.identity.device, identity.size >= 0
                    else { throw DurableArtifactStoreError.insecureEntry }
                    try body(
                        DurableArtifactObjectID(family: family, digest: digest),
                        identity,
                        shard,
                        digestName
                    )
                }
            }
        }
    }

    private func deleteExpiredQuarantine(
        now: UInt64,
        grace: UInt64,
        report: inout DurableArtifactGCReport
    ) throws {
        try DurableArtifactSecureIO.forEachEntry(in: store.layout.quarantine) { name in
            let components = name.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count >= 5,
                  let family = DurableArtifactFamily(rawValue: String(components[1])),
                  let digest = try? DurableArtifactDigest(hex: String(components[2])),
                  let epoch = UInt64(components[3])
            else { throw DurableArtifactStoreError.insecureEntry }
            guard now >= epoch, now - epoch >= grace else { return }
            let id = DurableArtifactObjectID(family: family, digest: digest)
            let lockParent = try store.objectLockDirectory(for: id, create: true)!
            guard let objectLock = try DurableArtifactSecureIO.lockDescriptor(
                parent: lockParent,
                name: "\(digest.hex).lock",
                exclusive: true,
                nonBlocking: true
            ) else {
                report.busyObjectCount &+= 1
                return
            }
            defer { objectLock.close() }
            guard let opened = try DurableArtifactSecureIO.openRegularFile(
                parent: store.layout.quarantine,
                name: name
            ) else { return }
            defer { opened.0.close() }
            if try DurableArtifactSecureIO.removeIfSame(
                parent: store.layout.quarantine,
                name: name,
                descriptor: opened.0.rawValue,
                identity: opened.1
            ) {
                report.deletedQuarantineCount &+= 1
            }
        }
    }

    private func removeAbandonedWork(
        now: UInt64,
        age: UInt64,
        report: inout DurableArtifactGCReport
    ) throws {
        try DurableArtifactSecureIO.forEachEntry(in: store.layout.work) { name in
            guard name.hasPrefix(".tmp.") || name.hasPrefix(".catalog.tmp.")
                || name.hasSuffix(".work") || name.hasSuffix(".raw-spool")
            else { throw DurableArtifactStoreError.insecureEntry }
            guard let opened = try DurableArtifactSecureIO.openRegularFile(parent: store.layout.work, name: name) else {
                throw DurableArtifactStoreError.insecureEntry
            }
            defer { opened.0.close() }
            let modified = UInt64(max(0, opened.1.modificationSeconds))
            guard now >= modified, now - modified >= age else { return }
            if try DurableArtifactSecureIO.removeIfSame(
                parent: store.layout.work,
                name: name,
                descriptor: opened.0.rawValue,
                identity: opened.1
            ) {
                report.abandonedWorkRemovedCount &+= 1
            }
        }
    }

    private func removeSecureTree(
        parent: DurableArtifactDirectory,
        name: String,
        depth: Int
    ) throws {
        guard depth <= 64 else { throw DurableArtifactStoreError.insecureEntry }
        let directory = try DurableArtifactSecureIO.ownedDirectory(parent: parent, name: name, create: false)
        try DurableArtifactSecureIO.forEachEntry(in: directory) { childName in
            let identity = try DurableArtifactSecureIO.pathIdentity(parent: directory, name: childName)
            if identity.isDirectory {
                try removeSecureTree(parent: directory, name: childName, depth: depth + 1)
            } else {
                guard identity.isRegular, identity.owner == geteuid(), identity.permissions == 0o600,
                      identity.linkCount == 1, identity.device == directory.identity.device
                else { throw DurableArtifactStoreError.insecureEntry }
                guard let opened = try DurableArtifactSecureIO.openRegularFile(
                    parent: directory,
                    name: childName
                ) else { return }
                defer { opened.0.close() }
                guard try DurableArtifactSecureIO.removeIfSame(
                    parent: directory,
                    name: childName,
                    descriptor: opened.0.rawValue,
                    identity: opened.1
                ) else { throw DurableArtifactStoreError.insecureEntry }
            }
        }
        guard try DurableArtifactSecureIO.removeDirectoryIfSame(
            parent: parent,
            name: name,
            directory: directory
        ) else { throw DurableArtifactStoreError.insecureEntry }
    }

    private enum ObsoleteCandidate {
        case raw
        case retired
    }

    private func classifyObsoleteCandidate(_ name: String) -> ObsoleteCandidate? {
        if isObsoleteVersionName(name), name != "v1" { return .raw }
        let prefix = ".obsolete."
        guard name.hasPrefix(prefix) else { return nil }
        let remainder = name.dropFirst(prefix.count)
        guard let separator = remainder.firstIndex(of: "."),
              separator != remainder.startIndex,
              remainder.index(after: separator) != remainder.endIndex
        else { return nil }
        let version = String(remainder[..<separator])
        guard isObsoleteVersionName(version), version != "v1" else { return nil }
        return .retired
    }

    private func isObsoleteVersionName(_ name: String) -> Bool {
        guard name.first == "v", name.count > 1 else { return false }
        return name.dropFirst().allSatisfy(\.isNumber)
    }
}

private final class DurableArtifactNameSpool {
    private let parent: DurableArtifactDirectory
    private let name: String
    private let descriptor: DurableArtifactDescriptor
    private let memoryByteBudget: Int
    private var buffer = Data()
    private var bufferedCandidateCount: UInt64 = 0
    private var removed = false
    private(set) var candidateCount: UInt64 = 0
    private(set) var spillRunCount: UInt64 = 0
    private(set) var peakResidentCandidateCount: UInt64 = 0
    private(set) var peakResidentCandidateByteCount = 0

    init(parent: DurableArtifactDirectory, name: String, memoryByteBudget: Int) throws {
        guard memoryByteBudget > 0 else { throw DurableArtifactStoreError.invalidFraming }
        self.parent = parent
        self.name = name
        self.memoryByteBudget = memoryByteBudget
        descriptor = try DurableArtifactSecureIO.createExclusiveFile(parent: parent, name: name)
    }

    func append(_ value: String) throws {
        let bytes = Data(value.utf8)
        guard !bytes.isEmpty, bytes.count <= Int(UInt16.max) else {
            throw DurableArtifactStoreError.invalidFraming
        }
        var length = UInt16(bytes.count).bigEndian
        var record = withUnsafeBytes(of: &length) { Data($0) }
        record.append(bytes)
        candidateCount &+= 1
        if record.count > memoryByteBudget {
            try flush()
            try DurableArtifactSecureIO.writeAll(descriptor.rawValue, data: record)
            spillRunCount &+= 1
            return
        }
        if !buffer.isEmpty, buffer.count + record.count > memoryByteBudget {
            try flush()
        }
        buffer.append(record)
        bufferedCandidateCount &+= 1
        peakResidentCandidateCount = max(peakResidentCandidateCount, bufferedCandidateCount)
        peakResidentCandidateByteCount = max(peakResidentCandidateByteCount, buffer.count)
    }

    func next(offset: inout off_t) throws -> String? {
        let identity = try DurableArtifactSecureIO.identity(descriptor.rawValue)
        guard identity.size >= 0, offset >= 0, offset <= identity.size else {
            throw DurableArtifactStoreError.invalidFraming
        }
        if offset == identity.size { return nil }
        let lengthData = try DurableArtifactSecureIO.preadExactly(descriptor.rawValue, offset: offset, count: 2)
        let length = lengthData.withUnsafeBytes { raw in
            UInt16(bigEndian: raw.loadUnaligned(as: UInt16.self))
        }
        guard length > 0 else { throw DurableArtifactStoreError.invalidFraming }
        let (nextOffset, overflow) = offset.addingReportingOverflow(off_t(2 + Int(length)))
        guard !overflow, nextOffset <= identity.size else { throw DurableArtifactStoreError.invalidFraming }
        let valueData = try DurableArtifactSecureIO.preadExactly(
            descriptor.rawValue,
            offset: offset + 2,
            count: Int(length)
        )
        guard let value = String(data: valueData, encoding: .utf8),
              !value.contains("/"), value != ".", value != ".."
        else { throw DurableArtifactStoreError.invalidFraming }
        offset = nextOffset
        return value
    }

    func synchronize() throws {
        try flush()
        try DurableArtifactSecureIO.synchronize(descriptor.rawValue, operation: "obsolete-list-sync")
        _ = try DurableArtifactSecureIO.validateRegularFile(
            descriptor: descriptor.rawValue,
            parent: parent,
            name: name
        )
    }

    func remove() throws {
        guard !removed else { return }
        let identity = try DurableArtifactSecureIO.validateRegularFile(
            descriptor: descriptor.rawValue,
            parent: parent,
            name: name
        )
        removed = try DurableArtifactSecureIO.removeIfSame(
            parent: parent,
            name: name,
            descriptor: descriptor.rawValue,
            identity: identity
        )
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try DurableArtifactSecureIO.writeAll(descriptor.rawValue, data: buffer)
        spillRunCount &+= 1
        buffer.removeAll(keepingCapacity: true)
        bufferedCandidateCount = 0
    }
}

private final class DurableArtifactGCMarkFile {
    private let parent: DurableArtifactDirectory
    private let name: String
    private let descriptor: DurableArtifactDescriptor
    private var removed = false

    init(parent: DurableArtifactDirectory, name: String) throws {
        self.parent = parent
        self.name = name
        descriptor = try DurableArtifactSecureIO.createExclusiveFile(parent: parent, name: name)
    }

    func append(_ id: DurableArtifactObjectID) throws {
        let familyBytes = Data(id.family.rawValue.utf8)
        guard familyBytes.count <= 64 else { throw DurableArtifactStoreError.invalidFamily }
        var record = Data([UInt8(familyBytes.count)])
        record.append(familyBytes)
        record.append(id.digest.bytes)
        try DurableArtifactSecureIO.writeAll(descriptor.rawValue, data: record)
    }

    func contains(_ expected: DurableArtifactObjectID) throws -> Bool {
        var offset: off_t = 0
        while let candidate = try next(offset: &offset) {
            if candidate == expected { return true }
        }
        return false
    }

    func next(offset: inout off_t) throws -> DurableArtifactObjectID? {
        let identity = try DurableArtifactSecureIO.identity(descriptor.rawValue)
        guard identity.size >= 0, offset >= 0, offset <= identity.size else {
            throw DurableArtifactStoreError.invalidFraming
        }
        if offset == identity.size { return nil }
        let lengthData = try DurableArtifactSecureIO.preadExactly(descriptor.rawValue, offset: offset, count: 1)
        let familyLength = Int(lengthData[0])
        guard familyLength > 0, familyLength <= 64 else { throw DurableArtifactStoreError.invalidFraming }
        let recordByteCount = 1 + familyLength + 32
        let (nextOffset, overflow) = offset.addingReportingOverflow(off_t(recordByteCount))
        guard !overflow, nextOffset <= identity.size else { throw DurableArtifactStoreError.invalidFraming }
        let body = try DurableArtifactSecureIO.preadExactly(
            descriptor.rawValue,
            offset: offset + 1,
            count: familyLength + 32
        )
        guard let familyName = String(data: body.prefix(familyLength), encoding: .utf8),
              let family = DurableArtifactFamily(rawValue: familyName)
        else { throw DurableArtifactStoreError.invalidFraming }
        let digest = try DurableArtifactDigest(bytes: Data(body.suffix(32)))
        offset = nextOffset
        return DurableArtifactObjectID(family: family, digest: digest)
    }

    func synchronize() throws {
        try DurableArtifactSecureIO.synchronize(descriptor.rawValue, operation: "gc-mark-file-sync")
        _ = try DurableArtifactSecureIO.validateRegularFile(
            descriptor: descriptor.rawValue,
            parent: parent,
            name: name
        )
    }

    func remove() throws {
        guard !removed else { return }
        let identity = try DurableArtifactSecureIO.validateRegularFile(
            descriptor: descriptor.rawValue,
            parent: parent,
            name: name
        )
        removed = try DurableArtifactSecureIO.removeIfSame(
            parent: parent,
            name: name,
            descriptor: descriptor.rawValue,
            identity: identity
        )
    }
}
