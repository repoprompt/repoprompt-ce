import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class WorkspaceCodemapGitCapabilityServiceTests: XCTestCase {
    private let namespaceSalt = Data(repeating: 0x42, count: GitBlobRepositoryNamespace.saltByteCount)

    func testCanonicalSubdirectoryAndLinkedWorktreeCapabilitiesPreserveTopology() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let canonical = try fixture.makeRepository(named: "canonical")
        let subdirectory = canonical.appendingPathComponent("Sources", isDirectory: true)
        let linked = try fixture.makeLinkedWorktree(from: canonical, named: "linked", branch: "linked")
        let service = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)

        let canonicalCapability = try await capability(
            service.resolve(root: request(for: canonical, seed: 1))
        )
        let subdirectoryCapability = try await capability(
            service.resolve(root: request(for: subdirectory, seed: 2))
        )
        let linkedCapability = try await capability(
            service.resolve(root: request(for: linked, seed: 3))
        )

        XCTAssertEqual(canonicalCapability.repositoryRelativeLoadedRootPrefix, "")
        XCTAssertEqual(subdirectoryCapability.repositoryRelativeLoadedRootPrefix, "Sources")
        XCTAssertEqual(linkedCapability.repositoryRelativeLoadedRootPrefix, "")
        XCTAssertEqual(canonicalCapability.repositoryNamespace, subdirectoryCapability.repositoryNamespace)
        XCTAssertEqual(canonicalCapability.repositoryNamespace, linkedCapability.repositoryNamespace)
        XCTAssertEqual(canonicalCapability.repositoryIdentity.repositoryID, linkedCapability.repositoryIdentity.repositoryID)
        XCTAssertNotEqual(canonicalCapability.worktreeID, linkedCapability.worktreeID)
        XCTAssertFalse(canonicalCapability.repositoryLayout.isLinkedWorktree)
        XCTAssertTrue(linkedCapability.repositoryLayout.isLinkedWorktree)
    }

    func testRepositoryTopologySeparatesSharedWorktreesNestedAndSubmoduleAuthorities() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let canonical = try fixture.makeRepository(named: "canonical")
        let linked = try fixture.makeLinkedWorktree(
            from: canonical,
            named: "linked",
            branch: "linked-topology"
        )
        let externalParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(#function)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalParent, withIntermediateDirectories: false)
        let external = externalParent.appendingPathComponent("external", isDirectory: true)
        _ = try fixture.runGit(
            ["worktree", "add", "-b", "external-topology", external.path, "HEAD"],
            at: canonical
        )
        defer {
            _ = try? fixture.runGit(["worktree", "remove", "--force", external.path], at: canonical)
            try? FileManager.default.removeItem(at: externalParent)
        }

        let nested = canonical.appendingPathComponent("NestedRepository", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        _ = try fixture.runGit(["init"], at: nested)
        _ = try fixture.runGit(["config", "user.name", "RepoPrompt Test"], at: nested)
        _ = try fixture.runGit(["config", "user.email", "repoprompt@example.test"], at: nested)
        _ = try fixture.runGit(["config", "commit.gpgSign", "false"], at: nested)
        _ = try fixture.runGit(["checkout", "-b", "nested-main"], at: nested)
        try fixture.write("struct Nested {}\n", to: "Sources/Nested.swift", at: nested)
        _ = try fixture.runGit(["add", "."], at: nested)
        _ = try fixture.runGit(["commit", "-m", "Nested repository"], at: nested)

        let submoduleSource = try fixture.makeRepository(
            named: "submodule-source",
            files: ["Sources/Submodule.swift": "struct Submodule {}\n"]
        )
        _ = try fixture.runGit(
            ["-c", "protocol.file.allow=always", "submodule", "add", submoduleSource.path, "Vendor/Sub"],
            at: canonical
        )
        try fixture.commit("Add submodule", at: canonical)
        let submodule = canonical.appendingPathComponent("Vendor/Sub", isDirectory: true)

        let service = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)
        let canonicalCapability = try await capability(
            service.resolve(root: request(for: canonical, seed: 4))
        )
        let linkedCapability = try await capability(
            service.resolve(root: request(for: linked, seed: 5))
        )
        let externalCapability = try await capability(
            service.resolve(root: request(for: external, seed: 6))
        )
        let nestedCapability = try await capability(
            service.resolve(root: request(for: nested, seed: 7))
        )
        let submoduleCapability = try await capability(
            service.resolve(root: request(for: submodule, seed: 8))
        )

        XCTAssertEqual(canonicalCapability.repositoryNamespace, linkedCapability.repositoryNamespace)
        XCTAssertEqual(canonicalCapability.repositoryNamespace, externalCapability.repositoryNamespace)
        XCTAssertNotEqual(canonicalCapability.worktreeID, linkedCapability.worktreeID)
        XCTAssertNotEqual(canonicalCapability.worktreeID, externalCapability.worktreeID)
        XCTAssertNotEqual(linkedCapability.worktreeID, externalCapability.worktreeID)
        XCTAssertTrue(linkedCapability.repositoryLayout.isLinkedWorktree)
        XCTAssertTrue(externalCapability.repositoryLayout.isLinkedWorktree)
        XCTAssertNotEqual(canonicalCapability.repositoryNamespace, nestedCapability.repositoryNamespace)
        XCTAssertNotEqual(canonicalCapability.repositoryNamespace, submoduleCapability.repositoryNamespace)
        XCTAssertNotEqual(nestedCapability.repositoryNamespace, submoduleCapability.repositoryNamespace)
    }

    func testNonGitBareUnsupportedAndLocalizedDiagnosticsFailClosed() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let plain = fixture.sandbox.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let bare = fixture.sandbox.appendingPathComponent("bare.git", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        _ = try fixture.runGit(["init", "--bare"], at: bare)

        let service = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)
        await assertEqual(
            service.resolve(root: request(for: plain, seed: 10)),
            .terminalUnavailable(.nonGit)
        )
        await assertEqual(
            service.resolve(root: request(for: bare, seed: 11)),
            .terminalUnavailable(.bareRepository)
        )

        let unsupportedRoot = fixture.sandbox.appendingPathComponent("unsupported", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unsupportedRoot.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let fakeGit = fixture.sandbox.appendingPathComponent("fake-git")
        try """
        #!/bin/sh
        case "$*" in
          *--show-toplevel*) printf '%s\n' "$PWD" ;;
          *--show-object-format*) printf 'sha512\n' ;;
          *) exit 1 ;;
        esac
        """.write(to: fakeGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeGit.path)
        let unsupportedService = WorkspaceCodemapGitCapabilityService(
            gitService: GitService(gitExecutableURL: fakeGit),
            namespaceSalt: namespaceSalt
        )
        await assertEqual(
            unsupportedService.resolve(root: request(for: unsupportedRoot, seed: 12)),
            .terminalUnavailable(.unsupportedObjectFormat)
        )

        let unavailableGit = fixture.sandbox.appendingPathComponent("unavailable-git")
        try """
        #!/bin/sh
        case "$*" in
          *--show-toplevel*) printf '%s\n' "$PWD" ;;
          *--show-object-format*) printf 'unsupported option\n' >&2; exit 1 ;;
          *) exit 1 ;;
        esac
        """.write(to: unavailableGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unavailableGit.path)
        let unavailableService = WorkspaceCodemapGitCapabilityService(
            gitService: GitService(gitExecutableURL: unavailableGit),
            namespaceSalt: namespaceSalt
        )
        await assertEqual(
            unavailableService.resolve(root: request(for: unsupportedRoot, seed: 14)),
            .terminalUnavailable(.unsupportedGit)
        )

        let localeLog = fixture.sandbox.appendingPathComponent("locale.log")
        let localizedGit = fixture.sandbox.appendingPathComponent("localized-git")
        try """
        #!/bin/sh
        printf '%s|%s\n' "$LC_ALL" "$LANG" >> '\(localeLog.path)'
        printf 'fatal: ceci n’est pas un dépôt git\n' >&2
        exit 128
        """.write(to: localizedGit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: localizedGit.path)
        let localizedService = WorkspaceCodemapGitCapabilityService(
            gitService: GitService(gitExecutableURL: localizedGit),
            namespaceSalt: namespaceSalt
        )
        await assertEqual(
            localizedService.resolve(root: request(for: plain, seed: 13)),
            .terminalUnavailable(.nonGit)
        )
        let localeLines = try String(contentsOf: localeLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        XCTAssertFalse(localeLines.isEmpty)
        XCTAssertTrue(localeLines.allSatisfy { $0 == "C|C" })
    }

    func testInvalidLayoutContainmentAndNamespaceFailClosed() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)

        let invalidLayoutRoot = fixture.sandbox.appendingPathComponent("invalid-layout", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidLayoutRoot, withIntermediateDirectories: true)
        try "invalid gitfile\n".write(
            to: invalidLayoutRoot.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )
        let invalidLayoutGit = fixture.sandbox.appendingPathComponent("invalid-layout-git")
        try fakeGitScript(topLevel: invalidLayoutRoot.path).write(
            to: invalidLayoutGit,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: invalidLayoutGit.path)
        let invalidLayoutService = WorkspaceCodemapGitCapabilityService(
            gitService: GitService(gitExecutableURL: invalidLayoutGit),
            namespaceSalt: namespaceSalt
        )
        await assertEqual(
            invalidLayoutService.resolve(root: request(for: invalidLayoutRoot, seed: 14)),
            .terminalUnavailable(.invalidLayout)
        )

        let foreignRoot = fixture.sandbox.appendingPathComponent("foreign", isDirectory: true)
        try FileManager.default.createDirectory(
            at: foreignRoot.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let outsideRoot = fixture.sandbox.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        let containmentGit = fixture.sandbox.appendingPathComponent("containment-git")
        try fakeGitScript(topLevel: foreignRoot.path).write(
            to: containmentGit,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: containmentGit.path)
        let containmentService = WorkspaceCodemapGitCapabilityService(
            gitService: GitService(gitExecutableURL: containmentGit),
            namespaceSalt: namespaceSalt
        )
        await assertEqual(
            containmentService.resolve(root: request(for: outsideRoot, seed: 15)),
            .terminalUnavailable(.invalidLoadedRootContainment)
        )

        let repository = try fixture.makeRepository(named: "namespace")
        let namespaceService = WorkspaceCodemapGitCapabilityService(namespaceSalt: Data())
        await assertEqual(
            namespaceService.resolve(root: request(for: repository, seed: 16)),
            .terminalUnavailable(.namespaceUnavailable)
        )
    }

    func testTerminalIsStickyUntilReloadAndTransientDisappearanceRecovers() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let plain = fixture.sandbox.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let terminalRequest = request(for: plain, seed: 20)
        let service = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)

        await assertEqual(service.resolve(root: terminalRequest), .terminalUnavailable(.nonGit))
        _ = try fixture.makeRepository(named: "plain")
        await assertEqual(service.resolve(root: terminalRequest), .terminalUnavailable(.nonGit))
        _ = try await capability(service.reload(root: terminalRequest))

        let gitDirectory = plain.appendingPathComponent(".git", isDirectory: true)
        let temporarilyMissingGitDirectory = fixture.sandbox.appendingPathComponent(
            "plain-temporarily-missing.git",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: gitDirectory, to: temporarilyMissingGitDirectory)
        await assertTransient(
            service.resolve(root: terminalRequest),
            reason: .repositoryChanging
        )
        try FileManager.default.moveItem(at: temporarilyMissingGitDirectory, to: gitDirectory)
        _ = try await capability(service.resolve(root: terminalRequest))

        let missing = fixture.sandbox.appendingPathComponent("missing", isDirectory: true)
        let transientRequest = request(for: missing, seed: 21)
        await assertTransient(
            service.resolve(root: transientRequest),
            reason: .repositoryChanging
        )
        _ = try fixture.makeRepository(named: "missing")
        _ = try await capability(service.resolve(root: transientRequest))
    }

    func testPermissionFailureIsTransientAndRecovers() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try fixture.makeRepository(named: "repository")
        let rootRequest = request(for: root, seed: 22)
        let service = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
        await assertTransient(
            service.resolve(root: rootRequest),
            reason: .permissionFailure
        )

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        _ = try await capability(service.resolve(root: rootRequest))
    }

    func testAuthorityAdvancesForIndexConfigAttributesSparseAndRefs() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try fixture.makeRepository(named: "repository")
        let rootRequest = request(for: root, seed: 30)
        let service = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)

        let initial = try await capability(service.resolve(root: rootRequest)).repositoryAuthority

        try fixture.write("let value = 2\n", to: "Sources/Feature.swift", at: root)
        try fixture.stage("Sources/Feature.swift", at: root)
        let afterIndex = try await capability(service.resolve(root: rootRequest)).repositoryAuthority
        XCTAssertGreaterThan(afterIndex.authorityGeneration, initial.authorityGeneration)
        XCTAssertNotEqual(afterIndex.indexGeneration, initial.indexGeneration)

        _ = try fixture.runGit(["config", "core.autocrlf", "true"], at: root)
        let afterConfiguration = try await capability(service.resolve(root: rootRequest)).repositoryAuthority
        XCTAssertNotEqual(
            afterConfiguration.checkoutConfigurationGeneration,
            afterIndex.checkoutConfigurationGeneration
        )

        try fixture.write("*.swift text eol=lf\n", to: ".gitattributes", at: root)
        let afterRootAttributes = try await capability(service.resolve(root: rootRequest)).repositoryAuthority
        XCTAssertNotEqual(afterRootAttributes.attributeGeneration, afterConfiguration.attributeGeneration)

        try fixture.write("*.swift -text\n", to: ".git/info/attributes", at: root)
        let afterInfoAttributes = try await capability(service.resolve(root: rootRequest)).repositoryAuthority
        XCTAssertNotEqual(afterInfoAttributes.attributeGeneration, afterRootAttributes.attributeGeneration)

        let configuredAttributes = root.appendingPathComponent("authority.attributes")
        try "*.swift ident\n".write(to: configuredAttributes, atomically: true, encoding: .utf8)
        _ = try fixture.runGit(["config", "core.attributesFile", configuredAttributes.path], at: root)
        let afterConfiguredAttributes = try await capability(service.resolve(root: rootRequest)).repositoryAuthority
        XCTAssertNotEqual(
            afterConfiguredAttributes.checkoutConfigurationGeneration,
            afterInfoAttributes.checkoutConfigurationGeneration
        )
        XCTAssertNotEqual(afterConfiguredAttributes.attributeGeneration, afterInfoAttributes.attributeGeneration)

        try "*.swift -ident\n".write(to: configuredAttributes, atomically: true, encoding: .utf8)
        let afterConfiguredEdit = try await capability(service.resolve(root: rootRequest)).repositoryAuthority
        XCTAssertNotEqual(afterConfiguredEdit.attributeGeneration, afterConfiguredAttributes.attributeGeneration)

        _ = try fixture.runGit(["config", "core.sparseCheckout", "true"], at: root)
        _ = try fixture.runGit(["config", "core.sparseCheckoutCone", "false"], at: root)
        try fixture.write("Sources/**\n", to: ".git/info/sparse-checkout", at: root)
        let afterSparse = try await capability(service.resolve(root: rootRequest)).repositoryAuthority
        XCTAssertNotEqual(afterSparse.sparseGeneration, afterConfiguredEdit.sparseGeneration)

        try fixture.commit("Authority metadata", at: root)
        let afterHead = try await capability(service.resolve(root: rootRequest)).repositoryAuthority
        XCTAssertNotEqual(afterHead.metadataGeneration, afterSparse.metadataGeneration)

        _ = try fixture.runGit(["tag", "authority-tag"], at: root)
        _ = try fixture.runGit(["pack-refs", "--all"], at: root)
        let afterPackedRefs = try await capability(service.resolve(root: rootRequest)).repositoryAuthority
        XCTAssertNotEqual(afterPackedRefs.metadataGeneration, afterHead.metadataGeneration)
    }

    func testAuthorityEvidenceDescriptorRejectsLeafReplacementAndParentSymlinkSwap() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)

        let leafRoot = try fixture.makeRepository(named: "leaf")
        let leafConfig = leafRoot.appendingPathComponent(".git/config").standardizedFileURL
        let leafReplacement = AuthorityEvidenceLeafReplacement(
            target: leafConfig,
            replacementContents: Data("[core]\nrepositoryformatversion = 999\n".utf8)
        )
        let leafService = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: namespaceSalt,
            hooks: WorkspaceCodemapGitCapabilityServiceHooks(
                afterAuthorityEvidenceOpen: { leafReplacement.replaceIfTarget($0) }
            )
        )
        guard case .transientUnavailable(.repositoryChanging, _) = await leafService.resolve(
            root: request(for: leafRoot, seed: 26)
        ) else { return XCTFail("Leaf replacement after descriptor open must fail closed.") }

        let parentRoot = try fixture.makeRepository(named: "parent")
        let info = parentRoot.appendingPathComponent(".git/info", isDirectory: true)
        let attributes = info.appendingPathComponent("attributes")
        try "*.swift text\n".write(to: attributes, atomically: true, encoding: .utf8)
        let outside = fixture.sandbox.appendingPathComponent("outside-info", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "*.swift filter=outside\n".write(
            to: outside.appendingPathComponent("attributes"),
            atomically: true,
            encoding: .utf8
        )
        let parentSwap = AuthorityEvidenceParentSymlinkSwap(
            targetDirectory: info,
            triggerFile: attributes,
            outsideDirectory: outside
        )
        let parentService = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: namespaceSalt,
            hooks: WorkspaceCodemapGitCapabilityServiceHooks(
                afterAuthorityEvidenceOpen: { parentSwap.swapIfTarget($0) }
            )
        )
        guard case .transientUnavailable(.repositoryChanging, _) = await parentService.resolve(
            root: request(for: parentRoot, seed: 27)
        ) else { return XCTFail("Parent symlink swap after descriptor open must fail closed.") }
    }

    func testLinkedWorktreeCommonAndPerWorktreeAuthorityChanges() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let canonical = try fixture.makeRepository(named: "canonical")
        let linked = try fixture.makeLinkedWorktree(from: canonical, named: "linked", branch: "linked")
        let linkedRequest = request(for: linked, seed: 31)
        let service = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)

        let initialCapability = try await capability(service.resolve(root: linkedRequest))
        let initial = initialCapability.repositoryAuthority

        try fixture.write("*.swift text\n", to: ".git/info/attributes", at: canonical)
        let afterCommonAttributes = try await capability(service.resolve(root: linkedRequest)).repositoryAuthority
        XCTAssertNotEqual(afterCommonAttributes.attributeGeneration, initial.attributeGeneration)

        let gitDir = initialCapability.repositoryLayout.gitDir
        try FileManager.default.createDirectory(
            at: gitDir.appendingPathComponent("info", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "*.swift -text\n".write(
            to: gitDir.appendingPathComponent("info/attributes"),
            atomically: true,
            encoding: .utf8
        )
        let afterWorktreeAttributes = try await capability(service.resolve(root: linkedRequest)).repositoryAuthority
        XCTAssertNotEqual(afterWorktreeAttributes.attributeGeneration, afterCommonAttributes.attributeGeneration)

        _ = try fixture.runGit(["config", "extensions.worktreeConfig", "true"], at: canonical)
        _ = try fixture.runGit(["config", "--worktree", "core.autocrlf", "input"], at: linked)
        let afterWorktreeConfig = try await capability(service.resolve(root: linkedRequest)).repositoryAuthority
        XCTAssertNotEqual(
            afterWorktreeConfig.checkoutConfigurationGeneration,
            afterWorktreeAttributes.checkoutConfigurationGeneration
        )

        try "Sources/**\n".write(
            to: gitDir.appendingPathComponent("info/sparse-checkout"),
            atomically: true,
            encoding: .utf8
        )
        let afterWorktreeSparse = try await capability(service.resolve(root: linkedRequest)).repositoryAuthority
        XCTAssertNotEqual(afterWorktreeSparse.sparseGeneration, afterWorktreeConfig.sparseGeneration)

        try "Sources/Feature.swift\n".write(
            to: initialCapability.repositoryLayout.commonDir.appendingPathComponent("info/sparse-checkout"),
            atomically: true,
            encoding: .utf8
        )
        let afterCommonSparse = try await capability(service.resolve(root: linkedRequest)).repositoryAuthority
        XCTAssertNotEqual(afterCommonSparse.sparseGeneration, afterWorktreeSparse.sparseGeneration)
    }

    func testRootEpochRejectsPathAndRepositoryRetargetCollisions() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let first = try fixture.makeRepository(named: "first")
        let second = try fixture.makeRepository(named: "second")
        let firstRequest = request(for: first, seed: 40)
        let sameEpochDifferentPath = WorkspaceCodemapGitCapabilityRequest(
            rootID: firstRequest.rootEpoch.rootID,
            rootLifetimeID: firstRequest.rootEpoch.rootLifetimeID,
            loadedRootURL: second
        )
        let service = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)

        let original = try await capability(service.resolve(root: firstRequest))
        await assertEqual(
            service.resolve(root: sameEpochDifferentPath),
            .terminalUnavailable(.rootEpochBindingMismatch)
        )
        await assertEqual(service.state(for: firstRequest.rootEpoch), .eligible(original))

        let oldGitDirectory = first.appendingPathComponent(".git", isDirectory: true)
        let retiredGitDirectory = fixture.sandbox.appendingPathComponent("retired.git", isDirectory: true)
        try FileManager.default.moveItem(at: oldGitDirectory, to: retiredGitDirectory)
        _ = try fixture.runGit(["init"], at: first)
        await assertEqual(
            service.resolve(root: firstRequest),
            .terminalUnavailable(.rootEpochBindingMismatch)
        )

        let retargetRequest = request(for: first, seed: 41)
        _ = try await capability(service.retarget(from: firstRequest.rootEpoch, to: retargetRequest))
        await assertEqual(
            service.state(for: firstRequest.rootEpoch),
            .terminalUnavailable(.releasedRootEpoch)
        )
    }

    func testSourceAuthorityFactoryRejectsCollisionMatrixAndTracksNestedAttributes() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try fixture.makeRepository(named: "repository")
        try fixture.write("let nested = true\n", to: "Sources/Nested/Feature.swift", at: root)
        let loadedRoot = root.appendingPathComponent("Sources", isDirectory: true)
        let service = WorkspaceCodemapGitCapabilityService(namespaceSalt: namespaceSalt)
        let capability = try await capability(service.resolve(root: request(for: loadedRoot, seed: 50)))
        let path = "Sources/Nested/Feature.swift"
        let pathFingerprint = try fingerprint(at: root.appendingPathComponent(path))

        let acceptedCandidate = await service.makeSourceAuthority(
            capability: capability,
            observedRootEpoch: capability.rootEpoch,
            observedRepositoryAuthority: capability.repositoryAuthority,
            candidateRepositoryRelativePath: path,
            observedPathGeneration: 7,
            currentPathGeneration: 7,
            observedIngressGeneration: 11,
            currentIngressGeneration: 11
        )
        let accepted = try XCTUnwrap(acceptedCandidate)
        XCTAssertTrue(accepted.isFactoryValidated)
        XCTAssertEqual(accepted.repositoryRelativeLoadedRootPrefix, "Sources")
        XCTAssertEqual(accepted.acceptedPrePathFingerprint, pathFingerprint)
        XCTAssertEqual(accepted.acceptedPostPathFingerprint, pathFingerprint)

        let mismatchedEpoch = WorkspaceCodemapRootEpoch(rootID: UUID(), rootLifetimeID: UUID())
        await assertNil(service.makeSourceAuthority(
            capability: capability,
            observedRootEpoch: mismatchedEpoch,
            observedRepositoryAuthority: capability.repositoryAuthority,
            candidateRepositoryRelativePath: path,
            observedPathGeneration: 7,
            currentPathGeneration: 7,
            observedIngressGeneration: 11,
            currentIngressGeneration: 11
        ))
        await assertNil(service.makeSourceAuthority(
            capability: capability,
            observedRootEpoch: capability.rootEpoch,
            observedRepositoryAuthority: capability.repositoryAuthority,
            candidateRepositoryRelativePath: "SourcesSibling/Feature.swift",
            observedPathGeneration: 7,
            currentPathGeneration: 7,
            observedIngressGeneration: 11,
            currentIngressGeneration: 11
        ))
        await assertNil(service.makeSourceAuthority(
            capability: capability,
            observedRootEpoch: capability.rootEpoch,
            observedRepositoryAuthority: capability.repositoryAuthority,
            candidateRepositoryRelativePath: path,
            observedPathGeneration: 6,
            currentPathGeneration: 7,
            observedIngressGeneration: 11,
            currentIngressGeneration: 11
        ))
        await assertNil(service.makeSourceAuthority(
            capability: capability,
            observedRootEpoch: capability.rootEpoch,
            observedRepositoryAuthority: capability.repositoryAuthority,
            candidateRepositoryRelativePath: path,
            observedPathGeneration: 7,
            currentPathGeneration: 7,
            observedIngressGeneration: 10,
            currentIngressGeneration: 11
        ))

        let mismatchedAuthority = WorkspaceCodemapRepositoryAuthorityToken(
            authorityGeneration: capability.repositoryAuthority.authorityGeneration + 1,
            repositoryNamespace: capability.repositoryAuthority.repositoryNamespace,
            objectFormat: capability.repositoryAuthority.objectFormat,
            repositoryBindingEpoch: capability.repositoryAuthority.repositoryBindingEpoch,
            worktreeBindingEpoch: capability.repositoryAuthority.worktreeBindingEpoch,
            layoutGeneration: capability.repositoryAuthority.layoutGeneration,
            indexGeneration: capability.repositoryAuthority.indexGeneration,
            checkoutConfigurationGeneration: capability.repositoryAuthority.checkoutConfigurationGeneration,
            attributeGeneration: capability.repositoryAuthority.attributeGeneration,
            sparseGeneration: capability.repositoryAuthority.sparseGeneration,
            metadataGeneration: capability.repositoryAuthority.metadataGeneration
        )
        await assertNil(service.makeSourceAuthority(
            capability: capability,
            observedRootEpoch: capability.rootEpoch,
            observedRepositoryAuthority: mismatchedAuthority,
            candidateRepositoryRelativePath: path,
            observedPathGeneration: 7,
            currentPathGeneration: 7,
            observedIngressGeneration: 11,
            currentIngressGeneration: 11
        ))

        try fixture.write("*.swift -text\n", to: "Sources/Nested/.gitattributes", at: root)
        let afterNestedAttributesCandidate = await service.makeSourceAuthority(
            capability: capability,
            observedRootEpoch: capability.rootEpoch,
            observedRepositoryAuthority: capability.repositoryAuthority,
            candidateRepositoryRelativePath: path,
            observedPathGeneration: 7,
            currentPathGeneration: 7,
            observedIngressGeneration: 11,
            currentIngressGeneration: 11
        )
        let afterNestedAttributes = try XCTUnwrap(afterNestedAttributesCandidate)
        XCTAssertNotEqual(afterNestedAttributes.candidateAttributeGeneration, accepted.candidateAttributeGeneration)
    }

    func testSourceAuthorityNoFollowFingerprintRejectsSymlinkAndMutation() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try fixture.makeRepository(named: "repository")
        let path = "Sources/Feature.swift"
        let candidateURL = root.appendingPathComponent(path).standardizedFileURL
        let recorder = ExactPathFingerprintRecorder(expectedURL: candidateURL)
        let recordingService = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: namespaceSalt,
            pathFingerprintClient: recorder.client
        )
        let recordingCapability = try await capability(
            recordingService.resolve(root: request(for: root, seed: 51))
        )
        let authority = await recordingService.makeSourceAuthority(
            capability: recordingCapability,
            observedRootEpoch: recordingCapability.rootEpoch,
            observedRepositoryAuthority: recordingCapability.repositoryAuthority,
            candidateRepositoryRelativePath: path,
            observedPathGeneration: 1,
            currentPathGeneration: 1,
            observedIngressGeneration: 1,
            currentIngressGeneration: 1
        )
        XCTAssertNotNil(authority)
        XCTAssertEqual(recorder.snapshot(), .init(callCount: 2, allPathsMatched: true))

        let symlinkTarget = root.appendingPathComponent("Sources/Target.swift")
        try "let target = true\n".write(to: symlinkTarget, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: candidateURL)
        try FileManager.default.createSymbolicLink(at: candidateURL, withDestinationURL: symlinkTarget)
        await assertNil(recordingService.makeSourceAuthority(
            capability: recordingCapability,
            observedRootEpoch: recordingCapability.rootEpoch,
            observedRepositoryAuthority: recordingCapability.repositoryAuthority,
            candidateRepositoryRelativePath: path,
            observedPathGeneration: 1,
            currentPathGeneration: 1,
            observedIngressGeneration: 1,
            currentIngressGeneration: 1
        ))

        try FileManager.default.removeItem(at: candidateURL)
        try "let value = 1\n".write(to: candidateURL, atomically: true, encoding: .utf8)

        let outsideDirectory = fixture.sandbox.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try "let escaped = true\n".write(
            to: outsideDirectory.appendingPathComponent("Escape.swift"),
            atomically: true,
            encoding: .utf8
        )
        let intermediateSymlink = root.appendingPathComponent("Sources/Intermediate")
        try FileManager.default.createSymbolicLink(
            at: intermediateSymlink,
            withDestinationURL: outsideDirectory
        )
        await assertNil(recordingService.makeSourceAuthority(
            capability: recordingCapability,
            observedRootEpoch: recordingCapability.rootEpoch,
            observedRepositoryAuthority: recordingCapability.repositoryAuthority,
            candidateRepositoryRelativePath: "Sources/Intermediate/Escape.swift",
            observedPathGeneration: 1,
            currentPathGeneration: 1,
            observedIngressGeneration: 1,
            currentIngressGeneration: 1
        ))

        let mutation = SourcePathMutation(url: candidateURL)
        let mutationService = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: namespaceSalt,
            hooks: WorkspaceCodemapGitCapabilityServiceHooks(
                afterSourcePathFingerprintCapture: { await mutation.mutateOnce() }
            )
        )
        let mutationCapability = try await capability(
            mutationService.resolve(root: request(for: root, seed: 52))
        )
        await assertNil(mutationService.makeSourceAuthority(
            capability: mutationCapability,
            observedRootEpoch: mutationCapability.rootEpoch,
            observedRepositoryAuthority: mutationCapability.repositoryAuthority,
            candidateRepositoryRelativePath: path,
            observedPathGeneration: 1,
            currentPathGeneration: 1,
            observedIngressGeneration: 1,
            currentIngressGeneration: 1
        ))

        let racedDirectory = root.appendingPathComponent("Sources/Raced", isDirectory: true)
        try FileManager.default.createDirectory(at: racedDirectory, withIntermediateDirectories: true)
        try "let raced = true\n".write(
            to: racedDirectory.appendingPathComponent("Race.swift"),
            atomically: true,
            encoding: .utf8
        )
        let intermediateReplacement = IntermediatePathReplacement(
            directory: racedDirectory,
            replacementTarget: outsideDirectory
        )
        let replacementService = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: namespaceSalt,
            hooks: WorkspaceCodemapGitCapabilityServiceHooks(
                afterSourcePathFingerprintCapture: { await intermediateReplacement.replaceOnce() }
            )
        )
        let replacementCapability = try await capability(
            replacementService.resolve(root: request(for: root, seed: 53))
        )
        await assertNil(replacementService.makeSourceAuthority(
            capability: replacementCapability,
            observedRootEpoch: replacementCapability.rootEpoch,
            observedRepositoryAuthority: replacementCapability.repositoryAuthority,
            candidateRepositoryRelativePath: "Sources/Raced/Race.swift",
            observedPathGeneration: 1,
            currentPathGeneration: 1,
            observedIngressGeneration: 1,
            currentIngressGeneration: 1
        ))
    }

    func testConcurrentSameRootResolutionCoalescesAndWaiterCancellationPreservesEligibleState() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try fixture.makeRepository(named: "repository")
        let gate = CapabilityResolutionGate()
        let service = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: namespaceSalt,
            hooks: WorkspaceCodemapGitCapabilityServiceHooks(
                beforeResolution: { await gate.enter() }
            )
        )
        let rootRequest = request(for: root, seed: 60)
        let initial = try await capability(service.resolve(root: rootRequest))
        await gate.setPaused(true)

        let first = Task { await service.resolve(root: rootRequest) }
        let second = Task { await service.resolve(root: rootRequest) }
        await waitForEntryCount(2, gate: gate)
        await waitForWaiterCount(2, service: service)

        first.cancel()
        await assertEqual(first.value, .eligible(initial))
        await waitForWaiterCount(1, service: service)
        await assertEqual(service.state(for: rootRequest.rootEpoch), .resolving(generation: 2))

        await gate.resumeAll()
        _ = try await capability(second.value)
        let snapshot = await service.snapshotForTesting()
        XCTAssertEqual(snapshot.activeFlightCount, 0)
        XCTAssertEqual(snapshot.waiterCount, 0)
        await assertEqual(gate.entryCount(), 2)
    }

    func testLastWaiterCancellationRestoresPriorStateAndStaleCompletionCannotPublish() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try fixture.makeRepository(named: "repository")
        let gate = CapabilityResolutionGate()
        await gate.setPaused(true)
        let service = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: namespaceSalt,
            hooks: WorkspaceCodemapGitCapabilityServiceHooks(
                beforeResolution: { await gate.enter() }
            )
        )
        let rootRequest = request(for: root, seed: 61)

        let task = Task { await service.resolve(root: rootRequest) }
        await waitForEntryCount(1, gate: gate)
        task.cancel()
        await assertEqual(task.value, .unresolved)
        await waitForWaiterCount(0, service: service)
        await assertEqual(service.state(for: rootRequest.rootEpoch), .unresolved)

        await gate.resumeAll()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await assertEqual(service.state(for: rootRequest.rootEpoch), .unresolved)
    }

    func testReleaseFencesStaleCompletionAndBoundsHistoricalStateWithoutEvictingActiveRoots() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let activeRoot = try fixture.makeRepository(named: "active")
        let gate = CapabilityResolutionGate()
        let service = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: namespaceSalt,
            hooks: WorkspaceCodemapGitCapabilityServiceHooks(
                beforeResolution: { await gate.enter() }
            ),
            historicalRecordLimit: 4
        )
        let activeRequest = request(for: activeRoot, seed: 70)
        let activeCapability = try await capability(service.resolve(root: activeRequest))

        let staleRoot = try fixture.makeRepository(named: "stale")
        let staleRequest = request(for: staleRoot, seed: 71)
        await gate.setPaused(true)
        let staleTask = Task { await service.resolve(root: staleRequest) }
        await waitForEntryCount(2, gate: gate)
        await service.release(rootEpoch: staleRequest.rootEpoch)
        await assertEqual(staleTask.value, .unresolved)
        await gate.resumeAll()
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        await assertEqual(
            service.state(for: staleRequest.rootEpoch),
            .terminalUnavailable(.releasedRootEpoch)
        )

        let plain = fixture.sandbox.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        var newestReleasedEpoch = staleRequest.rootEpoch
        for seed in UInt8(80) ..< UInt8(88) {
            let churnRequest = request(for: plain, seed: seed)
            _ = await service.resolve(root: churnRequest)
            await service.release(rootEpoch: churnRequest.rootEpoch)
            newestReleasedEpoch = churnRequest.rootEpoch
        }

        let snapshot = await service.snapshotForTesting()
        XCTAssertEqual(snapshot.activeRecordCount, 1)
        XCTAssertEqual(snapshot.historicalRecordCount, 4)
        await assertEqual(service.state(for: activeRequest.rootEpoch), .eligible(activeCapability))
        await assertEqual(
            service.state(for: newestReleasedEpoch),
            .terminalUnavailable(.releasedRootEpoch)
        )
    }

    func testGitLayoutCacheBoundsChurnAndRetainsSharedActiveEntryUntilFinalRelease() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let activeRoot = try fixture.makeRepository(named: "active")
        let gitService = GitService(worktreeLayoutCacheLimit: 3)
        let service = WorkspaceCodemapGitCapabilityService(
            gitService: gitService,
            namespaceSalt: namespaceSalt
        )
        let firstRequest = request(for: activeRoot, seed: 72)
        let secondRequest = request(for: activeRoot, seed: 73)
        _ = try await capability(service.resolve(root: firstRequest))
        _ = try await capability(service.resolve(root: secondRequest))

        for index in 0 ..< 8 {
            let root = try fixture.makeRepository(named: "churn-\(index)")
            _ = try await gitService.resolveGitBlobRepository(containing: root)
        }

        let activePath = activeRoot.standardizedFileURL.path
        var snapshot = await gitService.worktreeLayoutCacheSnapshotForTesting()
        XCTAssertLessThanOrEqual(snapshot.entryCount, 3)
        XCTAssertTrue(snapshot.paths.contains(activePath))
        XCTAssertTrue(snapshot.retainedPaths.contains(activePath))

        await gitService.clearLayoutCache()
        snapshot = await gitService.worktreeLayoutCacheSnapshotForTesting()
        XCTAssertEqual(snapshot.entryCount, 1)
        XCTAssertTrue(snapshot.retainedPaths.contains(activePath))
        XCTAssertTrue(snapshot.invalidatedPaths.contains(activePath))

        _ = try await capability(service.resolve(root: firstRequest))
        snapshot = await gitService.worktreeLayoutCacheSnapshotForTesting()
        XCTAssertTrue(snapshot.retainedPaths.contains(activePath))
        XCTAssertFalse(snapshot.invalidatedPaths.contains(activePath))

        await service.release(rootEpoch: firstRequest.rootEpoch)
        snapshot = await gitService.worktreeLayoutCacheSnapshotForTesting()
        XCTAssertTrue(snapshot.retainedPaths.contains(activePath))

        await service.release(rootEpoch: secondRequest.rootEpoch)
        snapshot = await gitService.worktreeLayoutCacheSnapshotForTesting()
        XCTAssertFalse(snapshot.paths.contains(activePath))
        XCTAssertLessThanOrEqual(snapshot.entryCount, 3)
    }

    func testRepositoryMutationDuringCaptureIsTransientAndRetryable() async throws {
        let fixture = try ReviewGitRepositoryFixture(name: #function)
        let root = try fixture.makeRepository(named: "repository")
        let mutation = AuthorityMutation(root: root)
        let service = WorkspaceCodemapGitCapabilityService(
            namespaceSalt: namespaceSalt,
            hooks: WorkspaceCodemapGitCapabilityServiceHooks(
                afterFirstAuthorityCapture: { await mutation.mutate() }
            )
        )
        let rootRequest = request(for: root, seed: 90)

        await assertTransient(
            service.resolve(root: rootRequest),
            reason: .repositoryChanging
        )
        await mutation.disable()
        _ = try await capability(service.resolve(root: rootRequest))
    }

    private func request(for root: URL, seed: UInt8) -> WorkspaceCodemapGitCapabilityRequest {
        WorkspaceCodemapGitCapabilityRequest(
            rootID: UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            rootLifetimeID: UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)),
            loadedRootURL: root
        )
    }

    private func capability(
        _ state: WorkspaceCodemapGitCapabilityState
    ) throws -> GitCodemapRootCapability {
        guard case let .eligible(capability) = state else {
            XCTFail("Expected eligible capability, received \(state)")
            throw NSError(domain: #function, code: 1)
        }
        return capability
    }

    private func assertEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertNil(
        _ value: (some Any)?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(value, file: file, line: line)
    }

    private func assertTransient(
        _ state: WorkspaceCodemapGitCapabilityState,
        reason: WorkspaceCodemapGitTransientUnavailableReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .transientUnavailable(actualReason, _) = state else {
            XCTFail("Expected transient \(reason), received \(state)", file: file, line: line)
            return
        }
        XCTAssertEqual(actualReason, reason, file: file, line: line)
    }

    private func fingerprint(at url: URL) throws -> GitBlobLStatFingerprint {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return GitBlobLStatFingerprint(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            mode: UInt16(value.st_mode),
            size: Int64(value.st_size),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changeSeconds: Int64(value.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }

    private func waitForEntryCount(_ expected: Int, gate: CapabilityResolutionGate) async {
        for _ in 0 ..< 500 {
            if await gate.entryCount() >= expected { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for \(expected) capability resolution entries")
    }

    private func waitForWaiterCount(
        _ expected: Int,
        service: WorkspaceCodemapGitCapabilityService
    ) async {
        for _ in 0 ..< 500 {
            if await service.snapshotForTesting().waiterCount == expected { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for \(expected) capability waiters")
    }

    private func fakeGitScript(topLevel: String) -> String {
        """
        #!/bin/sh
        case "$*" in
          *--show-toplevel*) printf '%s\\n' '\(topLevel)' ;;
          *) exit 1 ;;
        esac
        """
    }
}

private final class AuthorityEvidenceLeafReplacement: @unchecked Sendable {
    private let lock = NSLock()
    private let targetPath: String
    private let replacementContents: Data
    private var didReplace = false

    init(target: URL, replacementContents: Data) {
        targetPath = target.standardizedFileURL.path
        self.replacementContents = replacementContents
    }

    func replaceIfTarget(_ openedURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard !didReplace, openedURL.standardizedFileURL.path == targetPath else { return }
        didReplace = true
        try? replacementContents.write(to: URL(fileURLWithPath: targetPath), options: .atomic)
    }
}

private final class AuthorityEvidenceParentSymlinkSwap: @unchecked Sendable {
    private let lock = NSLock()
    private let targetDirectory: URL
    private let backupDirectory: URL
    private let triggerPath: String
    private let outsideDirectory: URL
    private var didSwap = false

    init(targetDirectory: URL, triggerFile: URL, outsideDirectory: URL) {
        self.targetDirectory = targetDirectory
        backupDirectory = targetDirectory.deletingLastPathComponent()
            .appendingPathComponent(targetDirectory.lastPathComponent + "-original", isDirectory: true)
        triggerPath = triggerFile.standardizedFileURL.path
        self.outsideDirectory = outsideDirectory
    }

    func swapIfTarget(_ openedURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard !didSwap, openedURL.standardizedFileURL.path == triggerPath else { return }
        didSwap = true
        try? FileManager.default.moveItem(at: targetDirectory, to: backupDirectory)
        try? FileManager.default.createSymbolicLink(
            at: targetDirectory,
            withDestinationURL: outsideDirectory
        )
    }
}

private actor CapabilityResolutionGate {
    private var paused = false
    private var entries = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func setPaused(_ paused: Bool) {
        self.paused = paused
    }

    func enter() async {
        entries += 1
        guard paused else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeAll() {
        paused = false
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func entryCount() -> Int {
        entries
    }
}

private actor AuthorityMutation {
    private let root: URL
    private var enabled = true
    private var sequence = 0

    init(root: URL) {
        self.root = root
    }

    func mutate() {
        guard enabled else { return }
        sequence += 1
        let marker = root.appendingPathComponent(".git/authority-race-\(sequence)")
        try? "race-\(sequence)\n".write(to: marker, atomically: true, encoding: .utf8)
    }

    func disable() {
        enabled = false
    }
}

private final class ExactPathFingerprintRecorder: @unchecked Sendable {
    struct Snapshot: Equatable {
        let callCount: Int
        let allPathsMatched: Bool
    }

    private let lock = NSLock()
    private let expectedPath: String
    private var callCount = 0
    private var allPathsMatched = true

    init(expectedURL: URL) {
        expectedPath = expectedURL.standardizedFileURL.path
    }

    var client: WorkspaceCodemapPathFingerprintClient {
        WorkspaceCodemapPathFingerprintClient { [self] repositoryRoot, relativePath in
            let candidateURL = repositoryRoot
                .appendingPathComponent(relativePath, isDirectory: false)
                .standardizedFileURL
            lock.lock()
            callCount += 1
            allPathsMatched = allPathsMatched && candidateURL.path == expectedPath
            lock.unlock()
            return try WorkspaceCodemapPathFingerprintClient.noFollow.fingerprint(
                repositoryRoot,
                relativePath
            )
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(callCount: callCount, allPathsMatched: allPathsMatched)
    }
}

private actor SourcePathMutation {
    private let url: URL
    private var didMutate = false

    init(url: URL) {
        self.url = url
    }

    func mutateOnce() {
        guard !didMutate else { return }
        didMutate = true
        try? "let value = 2\n".write(to: url, atomically: true, encoding: .utf8)
    }
}

private actor IntermediatePathReplacement {
    private let directory: URL
    private let replacementTarget: URL
    private var didReplace = false

    init(directory: URL, replacementTarget: URL) {
        self.directory = directory
        self.replacementTarget = replacementTarget
    }

    func replaceOnce() {
        guard !didReplace else { return }
        didReplace = true
        let retired = directory.deletingLastPathComponent()
            .appendingPathComponent("\(directory.lastPathComponent)-retired", isDirectory: true)
        try? FileManager.default.moveItem(at: directory, to: retired)
        try? FileManager.default.createSymbolicLink(
            at: directory,
            withDestinationURL: replacementTarget
        )
    }
}
