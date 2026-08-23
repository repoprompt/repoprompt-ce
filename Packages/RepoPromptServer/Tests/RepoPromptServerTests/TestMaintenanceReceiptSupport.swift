import Foundation
@testable import RepoPromptServerHost
@testable import RepoPromptServicePersistence

func makeTestMaintenanceReceipt(
    storeID: UUID,
    backupSequence: Int64,
    manifestSHA256: String,
    archiveSHA256: String = String(repeating: "c", count: 64)
) -> MaintenanceReceiptEvidence {
    MaintenanceReceiptEvidence(
        archiveSHA256: archiveSHA256,
        manifestSHA256: manifestSHA256,
        source: MigrationSourceEvidence(
            storeID: storeID,
            schemaVersion: 9,
            nextGlobalSequence: backupSequence,
            sqliteSHA256: String(repeating: "a", count: 64),
            migrationLedgerSHA256: String(repeating: "b", count: 64)
        ),
        verifierFingerprint: String(repeating: "d", count: 64),
        recipientFingerprints: ["x25519:test-recipient"],
        sidecarSHA256: String(repeating: "e", count: 64),
        toolVersion: "RepoPromptServerTests/1",
        toolDigest: String(repeating: "f", count: 64)
    )
}

func makeTestMaintenanceReceipt(_ receipt: RestoreMaintenanceReceiptV1) -> MaintenanceReceiptEvidence {
    MaintenanceReceiptEvidence(
        archiveSHA256: receipt.archiveSHA256,
        manifestSHA256: receipt.manifestSHA256,
        source: receipt.source,
        verifierFingerprint: receipt.verifierFingerprint,
        recipientFingerprints: receipt.recipientFingerprints,
        sidecarSHA256: receipt.sidecarSHA256,
        toolVersion: receipt.toolVersion,
        toolDigest: receipt.toolDigest
    )
}
