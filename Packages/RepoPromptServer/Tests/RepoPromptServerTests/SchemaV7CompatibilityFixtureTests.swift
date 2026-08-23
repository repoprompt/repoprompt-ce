import Crypto
import Foundation
import XCTest
@testable import RepoPromptServicePersistence

final class SchemaV7CompatibilityFixtureTests: XCTestCase {
    func testEveryFrozenV6DigestPreservesLedgerAndRecordsExactNormalization() async throws {
        let fixtures: [(digest: String, programID: String?)] = [
            (StoreMigrationTestSupport.knownV6Digests[0], nil),
        ] + StoreMigrationTestSupport.historicalV6Programs
            .filter { $0.programID != "typed-mcp-show-model-presets" }
            .map { ($0.ledgerDigest, Optional($0.programID)) }

        for fixture in fixtures {
            let digest = fixture.digest
            let root = try StoreMigrationTestSupport.temporaryDirectory(fixture.programID ?? "current-v6")
            defer { try? FileManager.default.removeItem(at: root) }
            let databaseURL = root.appendingPathComponent("repoprompt.sqlite")
            if let programID = fixture.programID {
                try await StoreMigrationTestSupport.makeV6Store(at: databaseURL, programID: programID)
            } else {
                try await StoreMigrationTestSupport.makeV6Store(at: databaseURL, digest: digest)
            }
            let store = try await SQLiteServiceStore.openForMaintenance(storage: .file(databaseURL.path))
            let projectID = UUID()
            let legacyJSON = #"{"goblinUserId":"u1","selection":"goblin-explicit-selection"}"#
            _ = try await store.database.query(
                "INSERT INTO projects(project_id,schema_version,name,creator_json,lifecycle_state,revision,snapshot_json,created_at,updated_at) VALUES(?,1,'goblinUserId',?,'active',1,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)",
                [.text(projectID.uuidString), .text(legacyJSON), .text(legacyJSON)]
            )
            let legacySessionID = UUID().uuidString
            if fixture.programID != nil {
                _ = try await store.database.query(
                    "INSERT INTO sessions(session_id,project_id,root_session_id,schema_version,creator_external_id,lifecycle_state,provider_kind,visibility,run_generation,turn_epoch,revision,snapshot_json,created_at,updated_at) VALUES(?,?,?,1,'fixture','active','fake','private',0,0,1,'{}',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)",
                    [.text(legacySessionID), .text(projectID.uuidString), .text(legacySessionID)]
                )
                let historicalColumns = Set(
                    try await store.database.query("PRAGMA table_info(collaboration_metadata)")
                        .compactMap { $0.column("name")?.string }
                )
                if historicalColumns.contains("collaboration_acknowledgement_json"),
                   historicalColumns.contains("goblin_acknowledgement_json")
                {
                    _ = try await store.database.query(
                        "INSERT INTO collaboration_metadata(session_id,schema_version,visibility,collaborative_steering_enabled,controller_user_id,policy_revision,controller_revision,membership_revision,collaboration_acknowledgement_json,goblin_acknowledgement_json,updated_at) VALUES(?,1,'private',0,'fixture',1,1,1,NULL,'{\"accepted\":true}',CURRENT_TIMESTAMP)",
                        [.text(legacySessionID)]
                    )
                } else if historicalColumns.contains("goblin_acknowledgement_json") {
                    _ = try await store.database.query(
                        "INSERT INTO collaboration_metadata(session_id,schema_version,visibility,collaborative_steering_enabled,controller_user_id,policy_revision,controller_revision,membership_revision,goblin_acknowledgement_json,updated_at) VALUES(?,1,'private',0,'fixture',1,1,1,'{\"accepted\":true}',CURRENT_TIMESTAMP)",
                        [.text(legacySessionID)]
                    )
                } else {
                    XCTAssertTrue(historicalColumns.contains("collaboration_acknowledgement_json"))
                    _ = try await store.database.query(
                        "INSERT INTO collaboration_metadata(session_id,schema_version,visibility,collaborative_steering_enabled,controller_user_id,policy_revision,controller_revision,membership_revision,collaboration_acknowledgement_json,updated_at) VALUES(?,1,'private',0,'fixture',1,1,1,'{\"accepted\":true}',CURRENT_TIMESTAMP)",
                        [.text(legacySessionID)]
                    )
                }
            }
            let source = try await store.migrationSourceEvidence()
            _ = try await store.migrateToLatest(
                verifiedBackup: .init(
                    source: source,
                    archiveSHA256: String(repeating: "a", count: 64),
                    manifestSHA256: String(repeating: "b", count: 64),
                    verifierFingerprint: String(repeating: "c", count: 64),
                    recipientFingerprints: ["age:x25519:test"],
                    sidecarSHA256: String(repeating: "d", count: 64),
                    toolVersion: "test-tool",
                    toolDigest: String(repeating: "e", count: 64)
                ),
                namespaceKind: "server",
                databaseIdentityDigest: String(repeating: "d", count: 64)
            )
            let preserved = try await store.database.query("SELECT digest FROM schema_migrations WHERE version=6").first?.column("digest")?.string
            XCTAssertEqual(preserved, digest)
            let audit = try await store.database.query(
                "SELECT observed_digest,normalization_id,schema_shape_digest FROM schema_compatibility_audit"
            ).first
            XCTAssertEqual(audit?.column("observed_digest")?.string, digest)
            XCTAssertEqual(audit?.column("normalization_id")?.string, SchemaV7.normalizationID(for: digest))
            XCTAssertEqual(audit?.column("schema_shape_digest")?.string, SchemaV7.finalV6ShapeDigest)
            let normalizedProject = try await store.database.query(
                "SELECT name,creator_json,snapshot_json FROM projects WHERE project_id=?",
                [.text(projectID.uuidString)]
            ).first
            XCTAssertEqual(normalizedProject?.column("name")?.string, "goblinUserId")
            if fixture.programID == nil {
                XCTAssertEqual(normalizedProject?.column("creator_json")?.string, legacyJSON)
                XCTAssertEqual(normalizedProject?.column("snapshot_json")?.string, legacyJSON)
            } else {
                XCTAssertEqual(
                    normalizedProject?.column("creator_json")?.string,
                    #"{"userId":"u1","selection":"explicit-selection"}"#
                )
                XCTAssertEqual(
                    normalizedProject?.column("snapshot_json")?.string,
                    #"{"userId":"u1","selection":"explicit-selection"}"#
                )
            }
            if fixture.programID != nil {
                let collaboration = try await store.database.query(
                    "SELECT collaboration_acknowledgement_json FROM collaboration_metadata WHERE session_id=?",
                    [.text(legacySessionID)]
                ).first
                XCTAssertEqual(
                    collaboration?.column("collaboration_acknowledgement_json")?.string,
                    "{\"accepted\":true}"
                )
                let columns = Set(try await store.database.query("PRAGMA table_info(collaboration_metadata)")
                    .compactMap { $0.column("name")?.string })
                XCTAssertFalse(columns.contains("goblin_acknowledgement_json"))
            }
            let metadata = try await store.metadata()
            XCTAssertEqual(metadata.schemaVersion, SchemaV9.version)
            try await store.close(clean: false)
        }
    }

    func testFrozenHistoricalProgramsHaveVerifiedIdentitiesAndDistinguishSameLabelShapes() {
        let baseStatementsDigest = "sha256:f1812a9dbb2142d6cff44866cee15a133a0b68d2fa541e8d81a06e623857bc31"
        let baseProgramDigest = "sha256:dbe86488211353095d59d46befb63d15c1fc02103429ab96c86bd26a5b3606c9"
        XCTAssertEqual(StoreMigrationTestSupport.frozenFormatVersion, 1)
        XCTAssertEqual(StoreMigrationTestSupport.frozenBaseSourceCommit, "561a4a3831f248e280be42c7c73f597a8199a74f")
        XCTAssertEqual(StoreMigrationTestSupport.frozenBaseStatementsDigest, baseStatementsDigest)
        XCTAssertEqual(StoreMigrationTestSupport.frozenBaseProgramDigest, baseProgramDigest)

        let expectedBaseVersions: [(Int, String, String)] = [
            (1, "v1", "initial-durable-service-schema-v1"),
            (2, "repoprompt-service-schema-v2-owned-resources-archives-restore-counters", "owned-resources-archives-restore-counters-v1"),
            (3, "repoprompt-service-schema-v3-provider-settings", "provider-settings-v1"),
            (4, "repoprompt-service-schema-v4-provider-connections-audit", "provider-connections-audit-v1"),
            (5, "repoprompt-service-schema-v5-portal-desktop-settings", "provider-model-catalog-cache-v1"),
        ]
        let versions = StoreMigrationTestSupport.frozenVersions1Through5
        XCTAssertEqual(versions.count, expectedBaseVersions.count)
        for (version, expected) in zip(versions, expectedBaseVersions) {
            XCTAssertEqual(version.version, expected.0)
            XCTAssertEqual(version.ledgerDigest, expected.1)
            XCTAssertEqual(version.transformationID, expected.2)
        }
        XCTAssertEqual(Self.digest(Self.baseProgramMaterial(versions)), baseStatementsDigest)
        XCTAssertEqual(
            Self.digest([
                "format:1",
                "source:561a4a3831f248e280be42c7c73f597a8199a74f",
                "statements:\(baseStatementsDigest)",
            ]),
            baseProgramDigest
        )

        let programs = StoreMigrationTestSupport.historicalV6Programs
        XCTAssertEqual(Set(programs.map(\.ledgerDigest)), Set(StoreMigrationTestSupport.knownV6Digests))
        XCTAssertEqual(Set(programs.map(\.programID)), Set(Self.trustedV6Identities.keys))
        for program in programs {
            guard let trusted = Self.trustedV6Identities[program.programID] else {
                return XCTFail("untrusted historical program \(program.programID)")
            }
            XCTAssertEqual(program.sourceCommit, trusted.sourceCommit)
            XCTAssertEqual(program.sourceKind, trusted.sourceKind)
            XCTAssertEqual(program.ledgerDigest, trusted.ledgerDigest)
            XCTAssertEqual(program.transformationID, trusted.transformationID)
            XCTAssertEqual(program.statementsDigest, trusted.statementsDigest)
            XCTAssertEqual(program.programDigest, trusted.programDigest)
            XCTAssertEqual(
                Self.digest([program.transformationID] + program.statements),
                trusted.statementsDigest,
                "frozen historical statements changed; add a new trusted identity"
            )
            XCTAssertEqual(
                Self.digest([
                    "program:\(program.programID)",
                    "source:\(program.sourceCommit)",
                    "kind:\(program.sourceKind)",
                    "ledger:\(program.ledgerDigest)",
                    "statements:\(trusted.statementsDigest)",
                ]),
                trusted.programDigest,
                "frozen historical identity changed; add a new trusted identity"
            )
        }

        let sameLabel = programs.filter {
            $0.ledgerDigest == "repoprompt-service-schema-v6-typed-settings-agent-composer-semantic-acceptance"
        }
        XCTAssertEqual(sameLabel.count, 2)
        XCTAssertEqual(Set(sameLabel.map(\.sourceCommit)).count, 2)
        XCTAssertEqual(Set(sameLabel.map(\.programDigest)).count, 2)
        XCTAssertEqual(Set(sameLabel.map(\.statementsDigest)).count, 2)
        XCTAssertNotEqual(sameLabel[0].statements, sameLabel[1].statements)
    }

    private struct TrustedV6Identity {
        let sourceCommit: String
        let sourceKind: String
        let ledgerDigest: String
        let transformationID: String
        let statementsDigest: String
        let programDigest: String
    }

    private static let trustedV6Identities: [String: TrustedV6Identity] = [
        "typed-settings": .init(sourceCommit: "a01611958c1a1f9b37cb2a315875fb98653fa2ba", sourceKind: "reachable-commit", ledgerDigest: "repoprompt-service-schema-v6-typed-settings-workflows-direct-providers-cas-audit", transformationID: "prototype-v6-program:typed-settings", statementsDigest: "sha256:831dbd5fe8a03a28acfa519ee8ad0498bfe5c4fb8950497312cb6eb7bc9c1321", programDigest: "sha256:69f0099aa42d2e9087b44b573c83499eee517dd852a0b2fb0feddf3b94a66fd1"),
        "composer-only": .init(sourceCommit: "387ad35765f1398cba2aa2616b4a7e6c930ab568", sourceKind: "reachable-commit", ledgerDigest: "repoprompt-service-schema-v6-agent-composer-semantic-acceptance", transformationID: "prototype-v6-program:composer-only", statementsDigest: "sha256:339172f4b715c1e78bfbdc98d7e9bae392f2b85c9f09882b75e459ee8fbbcb78", programDigest: "sha256:e0c92ab4ac7517c94d438599e3935e1e1f5515ab2953ae57beab19bca0c63724"),
        "typed-composer-foundation": .init(sourceCommit: "7dbeafa5c8e00b4a9e33d4973ba144fac85edca0", sourceKind: "reachable-commit", ledgerDigest: "repoprompt-service-schema-v6-typed-settings-agent-composer-semantic-acceptance", transformationID: "prototype-v6-program:typed-composer-foundation", statementsDigest: "sha256:ccff9cf77b979e50126c2a1510ab735d47d15191e77f2a3a0a628ea48407b82d", programDigest: "sha256:b5e0b50c357d77b12e1acce27651bda0f27fd3814e5a55b3dd2bb086ba073d87"),
        "typed-composer-streamed": .init(sourceCommit: "047f3a2e7b408e8b8394274f49946ea05467ba7d", sourceKind: "reachable-commit", ledgerDigest: "repoprompt-service-schema-v6-typed-settings-agent-composer-semantic-acceptance", transformationID: "prototype-v6-program:typed-composer-streamed", statementsDigest: "sha256:acf96b19bf1abe78b61a2386bfecfa7cf5354dc8b086ce78783df364fd5ba11f", programDigest: "sha256:65c9ab3b067fb28e39fd9744a99f5b359497725fecee80b21e854c35cc73f49e"),
        "typed-direct-agent-permissions": .init(sourceCommit: "91d689ec1b16624939f6961e08217e82e503a97c", sourceKind: "reachable-commit", ledgerDigest: "repoprompt-service-schema-v6-typed-direct-agent-permissions", transformationID: "prototype-v6-program:typed-direct-agent-permissions", statementsDigest: "sha256:60e99ec5a6ac204a0d706937f7d46ce43f726dc1661e35820c60d32ab56c3397", programDigest: "sha256:2a922b88c0d38be5bd7524b3452f33a8b890ee223a2f8580408a376c5a9e2059"),
        "typed-workspace-approvals": .init(sourceCommit: "561a4a3831f248e280be42c7c73f597a8199a74f", sourceKind: "reachable-declared-stage", ledgerDigest: "repoprompt-service-schema-v6-typed-workspace-approvals", transformationID: "prototype-v6-program:typed-workspace-approvals", statementsDigest: "sha256:96913afd25bc38f41710898cbd2a5e73adce1322ca8b6f87d844d6994b96ef23", programDigest: "sha256:1ba587afef2cc5eee11e97848de3236a1aa66437ccf98e9d4f13ac15b9e73dc0"),
        "typed-mcp-disabled-tools": .init(sourceCommit: "561a4a3831f248e280be42c7c73f597a8199a74f", sourceKind: "reachable-declared-stage", ledgerDigest: "repoprompt-service-schema-v6-typed-mcp-disabled-tools", transformationID: "prototype-v6-program:typed-mcp-disabled-tools", statementsDigest: "sha256:adb4045090bbafc2327b43f4e00fd29999d22be8096dbef6022768a12ff9559d", programDigest: "sha256:627471feff28cd8657638e65d72eb22883f586f5a63f028461462b2df9a841ee"),
        "typed-mcp-show-model-presets": .init(sourceCommit: "561a4a3831f248e280be42c7c73f597a8199a74f", sourceKind: "reachable-declared-stage", ledgerDigest: "repoprompt-service-schema-v6-typed-mcp-show-model-presets", transformationID: "prototype-v6-program:typed-mcp-show-model-presets", statementsDigest: "sha256:fd3c6a05e5db72f48c3d6656a20705c713ec2d162b76395ae75e4cd851417522", programDigest: "sha256:20c0cd1846c2b1cbccd0318c8dec17e9d5799d8b27c8f445edd95c60754d20a1"),
    ]

    private static func baseProgramMaterial(
        _ versions: [StoreMigrationTestSupport.FrozenSchemaVersionProgram]
    ) -> [String] {
        var material: [String] = []
        for version in versions {
            material.append("version:\(version.version)")
            material.append("ledger:\(version.ledgerDigest)")
            material.append("transformation:\(version.transformationID)")
            material.append(contentsOf: version.statements.map { "statement:\($0)" })
            material.append(contentsOf: (version.operatorStatements ?? []).map { "operator:\($0)" })
            material.append(contentsOf: (version.legacyColumns ?? []).map {
                "legacy:\($0.table):\($0.column):\($0.definition)"
            })
            material.append(contentsOf: (version.dataStatements ?? []).map { "data:\($0)" })
        }
        return material
    }

    private static func digest(_ parts: [String]) -> String {
        let material = parts.joined(separator: "\0")
        return "sha256:" + SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func testV7OwnsOnlyTwoNewTables() {
        XCTAssertEqual(
            Set(SchemaV7.normalizationPlans.keys),
            SchemaV7.knownPrototypeV6Digests.union([SchemaV6.legacyCanonicalDigest, SchemaV6.canonicalDigest])
        )
        XCTAssertEqual(SchemaV7.knownPrototypeV6Digests.count, 7)
        XCTAssertEqual(SchemaV7.statements.count, 2)
        XCTAssertTrue(SchemaV7.statements[0].contains("schema_compatibility_audit"))
        XCTAssertTrue(SchemaV7.statements[1].contains("authority_namespace_identity"))
        XCTAssertFalse(SchemaV7.statements.joined().contains("outbox"))
        XCTAssertFalse(SchemaV7.statements.joined().contains("rate_limit"))
        XCTAssertFalse(SchemaV7.statements.joined().contains("backup_receipt"))
    }
}
