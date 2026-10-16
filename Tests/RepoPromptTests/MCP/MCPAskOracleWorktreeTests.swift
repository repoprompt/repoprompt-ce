import Darwin
import Dispatch
import Foundation
@testable import RepoPromptApp
import RepoPromptDomainRuntime
import RepoPromptWorkspaceCore
import XCTest

#if DEBUG
    @MainActor
    final class MCPAskOracleWorktreeTests: XCTestCase {
        func testOracleSendContextKeepsConversationOwnerSeparateFromDelegatedPackagingSource() throws {
            let childTabID = UUID()
            let childWorkspaceID = UUID()
            let childSessionID = UUID()
            let childRunID = UUID()
            let sourceTabID = UUID()
            let sourceSessionID = UUID()
            let sourceRunID = UUID()
            let delegationID = UUID()
            let sourceSelection = StoredSelection(
                selectedPaths: ["/tmp/source/Sources/Feature.swift"],
                codemapAutoEnabled: false
            )
            let sourceCapability = SelectedGitArtifactCapability(
                workspaceID: childWorkspaceID,
                workspaceDirectoryPath: "/tmp/workspace",
                gitDataRoot: WorkspaceRootRef(
                    id: UUID(),
                    name: "_git_data",
                    fullPath: "/tmp/workspace/_git_data"
                ),
                creatorTabID: sourceTabID,
                sessionID: sourceSessionID,
                boundCheckouts: [],
                canonicalWorkspaceRootPaths: ["/tmp/source"]
            )
            let sourceReviewContext = FrozenPromptGitReviewContext(
                artifactCapability: sourceCapability,
                compareIntent: .uncommittedHEAD,
                displayContext: ReviewGitDisplayContext(roots: [])
            )
            let capturedSource = AgentRunOracleReviewSource.Captured(
                delegationID: delegationID,
                sourceTabID: sourceTabID,
                workspaceID: childWorkspaceID,
                sourceSelectionRevision: 42,
                promptText: "source prompt",
                selection: sourceSelection,
                lookupContext: .visibleWorkspace,
                reviewGitContext: sourceReviewContext,
                sourceAgentSessionID: sourceSessionID,
                sourceAgentRunID: sourceRunID,
                sourceWorktreeBindings: []
            )
            let delegated = DelegatedAgentRunOracleReviewContext(
                source: .captured(capturedSource),
                target: AgentRunOracleReviewTargetSnapshot(
                    tabID: childTabID,
                    workspaceID: childWorkspaceID,
                    agentSessionID: childSessionID,
                    activationID: UUID(),
                    expectedParentSessionID: sourceSessionID,
                    worktreeBindings: [],
                    validationFailure: nil
                ),
                targetRunID: childRunID
            )
            let packaging = try OracleViewModel.OracleSendPackagingContext(delegated: delegated)
            let context = OracleViewModel.OracleSendTabContext(
                tabID: childTabID,
                workspaceID: childWorkspaceID,
                origin: .askOracle,
                agentModeSessionID: childSessionID,
                agentModeRunID: childRunID,
                packaging: packaging
            )

            XCTAssertEqual(context.tabID, childTabID)
            XCTAssertEqual(context.agentModeSessionID, childSessionID)
            XCTAssertEqual(context.agentModeRunID, childRunID)
            XCTAssertEqual(context.packaging.sourceTabID, sourceTabID)
            XCTAssertEqual(context.packaging.sourceAgentSessionID, sourceSessionID)
            XCTAssertEqual(context.packaging.sourceAgentRunID, sourceRunID)
            XCTAssertEqual(context.packaging.selection, sourceSelection)
            XCTAssertEqual(context.packaging.provenance, .delegated(delegationID: delegationID))
            guard case let .delegated(artifactDelegation) = try XCTUnwrap(
                context.packaging.reviewGitContext.artifactCapability
            ).access else {
                return XCTFail("Expected delegated artifact capability")
            }
            XCTAssertEqual(artifactDelegation.sourceTabID, sourceTabID)
            XCTAssertEqual(artifactDelegation.targetTabID, childTabID)
            XCTAssertEqual(artifactDelegation.targetAgentSessionID, childSessionID)
            XCTAssertEqual(artifactDelegation.targetAgentRunID, childRunID)
            XCTAssertEqual(
                context.packaging.reviewGitContext.artifactDelegationConsumer,
                SelectedGitArtifactDelegationConsumer(
                    workspaceID: childWorkspaceID,
                    tabID: childTabID,
                    agentSessionID: childSessionID,
                    agentRunID: childRunID,
                    boundCheckouts: []
                )
            )
        }

        func testExplicitOracleContinuationRequiresExactAgentSessionAndRunOwner() {
            let tabID = UUID()
            let sessionID = UUID()
            let runID = UUID()
            let owned = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: runID
            )
            let unownedLegacy = ChatSession(composeTabID: tabID)

            XCTAssertTrue(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: sessionID,
                    agentModeRunID: UUID()
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: UUID(),
                    agentModeRunID: runID
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    unownedLegacy,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: nil,
                    agentModeRunID: nil
                )
            )
            XCTAssertFalse(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    owned,
                    agentModeSessionID: sessionID,
                    agentModeRunID: nil
                )
            )
            XCTAssertTrue(
                OracleViewModel.sessionMatchesOracleOwnerForExplicitContinuation(
                    unownedLegacy,
                    agentModeSessionID: nil,
                    agentModeRunID: nil
                )
            )
        }

        func testOracleLogLookupDoesNotAdoptLegacyOrSiblingRun() {
            let tabID = UUID()
            let sessionID = UUID()
            let runID = UUID()
            let exact = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: runID,
                savedAt: Date(timeIntervalSince1970: 1)
            )
            let newerSibling = ChatSession(
                composeTabID: tabID,
                agentModeSessionID: sessionID,
                agentModeRunID: UUID(),
                savedAt: Date(timeIntervalSince1970: 3)
            )
            let newestLegacy = ChatSession(
                composeTabID: tabID,
                savedAt: Date(timeIntervalSince1970: 4)
            )

            XCTAssertEqual(
                OracleViewModel.test_preferredOracleLogSession(
                    forTabID: tabID,
                    sessions: [newestLegacy, newerSibling, exact],
                    activeSessionID: newestLegacy.id,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )?.id,
                exact.id
            )
            XCTAssertNil(
                OracleViewModel.test_preferredOracleLogSession(
                    forTabID: tabID,
                    sessions: [newestLegacy, newerSibling],
                    activeSessionID: newestLegacy.id,
                    agentModeSessionID: sessionID,
                    agentModeRunID: runID
                )
            )
        }
    }
#endif

final class OracleImageAttachmentLoaderTests: XCTestCase {
    private var testRoot: URL!

    override func setUpWithError() throws {
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("oracle-image-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
    }

    func testRootCaptureRejectsSymlinkSubstitutionBeforeAcquisition() throws {
        for substituteAncestor in [false, true] {
            let fixture = testRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let ancestor = fixture.appendingPathComponent("ancestor", isDirectory: true)
            let root = ancestor.appendingPathComponent("root", isDirectory: true)
            let outside = fixture.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside.appendingPathComponent("root"), withIntermediateDirectories: true)
            // Prove acquisition works before substitution, so rejection cannot be vacuous.
            _ = try OracleImagePhysicalRootCapture.capture(physicalRootPath: root.path, index: 0)
            let substituted = substituteAncestor ? ancestor : root
            let target = substituteAncestor ? outside : outside.appendingPathComponent("root")
            XCTAssertThrowsError(try OracleImagePhysicalRootCapture.capture(
                physicalRootPath: root.path,
                index: 0,
                beforeAcquiringResolvedRoot: {
                    try FileManager.default.moveItem(at: substituted, to: fixture.appendingPathComponent("original"))
                    try FileManager.default.createSymbolicLink(at: substituted, withDestinationURL: target)
                }
            )) { error in
                XCTAssertEqual(error as? OracleImageLoadError, .unsafePath(index: 0))
            }
        }
    }

    func testRootCaptureLoadsThroughSearchOnlyAncestorAndPrivatePath() throws {
        let ancestor = testRoot.appendingPathComponent("search-only", isDirectory: true)
        let root = ancestor.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("image.png")
        try Self.pngData.write(to: image)
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: ancestor.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ancestor.path) }
        let projection = try OracleImagePhysicalRootCapture.capture(physicalRootPath: root.path, index: 0)
            .projection(logicalRootPath: root.path)
        XCTAssertTrue(projection.resolvedPhysicalRootPath.hasPrefix("/private/"))
        let privateCapture = try OracleImagePhysicalRootCapture.capture(
            physicalRootPath: projection.resolvedPhysicalRootPath,
            index: 0
        )
        XCTAssertEqual(privateCapture.rootIdentity, projection.rootIdentity)
        let images = try OracleImageAttachmentLoader().load(
            requests: [.init(index: 0, path: image.path, title: nil)],
            authority: OracleImageWorkspaceAuthority(roots: [projection])
        )
        XCTAssertEqual(images.first?.bytes, Self.pngData)
    }

    func testLoadsClassicFormatsAndPreservesOrderWithoutPaths() throws {
        let fixtures: [(String, Data, AIImageMediaType)] = [
            ("one.png", Self.pngData, .png),
            ("two.JPG", Self.jpegData, .jpeg),
            ("three.gif", Self.gifData, .gif),
            ("four.webp", Self.webpData, .webp)
        ]
        let requests = try fixtures.enumerated().map { index, fixture in
            let url = testRoot.appendingPathComponent(fixture.0)
            try fixture.1.write(to: url)
            return OracleImageRequest(index: index, path: url.path, title: "Image \(index + 1)")
        }

        let images = try OracleImageAttachmentLoader().load(
            requests: requests,
            authority: authority(logical: testRoot, physical: testRoot)
        )

        XCTAssertEqual(images.map(\.mediaType), fixtures.map(\.2))
        XCTAssertEqual(images.map(\.bytes), fixtures.map(\.1))
        XCTAssertEqual(images.map(\.title), ["Image 1", "Image 2", "Image 3", "Image 4"])
    }

    func testLogicalPathReadsBoundPhysicalWorktreeFile() throws {
        let logicalRoot = testRoot.appendingPathComponent("logical", isDirectory: true)
        let physicalRoot = testRoot.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: logicalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: physicalRoot, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: logicalRoot.appendingPathComponent("asset.png"))
        try Self.pngData.write(to: physicalRoot.appendingPathComponent("asset.png"))

        let images = try OracleImageAttachmentLoader().load(
            requests: [.init(
                index: 0,
                path: logicalRoot.appendingPathComponent("asset.png").path,
                title: nil
            )],
            authority: authority(logical: logicalRoot, physical: physicalRoot)
        )

        XCTAssertEqual(images.first?.bytes, Self.pngData)
    }

    func testRejectsNonCanonicalOutsideAndSymlinkPathsWithoutLeakingThem() throws {
        let imageURL = testRoot.appendingPathComponent("image.png")
        try Self.pngData.write(to: imageURL)
        let linkURL = testRoot.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: imageURL)
        let siblingURL = testRoot.deletingLastPathComponent().appendingPathComponent("outside-\(UUID()).png")
        try Self.pngData.write(to: siblingURL)
        defer { try? FileManager.default.removeItem(at: siblingURL) }

        let cases = [
            "relative.png",
            testRoot.appendingPathComponent("folder/../image.png").path,
            siblingURL.path,
            linkURL.path
        ]
        for path in cases {
            XCTAssertThrowsError(try OracleImageAttachmentLoader().load(
                requests: [.init(index: 0, path: path, title: nil)],
                authority: authority(logical: testRoot, physical: testRoot)
            )) { error in
                XCTAssertFalse(error.localizedDescription.contains(testRoot.path))
                XCTAssertFalse(error.localizedDescription.contains("image.png"))
                XCTAssertFalse(error.localizedDescription.contains("link.png"))
            }
        }
    }

    func testAllowsSymlinkedTrustedRootButRejectsSymlinksBelowIt() throws {
        let actualRoot = testRoot.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actualRoot, withIntermediateDirectories: true)
        try Self.gifData.write(to: actualRoot.appendingPathComponent("image.gif"))

        let trustedRoot = testRoot.appendingPathComponent("trusted-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: trustedRoot, withDestinationURL: actualRoot)
        let pinnedAuthority = try authority(logical: trustedRoot, physical: trustedRoot)
        let images = try OracleImageAttachmentLoader().load(
            requests: [.init(
                index: 0,
                path: trustedRoot.appendingPathComponent("image.gif").path,
                title: nil
            )],
            authority: pinnedAuthority
        )
        XCTAssertEqual(images.first?.bytes, Self.gifData)

        let retargetedRoot = testRoot.appendingPathComponent("retargeted", isDirectory: true)
        try FileManager.default.createDirectory(at: retargetedRoot, withIntermediateDirectories: true)
        let retargetedData = Data(Array("GIF87a".utf8) + [2, 0, 1, 0])
        try retargetedData.write(to: retargetedRoot.appendingPathComponent("image.gif"))
        try FileManager.default.removeItem(at: trustedRoot)
        try FileManager.default.createSymbolicLink(at: trustedRoot, withDestinationURL: retargetedRoot)
        let pinnedImages = try OracleImageAttachmentLoader().load(
            requests: [.init(
                index: 0,
                path: trustedRoot.appendingPathComponent("image.gif").path,
                title: nil
            )],
            authority: pinnedAuthority
        )
        XCTAssertEqual(pinnedImages.first?.bytes, Self.gifData)

        let realDirectory = actualRoot.appendingPathComponent("real-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        try Self.gifData.write(to: realDirectory.appendingPathComponent("nested.gif"))
        try FileManager.default.createSymbolicLink(
            at: actualRoot.appendingPathComponent("linked-directory", isDirectory: true),
            withDestinationURL: realDirectory
        )
        XCTAssertThrowsError(try OracleImageAttachmentLoader().load(
            requests: [.init(
                index: 0,
                path: trustedRoot.appendingPathComponent("linked-directory/nested.gif").path,
                title: nil
            )],
            authority: pinnedAuthority
        )) { error in
            guard let loadError = error as? OracleImageLoadError else {
                return XCTFail("Expected OracleImageLoadError, got \(error)")
            }
            XCTAssertTrue(
                loadError == .unsafePath(index: 0)
                    || loadError == .missingOrUnreadable(index: 0)
            )
        }
    }

    func testParentCancellationCancelsDetachedLoad() async throws {
        let imageURL = testRoot.appendingPathComponent("cancel.gif")
        try Self.gifData.write(to: imageURL)
        let authority = try authority(logical: testRoot, physical: testRoot)
        let started = DispatchSemaphore(value: 0)
        let loader = OracleImageAttachmentLoader(afterFirstRead: { _ in
            started.signal()
            let deadline = Date().addingTimeInterval(2)
            while !Task.isCancelled, Date() < deadline {
                Darwin.usleep(1000)
            }
            guard Task.isCancelled else {
                throw CancellationProbeError.notPropagated
            }
            throw CancellationError()
        })
        let task = Task {
            try await OracleImageAttachmentLoader.loadDetached(
                requests: [.init(index: 0, path: imageURL.path, title: nil)],
                authority: authority,
                loader: loader
            )
        }

        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: parent cancellation reached detached loader work.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testEnforcesPerImageAndTotalLimitsBeforeReturningPayloads() throws {
        let firstURL = testRoot.appendingPathComponent("first.gif")
        let secondURL = testRoot.appendingPathComponent("second.gif")
        try Self.gifData.write(to: firstURL)
        try Self.gifData.write(to: secondURL)

        let requests: [OracleImageRequest] = [
            .init(index: 0, path: firstURL.path, title: nil),
            .init(index: 1, path: secondURL.path, title: nil)
        ]
        let images = try OracleImageAttachmentLoader(
            limits: .init(
                maxCount: requests.count,
                maxBytesPerImage: Self.gifData.count,
                maxTotalBytes: Self.gifData.count * 2
            )
        ).load(
            requests: requests,
            authority: authority(logical: testRoot, physical: testRoot)
        )
        XCTAssertEqual(images.map(\.bytes), [Self.gifData, Self.gifData])
        XCTAssertEqual(images.map(\.mediaType), [.gif, .gif])

        XCTAssertThrowsError(try OracleImageAttachmentLoader(
            limits: .init(maxCount: 10, maxBytesPerImage: Self.gifData.count - 1, maxTotalBytes: 100),
            afterFirstRead: { _ in XCTFail("Oversized image must be rejected before reading bytes") }
        ).load(
            requests: [.init(index: 0, path: firstURL.path, title: nil)],
            authority: authority(logical: testRoot, physical: testRoot)
        )) { error in
            XCTAssertEqual(
                error as? OracleImageLoadError,
                .tooLarge(index: 0, maximumBytes: Self.gifData.count - 1)
            )
        }

        XCTAssertThrowsError(try OracleImageAttachmentLoader(
            limits: .init(
                maxCount: 10,
                maxBytesPerImage: Self.gifData.count,
                maxTotalBytes: Self.gifData.count * 2 - 1
            ),
            afterFirstRead: { _ in XCTFail("Oversized aggregate must be rejected before reading any image bytes") }
        ).load(
            requests: [
                .init(index: 0, path: firstURL.path, title: nil),
                .init(index: 1, path: secondURL.path, title: nil)
            ],
            authority: authority(logical: testRoot, physical: testRoot)
        )) { error in
            XCTAssertEqual(
                error as? OracleImageLoadError,
                .totalTooLarge(maximumBytes: Self.gifData.count * 2 - 1)
            )
        }
    }

    func testJPEGDetectionIsByteLevelAndToleratesTrailingBytes() throws {
        // Legal JPEGs may carry padding or appended metadata after the EOI marker; the loader
        // performs format sniffing (SOI + marker), not full decodability validation.
        let paddedJPEGURL = testRoot.appendingPathComponent("padded.jpg")
        try (Self.jpegData + Data([0x00, 0x00, 0xAA])).write(to: paddedJPEGURL)
        let truncatedJPEGURL = testRoot.appendingPathComponent("truncated.jpg")
        try Self.jpegData.dropLast(2).write(to: truncatedJPEGURL)

        let images = try OracleImageAttachmentLoader().load(
            requests: [
                .init(index: 0, path: paddedJPEGURL.path, title: nil),
                .init(index: 1, path: truncatedJPEGURL.path, title: nil)
            ],
            authority: authority(logical: testRoot, physical: testRoot)
        )
        XCTAssertEqual(images.map(\.mediaType), [.jpeg, .jpeg])
        XCTAssertEqual(images[0].bytes, Self.jpegData + Data([0x00, 0x00, 0xAA]))
    }

    func testDecodableMinimalPNGPassesFormatSniffing() throws {
        // A real 1x1 PNG fixture (valid IHDR/IDAT/IEND), not just a magic-byte header.
        let pngURL = testRoot.appendingPathComponent("pixel.png")
        try Self.realPNGData.write(to: pngURL)

        let images = try OracleImageAttachmentLoader().load(
            requests: [.init(index: 0, path: pngURL.path, title: nil)],
            authority: authority(logical: testRoot, physical: testRoot)
        )
        XCTAssertEqual(images.first?.mediaType, .png)
        XCTAssertEqual(images.first?.bytes, Self.realPNGData)
    }

    func testDeriveAuthorityIsolatesUnavailableRootsPerImage() throws {
        let missingRoot = testRoot.appendingPathComponent("missing-root", isDirectory: true)
        let authority = try OracleImageAttachmentLoader.deriveAuthority(rootSpecs: [
            OracleImageRootSpec(
                physicalRootPath: testRoot.path,
                logicalRootPaths: [testRoot.path]
            ),
            OracleImageRootSpec(
                physicalRootPath: missingRoot.path,
                logicalRootPaths: [missingRoot.path, testRoot.appendingPathComponent("alias").path]
            )
        ])
        XCTAssertEqual(authority.roots.count, 1)
        XCTAssertEqual(authority.unavailableRoots.count, 1)

        let imageURL = testRoot.appendingPathComponent("image.png")
        try Self.pngData.write(to: imageURL)
        let images = try OracleImageAttachmentLoader().load(
            requests: [.init(index: 0, path: imageURL.path, title: nil)],
            authority: authority
        )
        XCTAssertEqual(images.first?.bytes, Self.pngData)

        // A path under the unavailable root fails closed with an accurate per-image error.
        XCTAssertThrowsError(try OracleImageAttachmentLoader().load(
            requests: [.init(
                index: 7,
                path: missingRoot.appendingPathComponent("image.png").path,
                title: nil
            )],
            authority: authority
        )) { error in
            XCTAssertEqual(error as? OracleImageLoadError, .missingOrUnreadable(index: 7))
        }
        // Unrelated paths still fail as outside authority.
        XCTAssertThrowsError(try OracleImageAttachmentLoader().load(
            requests: [.init(index: 3, path: "/nonexistent-outside/image.png", title: nil)],
            authority: authority
        )) { error in
            XCTAssertEqual(error as? OracleImageLoadError, .outsideAuthority(index: 3))
        }
    }

    func testUnavailableNestedBindingFailsInsteadOfFallingBackToBroaderRoot() throws {
        // The nested binding's physical root is missing, but the same logical path also
        // exists inside the available parent. The unavailable binding is more specific, so
        // it must win the request and fail — not silently load the parent's copy.
        let nestedLogical = testRoot.appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedLogical, withIntermediateDirectories: true)
        try Self.pngData.write(to: nestedLogical.appendingPathComponent("diagram.png"))
        let missingPhysical = testRoot.appendingPathComponent("missing-worktree", isDirectory: true)

        let authority = try OracleImageAttachmentLoader.deriveAuthority(rootSpecs: [
            OracleImageRootSpec(
                physicalRootPath: testRoot.path,
                logicalRootPaths: [testRoot.path]
            ),
            OracleImageRootSpec(
                physicalRootPath: missingPhysical.path,
                logicalRootPaths: [nestedLogical.path]
            )
        ])
        XCTAssertEqual(authority.roots.count, 1)
        XCTAssertEqual(authority.unavailableRoots.count, 1)

        XCTAssertThrowsError(try OracleImageAttachmentLoader().load(
            requests: [.init(
                index: 4,
                path: nestedLogical.appendingPathComponent("diagram.png").path,
                title: nil
            )],
            authority: authority
        )) { error in
            XCTAssertEqual(error as? OracleImageLoadError, .missingOrUnreadable(index: 4))
        }
    }

    func testUnavailableBindingAtEqualSpecificityFailsClosed() throws {
        // An available root and a failed binding claim the same logical prefix. The conflict
        // is ambiguous, so the request fails rather than trusting the available root.
        let missingPhysical = testRoot.appendingPathComponent("missing-worktree", isDirectory: true)
        let authority = try OracleImageAttachmentLoader.deriveAuthority(rootSpecs: [
            OracleImageRootSpec(
                physicalRootPath: testRoot.path,
                logicalRootPaths: [testRoot.path]
            ),
            OracleImageRootSpec(
                physicalRootPath: missingPhysical.path,
                logicalRootPaths: [testRoot.path]
            )
        ])
        XCTAssertEqual(authority.roots.count, 1)
        XCTAssertEqual(authority.unavailableRoots.count, 1)

        let imageURL = testRoot.appendingPathComponent("image.png")
        try Self.pngData.write(to: imageURL)
        XCTAssertThrowsError(try OracleImageAttachmentLoader().load(
            requests: [.init(index: 2, path: imageURL.path, title: nil)],
            authority: authority
        )) { error in
            XCTAssertEqual(error as? OracleImageLoadError, .missingOrUnreadable(index: 2))
        }
    }

    func testRejectsExtensionMismatchAndFileReplacementDuringRead() throws {
        let mismatchURL = testRoot.appendingPathComponent("wrong.jpg")
        try Self.pngData.write(to: mismatchURL)
        XCTAssertThrowsError(try OracleImageAttachmentLoader().load(
            requests: [.init(index: 0, path: mismatchURL.path, title: nil)],
            authority: authority(logical: testRoot, physical: testRoot)
        )) { error in
            XCTAssertEqual(
                error as? OracleImageLoadError,
                .extensionMismatch(index: 0, mediaType: .png)
            )
        }

        let changingURL = testRoot.appendingPathComponent("changing.gif")
        try Self.gifData.write(to: changingURL)
        let replacement = Data(Array("GIF87a".utf8) + [2, 0, 1, 0])
        let loader = OracleImageAttachmentLoader(afterFirstRead: { _ in
            try replacement.write(to: changingURL, options: .atomic)
        })
        XCTAssertThrowsError(try loader.load(
            requests: [.init(index: 0, path: changingURL.path, title: nil)],
            authority: authority(logical: testRoot, physical: testRoot)
        )) { error in
            XCTAssertEqual(error as? OracleImageLoadError, .changedWhileReading(index: 0))
        }
    }

    func testPhysicalRootCapturePinsEveryAliasToOneIdentity() throws {
        let originalRoot = testRoot.appendingPathComponent("original", isDirectory: true)
        let retargetedRoot = testRoot.appendingPathComponent("retargeted", isDirectory: true)
        try FileManager.default.createDirectory(at: originalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retargetedRoot, withIntermediateDirectories: true)
        try Self.gifData.write(to: originalRoot.appendingPathComponent("image.gif"))
        let replacement = Data(Array("GIF87a".utf8) + [2, 0, 1, 0])
        try replacement.write(to: retargetedRoot.appendingPathComponent("image.gif"))

        let trustedRoot = testRoot.appendingPathComponent("trusted-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: trustedRoot, withDestinationURL: originalRoot)
        let capture = try OracleImagePhysicalRootCapture.capture(
            physicalRootPath: trustedRoot.path,
            index: 0
        )
        let firstAlias = testRoot.appendingPathComponent("alias-a", isDirectory: true)
        let firstProjection = capture.projection(logicalRootPath: firstAlias.path)

        try FileManager.default.removeItem(at: trustedRoot)
        try FileManager.default.createSymbolicLink(at: trustedRoot, withDestinationURL: retargetedRoot)
        let secondAlias = testRoot.appendingPathComponent("alias-b", isDirectory: true)
        let secondProjection = capture.projection(logicalRootPath: secondAlias.path)

        XCTAssertEqual(firstProjection.rootIdentity, secondProjection.rootIdentity)
        XCTAssertEqual(firstProjection.resolvedPhysicalRootPath, secondProjection.resolvedPhysicalRootPath)

        let images = try OracleImageAttachmentLoader().load(
            requests: [
                .init(index: 0, path: firstAlias.appendingPathComponent("image.gif").path, title: nil),
                .init(index: 1, path: secondAlias.appendingPathComponent("image.gif").path, title: nil),
                .init(index: 2, path: trustedRoot.appendingPathComponent("image.gif").path, title: nil)
            ],
            authority: OracleImageWorkspaceAuthority(roots: [
                firstProjection,
                secondProjection,
                capture.projection(logicalRootPath: trustedRoot.path)
            ])
        )
        XCTAssertEqual(images.map(\.bytes), [Self.gifData, Self.gifData, Self.gifData])
    }

    func testSessionAttachmentAuthorizesOnlyThatExactFileOutsideWorkspaceRoots() throws {
        let workspaceRoot = testRoot.appendingPathComponent("workspace", isDirectory: true)
        let store = testRoot.appendingPathComponent("agent_attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let attached = store.appendingPathComponent("ATTACHED.png")
        let sibling = store.appendingPathComponent("OTHER-SESSION.png")
        let outside = testRoot.appendingPathComponent("outside.png")
        try Self.pngData.write(to: attached)
        try Self.gifData.write(to: sibling)
        try Self.pngData.write(to: outside)

        let authority = try OracleImageAttachmentLoader.deriveAuthority(
            rootSpecs: [OracleImageRootSpec(physicalRootPath: workspaceRoot.path, logicalRootPaths: [workspaceRoot.path])],
            sessionAttachmentPaths: [attached.path]
        )

        let images = try OracleImageAttachmentLoader().load(
            requests: [.init(index: 0, path: attached.path, title: nil)],
            authority: authority
        )
        XCTAssertEqual(images.map(\.bytes), [Self.pngData])

        // The temp directory is reached through /var -> /private/var; both spellings name the file.
        let resolvedAttached = attached.resolvingSymlinksInPath().path
        XCTAssertEqual(
            try OracleImageAttachmentLoader().load(
                requests: [.init(index: 0, path: resolvedAttached, title: nil)],
                authority: authority
            ).map(\.bytes),
            [Self.pngData]
        )

        // Neither another file in the same managed store nor an arbitrary outside path is authorized.
        for (index, url) in [sibling, outside].enumerated() {
            XCTAssertThrowsError(try OracleImageAttachmentLoader().load(
                requests: [.init(index: index, path: url.path, title: nil)],
                authority: authority
            )) { error in
                XCTAssertEqual(error as? OracleImageLoadError, .outsideAuthority(index: index))
            }
        }
        // Without the session allowance, the attached file itself is outside authority too.
        let rootsOnly = try OracleImageAttachmentLoader.deriveAuthority(rootSpecs: [
            OracleImageRootSpec(physicalRootPath: workspaceRoot.path, logicalRootPaths: [workspaceRoot.path])
        ])
        XCTAssertThrowsError(try OracleImageAttachmentLoader().load(
            requests: [.init(index: 0, path: attached.path, title: nil)],
            authority: rootsOnly
        )) { error in
            XCTAssertEqual(error as? OracleImageLoadError, .outsideAuthority(index: 0))
        }
    }

    func testSessionAttachmentReplacedBySymlinkIsRejected() throws {
        let store = testRoot.appendingPathComponent("agent_attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let attached = store.appendingPathComponent("ATTACHED.png")
        let target = testRoot.appendingPathComponent("secret.png")
        try Self.pngData.write(to: target)
        try FileManager.default.createSymbolicLink(at: attached, withDestinationURL: target)

        let authority = try OracleImageAttachmentLoader.deriveAuthority(
            rootSpecs: [],
            sessionAttachmentPaths: [attached.path]
        )
        XCTAssertThrowsError(try OracleImageAttachmentLoader().load(
            requests: [.init(index: 0, path: attached.path, title: nil)],
            authority: authority
        ))
    }

    private func authority(logical: URL, physical: URL) throws -> OracleImageWorkspaceAuthority {
        let capture = try OracleImagePhysicalRootCapture.capture(
            physicalRootPath: physical.path,
            index: 0
        )
        return OracleImageWorkspaceAuthority(roots: [
            capture.projection(logicalRootPath: logical.path)
        ])
    }

    private enum CancellationProbeError: Error {
        case notPropagated
    }

    private static let pngData: Data = {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += [0, 0, 0, 13]
        bytes += Array("IHDR".utf8)
        bytes += Array(repeating: 0, count: 17)
        return Data(bytes)
    }()

    /// A genuine 1x1 transparent PNG (signature + IHDR + IDAT + IEND).
    private static let realPNGData = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    )!

    private static let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0xFF, 0xD9])
    private static let gifData = Data(Array("GIF89a".utf8) + [1, 0, 1, 0])
    private static let webpData = Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WEBPVP8 ".utf8))
}
