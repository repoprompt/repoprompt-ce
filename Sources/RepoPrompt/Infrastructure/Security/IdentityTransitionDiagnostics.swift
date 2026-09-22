import Foundation

struct IdentityTransitionDiagnosticEvent: Codable, Equatable {
    enum Subsystem: String, Codable {
        case defaultsMigration = "defaults-migration"
        case secureStorage = "secure-storage"
        case sparkle
    }

    enum Outcome: String, Codable {
        case started
        case succeeded
        case skipped
        case alreadyCompleted = "already-completed"
        case blocked
        case failed
        case cancelled
        case selected
    }

    let timestamp: Date
    let subsystem: Subsystem
    let stage: String
    let outcome: Outcome
    let bundleIdentifier: String?
    let displayVersion: String?
    let buildVersion: String?
    let migrationPhase: String?
    let secureStorageDomain: String?
    let updateChannel: String?
    let targetDisplayVersion: String?
    let targetBuildVersion: String?
    let recordStateCounts: [String: Int]?
    let errorClass: String?
}

/// A small, local source of truth for the identity rollover. Events deliberately omit
/// credential identifiers, values, attempt IDs, paths, URLs, and raw error text.
final class IdentityTransitionDiagnostics: @unchecked Sendable {
    private struct Ledger: Codable, Equatable {
        static let currentVersion = 1

        let schemaVersion: Int
        var events: [IdentityTransitionDiagnosticEvent]
    }

    static let shared = IdentityTransitionDiagnostics()
    static let maximumEventCount = 64

    private let fileManager: FileManager
    private let fileURL: URL?
    private let maximumEventCount: Int
    private let now: () -> Date
    private let lock = NSLock()

    init(
        fileManager: FileManager = .default,
        fileURL: URL? = IdentityTransitionDiagnostics.defaultFileURL(),
        maximumEventCount: Int = IdentityTransitionDiagnostics.maximumEventCount,
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.fileURL = fileURL
        self.maximumEventCount = max(1, maximumEventCount)
        self.now = now
    }

    func record(
        subsystem: IdentityTransitionDiagnosticEvent.Subsystem,
        stage: String,
        outcome: IdentityTransitionDiagnosticEvent.Outcome,
        bundle: Bundle = .main,
        secureStorageDomain: RuntimeSecureStorageDomain? = nil,
        targetDisplayVersion: String? = nil,
        targetBuildVersion: String? = nil,
        recordStateCounts: [String: Int]? = nil,
        errorClass: String? = nil
    ) {
        let event = IdentityTransitionDiagnosticEvent(
            timestamp: now(),
            subsystem: subsystem,
            stage: stage,
            outcome: outcome,
            bundleIdentifier: bundle.bundleIdentifier,
            displayVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            migrationPhase: bundle.object(
                forInfoDictionaryKey: SecureStorageIdentityMigrationBootstrap.phaseInfoKey
            ) as? String,
            secureStorageDomain: secureStorageDomain?.diagnosticName,
            updateChannel: UpdateChannel.load().rawValue,
            targetDisplayVersion: targetDisplayVersion,
            targetBuildVersion: targetBuildVersion,
            recordStateCounts: recordStateCounts,
            errorClass: errorClass
        )
        record(event)
    }

    func record(_ event: IdentityTransitionDiagnosticEvent) {
        let line = "[IdentityTransition] subsystem=\(event.subsystem.rawValue) stage=\(event.stage) outcome=\(event.outcome.rawValue)\n"
        FileHandle.standardError.write(Data(line.utf8))
        guard let fileURL else { return }

        lock.lock()
        defer { lock.unlock() }

        do {
            let directoryURL = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )

            var ledger = loadLedger(from: fileURL) ?? Ledger(
                schemaVersion: Ledger.currentVersion,
                events: []
            )
            ledger.events.append(event)
            if ledger.events.count > maximumEventCount {
                ledger.events.removeFirst(ledger.events.count - maximumEventCount)
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(ledger).write(to: fileURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // Diagnostics must never change update or migration behavior. The sanitized
            // stderr event above remains available if durable persistence fails.
        }
    }

    func readEvents() -> [IdentityTransitionDiagnosticEvent] {
        guard let fileURL else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return loadLedger(from: fileURL)?.events ?? []
    }

    private func loadLedger(from fileURL: URL) -> Ledger? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let ledger = try? decoder.decode(Ledger.self, from: data),
              ledger.schemaVersion == Ledger.currentVersion
        else {
            return nil
        }
        return ledger
    }

    private static func defaultFileURL(fileManager: FileManager = .default) -> URL? {
        guard let supportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return supportURL
            .appendingPathComponent("RepoPrompt CE", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("identity-transition-v1.json", isDirectory: false)
    }
}

private extension RuntimeSecureStorageDomain {
    var diagnosticName: String {
        switch self {
        case .officialDeveloperID: "legacy-official"
        case .successorOfficialDeveloperID: "successor-official"
        case .localSelfSigned: "local-self-signed"
        case .appleDevelopmentDebug: "apple-development"
        case .ephemeral: "ephemeral"
        }
    }
}
