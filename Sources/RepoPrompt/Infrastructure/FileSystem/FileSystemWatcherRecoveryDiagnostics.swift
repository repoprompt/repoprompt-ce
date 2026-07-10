import CoreServices
import Foundation

struct FileSystemWatcherRecoveryCauseSet: OptionSet, Sendable, Hashable {
    let rawValue: UInt16

    static let mustScanSubdirectories = Self(rawValue: 1 << 0)
    static let userDropped = Self(rawValue: 1 << 1)
    static let kernelDropped = Self(rawValue: 1 << 2)
    static let rootChanged = Self(rawValue: 1 << 3)
    static let eventIDsWrapped = Self(rawValue: 1 << 4)
    static let mailboxCapacity = Self(rawValue: 1 << 5)
    static let serviceCapacity = Self(rawValue: 1 << 6)

    static let fseventUncertainty: Self = [
        .mustScanSubdirectories,
        .userDropped,
        .kernelDropped,
        .rootChanged,
        .eventIDsWrapped
    ]

    static let rootRescanRequired: Self = [
        .mustScanSubdirectories,
        .userDropped,
        .kernelDropped,
        .rootChanged,
        .eventIDsWrapped,
        .mailboxCapacity,
        .serviceCapacity
    ]

    static func from(_ flags: FSEventStreamEventFlags) -> Self {
        let raw = UInt32(flags)
        func has(_ flag: Int) -> Bool {
            (raw & UInt32(flag)) != 0
        }

        var causes: Self = []
        if has(kFSEventStreamEventFlagMustScanSubDirs) {
            causes.insert(.mustScanSubdirectories)
        }
        if has(kFSEventStreamEventFlagUserDropped) {
            causes.insert(.userDropped)
        }
        if has(kFSEventStreamEventFlagKernelDropped) {
            causes.insert(.kernelDropped)
        }
        if has(kFSEventStreamEventFlagRootChanged) {
            causes.insert(.rootChanged)
        }
        if has(kFSEventStreamEventFlagEventIdsWrapped) {
            causes.insert(.eventIDsWrapped)
        }
        return causes
    }
}

struct FileSystemWatcherIngressTriggerSet: OptionSet, Sendable, Hashable {
    let rawValue: UInt8

    static let ordinary = Self(rawValue: 1 << 0)
    static let ignoreControl = Self(rawValue: 1 << 1)
    static let fseventRecovery = Self(rawValue: 1 << 2)
    static let mailboxCapacity = Self(rawValue: 1 << 3)
    static let serviceCapacity = Self(rawValue: 1 << 4)
}

struct FileSystemWatcherIngressEvidence: Sendable, Equatable {
    var callbackCount: Int
    var sourceEntryCount: Int
    var retainedEntryCount: Int
    var earlyFilteredEntryCount: Int
    var callbackDurationMicroseconds: UInt64
    var triggers: FileSystemWatcherIngressTriggerSet
    var recoveryCauses: FileSystemWatcherRecoveryCauseSet

    static let empty = Self(
        callbackCount: 0,
        sourceEntryCount: 0,
        retainedEntryCount: 0,
        earlyFilteredEntryCount: 0,
        callbackDurationMicroseconds: 0,
        triggers: [],
        recoveryCauses: []
    )

    static func callback(
        sourcePayload: FSEventCallbackPayload,
        retainedEntryCount: Int,
        earlyFilteredEntryCount: Int,
        callbackDurationMicroseconds: UInt64
    ) -> Self {
        var triggers: FileSystemWatcherIngressTriggerSet = []
        var causes: FileSystemWatcherRecoveryCauseSet = []
        var hasIgnoreControl = false
        for entry in sourcePayload.entries {
            causes.formUnion(.from(entry.flags))
            hasIgnoreControl = hasIgnoreControl || Self.isIgnoreControlPath(entry.path)
        }
        if causes.intersection(.fseventUncertainty).isEmpty {
            triggers.insert(.ordinary)
        } else {
            triggers.insert(.fseventRecovery)
        }
        if hasIgnoreControl {
            triggers.insert(.ignoreControl)
        }
        return Self(
            callbackCount: 1,
            sourceEntryCount: sourcePayload.count,
            retainedEntryCount: retainedEntryCount,
            earlyFilteredEntryCount: earlyFilteredEntryCount,
            callbackDurationMicroseconds: callbackDurationMicroseconds,
            triggers: triggers,
            recoveryCauses: causes
        )
    }

    func merging(_ other: Self) -> Self {
        Self(
            callbackCount: callbackCount + other.callbackCount,
            sourceEntryCount: sourceEntryCount + other.sourceEntryCount,
            retainedEntryCount: retainedEntryCount + other.retainedEntryCount,
            earlyFilteredEntryCount: earlyFilteredEntryCount + other.earlyFilteredEntryCount,
            callbackDurationMicroseconds: callbackDurationMicroseconds + other.callbackDurationMicroseconds,
            triggers: triggers.union(other.triggers),
            recoveryCauses: recoveryCauses.union(other.recoveryCauses)
        )
    }

    func addingCapacityRecovery(
        cause: FileSystemWatcherRecoveryCauseSet,
        trigger: FileSystemWatcherIngressTriggerSet
    ) -> Self {
        var updated = self
        updated.recoveryCauses.formUnion(cause)
        updated.triggers.formUnion(trigger)
        return updated
    }

    private static func isIgnoreControlPath(_ path: String) -> Bool {
        let filename = (path as NSString).lastPathComponent.lowercased()
        return filename == ".gitignore" || filename == ".repo_ignore" || filename == ".cursorignore"
    }
}

struct FileSystemWatcherRecoveryEpisodeSummary: Sendable, Equatable {
    let triggers: FileSystemWatcherIngressTriggerSet
    let causes: FileSystemWatcherRecoveryCauseSet
    let callbackCount: Int
    let acceptedEntryCount: Int
    let earlyFilteredEntryCount: Int
    let callbackDurationMicroseconds: UInt64
    let triggeredRootRescan: Bool
    let triggeredFullResync: Bool
    let completedFullResync: Bool
    let acceptedHighWatermark: UInt64?
    let servicePublicationSequence: UInt64?
}

struct FileSystemWatcherRecoveryDiagnosticsSnapshot: Sendable, Equatable {
    let callbackCount: UInt64
    let sourceEntryCount: UInt64
    let retainedEntryCount: UInt64
    let earlyFilteredEntryCount: UInt64
    let callbackDurationMicroseconds: UInt64
    let recoveryEpisodes: [FileSystemWatcherRecoveryEpisodeSummary]
}

final class FileSystemWatcherRecoveryDiagnostics: @unchecked Sendable {
    private static let maximumRetainedEpisodes = 64

    private let lock = NSLock()
    private var callbackCount: UInt64 = 0
    private var sourceEntryCount: UInt64 = 0
    private var retainedEntryCount: UInt64 = 0
    private var earlyFilteredEntryCount: UInt64 = 0
    private var callbackDurationMicroseconds: UInt64 = 0
    private var recoveryEpisodes: [FileSystemWatcherRecoveryEpisodeSummary] = []

    func recordCallback(_ evidence: FileSystemWatcherIngressEvidence) {
        lock.lock()
        callbackCount &+= UInt64(evidence.callbackCount)
        sourceEntryCount &+= UInt64(evidence.sourceEntryCount)
        retainedEntryCount &+= UInt64(evidence.retainedEntryCount)
        earlyFilteredEntryCount &+= UInt64(evidence.earlyFilteredEntryCount)
        callbackDurationMicroseconds &+= evidence.callbackDurationMicroseconds
        lock.unlock()
    }

    func recordRecoveryEpisode(
        evidence: FileSystemWatcherIngressEvidence,
        triggeredFullResync: Bool,
        completedFullResync: Bool,
        acceptedHighWatermark: FileSystemWatcherIngressMailbox.Watermark?,
        servicePublicationSequence: UInt64?
    ) {
        guard !evidence.recoveryCauses.isEmpty else { return }
        let summary = FileSystemWatcherRecoveryEpisodeSummary(
            triggers: evidence.triggers,
            causes: evidence.recoveryCauses,
            callbackCount: evidence.callbackCount,
            acceptedEntryCount: evidence.retainedEntryCount,
            earlyFilteredEntryCount: evidence.earlyFilteredEntryCount,
            callbackDurationMicroseconds: evidence.callbackDurationMicroseconds,
            triggeredRootRescan: !evidence.recoveryCauses.intersection(.rootRescanRequired).isEmpty,
            triggeredFullResync: triggeredFullResync,
            completedFullResync: completedFullResync,
            acceptedHighWatermark: acceptedHighWatermark?.rawValue,
            servicePublicationSequence: servicePublicationSequence
        )
        lock.lock()
        if let index = recoveryEpisodes.lastIndex(where: {
            $0.acceptedHighWatermark == summary.acceptedHighWatermark && !$0.completedFullResync
        }) {
            recoveryEpisodes[index] = summary
        } else {
            recoveryEpisodes.append(summary)
        }
        if recoveryEpisodes.count > Self.maximumRetainedEpisodes {
            recoveryEpisodes.removeFirst(recoveryEpisodes.count - Self.maximumRetainedEpisodes)
        }
        lock.unlock()
    }

    func snapshot() -> FileSystemWatcherRecoveryDiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return FileSystemWatcherRecoveryDiagnosticsSnapshot(
            callbackCount: callbackCount,
            sourceEntryCount: sourceEntryCount,
            retainedEntryCount: retainedEntryCount,
            earlyFilteredEntryCount: earlyFilteredEntryCount,
            callbackDurationMicroseconds: callbackDurationMicroseconds,
            recoveryEpisodes: recoveryEpisodes
        )
    }
}
