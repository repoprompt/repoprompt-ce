import Foundation
@testable import RepoPrompt
import XCTest

final class GitBlobIdentityServiceTests: XCTestCase {
    func testCleanSHA1SubdirectoryAndLinkedWorktreeAreOIDEligible() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository = try fixture.makeRepository(named: "repo")
        let linked = try fixture.makeLinkedWorktree(from: repository, named: "linked", branch: "linked-phase4")
        let expectedOID = try fixture.headBlobOID(for: "Sources/Feature.swift", at: repository)

        let service = GitBlobIdentityService()
        let primary = await service.classify(
            workspaceRoot: repository.appendingPathComponent("Sources"),
            relativePaths: ["Feature.swift"]
        )
        let secondary = await service.classify(
            workspaceRoot: linked.appendingPathComponent("Sources"),
            relativePaths: ["Feature.swift"]
        )

        XCTAssertEqual(primary.objectFormat, .sha1)
        XCTAssertEqual(primary.classifications.first?.repositoryRelativePath, "Sources/Feature.swift")
        XCTAssertEqual(primary.classifications.first?.indexEntries.first?.mode, "100644")
        XCTAssertEqual(primary.classifications.first?.indexEntries.first?.stage, 0)
        XCTAssertNotNil(primary.classifications.first?.validationTokens.preRepository)
        XCTAssertEqual(
            primary.classifications.first?.validationTokens.preRepository,
            primary.classifications.first?.validationTokens.postRepository
        )
        XCTAssertEqual(
            primary.classifications.first?.validationTokens.preWorktree,
            primary.classifications.first?.validationTokens.postWorktree
        )
        XCTAssertEqual(eligibleOID(primary), expectedOID)
        XCTAssertEqual(eligibleOID(secondary), expectedOID)

        let bytes = try Data(contentsOf: repository.appendingPathComponent("Sources/Feature.swift"))
        let validation = try await service.shadowValidate(
            classification: XCTUnwrap(primary.classifications.first),
            validatedWorktreeBytes: bytes
        )
        XCTAssertEqual(validation, .match)
        let mismatch = try await service.shadowValidate(
            classification: XCTUnwrap(primary.classifications.first),
            validatedWorktreeBytes: Data("different bytes\n".utf8)
        )
        XCTAssertEqual(mismatch, .mismatch)
        let diagnostics = await service.shadowDiagnostics()
        XCTAssertEqual(
            diagnostics,
            GitBlobShadowDiagnostics(
                eligibleOpportunityCount: 2,
                digestMatchCount: 1,
                digestMismatchCount: 1
            )
        )
    }

    func testLinkedWorktreeRetargetRefreshesLayoutCacheForIndexReads() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository = try fixture.makeRepository(named: "repo")
        let first = try fixture.makeLinkedWorktree(from: repository, named: "first", branch: "cache-first")
        let second = try fixture.makeLinkedWorktree(from: repository, named: "second", branch: "cache-second")
        let path = "Sources/Feature.swift"
        let service = GitBlobIdentityService()

        let initial = await service.classify(workspaceRoot: first, relativePaths: [path])
        XCTAssertEqual(eligibleOID(initial), try fixture.headBlobOID(for: path, at: repository))

        let retargetedContents = "let value = 2\n"
        try fixture.write(retargetedContents, to: path, at: second)
        try fixture.stage(path, at: second)
        let expectedOID = try fixture.runGit(["rev-parse", "--verify", ":\(path)"], at: second)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        try fixture.write(retargetedContents, to: path, at: first)
        let secondGitFile = try String(contentsOf: second.appendingPathComponent(".git"), encoding: .utf8)
        try secondGitFile.write(
            to: first.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        let retargeted = await service.classify(workspaceRoot: first, relativePaths: [path])

        XCTAssertNotEqual(expectedOID, try fixture.headBlobOID(for: path, at: repository))
        XCTAssertEqual(eligibleOID(retargeted), expectedOID)
    }

    func testNestedRepositoryMarkersBlockOuterBlobIdentityWhileNestedRootRemainsEligible() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let contents = "struct BoundaryOwned {}\n"
        let repository = try fixture.makeRepository(
            named: "outer",
            files: [
                "Nested/Sources/Feature.swift": contents,
                "GitFileBoundary/Sources/Feature.swift": contents
            ]
        )
        let nested = repository.appendingPathComponent("Nested", isDirectory: true)
        _ = try fixture.runGit(["init"], at: nested)
        _ = try fixture.runGit(["config", "user.name", "RepoPrompt Test"], at: nested)
        _ = try fixture.runGit(["config", "user.email", "repoprompt@example.test"], at: nested)
        _ = try fixture.runGit(["config", "commit.gpgSign", "false"], at: nested)
        _ = try fixture.runGit(["checkout", "-b", "nested-main"], at: nested)
        _ = try fixture.runGit(["add", "."], at: nested)
        _ = try fixture.runGit(["commit", "-m", "Nested repository"], at: nested)
        try "gitdir: /untrusted/external/repository\n".write(
            to: repository.appendingPathComponent("GitFileBoundary/.git"),
            atomically: true,
            encoding: .utf8
        )

        let service = GitBlobIdentityService()
        let outer = await service.classify(
            workspaceRoot: repository,
            relativePaths: [
                "Nested/Sources/Feature.swift",
                "GitFileBoundary/Sources/Feature.swift"
            ]
        )
        XCTAssertNil(outer.failure)
        XCTAssertEqual(
            outer.classifications.map(\.outcome),
            [.unavailable(.repositoryUnavailable), .unavailable(.repositoryUnavailable)]
        )
        XCTAssertTrue(outer.classifications.allSatisfy { classification in
            classification.indexEntries.contains { entry in
                entry.stage == 0 && entry.oid == (try? fixture.headBlobOID(
                    for: classification.repositoryRelativePath ?? "",
                    at: repository
                ))
            }
        })

        let nestedBatch = await service.classify(
            workspaceRoot: nested,
            relativePaths: ["Sources/Feature.swift"]
        )
        XCTAssertEqual(
            eligibleOID(nestedBatch),
            try fixture.headBlobOID(for: "Sources/Feature.swift", at: nested)
        )
    }

    func testConeSparseCheckoutClassifiesPresentBlobAndReportsSparseAbsent() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository = try fixture.makeRepository(
            named: "repository",
            files: [
                "Sources/Included.swift": "struct Included {}\n",
                "Excluded/Absent.swift": "struct Absent {}\n"
            ]
        )
        _ = try fixture.runGit(["sparse-checkout", "init", "--cone"], at: repository)
        _ = try fixture.runGit(["sparse-checkout", "set", "Sources"], at: repository)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repository.appendingPathComponent("Excluded/Absent.swift").path
            )
        )

        let batch = await GitBlobIdentityService().classify(
            workspaceRoot: repository,
            relativePaths: ["Sources/Included.swift", "Excluded/Absent.swift"]
        )
        XCTAssertNil(batch.failure)
        XCTAssertEqual(batch.classifications.count, 2)
        XCTAssertEqual(
            batch.classifications[0].outcome,
            try .oidEligible(GitBlobOID(
                objectFormat: .sha1,
                lowercaseHex: fixture.headBlobOID(for: "Sources/Included.swift", at: repository)
            ))
        )
        XCTAssertTrue(batch.classifications[1].skipWorktree)
        XCTAssertEqual(batch.classifications[1].outcome, .unavailable(.sparseAbsent))
    }

    func testSHA256RepositoryUsesExplicitObjectFormatAndOIDLength() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository: URL
        do {
            repository = try fixture.makeRepository(named: "sha256", objectFormat: .sha256)
        } catch {
            throw XCTSkip("Installed Git does not support SHA-256 repositories: \(error)")
        }

        let batch = await GitBlobIdentityService().classify(
            workspaceRoot: repository,
            relativePaths: ["Sources/Feature.swift"]
        )
        XCTAssertEqual(batch.objectFormat, .sha256)
        XCTAssertEqual(eligibleOID(batch)?.count, 64)
        let classification = try XCTUnwrap(batch.classifications.first)
        let bytes = try Data(contentsOf: repository.appendingPathComponent("Sources/Feature.swift"))
        let service = GitBlobIdentityService()
        let serviceBatch = await service.classify(
            workspaceRoot: repository,
            relativePaths: ["Sources/Feature.swift"]
        )
        let match = try await service.shadowValidate(
            classification: XCTUnwrap(serviceBatch.classifications.first),
            validatedWorktreeBytes: bytes
        )
        let mismatch = await service.shadowValidate(
            classification: classification,
            validatedWorktreeBytes: Data("mismatch".utf8)
        )
        XCTAssertEqual(match, .match)
        XCTAssertEqual(mismatch, .mismatch)
    }

    func testStagedDirtyUntrackedIgnoredAndIntentToAddClassifications() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository = try fixture.makeRepository(
            named: "repo",
            files: [
                ".gitignore": "Generated.swift\n",
                "Tracked.swift": "let value = 1\n"
            ]
        )
        let service = GitBlobIdentityService()

        try fixture.write("let value = 2\n", to: "Tracked.swift", at: repository)
        try fixture.stage("Tracked.swift", at: repository)
        var classification = await classify(service, root: repository, path: "Tracked.swift")
        guard case .oidEligible = classification.outcome else {
            return XCTFail("A staged-only regular file should use its stage-0 OID: \(classification.outcome)")
        }
        XCTAssertTrue(classification.porcelainRecord?.hasIndexChange == true)
        XCTAssertFalse(classification.porcelainRecord?.hasWorkTreeChange == true)

        try fixture.write("let value = 3\n", to: "Tracked.swift", at: repository)
        classification = await classify(service, root: repository, path: "Tracked.swift")
        XCTAssertEqual(classification.outcome, .requiresValidatedWorktreeBytes(.stagedAndUnstaged))

        try fixture.write("let other = 1\n", to: "Untracked.swift", at: repository)
        classification = await classify(service, root: repository, path: "Untracked.swift")
        XCTAssertEqual(classification.outcome, .requiresValidatedWorktreeBytes(.untracked))

        try fixture.write("let generated = 1\n", to: "Generated.swift", at: repository)
        classification = await classify(service, root: repository, path: "Generated.swift")
        XCTAssertEqual(classification.outcome, .requiresValidatedWorktreeBytes(.ignored))

        try fixture.write("let planned = 1\n", to: "Intent.swift", at: repository)
        _ = try fixture.runGit(["add", "-N", "--", "Intent.swift"], at: repository)
        classification = await classify(service, root: repository, path: "Intent.swift")
        XCTAssertTrue(classification.intentToAdd)
        XCTAssertEqual(classification.outcome, .requiresValidatedWorktreeBytes(.intentToAdd))
    }

    func testConflictStagesNeverChooseAnImplicitBlob() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository = try fixture.makeRepository(
            named: "repo",
            files: ["Conflict.swift": "let side = 0\n"]
        )
        _ = try fixture.runGit(["checkout", "-b", "other"], at: repository)
        try fixture.write("let side = 1\n", to: "Conflict.swift", at: repository)
        try fixture.stage("Conflict.swift", at: repository)
        try fixture.commit("Other", at: repository)
        _ = try fixture.runGit(["checkout", "main"], at: repository)
        try fixture.write("let side = 2\n", to: "Conflict.swift", at: repository)
        try fixture.stage("Conflict.swift", at: repository)
        try fixture.commit("Main", at: repository)
        let merge = try fixture.runGitResult(["merge", "other"], at: repository)
        XCTAssertNotEqual(merge.terminationStatus, 0)

        let classification = await classify(
            GitBlobIdentityService(),
            root: repository,
            path: "Conflict.swift"
        )
        XCTAssertTrue(classification.hasConflictStages)
        XCTAssertEqual(classification.indexEntries.map(\.stage), [1, 2, 3])
        XCTAssertEqual(classification.outcome, .requiresValidatedWorktreeBytes(.unmerged))
        guard case .unmerged? = classification.porcelainRecord?.kind else {
            return XCTFail("Expected porcelain-v2 unmerged identity fields")
        }
        XCTAssertNotNil(classification.porcelainRecord?.conflictStage1OID)
        XCTAssertNotNil(classification.porcelainRecord?.conflictStage2OID)
        XCTAssertNotNil(classification.porcelainRecord?.conflictStage3OID)
    }

    func testSkipWorktreeAssumeUnchangedAndSparseAbsentFailClosed() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository = try fixture.makeRepository(named: "repo")
        let path = "Sources/Feature.swift"
        let service = GitBlobIdentityService()

        _ = try fixture.runGit(["update-index", "--assume-unchanged", "--", path], at: repository)
        var classification = await classify(service, root: repository, path: path)
        XCTAssertTrue(classification.assumeUnchanged)
        XCTAssertEqual(classification.outcome, .requiresValidatedWorktreeBytes(.indexFlag))
        _ = try fixture.runGit(["update-index", "--no-assume-unchanged", "--", path], at: repository)

        _ = try fixture.runGit(["update-index", "--skip-worktree", "--", path], at: repository)
        classification = await classify(service, root: repository, path: path)
        XCTAssertTrue(classification.skipWorktree)
        XCTAssertEqual(classification.outcome, .requiresValidatedWorktreeBytes(.indexFlag))

        try FileManager.default.removeItem(at: repository.appendingPathComponent(path))
        classification = await classify(service, root: repository, path: path)
        XCTAssertEqual(classification.outcome, .unavailable(.sparseAbsent))
    }

    func testCheckoutAttributesConfigFiltersLFSIdentAndEncodingRequireRawBytes() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository = try fixture.makeRepository(
            named: "repo",
            files: [
                ".gitattributes": [
                    "Text.swift text eol=lf",
                    "LFS.swift filter=lfs",
                    "Encoded.swift working-tree-encoding=UTF-8 ident",
                    "Unknown.swift filter=mystery"
                ].joined(separator: "\n") + "\n",
                "Text.swift": "let text = 1\n",
                "LFS.swift": "let lfs = 1\n",
                "Encoded.swift": "let encoded = 1\n",
                "Unknown.swift": "let unknown = 1\n"
            ]
        )
        _ = try fixture.runGit(["config", "filter.lfs.clean", "cat"], at: repository)
        _ = try fixture.runGit(["config", "filter.lfs.smudge", "cat"], at: repository)
        let service = GitBlobIdentityService()

        let text = await classify(service, root: repository, path: "Text.swift")
        XCTAssertEqual(text.outcome, .requiresValidatedWorktreeBytes(.checkoutTransformation))
        XCTAssertTransformReasons(text, contain: [.textAttribute, .eolAttribute])

        let lfs = await classify(service, root: repository, path: "LFS.swift")
        XCTAssertTransformReasons(lfs, contain: [.filterAttribute, .lfsFilter])

        let encoded = await classify(service, root: repository, path: "Encoded.swift")
        XCTAssertTransformReasons(encoded, contain: [.identAttribute, .workingTreeEncoding])

        let unknown = await classify(service, root: repository, path: "Unknown.swift")
        XCTAssertTransformReasons(unknown, contain: [.filterAttribute, .unknownFilterDriver])

        _ = try fixture.runGit(["config", "core.autocrlf", "true"], at: repository)
        let configured = await classify(service, root: repository, path: "Text.swift")
        XCTAssertTransformReasons(configured, contain: [.coreAutoCRLF])
    }

    func testLiteralUnspecifiedFilterValueRemainsExplicitAndFailsClosed() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository = try fixture.makeRepository(
            named: "repo",
            files: [
                ".gitattributes": [
                    "Feature.swift filter=unspecified",
                    "LiteralUnset.swift filter=unset",
                    "Unset.swift -filter",
                    "Set.swift filter"
                ].joined(separator: "\n") + "\n",
                "Feature.swift": "let value = 1\n",
                "LiteralUnset.swift": "let value = 2\n",
                "Unset.swift": "let value = 3\n",
                "Set.swift": "let value = 4\n"
            ]
        )
        _ = try fixture.runGit(["config", "filter.unspecified.clean", "cat"], at: repository)
        let classification = await classify(
            GitBlobIdentityService(),
            root: repository,
            path: "Feature.swift"
        )

        XCTAssertEqual(classification.attributes?.filter, .set("unspecified"))
        XCTAssertTransformReasons(classification, contain: [.filterAttribute])
        let unset = await classify(GitBlobIdentityService(), root: repository, path: "Unset.swift")
        XCTAssertEqual(unset.attributes?.filter, .unset)
        XCTAssertEqual(unset.checkoutMaterialization, .bytePreserving)

        _ = try fixture.runGit(["config", "filter.unset.clean", "cat"], at: repository)
        let literalUnset = await classify(
            GitBlobIdentityService(),
            root: repository,
            path: "LiteralUnset.swift"
        )
        XCTAssertEqual(literalUnset.attributes?.filter, .unset)
        XCTAssertTransformReasons(literalUnset, contain: [.filterAttribute])

        let set = await classify(GitBlobIdentityService(), root: repository, path: "Set.swift")
        XCTAssertEqual(set.attributes?.filter, .set(""))
        XCTAssertTransformReasons(set, contain: [.filterAttribute])
    }

    func testStagedAddDeleteRenameAndCopyUseExplicitIndexState() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository = try fixture.makeRepository(
            named: "repo",
            files: ["Original.swift": "let value = 1\n", "Deleted.swift": "let deleted = 1\n"]
        )
        try fixture.write("let added = 1\n", to: "Added.swift", at: repository)
        try fixture.write("let value = 1\n", to: "Copied.swift", at: repository)
        _ = try fixture.runGit(["mv", "Original.swift", "Renamed.swift"], at: repository)
        _ = try fixture.runGit(["rm", "Deleted.swift"], at: repository)
        _ = try fixture.runGit(["add", "Added.swift", "Copied.swift"], at: repository)
        _ = try fixture.runGit(["config", "status.renames", "copies"], at: repository)

        let batch = await GitBlobIdentityService().classify(
            workspaceRoot: repository,
            relativePaths: ["Added.swift", "Deleted.swift", "Renamed.swift", "Copied.swift"]
        )
        XCTAssertNil(batch.failure)
        let byPath = Dictionary(uniqueKeysWithValues: batch.classifications.map { ($0.relativePath, $0) })
        guard case .oidEligible = byPath["Added.swift"]?.outcome else {
            return XCTFail("staged add should use its explicit stage-zero OID")
        }
        XCTAssertEqual(byPath["Deleted.swift"]?.outcome, .unavailable(.missing))
        guard case .oidEligible = byPath["Renamed.swift"]?.outcome else {
            return XCTFail("staged rename destination should use its explicit stage-zero OID")
        }
        guard case .oidEligible = byPath["Copied.swift"]?.outcome else {
            return XCTFail("staged copy should use its explicit stage-zero OID")
        }
    }

    func testGitlinkAndSymlinkPoliciesExcludeNonSourceContent() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let child = try fixture.makeRepository(named: "child", files: ["Child.swift": "let child = 1\n"])
        let parent = try fixture.makeRepository(named: "parent", files: ["Real/File.swift": "let real = 1\n"])
        _ = try fixture.runGit(
            ["-c", "protocol.file.allow=always", "submodule", "add", child.path, "Vendor/Sub"],
            at: parent
        )
        try fixture.commit("Add submodule", at: parent)

        let service = GitBlobIdentityService()
        let gitlink = await classify(service, root: parent, path: "Vendor/Sub")
        XCTAssertEqual(gitlink.indexEntries.first?.mode, "160000")
        XCTAssertEqual(gitlink.outcome, .unsupported(.gitlink))

        let leaf = parent.appendingPathComponent("Leaf.swift")
        try FileManager.default.createSymbolicLink(atPath: leaf.path, withDestinationPath: "Real/File.swift")
        _ = try fixture.runGit(["add", "--", "Leaf.swift"], at: parent)
        let symlink = await classify(service, root: parent, path: "Leaf.swift")
        XCTAssertEqual(symlink.outcome, .securityExcluded(.symlinkLeaf))

        let alias = parent.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "Real")
        let component = await classify(service, root: parent, path: "Alias/File.swift")
        XCTAssertEqual(component.outcome, .securityExcluded(.symlinkPathComponent))
    }

    func testParentSymlinkSwapDuringDescriptorTraversalFailsClosedWithoutEscapingRoot() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository = try fixture.makeRepository(
            named: "repo",
            files: ["Sources/Parent/Race.swift": "let inside = true\n"]
        )
        let outside = fixture.sandbox.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "let outside = true\n".write(
            to: outside.appendingPathComponent("Race.swift"),
            atomically: true,
            encoding: .utf8
        )
        let swap = GitBlobParentSymlinkSwap(
            root: repository,
            relativeDirectory: "Sources/Parent",
            outsideDirectory: outside
        )
        let service = GitBlobIdentityService(hooks: GitBlobIdentityServiceHooks(
            afterGitCollection: {},
            afterPathSecurityComponentOpen: { swap.swapIfNeeded(openedPath: $0) }
        ))

        let batch = await service.classify(
            workspaceRoot: repository,
            relativePaths: ["Sources/Parent/Race.swift"]
        )
        XCTAssertTrue(batch.retriedAfterInstability)
        XCTAssertEqual(
            batch.classifications.first?.outcome,
            .securityExcluded(.symlinkPathComponent)
        )
    }

    func testIndexAndWorktreeRacesRetryThenSuppressEligibility() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository = try fixture.makeRepository(named: "repo")
        let path = "Sources/Feature.swift"

        let indexMutator = GitBlobIdentityRaceMutator(root: repository, path: path, stage: true)
        let indexService = GitBlobIdentityService(
            hooks: GitBlobIdentityServiceHooks(afterGitCollection: { await indexMutator.mutate() })
        )
        var batch = await indexService.classify(workspaceRoot: repository, relativePaths: [path])
        XCTAssertTrue(batch.retriedAfterInstability)
        XCTAssertEqual(
            batch.classifications.first?.outcome,
            .requiresValidatedWorktreeBytes(.changedDuringClassification)
        )

        let worktreeMutator = GitBlobIdentityRaceMutator(root: repository, path: path, stage: false)
        let worktreeService = GitBlobIdentityService(
            hooks: GitBlobIdentityServiceHooks(afterGitCollection: { await worktreeMutator.mutate() })
        )
        batch = await worktreeService.classify(workspaceRoot: repository, relativePaths: [path])
        XCTAssertTrue(batch.retriedAfterInstability)
        XCTAssertEqual(
            batch.classifications.first?.outcome,
            .requiresValidatedWorktreeBytes(.changedDuringClassification)
        )
    }

    func testAttributeAndConfigRacesRetryThenSuppressEligibility() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository = try fixture.makeRepository(named: "repo")
        let mutator = GitBlobConfigurationRaceMutator(root: repository)
        let service = GitBlobIdentityService(
            hooks: GitBlobIdentityServiceHooks(afterGitCollection: { await mutator.mutate() })
        )

        let batch = await service.classify(
            workspaceRoot: repository,
            relativePaths: ["Sources/Feature.swift"]
        )
        XCTAssertTrue(batch.retriedAfterInstability)
        XCTAssertEqual(
            batch.classifications.first?.outcome,
            .requiresValidatedWorktreeBytes(.changedDuringClassification)
        )
    }

    func testLinkedWorktreeGitFileRetargetingIsFencedAcrossAttemptsAndHooks() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository = try fixture.makeRepository(named: "repo")
        let first = try fixture.makeLinkedWorktree(from: repository, named: "first", branch: "first-retarget")
        let second = try fixture.makeLinkedWorktree(from: repository, named: "second", branch: "second-retarget")
        let retargeter = try GitBlobLayoutRetargeter(first: first, second: second, alternateEveryCall: true)
        let service = GitBlobIdentityService(
            hooks: GitBlobIdentityServiceHooks(afterGitCollection: { await retargeter.retarget() })
        )

        let batch = await service.classify(
            workspaceRoot: first,
            relativePaths: ["Sources/Feature.swift"]
        )
        XCTAssertTrue(batch.retriedAfterInstability)
        XCTAssertNotEqual(
            batch.classifications.first?.validationTokens.preRepository?.layoutSHA256,
            batch.classifications.first?.validationTokens.postRepository?.layoutSHA256
        )
        XCTAssertEqual(
            batch.classifications.first?.outcome,
            .requiresValidatedWorktreeBytes(.changedDuringClassification)
        )

        let oneShot = try GitBlobLayoutRetargeter(first: first, second: second, alternateEveryCall: false)
        let retryService = GitBlobIdentityService(
            hooks: GitBlobIdentityServiceHooks(afterGitCollection: { await oneShot.retarget() })
        )
        let recovered = await retryService.classify(
            workspaceRoot: first,
            relativePaths: ["Sources/Feature.swift"]
        )
        XCTAssertTrue(recovered.retriedAfterInstability)
        guard case .oidEligible = recovered.classifications.first?.outcome else {
            return XCTFail("a stable re-resolved second attempt should recover eligibility")
        }
    }

    func testLinkedWorktreeCommonDirRetargetingIsFencedAcrossAttempts() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository = try fixture.makeRepository(named: "repo")
        let otherRepository = try fixture.makeRepository(named: "other")
        let linked = try fixture.makeLinkedWorktree(
            from: repository,
            named: "linked",
            branch: "commondir-retarget"
        )
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: linked))
        let retargeter = try GitBlobCommonDirRetargeter(
            commondirFile: layout.gitDir.appendingPathComponent("commondir"),
            alternateCommonDirectory: otherRepository.appendingPathComponent(".git")
        )
        let service = GitBlobIdentityService(
            hooks: GitBlobIdentityServiceHooks(afterGitCollection: { await retargeter.retarget() })
        )

        let batch = await service.classify(
            workspaceRoot: linked,
            relativePaths: ["Sources/Feature.swift"]
        )
        XCTAssertTrue(batch.retriedAfterInstability)
        if case .oidEligible? = batch.classifications.first?.outcome {
            XCTFail("a repeatedly retargeted commondir must not remain OID eligible")
        }
    }

    func testOversizedPathAndByteBatchesReturnOneBoundedFailure() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try fixture.makeRepository(named: "repo")
        let service = GitBlobIdentityService()

        let tooMany = await service.classify(
            workspaceRoot: root,
            relativePaths: (0 ... 256).map { "\($0).swift" }
        )
        XCTAssertEqual(tooMany.failure, .batchTooLarge)
        XCTAssertTrue(tooMany.classifications.isEmpty)

        let tooManyBytes = await service.classify(
            workspaceRoot: root,
            relativePaths: [String(repeating: "a", count: 256 * 1024 + 1)]
        )
        XCTAssertEqual(tooManyBytes.failure, .batchTooLarge)
        XCTAssertTrue(tooManyBytes.classifications.isEmpty)
    }

    func testGitBlobAttributesRejectsOversizedAdversarialRecordOutput() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = fixture.sandbox.appendingPathComponent("fake-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = fixture.sandbox.appendingPathComponent("fake-git")
        let script = """
        #!/bin/sh
        index=0
        while [ "$index" -lt 6 ]; do
          printf 'File.swift\\000text\\000set\\000'
          index=$((index + 1))
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let gitService = GitService(gitExecutableURL: executable)

        do {
            _ = try await gitService.gitBlobAttributes(
                at: root,
                repositoryRelativePaths: ["File.swift"]
            )
            XCTFail("expected bounded check-attr record rejection")
        } catch let error as GitBlobIdentityError {
            guard case .malformedGitOutput = error else {
                return XCTFail("unexpected Git blob identity error: \(error)")
            }
        }

        let completionMarker = fixture.sandbox.appendingPathComponent("unbounded-output-completed")
        let outputChunk = String(repeating: "x", count: 1024)
        let oversizedScript = """
        #!/bin/sh
        index=0
        while [ "$index" -lt 16384 ]; do
          printf '\(outputChunk)'
          index=$((index + 1))
        done
        printf completed > "\(completionMarker.path)"
        """
        try oversizedScript.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        do {
            _ = try await gitService.gitBlobAttributes(
                at: root,
                repositoryRelativePaths: ["File.swift"]
            )
            XCTFail("expected bounded check-attr byte rejection")
        } catch let error as GitBlobIdentityError {
            XCTAssertEqual(
                error,
                .malformedGitOutput("check-attr output exceeds byte limit")
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: completionMarker.path),
            "the subprocess must terminate at the capture limit instead of producing its entire response"
        )
    }

    func testCancellationFailsClosedWithoutRetryingFeatureCollection() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try fixture.makeRepository(named: "repo")
        let hookCounter = GitBlobHookCounter(cancelFirstCall: true)
        let service = GitBlobIdentityService(
            hooks: GitBlobIdentityServiceHooks(afterGitCollection: { await hookCounter.call() })
        )
        let task = Task { await service.classify(workspaceRoot: root, relativePaths: ["Sources/Feature.swift"]) }
        let batch = await task.value

        if case .oidEligible? = batch.classifications.first?.outcome {
            XCTFail("cancelled feature collection must not return eligibility")
        }
        let count = await hookCounter.count
        XCTAssertLessThanOrEqual(count, 2)
    }

    func testLiteralNewlineAndPathspecMagicCannotInjectAdditionalPaths() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let repository = try fixture.makeRepository(
            named: "repo",
            files: ["Seed.swift": "let seed = 1\n"]
        )
        let injected = ":(glob)*\nInjected.swift"
        try fixture.write("let exact = 1\n", to: injected, at: repository)
        try fixture.write("let decoy = 1\n", to: "Decoy.swift", at: repository)
        _ = try fixture.runGit(["--literal-pathspecs", "add", "--", injected], at: repository)
        try fixture.commit("Literal path", at: repository)

        let batch = await GitBlobIdentityService().classify(
            workspaceRoot: repository,
            relativePaths: [injected]
        )
        XCTAssertEqual(batch.classifications.count, 1)
        XCTAssertEqual(batch.classifications.first?.repositoryRelativePath, injected)
        XCTAssertNotNil(eligibleOID(batch))
        XCTAssertFalse(batch.classifications.first?.indexEntries.contains { $0.path == "Decoy.swift" } == true)
    }

    func testUnsupportedGitObjectFormatFailsClosed() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = fixture.sandbox.appendingPathComponent("unsupported")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let executable = fixture.sandbox.appendingPathComponent("fake-git")
        let script = """
        #!/bin/sh
        if [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ]; then pwd; exit 0; fi
        if [ "$1" = "rev-parse" ] && [ "$2" = "--show-object-format" ]; then exit 129; fi
        exit 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try fixture.write("let value = 1\n", to: "File.swift", at: root)

        let service = GitBlobIdentityService(gitService: GitService(gitExecutableURL: executable))
        var batch = await service.classify(workspaceRoot: root, relativePaths: ["File.swift"])
        XCTAssertEqual(batch.classifications.first?.outcome, .unsupported(.unsupportedGit))

        let invalidFormatExecutable = fixture.sandbox.appendingPathComponent("invalid-format-git")
        let invalidFormatScript = """
        #!/bin/sh
        if [ "$1" = "rev-parse" ] && [ "$2" = "--show-toplevel" ]; then pwd; exit 0; fi
        if [ "$1" = "rev-parse" ] && [ "$2" = "--show-object-format" ]; then printf 'sha512\\n'; exit 0; fi
        exit 1
        """
        try invalidFormatScript.write(to: invalidFormatExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: invalidFormatExecutable.path
        )
        let invalidFormatService = GitBlobIdentityService(
            gitService: GitService(gitExecutableURL: invalidFormatExecutable)
        )
        batch = await invalidFormatService.classify(workspaceRoot: root, relativePaths: ["File.swift"])
        XCTAssertEqual(batch.classifications.first?.outcome, .unsupported(.invalidObjectFormat))
    }

    func testGitObjectFormatRejectsUppercaseWhitespaceAndNUL() {
        XCTAssertThrowsError(try GitObjectFormat(gitValue: "SHA1"))
        XCTAssertThrowsError(try GitObjectFormat(gitValue: " sha1"))
        XCTAssertThrowsError(try GitObjectFormat(gitValue: "sha1\n"))
        XCTAssertThrowsError(try GitObjectFormat(gitValue: "sha1\0"))
        XCTAssertEqual(try GitObjectFormat(gitValue: "sha1"), .sha1)
        XCTAssertEqual(try GitObjectFormat(gitValue: "sha256"), .sha256)
    }

    func testNonGitRegularMissingAndDirectoryOutcomesAreExplicit() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = fixture.sandbox.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try fixture.write("let plain = 1\n", to: "Plain.swift", at: root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Folder"),
            withIntermediateDirectories: false
        )

        let batch = await GitBlobIdentityService().classify(
            workspaceRoot: root,
            relativePaths: ["Plain.swift", "Missing.swift", "Folder"]
        )
        XCTAssertNil(batch.objectFormat)
        XCTAssertEqual(
            batch.classifications.map(\.outcome),
            [
                .requiresValidatedWorktreeBytes(.nonGit),
                .unavailable(.missing),
                .unsupported(.nonRegularFile)
            ]
        )
    }

    private func classify(
        _ service: GitBlobIdentityService,
        root: URL,
        path: String
    ) async -> GitBlobIdentityClassification {
        let batch = await service.classify(workspaceRoot: root, relativePaths: [path])
        return batch.classifications[0]
    }

    private func eligibleOID(_ batch: GitBlobIdentityBatch) -> String? {
        guard case let .oidEligible(oid)? = batch.classifications.first?.outcome else { return nil }
        return oid.lowercaseHex
    }

    private func XCTAssertTransformReasons(
        _ classification: GitBlobIdentityClassification,
        contain expected: Set<GitBlobCheckoutTransformReason>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .requiresValidatedWorktreeBytes(reasons)? = classification.checkoutMaterialization else {
            return XCTFail("Expected a checkout transformation fallback", file: file, line: line)
        }
        XCTAssertTrue(expected.isSubset(of: Set(reasons)), "Missing \(expected) in \(reasons)", file: file, line: line)
        XCTAssertEqual(
            classification.outcome,
            .requiresValidatedWorktreeBytes(.checkoutTransformation),
            file: file,
            line: line
        )
    }
}

private final class GitBlobParentSymlinkSwap: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let backup: URL
    private let outsideDirectory: URL
    private let relativeDirectory: String
    private var didSwap = false

    init(root: URL, relativeDirectory: String, outsideDirectory: URL) {
        directory = root.appendingPathComponent(relativeDirectory)
        backup = root.appendingPathComponent(relativeDirectory + "-original")
        self.outsideDirectory = outsideDirectory
        self.relativeDirectory = relativeDirectory
    }

    func swapIfNeeded(openedPath: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !didSwap, openedPath == relativeDirectory else { return }
        didSwap = true
        try? FileManager.default.moveItem(at: directory, to: backup)
        try? FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outsideDirectory)
    }
}

private actor GitBlobIdentityRaceMutator {
    let root: URL
    let path: String
    let stage: Bool
    var generation = 0

    init(root: URL, path: String, stage: Bool) {
        self.root = root
        self.path = path
        self.stage = stage
    }

    func mutate() {
        generation += 1
        let url = root.appendingPathComponent(path)
        try? Data("let generation = \(generation)\n".utf8).write(to: url, options: .atomic)
        guard stage else { return }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        _ = try? TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["add", "--", path],
            currentDirectoryURL: root,
            environment: environment
        )
    }
}

private actor GitBlobConfigurationRaceMutator {
    let root: URL
    var generation = 0

    init(root: URL) {
        self.root = root
    }

    func mutate() {
        generation += 1
        try? "Sources/Feature.swift filter=race\n".write(
            to: root.appendingPathComponent(".gitattributes"),
            atomically: true,
            encoding: .utf8
        )
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        _ = try? TestProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["config", "filter.race.clean", generation.isMultiple(of: 2) ? "cat" : "sed s/a/b/"],
            currentDirectoryURL: root,
            environment: environment
        )
    }
}

private actor GitBlobLayoutRetargeter {
    let dotGitURL: URL
    let firstContents: String
    let secondContents: String
    let alternateEveryCall: Bool
    var generation = 0

    init(first: URL, second: URL, alternateEveryCall: Bool) throws {
        dotGitURL = first.appendingPathComponent(".git")
        firstContents = try String(contentsOf: dotGitURL, encoding: .utf8)
        secondContents = try String(contentsOf: second.appendingPathComponent(".git"), encoding: .utf8)
        self.alternateEveryCall = alternateEveryCall
    }

    func retarget() {
        generation += 1
        guard alternateEveryCall || generation == 1 else { return }
        let contents = generation.isMultiple(of: 2) ? firstContents : secondContents
        try? contents.write(to: dotGitURL, atomically: true, encoding: .utf8)
    }
}

private actor GitBlobCommonDirRetargeter {
    let commondirFile: URL
    let originalContents: String
    let alternateContents: String
    var generation = 0

    init(commondirFile: URL, alternateCommonDirectory: URL) throws {
        self.commondirFile = commondirFile
        originalContents = try String(contentsOf: commondirFile, encoding: .utf8)
        alternateContents = alternateCommonDirectory.path + "\n"
    }

    func retarget() {
        generation += 1
        let contents = generation.isMultiple(of: 2) ? originalContents : alternateContents
        try? contents.write(to: commondirFile, atomically: true, encoding: .utf8)
    }
}

private actor GitBlobHookCounter {
    let cancelFirstCall: Bool
    private(set) var count = 0

    init(cancelFirstCall: Bool) {
        self.cancelFirstCall = cancelFirstCall
    }

    func call() {
        count += 1
        if cancelFirstCall, count == 1 {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
}
