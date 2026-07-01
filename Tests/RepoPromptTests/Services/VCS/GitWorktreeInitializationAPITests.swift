import Darwin
@testable import RepoPrompt
import XCTest

final class GitWorktreeInitializationAPITests: XCTestCase {
    func testBoundedAuthorityAPIsPreserveNULPathsAndExactRootPrefix() async throws {
        let fixture = try GitInitializationFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let prefix = try GitRepositoryRelativeRootPrefix("Root")
        let base = try await git.resolveTreeOID("HEAD", in: layout)

        let inventory = try await git.listTree(base, in: layout, prefix: prefix)
        XCTAssertEqual(inventory.prefixEntry?.repositoryRelativePath, "Root")
        XCTAssertEqual(inventory.entries.map(\.repositoryRelativePath), ["Root/old file.txt"])
        XCTAssertFalse(inventory.entries.contains { $0.repositoryRelativePath.hasPrefix("RootSibling/") })

        try fixture.rename("Root/old file.txt", to: "Root/new\nname.txt")
        try fixture.commitAll("rename")
        let target = try await git.resolveTreeOID("HEAD", in: layout)
        let delta = try await git.diffTrees(
            baseTreeOID: base,
            targetTreeOID: target,
            in: layout,
            prefix: prefix
        )
        XCTAssertEqual(delta.count, 1)
        XCTAssertEqual(delta[0].sourceRepositoryRelativePath, "Root/old file.txt")
        XCTAssertEqual(delta[0].repositoryRelativePath, "Root/new\nname.txt")
        guard case .renamed(score: 100) = delta[0].status else {
            return XCTFail("Expected an exact rename record")
        }

        let authority = try await git.authorityMetadata(in: layout, prefix: prefix)
        XCTAssertEqual(authority.objectFormat, .sha1)
        XCTAssertEqual(authority.treeOID, target)
        XCTAssertEqual(authority.repositoryRelativeRootPrefix, prefix)
        XCTAssertFalse(authority.indexGeneration.isEmpty)
        XCTAssertFalse(authority.ignoreAuthorityGeneration.isEmpty)
        XCTAssertFalse(authority.attributeAuthorityGeneration.isEmpty)
        XCTAssertFalse(authority.sparsePolicyGeneration.isEmpty)

        try fixture.write("Root/staged\tname.txt", "staged\n")
        try fixture.git(["add", "--", "Root/staged\tname.txt"])
        try fixture.write("Root/untracked*name.txt", "untracked\n")
        let manifest = try await git.indexManifest(in: layout, prefix: prefix)
        XCTAssertTrue(manifest.entries.contains { $0.repositoryRelativePath == "Root/staged\tname.txt" })
        XCTAssertTrue(manifest.entries.contains { $0.repositoryRelativePath == "Root/new\nname.txt" })

        let status = try await git.worktreeStatus(in: layout, prefix: prefix)
        XCTAssertTrue(status.pathRecords.contains { $0.path == "Root/staged\tname.txt" })
        XCTAssertTrue(status.pathRecords.contains { $0.path == "Root/untracked*name.txt" })
        XCTAssertFalse(status.pathRecords.contains { $0.path.hasPrefix("RootSibling/") })
    }

    func testTreeInventoryCapsTimeoutAndCancellationReturnTypedReasonsWithoutPermitLeaks() async throws {
        let fixture = try GitInitializationFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let tree = try await git.resolveTreeOID("HEAD", in: layout)
        let prefix = try GitRepositoryRelativeRootPrefix("Root")

        let recordLimited = GitWorktreeInitializationLimits(
            maximumRecordCount: 1,
            maximumOutputBytes: 1024 * 1024,
            commandTimeout: .seconds(5)
        )
        do {
            _ = try await git.listTree(tree, in: layout, prefix: prefix, limits: recordLimited)
            XCTFail("Expected the tree record cap to reject the inventory")
        } catch let error as GitWorktreeInitializationError {
            XCTAssertEqual(error.reason, .recordLimitExceeded)
        }

        let byteLimited = GitWorktreeInitializationLimits(
            maximumRecordCount: 100,
            maximumOutputBytes: 8,
            commandTimeout: .seconds(5)
        )
        do {
            _ = try await git.listTree(tree, in: layout, prefix: prefix, limits: byteLimited)
            XCTFail("Expected the tree byte cap to reject the inventory")
        } catch let error as GitWorktreeInitializationError {
            XCTAssertEqual(error.reason, .cappedOutput)
        }

        let sleepingExecutable = try fixture.makeSleepingGitExecutable()
        let admission = GitProcessAdmissionController(globalLimit: 1, perRepositoryLimit: 1)
        let slowGit = GitService(
            gitExecutableURL: sleepingExecutable,
            processAdmissionController: admission,
            processTerminationGrace: .milliseconds(10)
        )
        let timeoutLimits = GitWorktreeInitializationLimits(
            maximumRecordCount: 100,
            maximumOutputBytes: 1024,
            commandTimeout: .milliseconds(20)
        )
        do {
            _ = try await slowGit.listTree(tree, in: layout, prefix: prefix, limits: timeoutLimits)
            XCTFail("Expected the bounded command timeout")
        } catch let error as GitWorktreeInitializationError {
            XCTAssertEqual(error.reason, .timeout)
        }

        let cancellable = Task {
            try await slowGit.listTree(tree, in: layout, prefix: prefix)
        }
        for _ in 0 ..< 1000 {
            if await admission.snapshot().activeLeaseCount == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        cancellable.cancel()
        do {
            _ = try await cancellable.value
            XCTFail("Expected in-flight Git authority cancellation")
        } catch is CancellationError {
            // Expected.
        }
        let finalAdmission = await admission.snapshot()
        XCTAssertEqual(finalAdmission.activeLeaseCount, 0)
    }

    func testIndexManifestReportsAssumeUnchangedAndRepositoryWideSparseEnablement() async throws {
        let fixture = try GitInitializationFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let prefix = try GitRepositoryRelativeRootPrefix("Root")

        try fixture.git(["update-index", "--assume-unchanged", "--", "Root/old file.txt"])
        var manifest = try await git.indexManifest(in: layout, prefix: prefix)
        XCTAssertTrue(manifest.entries.contains {
            $0.repositoryRelativePath == "Root/old file.txt" && $0.assumeUnchanged
        })
        XCTAssertFalse(manifest.sparseCheckoutEnabled)

        try fixture.git(["update-index", "--no-assume-unchanged", "--", "Root/old file.txt"])
        try fixture.git(["sparse-checkout", "init", "--cone"])
        try fixture.git(["sparse-checkout", "set", "Root"])
        manifest = try await git.indexManifest(in: layout, prefix: prefix)
        XCTAssertTrue(manifest.sparseCheckoutEnabled)
        XCTAssertTrue(manifest.entries.contains { $0.repositoryRelativePath == "Root/old file.txt" })
        XCTAssertFalse(manifest.entries.contains { $0.skipWorktree })
    }

    func testUntrackedNestedRepositoryDirectoryRemainsExplicitInStatusEvidence() async throws {
        let fixture = try GitInitializationFixture()
        defer { fixture.cleanup() }
        let nested = fixture.root.appendingPathComponent("Root/Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedProcess = Process()
        nestedProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        nestedProcess.arguments = ["init", "--quiet", nested.path]
        try nestedProcess.run()
        nestedProcess.waitUntilExit()
        XCTAssertEqual(nestedProcess.terminationStatus, 0)

        let git = GitService()
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let prefix = try GitRepositoryRelativeRootPrefix("Root")
        let status = try await git.worktreeStatus(
            in: layout,
            prefix: prefix
        )
        XCTAssertTrue(status.pathRecords.contains { record in
            record.kind == .untracked && StandardizedPath.relative(record.path) == "Root/Nested"
        })
    }

    func testAuthorityPolicyIdentityUsesResolvedExternalContentsAndHierarchicalPrefixControls() async throws {
        let fixture = try GitInitializationFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let prefix = try GitRepositoryRelativeRootPrefix("Root/Nested")
        let excludes = fixture.sandbox.appendingPathComponent("global excludes one")
        let equivalentExcludes = fixture.sandbox.appendingPathComponent("global excludes two")
        let attributes = fixture.sandbox.appendingPathComponent("global attributes")
        try "*.temporary\n".write(to: excludes, atomically: true, encoding: .utf8)
        try "*.temporary\n".write(to: equivalentExcludes, atomically: true, encoding: .utf8)
        try "*.binary binary\n".write(to: attributes, atomically: true, encoding: .utf8)
        try fixture.git(["config", "core.excludesFile", excludes.path])
        try fixture.git(["config", "core.attributesFile", attributes.path])

        try fixture.write(".gitignore", "root-control\n")
        try fixture.write("Root/.repo_ignore", "ancestor-control\n")
        try fixture.write("Root/Nested/.cursorignore", "prefix-control\n")
        try fixture.write("Root/Nested/Deep/.gitattributes", "*.json text\n")
        try fixture.write("Root/Outside/.gitignore", "outside-prefix\n")
        try fixture.write("RootSibling/.cursorignore", "sibling-prefix\n")

        let baseline = try await git.authorityMetadata(in: layout, prefix: prefix)
        let policy = baseline.policyIdentity
        XCTAssertEqual(
            policy.mandatoryIgnorePolicyIdentity,
            WorkspaceGitignorePolicyIdentity.current.rawValue
        )
        XCTAssertEqual(policy.resolvedExcludesFileIdentity?.exists, true)
        XCTAssertEqual(policy.resolvedExcludesFileIdentity?.byteCount, "*.temporary\n".utf8.count)
        XCTAssertEqual(policy.resolvedAttributesFileIdentity?.exists, true)
        XCTAssertEqual(Set(baseline.resolvedExternalAuthorityPaths), Set([excludes, attributes]))
        XCTAssertFalse(policy.committedIgnoreControlDigest.isEmpty)
        XCTAssertFalse(policy.attributePolicyDigest.isEmpty)

        try fixture.git(["config", "core.excludesFile", equivalentExcludes.path])
        let equivalentLocation = try await git.authorityMetadata(in: layout, prefix: prefix)
        XCTAssertEqual(equivalentLocation.policyIdentity, baseline.policyIdentity)
        XCTAssertNotEqual(equivalentLocation.checkoutConfigurationGeneration, baseline.checkoutConfigurationGeneration)

        try fixture.write("RootSibling/.cursorignore", "changed but still sibling\n")
        let siblingMutation = try await git.authorityMetadata(in: layout, prefix: prefix)
        XCTAssertEqual(siblingMutation.policyIdentity, equivalentLocation.policyIdentity)

        try "*.changed\n".write(to: equivalentExcludes, atomically: true, encoding: .utf8)
        let externalMutation = try await git.authorityMetadata(in: layout, prefix: prefix)
        XCTAssertNotEqual(
            externalMutation.policyIdentity.resolvedExcludesFileIdentity,
            siblingMutation.policyIdentity.resolvedExcludesFileIdentity
        )
        XCTAssertNotEqual(
            externalMutation.policyIdentity.configuredIgnoreAuthorityDigest,
            siblingMutation.policyIdentity.configuredIgnoreAuthorityDigest
        )

        try fixture.write("Root/Nested/.cursorignore", "changed-prefix-control\n")
        let hierarchicalMutation = try await git.authorityMetadata(in: layout, prefix: prefix)
        XCTAssertNotEqual(
            hierarchicalMutation.policyIdentity.committedIgnoreControlDigest,
            externalMutation.policyIdentity.committedIgnoreControlDigest
        )
    }

    func testMainDerivedIgnoredControlsAndCleanLinkedWorktreeProduceIdenticalPolicyIdentity() async throws {
        let fixture = try GitInitializationFixture()
        defer { fixture.cleanup() }
        try fixture.write(".gitignore", "GeneratedEvidence/\n")
        try fixture.write(".repo_ignore", "*.repo-generated\n")
        try fixture.write("Root/.cursorignore", "*.cursor-generated\n")
        try fixture.write("Root/Nested/.gitignore", "*.nested-generated\n")
        try fixture.write(".gitattributes", "*.swift text\n")
        try fixture.commitAll("reachable policy controls")

        for index in 0 ..< 256 {
            try fixture.write(
                "GeneratedEvidence/ignore-\(index)/.gitignore",
                "ignored-\(index)\n"
            )
        }
        for index in 0 ..< 76 {
            try fixture.write(
                "GeneratedEvidence/attributes-\(index)/.gitattributes",
                "*.derived-\(index) binary\n"
            )
        }

        let linkedRoot = fixture.sandbox.appendingPathComponent("linked", isDirectory: true)
        try fixture.git(["worktree", "add", "--detach", linkedRoot.path, "HEAD"])
        let mainLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let linkedLayout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: linkedRoot))
        XCTAssertNotEqual(mainLayout.gitDir, linkedLayout.gitDir)
        let prefix = try GitRepositoryRelativeRootPrefix("")

        let mainControls = try await GitService.streamedPrefixControlEvidence(
            layout: mainLayout,
            prefix: prefix,
            indexedGitlinkPaths: []
        )
        let linkedControls = try await GitService.streamedPrefixControlEvidence(
            layout: linkedLayout,
            prefix: prefix,
            indexedGitlinkPaths: []
        )
        XCTAssertEqual(mainControls.recordCount, 5)
        XCTAssertEqual(linkedControls.recordCount, 5)
        XCTAssertEqual(mainControls.ignoreControlDigest, linkedControls.ignoreControlDigest)
        XCTAssertEqual(mainControls.attributeControlDigest, linkedControls.attributeControlDigest)

        let git = GitService()
        let main = try await git.authorityMetadata(
            in: mainLayout,
            prefix: prefix,
            cacheMode: .bypassReadAndAdmission
        )
        let linked = try await git.authorityMetadata(
            in: linkedLayout,
            prefix: prefix,
            cacheMode: .bypassReadAndAdmission
        )
        XCTAssertEqual(
            main.policyIdentity.mandatoryIgnorePolicyIdentity,
            WorkspaceGitignorePolicyIdentity.current.rawValue
        )
        XCTAssertEqual(
            main.policyIdentity.committedIgnoreControlDigest,
            linked.policyIdentity.committedIgnoreControlDigest
        )
        XCTAssertEqual(main.policyIdentity.attributePolicyDigest, linked.policyIdentity.attributePolicyDigest)
        XCTAssertEqual(main.policyIdentity, linked.policyIdentity)
        #if DEBUG
            let mainDiagnostics = try XCTUnwrap(main.policyIdentity.canonicalizationDiagnostics)
            let linkedDiagnostics = try XCTUnwrap(linked.policyIdentity.canonicalizationDiagnostics)
            XCTAssertEqual(mainDiagnostics.completeness, .complete)
            XCTAssertEqual(linkedDiagnostics.completeness, .complete)
            XCTAssertEqual(mainDiagnostics.canonicalIgnoreFooter.recordCount, 4)
            XCTAssertEqual(linkedDiagnostics.canonicalIgnoreFooter.recordCount, 4)
            XCTAssertEqual(mainDiagnostics.canonicalAttributeFooter.recordCount, 1)
            XCTAssertEqual(linkedDiagnostics.canonicalAttributeFooter.recordCount, 1)
            XCTAssertEqual(mainDiagnostics.prunedRootCount, 1)
            XCTAssertEqual(linkedDiagnostics.prunedRootCount, 0)
            XCTAssertEqual(mainDiagnostics.committedControlCount, 5)
            XCTAssertEqual(linkedDiagnostics.committedControlCount, 5)
            XCTAssertEqual(
                GitWorkspacePolicyCanonicalizationDiagnostics.comparison(
                    base: main.policyIdentity,
                    target: linked.policyIdentity
                )?.classification,
                .canonicalEquivalentAfterReachabilityFiltering
            )
        #endif
    }

    func testStreamingTargetEvidenceAPIsPreserveGitSemanticsAndAuthenticatedHeaders() async throws {
        let fixture = try GitInitializationFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let prefix = try GitRepositoryRelativeRootPrefix("Root")
        try fixture.write("Root/assumed.txt", "assumed\n")
        try fixture.commitAll("add assume-unchanged fixture")
        let base = try await git.resolveTreeOID("HEAD", in: layout)

        try fixture.rename("Root/old file.txt", to: "Root/new\nname.txt")
        try fixture.commitAll("rename for streamed evidence")
        try fixture.git(["update-index", "--assume-unchanged", "--", "Root/assumed.txt"])
        try fixture.git(["mv", "--", "Root/new\nname.txt", "Root/status\trenamed.txt"])
        try fixture.write("Root/untracked*name.txt", "untracked\n")

        let fence = try await git.pendingInitializationAuthorityFence(
            layout: layout,
            prefix: prefix
        )
        let attemptID = UUID()
        let suppliedProvenance = Data("creation-cut-v1".utf8)
        let store = try GitTargetEvidenceManifestStore()
        do {
            let deltaLease = try await git.writeTreeDeltaEvidence(
                baseTreeOID: base,
                in: layout,
                prefix: prefix,
                authorityFence: fence,
                attemptID: attemptID,
                suppliedCreationCutProvenanceBytes: suppliedProvenance,
                store: store
            )
            let deltaRecords = try readAll(deltaLease.makeReader())
            XCTAssertTrue(deltaRecords.contains {
                $0.status == .renamedSource &&
                    $0.repositoryRelativePathBytes == Data("Root/old file.txt".utf8)
            })
            XCTAssertTrue(deltaRecords.contains {
                $0.status == .renamed && $0.similarityScore == 100 &&
                    $0.sourceRepositoryRelativePathBytes == Data("Root/old file.txt".utf8) &&
                    $0.repositoryRelativePathBytes == Data("Root/new\nname.txt".utf8)
            })
            XCTAssertEqual(
                deltaLease.header.identity.authority.authorityGeneration,
                fence.lease.authorityGeneration
            )
            XCTAssertEqual(
                deltaLease.header.identity.authority.invalidationGeneration,
                fence.lease.invalidationGeneration
            )
            XCTAssertEqual(deltaLease.header.identity.authority.attemptID, attemptID)
            XCTAssertEqual(deltaLease.header.identity.suppliedCreationCutProvenanceBytes, suppliedProvenance)
            XCTAssertEqual(deltaLease.header.identity.baseObjectIDBytes, Data(base.lowercaseHex.utf8))
            XCTAssertEqual(
                deltaLease.header.identity.targetObjectIDBytes,
                Data(fence.snapshot.treeOID.lowercaseHex.utf8)
            )
            XCTAssertEqual(deltaLease.header.identity.environmentIdentityBytes.count, 32)
            XCTAssertEqual(deltaLease.header.identity.commandOutputDigestBytes.count, 32)
            XCTAssertTrue(deltaLease.header.identity.commandArguments.contains(Data("--raw".utf8)))

            let indexLease = try await git.writeIndexEvidence(
                in: layout,
                prefix: prefix,
                authorityFence: fence,
                attemptID: attemptID,
                suppliedCreationCutProvenanceBytes: suppliedProvenance,
                store: store
            )
            let indexRecords = try readAll(indexLease.makeReader())
            XCTAssertTrue(indexRecords.contains {
                $0.repositoryRelativePathBytes == Data("Root/assumed.txt".utf8) &&
                    $0.assumeUnchanged && $0.stage == 0
            })
            XCTAssertFalse(indexRecords.contains {
                $0.repositoryRelativePathBytes.starts(with: Data("RootSibling/".utf8))
            })

            let statusLease = try await git.writeStatusEvidence(
                in: layout,
                prefix: prefix,
                authorityFence: fence,
                attemptID: attemptID,
                suppliedCreationCutProvenanceBytes: suppliedProvenance,
                store: store
            )
            let statusRecords = try readAll(statusLease.makeReader())
            XCTAssertTrue(statusRecords.contains {
                $0.kind == .renamed && $0.similarityScore == 100 &&
                    $0.sourceRepositoryRelativePathBytes == Data("Root/new\nname.txt".utf8) &&
                    $0.repositoryRelativePathBytes == Data("Root/status\trenamed.txt".utf8)
            })
            XCTAssertTrue(statusRecords.contains {
                $0.kind == .untracked &&
                    $0.repositoryRelativePathBytes == Data("Root/untracked*name.txt".utf8)
            })
            XCTAssertFalse(statusRecords.contains {
                $0.repositoryRelativePathBytes.starts(with: Data("RootSibling/".utf8))
            })

            let bundle = try GitTargetEvidenceBundleLease(
                treeDelta: deltaLease,
                index: indexLease,
                status: statusLease
            )
            XCTAssertEqual(bundle.treeDelta.header.identity.authority.attemptID, attemptID)
        } catch {
            await git.releasePendingInitializationAuthorityFence(fence)
            throw error
        }
        await git.releasePendingInitializationAuthorityFence(fence)
    }

    func testStreamingTargetEvidenceDisablesRepositoryFSMonitorAndBindsSafeConfig() async throws {
        let fixture = try GitInitializationFixture()
        defer { fixture.cleanup() }
        let hook = fixture.sandbox.appendingPathComponent("fsmonitor-hook")
        let marker = fixture.sandbox.appendingPathComponent("fsmonitor-ran")
        try """
        #!/bin/sh
        /usr/bin/touch "\(marker.path)"
        exit 1
        """.write(to: hook, atomically: true, encoding: .utf8)
        guard chmod(hook.path, 0o755) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try fixture.git(["config", "core.fsmonitor", hook.path])
        try fixture.write("Root/fsmonitor-untracked.txt", "untracked\n")

        try fixture.git(["status", "--porcelain=v2", "-z"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.removeItem(at: marker)

        let git = GitService()
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let prefix = try GitRepositoryRelativeRootPrefix("Root")
        let base = try await git.resolveTreeOID("HEAD", in: layout)
        let fence = try await git.pendingInitializationAuthorityFence(
            layout: layout,
            prefix: prefix
        )
        let attemptID = UUID()
        let store = try GitTargetEvidenceManifestStore()
        do {
            let tree = try await git.writeTreeDeltaEvidence(
                baseTreeOID: base,
                in: layout,
                prefix: prefix,
                authorityFence: fence,
                attemptID: attemptID,
                suppliedCreationCutProvenanceBytes: nil,
                store: store
            )
            let index = try await git.writeIndexEvidence(
                in: layout,
                prefix: prefix,
                authorityFence: fence,
                attemptID: attemptID,
                suppliedCreationCutProvenanceBytes: nil,
                store: store
            )
            let status = try await git.writeStatusEvidence(
                in: layout,
                prefix: prefix,
                authorityFence: fence,
                attemptID: attemptID,
                suppliedCreationCutProvenanceBytes: nil,
                store: store
            )

            XCTAssertTrue(try readAll(tree.makeReader()).isEmpty)
            XCTAssertTrue(try readAll(index.makeReader()).contains {
                $0.repositoryRelativePathBytes == Data("Root/old file.txt".utf8)
            })
            XCTAssertTrue(try readAll(status.makeReader()).contains {
                $0.kind == .untracked &&
                    $0.repositoryRelativePathBytes == Data("Root/fsmonitor-untracked.txt".utf8)
            })
            let safeConfigArguments = [
                "-c", "core.fsmonitor=false",
                "-c", "core.hooksPath=/dev/null",
                "-c", "core.untrackedCache=false"
            ].map { Data($0.utf8) }
            XCTAssertEqual(
                Array(tree.header.identity.commandArguments.prefix(safeConfigArguments.count)),
                safeConfigArguments
            )
            XCTAssertEqual(
                Array(index.header.identity.commandArguments.prefix(safeConfigArguments.count)),
                safeConfigArguments
            )
            XCTAssertEqual(
                Array(status.header.identity.commandArguments.prefix(safeConfigArguments.count)),
                safeConfigArguments
            )
            XCTAssertEqual(
                tree.header.identity.environmentIdentityBytes,
                status.header.identity.environmentIdentityBytes
            )
            XCTAssertNoThrow(try GitTargetEvidenceBundleLease(
                treeDelta: tree,
                index: index,
                status: status
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        } catch {
            await git.releasePendingInitializationAuthorityFence(fence)
            throw error
        }
        await git.releasePendingInitializationAuthorityFence(fence)
    }

    func testStreamingTargetEvidenceRejectsSameTreeHEADMutation() async throws {
        let fixture = try GitInitializationFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let prefix = try GitRepositoryRelativeRootPrefix("Root")
        let original = try await git.authorityMetadata(in: layout, prefix: prefix)

        try fixture.git(["commit", "--allow-empty", "-m", "same tree replacement"])
        let replacement = try await git.authorityMetadata(in: layout, prefix: prefix)
        XCTAssertEqual(original.treeOID, replacement.treeOID)
        XCTAssertNotEqual(original.headCommitOID, replacement.headCommitOID)
        try fixture.git(["update-ref", "HEAD", original.headCommitOID.lowercaseHex])

        let fence = try await git.pendingInitializationAuthorityFence(
            layout: layout,
            prefix: prefix
        )
        let root = fixture.root
        let replacementHead = replacement.headCommitOID.lowercaseHex
        await git.setTargetEvidenceDidSealBeforeCommandHandlerForTesting {
            try runGitEvidenceTestCommand(
                ["update-ref", "HEAD", replacementHead],
                at: root
            )
        }
        do {
            _ = try await git.writeStatusEvidence(
                in: layout,
                prefix: prefix,
                authorityFence: fence,
                attemptID: UUID(),
                suppliedCreationCutProvenanceBytes: nil,
                store: GitTargetEvidenceManifestStore()
            )
            XCTFail("expected the sealed attempt to reject same-tree HEAD movement")
        } catch let error as GitTargetEvidenceCollectionError {
            XCTAssertEqual(error, .authorityChanged)
        }
        await git.setTargetEvidenceDidSealBeforeCommandHandlerForTesting(nil)
        await git.releasePendingInitializationAuthorityFence(fence)
    }

    func testStreamingTargetEvidenceBundleRejectsSuppliedCreationCutProvenanceMismatch() async throws {
        let fixture = try GitInitializationFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let prefix = try GitRepositoryRelativeRootPrefix("Root")
        let base = try await git.resolveTreeOID("HEAD", in: layout)
        let fence = try await git.pendingInitializationAuthorityFence(
            layout: layout,
            prefix: prefix
        )
        let attemptID = UUID()
        let store = try GitTargetEvidenceManifestStore()
        do {
            let tree = try await git.writeTreeDeltaEvidence(
                baseTreeOID: base,
                in: layout,
                prefix: prefix,
                authorityFence: fence,
                attemptID: attemptID,
                suppliedCreationCutProvenanceBytes: Data("supplied-cut-a".utf8),
                store: store
            )
            let index = try await git.writeIndexEvidence(
                in: layout,
                prefix: prefix,
                authorityFence: fence,
                attemptID: attemptID,
                suppliedCreationCutProvenanceBytes: Data("supplied-cut-a".utf8),
                store: store
            )
            let status = try await git.writeStatusEvidence(
                in: layout,
                prefix: prefix,
                authorityFence: fence,
                attemptID: attemptID,
                suppliedCreationCutProvenanceBytes: Data("supplied-cut-b".utf8),
                store: store
            )

            XCTAssertThrowsError(try GitTargetEvidenceBundleLease(
                treeDelta: tree,
                index: index,
                status: status
            )) { error in
                XCTAssertEqual(
                    error as? GitTargetEvidenceManifestError,
                    .corrupt("incoherent evidence bundle")
                )
            }
        } catch {
            await git.releasePendingInitializationAuthorityFence(fence)
            throw error
        }
        await git.releasePendingInitializationAuthorityFence(fence)
    }

    func testStreamingTargetEvidenceActivityTimeoutCancellationAndByteAdmissionReleasePermits() async throws {
        let fixture = try GitInitializationFixture()
        defer { fixture.cleanup() }
        let realGit = GitService()
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let prefix = try GitRepositoryRelativeRootPrefix("Root")
        let fence = try await realGit.pendingInitializationAuthorityFence(
            layout: layout,
            prefix: prefix
        )
        let attemptID = UUID()
        let admission = GitProcessAdmissionController(globalLimit: 1, perRepositoryLimit: 1)
        let sleepingGit = try GitService(
            gitExecutableURL: fixture.makeSleepingGitExecutable(),
            processAdmissionController: admission,
            processTerminationGrace: .milliseconds(10)
        )

        do {
            do {
                _ = try await sleepingGit.writeStatusEvidence(
                    in: layout,
                    prefix: prefix,
                    authorityFence: fence,
                    attemptID: attemptID,
                    suppliedCreationCutProvenanceBytes: nil,
                    store: GitTargetEvidenceManifestStore(),
                    spoolResourcePolicy: GitRawOutputSpoolResourcePolicy(
                        maximumSpoolByteCount: 1024,
                        maximumWriteChunkByteCount: 64 * 1024,
                        readChunkByteCount: 64 * 1024,
                        minimumFreeDiskBytes: 0,
                        activityTimeout: .milliseconds(20)
                    )
                )
                XCTFail("expected activity timeout")
            } catch let error as GitTargetEvidenceCollectionError {
                XCTAssertEqual(error, .activityTimeout)
            }
            var admissionSnapshot = await admission.snapshot()
            XCTAssertEqual(admissionSnapshot.activeLeaseCount, 0)

            let cancellable = Task {
                try await sleepingGit.writeStatusEvidence(
                    in: layout,
                    prefix: prefix,
                    authorityFence: fence,
                    attemptID: attemptID,
                    suppliedCreationCutProvenanceBytes: nil,
                    store: GitTargetEvidenceManifestStore(),
                    spoolResourcePolicy: GitRawOutputSpoolResourcePolicy(
                        maximumSpoolByteCount: 1024,
                        maximumWriteChunkByteCount: 64 * 1024,
                        readChunkByteCount: 64 * 1024,
                        minimumFreeDiskBytes: 0,
                        activityTimeout: .seconds(30)
                    )
                )
            }
            for _ in 0 ..< 1000 {
                if await admission.snapshot().activeLeaseCount == 1 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            cancellable.cancel()
            do {
                _ = try await cancellable.value
                XCTFail("expected streamed evidence cancellation")
            } catch is CancellationError {
                // Expected.
            }
            admissionSnapshot = await admission.snapshot()
            XCTAssertEqual(admissionSnapshot.activeLeaseCount, 0)

            try fixture.write("Root/untracked-output.txt", String(repeating: "x", count: 32))
            do {
                _ = try await realGit.writeStatusEvidence(
                    in: layout,
                    prefix: prefix,
                    authorityFence: fence,
                    attemptID: attemptID,
                    suppliedCreationCutProvenanceBytes: nil,
                    store: GitTargetEvidenceManifestStore(),
                    spoolResourcePolicy: GitRawOutputSpoolResourcePolicy(
                        maximumSpoolByteCount: 8,
                        maximumWriteChunkByteCount: 64 * 1024,
                        readChunkByteCount: 64 * 1024,
                        minimumFreeDiskBytes: 0,
                        activityTimeout: .seconds(5)
                    )
                )
                XCTFail("expected raw-spool byte admission failure")
            } catch let error as GitTargetEvidenceCollectionError {
                XCTAssertEqual(error, .spool(.resourceAdmission))
            }
        } catch {
            await realGit.releasePendingInitializationAuthorityFence(fence)
            throw error
        }
        await realGit.releasePendingInitializationAuthorityFence(fence)
    }

    func testStreamingTargetEvidenceSealedAttemptRejectsConcurrentIndexMutationAndSanitizesEnvironment() async throws {
        let fixture = try GitInitializationFixture()
        defer { fixture.cleanup() }
        let git = GitService()
        let layout = try XCTUnwrap(GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: fixture.root))
        let prefix = try GitRepositoryRelativeRootPrefix("Root")
        let staleFence = try await git.pendingInitializationAuthorityFence(
            layout: layout,
            prefix: prefix
        )
        let root = fixture.root
        await git.setTargetEvidenceDidSealBeforeCommandHandlerForTesting {
            try runGitEvidenceTestCommand(
                ["update-index", "--assume-unchanged", "--", "Root/old file.txt"],
                at: root
            )
        }
        do {
            _ = try await git.writeIndexEvidence(
                in: layout,
                prefix: prefix,
                authorityFence: staleFence,
                attemptID: UUID(),
                suppliedCreationCutProvenanceBytes: nil,
                store: GitTargetEvidenceManifestStore()
            )
            XCTFail("expected the sealed attempt to reject an index mutation")
        } catch let error as GitTargetEvidenceCollectionError {
            XCTAssertEqual(error, .authorityChanged)
        }
        await git.setTargetEvidenceDidSealBeforeCommandHandlerForTesting(nil)
        await git.releasePendingInitializationAuthorityFence(staleFence)
        try fixture.git(["update-index", "--no-assume-unchanged", "--", "Root/old file.txt"])

        let fence = try await git.pendingInitializationAuthorityFence(
            layout: layout,
            prefix: prefix
        )
        var hostileEnvironment = ProcessInfo.processInfo.environment
        let hostile = fixture.sandbox.appendingPathComponent("hostile", isDirectory: true)
        hostileEnvironment["GIT_OBJECT_DIRECTORY"] = hostile.appendingPathComponent("objects").path
        hostileEnvironment["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = hostile.appendingPathComponent("alternates").path
        hostileEnvironment["GIT_REPLACE_REF_BASE"] = "refs/hostile/"
        hostileEnvironment["GIT_CONFIG_PARAMETERS"] = "'status.showUntrackedFiles'='no'"
        hostileEnvironment["GIT_CONFIG_COUNT"] = "1"
        hostileEnvironment["GIT_CONFIG_KEY_0"] = "core.worktree"
        hostileEnvironment["GIT_CONFIG_VALUE_0"] = hostile.path
        hostileEnvironment["GIT_EXEC_PATH"] = hostile.path
        let hostileGit = GitService(inheritedProcessEnvironment: hostileEnvironment)
        let attemptID = UUID()
        do {
            let ordinary = try await git.writeStatusEvidence(
                in: layout,
                prefix: prefix,
                authorityFence: fence,
                attemptID: attemptID,
                suppliedCreationCutProvenanceBytes: nil,
                store: GitTargetEvidenceManifestStore()
            )
            let sanitized = try await hostileGit.writeStatusEvidence(
                in: layout,
                prefix: prefix,
                authorityFence: fence,
                attemptID: attemptID,
                suppliedCreationCutProvenanceBytes: nil,
                store: GitTargetEvidenceManifestStore()
            )
            XCTAssertEqual(
                ordinary.header.identity.environmentIdentityBytes,
                sanitized.header.identity.environmentIdentityBytes
            )
            XCTAssertEqual(
                ordinary.header.identity.commandOutputDigestBytes,
                sanitized.header.identity.commandOutputDigestBytes
            )
            XCTAssertEqual(
                ordinary.header.identity.authority.snapshotDigestBytes,
                sanitized.header.identity.authority.snapshotDigestBytes
            )
        } catch {
            await git.releasePendingInitializationAuthorityFence(fence)
            throw error
        }
        await git.releasePendingInitializationAuthorityFence(fence)
    }

    func testTargetEvidenceErrorMappingPreservesAdmissionProcessAndSpoolFailures() {
        let admissionCases: [GitProcessAdmissionError] = [
            .queueFull, .repositoryQueueFull, .deadlineQueueFull,
            .deadlineUnsupported, .deadlineExceeded
        ]
        for error in admissionCases {
            XCTAssertEqual(
                GitService.targetEvidenceCollectionError(error) as? GitTargetEvidenceCollectionError,
                .admission(error)
            )
        }
        let spoolCases: [GitRawOutputSpoolError] = [
            .invalidConfiguration,
            .resourceAdmission,
            .closed,
            .corrupt("digest mismatch"),
            .io(operation: "spool-fsync", code: EIO)
        ]
        for error in spoolCases {
            XCTAssertEqual(
                GitService.targetEvidenceCollectionError(error) as? GitTargetEvidenceCollectionError,
                .spool(error)
            )
        }
        let captureCases: [(GitService.GitProcessCaptureError, GitTargetEvidenceCollectionError)] = [
            (.stdoutByteLimitExceeded, .processCapture(.stdoutLimitExceeded)),
            (.stderrByteLimitExceeded, .processCapture(.stderrLimitExceeded)),
            (.timedOut, .activityTimeout)
        ]
        for (error, expected) in captureCases {
            XCTAssertEqual(
                GitService.targetEvidenceCollectionError(error) as? GitTargetEvidenceCollectionError,
                expected
            )
        }
        let launch = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOEXEC))
        XCTAssertEqual(
            GitService.targetEvidenceCollectionError(launch) as? GitTargetEvidenceCollectionError,
            .processLaunch(domain: NSPOSIXErrorDomain, code: Int(ENOEXEC))
        )
        let unknown = GitTargetEvidenceUnknownError()
        XCTAssertTrue(GitService.targetEvidenceCollectionError(unknown) is GitTargetEvidenceUnknownError)
    }

    func testParsersRejectSiblingPrefixesInvalidUTF8AndMissingNULTermination() throws {
        XCTAssertThrowsError(try GitRepositoryRelativeRootPrefix("Root/../escape"))
        let oid = try GitObjectID(objectFormat: .sha1, lowercaseHex: String(repeating: "1", count: 40))
        let prefix = try GitRepositoryRelativeRootPrefix("Root")
        let siblingRecord = Data("100644 blob \(oid.lowercaseHex)\tRootSibling/file\0".utf8)
        XCTAssertThrowsError(try GitTreeInventoryParser.parseTreeInventory(
            siblingRecord,
            treeOID: oid,
            rootPrefix: prefix,
            limits: .treeInventory
        ))

        var invalidUTF8 = Data("100644 blob \(oid.lowercaseHex)\tRoot/".utf8)
        invalidUTF8.append(0xFF)
        invalidUTF8.append(0)
        XCTAssertThrowsError(try GitTreeInventoryParser.parseTreeInventory(
            invalidUTF8,
            treeOID: oid,
            rootPrefix: prefix,
            limits: .treeInventory
        ))

        let unterminated = Data("100644 blob \(oid.lowercaseHex)\tRoot/file".utf8)
        XCTAssertThrowsError(try GitTreeInventoryParser.parseTreeInventory(
            unterminated,
            treeOID: oid,
            rootPrefix: prefix,
            limits: .treeInventory
        ))
    }

    private func readAll(
        _ reader: GitTargetTreeDeltaEvidenceReader
    ) throws -> [GitTargetTreeDeltaEvidenceRecord] {
        var records: [GitTargetTreeDeltaEvidenceRecord] = []
        while let record = try reader.next() {
            records.append(record)
        }
        XCTAssertEqual(reader.validationState, .verified)
        return records
    }

    private func readAll(
        _ reader: GitTargetIndexEvidenceReader
    ) throws -> [GitTargetIndexEvidenceRecord] {
        var records: [GitTargetIndexEvidenceRecord] = []
        while let record = try reader.next() {
            records.append(record)
        }
        XCTAssertEqual(reader.validationState, .verified)
        return records
    }

    private func readAll(
        _ reader: GitTargetStatusEvidenceReader
    ) throws -> [GitTargetStatusEvidenceRecord] {
        var records: [GitTargetStatusEvidenceRecord] = []
        while let record = try reader.next() {
            records.append(record)
        }
        XCTAssertEqual(reader.validationState, .verified)
        return records
    }
}

private struct GitTargetEvidenceUnknownError: Error {}

private func runGitEvidenceTestCommand(
    _ arguments: [String],
    at root: URL
) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.environment = ProcessInfo.processInfo.environment.merging([
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0"
    ]) { _, new in new }
    let stderr = Pipe()
    process.standardOutput = Pipe()
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let detail = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        throw NSError(
            domain: "GitTargetEvidenceTestCommand",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: detail]
        )
    }
}

private struct GitInitializationFixture {
    let sandbox: URL
    let root: URL

    init() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitWorktreeInitializationAPITests-\(UUID().uuidString)", isDirectory: true)
        root = sandbox.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init"])
        try git(["config", "user.name", "RepoPrompt Test"])
        try git(["config", "user.email", "repoprompt@example.test"])
        try git(["config", "commit.gpgSign", "false"])
        try write("Root/old file.txt", "base\n")
        try write("RootSibling/outside.txt", "outside\n")
        try commitAll("base")
    }

    func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func rename(_ source: String, to destination: String) throws {
        try FileManager.default.moveItem(
            at: root.appendingPathComponent(source),
            to: root.appendingPathComponent(destination)
        )
    }

    func commitAll(_ message: String) throws {
        try git(["add", "-A"])
        try git(["commit", "-m", message])
    }

    func makeSleepingGitExecutable() throws -> URL {
        let url = sandbox.appendingPathComponent("sleeping-git")
        try "#!/bin/sh\nsleep 10\n".write(to: url, atomically: true, encoding: .utf8)
        guard chmod(url.path, 0o755) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return url
    }

    func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0"
        ]) { _, new in new }
        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "GitWorktreeInitializationAPITests.git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: sandbox)
    }
}
