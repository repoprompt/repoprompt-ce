import CryptoKit
import Darwin
import Foundation
@testable import RepoPrompt
import XCTest

final class CodeMapArtifactContainerTests: XCTestCase {
    func testAllDeterministicOutcomesRoundTripThroughFixedContainer() throws {
        let key = try makeKey(sourceText: "all outcomes")
        let outcomes: [CodeMapSyntaxArtifactOutcome] = [
            .ready(makeArtifact()),
            .readyNoSymbols,
            .oversize(.utf8Bytes(actual: 20, limit: 10)),
            .oversize(.utf16Units(actual: 30, limit: 20)),
            .oversize(.lines(actual: 40, limit: 30)),
            .decodeFailed(.undecodable),
            .parseFailed(.parserReturnedNilTree),
            .parseFailed(.parserReturnedNilRoot)
        ]

        for outcome in outcomes {
            let encoded = try CodeMapArtifactContainer.encode(key: key, outcome: outcome)
            XCTAssertEqual(encoded.prefix(CodeMapArtifactContainer.magic.count), CodeMapArtifactContainer.magic)
            XCTAssertEqual(readUInt32(encoded, at: 16), CodeMapArtifactContainer.containerVersion)
            let decoded = try CodeMapArtifactContainer.decode(
                encoded,
                expectedKey: key,
                filenameDigest: key.storageDigestHex
            )
            XCTAssertEqual(decoded.key, key)
            XCTAssertEqual(decoded.outcome, outcome)
            XCTAssertEqual(decoded.containerByteCount, encoded.count)
            XCTAssertGreaterThan(decoded.payloadByteCount, 0)
            XCTAssertEqual(
                try CodeMapArtifactContainer.encode(key: decoded.key, outcome: decoded.outcome),
                encoded
            )
        }
    }

    func testStrictFramingRejectsKeySchemaKindLengthChecksumSummaryAndPayloadFaults() throws {
        let key = try makeKey(sourceText: "strict framing")
        let otherKey = try makeKey(sourceText: "other key")
        let canonical = try CodeMapArtifactContainer.encode(key: key, outcome: .ready(makeArtifact()))
        let layout = parseLayout(canonical)

        var wrongMagic = canonical
        wrongMagic[0] ^= 0xFF
        assertDecode(wrongMagic, key: key, throws: .invalidMagic)

        var wrongVersion = canonical
        replaceUInt32(&wrongVersion, at: 16, with: 2)
        assertDecode(wrongVersion, key: key, throws: .unsupportedContainerVersion)

        var wrongHeaderLength = canonical
        replaceUInt32(&wrongHeaderLength, at: 20, with: UInt32.max)
        assertDecode(wrongHeaderLength, key: key, throws: .invalidHeaderLength)

        var wrongKeyLength = canonical
        replaceUInt32(&wrongKeyLength, at: 24, with: UInt32.max)
        assertDecode(wrongKeyLength, key: key, throws: .invalidKeyLength)

        var invalidKey = canonical
        invalidKey[layout.keyOffset] ^= 0xFF
        assertDecode(invalidKey, key: key, throws: .invalidCanonicalKey)

        assertDecode(canonical, key: otherKey, filenameDigest: otherKey.storageDigestHex, throws: .keyMismatch)
        assertDecode(canonical, key: key, filenameDigest: String(repeating: "a", count: 64), throws: .filenameDigestMismatch)
        assertDecode(canonical, key: key, filenameDigest: key.storageDigestHex.uppercased(), throws: .filenameDigestMismatch)

        var wrongSchema = canonical
        replaceUInt32(&wrongSchema, at: layout.schemaOffset, with: key.pipelineIdentity.artifactSchemaVersion + 1)
        assertDecode(wrongSchema, key: key, throws: .schemaMismatch)

        var invalidKind = canonical
        invalidKind[layout.kindOffset] = 0xFF
        assertDecode(invalidKind, key: key, throws: .invalidOutcomeKind)

        var mismatchedKind = canonical
        mismatchedKind[layout.kindOffset] = 2
        assertDecode(mismatchedKind, key: key, throws: .outcomeKindMismatch)

        var hugePayload = canonical
        replaceUInt64(&hugePayload, at: layout.payloadLengthOffset, with: UInt64.max)
        assertDecode(hugePayload, key: key, throws: .invalidPayloadLength)

        var wrongChecksum = canonical
        wrongChecksum[layout.checksumOffset] ^= 0xFF
        assertDecode(wrongChecksum, key: key, throws: .checksumMismatch)

        var wrongSummaryVersion = canonical
        replaceUInt32(&wrongSummaryVersion, at: layout.summaryVersionOffset, with: 2)
        assertDecode(wrongSummaryVersion, key: key, throws: .invalidSummary)

        var wrongSummaryCount = canonical
        replaceUInt32(&wrongSummaryCount, at: layout.summaryCountOffset, with: 19)
        assertDecode(wrongSummaryCount, key: key, throws: .invalidSummary)

        var wrongSummaryValue = canonical
        replaceUInt64(&wrongSummaryValue, at: layout.summaryFieldsOffset, with: 999)
        assertDecode(wrongSummaryValue, key: key, throws: .invalidSummary)

        var malformedPayload = canonical
        malformedPayload[layout.headerByteCount] = UInt8(ascii: "[")
        rewritePayloadChecksum(&malformedPayload, layout: layout)
        assertDecode(malformedPayload, key: key, throws: .payloadDecodeFailed)

        let noncanonicalPayload = canonical.subdata(in: layout.headerByteCount ..< canonical.count) + Data([0x20])
        var noncanonical = canonical.prefix(layout.headerByteCount) + noncanonicalPayload
        replaceUInt64(&noncanonical, at: layout.payloadLengthOffset, with: UInt64(noncanonicalPayload.count))
        rewritePayloadChecksum(&noncanonical, layout: parseLayout(noncanonical))
        assertDecode(noncanonical, key: key, throws: .nonCanonicalPayload)
    }

    func testStrictFramingRejectsEveryTruncationTrailingBytesAndConfiguredBounds() throws {
        let key = try makeKey(sourceText: "bounded framing")
        let canonical = try CodeMapArtifactContainer.encode(key: key, outcome: .ready(makeArtifact()))
        for byteCount in 0 ..< canonical.count {
            XCTAssertThrowsError(
                try CodeMapArtifactContainer.decode(
                    Data(canonical.prefix(byteCount)),
                    expectedKey: key,
                    filenameDigest: key.storageDigestHex
                )
            )
        }
        assertDecode(canonical + Data([0]), key: key, throws: .trailingBytes)

        let payloadBound = CodeMapArtifactContainerPolicy(
            maximumPayloadByteCount: 1,
            maximumContainerByteCount: 64 * 1024
        )
        assertDecode(canonical, key: key, policy: payloadBound, throws: .invalidPayloadLength)

        let collectionBound = CodeMapArtifactContainerPolicy(
            maximumCollectionEntryCount: 1
        )
        assertDecode(canonical, key: key, policy: collectionBound, throws: .collectionLimitExceeded)

        let stringBound = CodeMapArtifactContainerPolicy(
            maximumStringCount: 1,
            maximumStringUTF8ByteCount: 1,
            maximumIndividualStringUTF8ByteCount: 1
        )
        assertDecode(canonical, key: key, policy: stringBound, throws: .stringLimitExceeded)

        let nestingBound = CodeMapArtifactContainerPolicy(maximumJSONNestingDepth: 1)
        assertDecode(canonical, key: key, policy: nestingBound, throws: .collectionLimitExceeded)

        let tokenBound = CodeMapArtifactContainerPolicy(maximumJSONTokenCount: 1)
        assertDecode(canonical, key: key, policy: tokenBound, throws: .collectionLimitExceeded)

        XCTAssertThrowsError(
            try CodeMapArtifactContainer.encode(
                key: key,
                outcome: .ready(makeArtifact()),
                policy: payloadBound
            )
        ) { error in
            XCTAssertEqual(error as? CodeMapArtifactContainerError, .invalidPayloadLength)
        }
    }

    func testFileStoreCreatesPrivateShardedLayoutAndSupportsImmutableIdempotence() throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CodeMapArtifactFileStore(rootURL: root)
        let key = try makeKey(sourceText: "private layout")
        let outcome = CodeMapSyntaxArtifactOutcome.ready(makeArtifact())

        XCTAssertEqual(try store.read(key: key), .miss)
        XCTAssertEqual(try store.write(key: key, outcome: outcome), .inserted)
        XCTAssertEqual(try store.write(key: key, outcome: outcome), .alreadyPresent)
        XCTAssertEqual(try store.read(key: key), .hit(outcome))

        let artifactURL = store.artifactURL(for: key)
        XCTAssertEqual(artifactURL.lastPathComponent, key.storageDigestHex)
        XCTAssertEqual(artifactURL.deletingLastPathComponent().lastPathComponent, key.shard)
        XCTAssertEqual(permissions(at: root.appendingPathComponent("CodeMapArtifacts")), 0o700)
        XCTAssertEqual(permissions(at: root.appendingPathComponent("CodeMapArtifacts/v1")), 0o700)
        XCTAssertEqual(permissions(at: root.appendingPathComponent("CodeMapArtifacts/v1/artifacts")), 0o700)
        XCTAssertEqual(permissions(at: artifactURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(permissions(at: artifactURL), 0o600)

        XCTAssertThrowsError(try store.write(key: key, outcome: .readyNoSymbols)) { error in
            XCTAssertEqual(error as? CodeMapArtifactFileStoreError, .integrityCollision)
        }
        XCTAssertEqual(try store.read(key: key), .hit(outcome))
    }

    func testCorruptDestinationQuarantinesToMissAndCanBeAtomicallyReplaced() throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CodeMapArtifactFileStore(rootURL: root)
        let key = try makeKey(sourceText: "corrupt replacement")
        let artifactURL = store.artifactURL(for: key)

        XCTAssertEqual(try store.write(key: key, outcome: .readyNoSymbols), .inserted)
        try Data("corrupt".utf8).write(to: artifactURL)
        XCTAssertEqual(chmod(artifactURL.path, 0o600), 0)
        XCTAssertEqual(try store.read(key: key), .miss)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactURL.path))
        XCTAssertEqual(try store.write(key: key, outcome: .readyNoSymbols), .inserted)
        XCTAssertEqual(try store.read(key: key), .hit(.readyNoSymbols))

        let quarantine = root.appendingPathComponent("CodeMapArtifacts/v1/quarantine")
        let names = try recursiveRelativePaths(at: quarantine)
        XCTAssertTrue(names.contains { $0.contains("/artifacts/\(key.shard)/\(key.storageDigestHex).") })
    }

    func testRootsComponentsShardsAndLeavesRejectSymlinkTypeModeAndContainmentAttacks() throws {
        let fileManager = FileManager.default

        let unsafeModeRoot = try makeSecureRoot()
        defer { try? fileManager.removeItem(at: unsafeModeRoot) }
        XCTAssertEqual(chmod(unsafeModeRoot.path, 0o755), 0)
        XCTAssertThrowsError(try CodeMapArtifactFileStore(rootURL: unsafeModeRoot))

        let realRoot = try makeSecureRoot()
        let symlinkParent = try makeSecureRoot()
        defer {
            try? fileManager.removeItem(at: realRoot)
            try? fileManager.removeItem(at: symlinkParent)
        }
        let rootLink = symlinkParent.appendingPathComponent("root-link")
        XCTAssertEqual(symlink(realRoot.path, rootLink.path), 0)
        XCTAssertThrowsError(try CodeMapArtifactFileStore(rootURL: rootLink))

        let componentRoot = try makeSecureRoot()
        let componentTarget = try makeSecureRoot()
        defer {
            try? fileManager.removeItem(at: componentRoot)
            try? fileManager.removeItem(at: componentTarget)
        }
        XCTAssertEqual(
            symlink(componentTarget.path, componentRoot.appendingPathComponent("CodeMapArtifacts").path),
            0
        )
        XCTAssertThrowsError(try CodeMapArtifactFileStore(rootURL: componentRoot))

        let root = try makeSecureRoot()
        let external = try makeSecureRoot()
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: external)
        }
        let store = try CodeMapArtifactFileStore(rootURL: root)
        let key = try makeKey(sourceText: "leaf attacks")
        let artifactURL = store.artifactURL(for: key)
        let shardURL = artifactURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: shardURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let externalFile = external.appendingPathComponent("external")
        try Data("external".utf8).write(to: externalFile)
        XCTAssertEqual(chmod(externalFile.path, 0o600), 0)
        XCTAssertEqual(symlink(externalFile.path, artifactURL.path), 0)
        XCTAssertThrowsError(try store.read(key: key))
        try fileManager.removeItem(at: artifactURL)

        try fileManager.createDirectory(
            at: artifactURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        XCTAssertThrowsError(try store.read(key: key))
        try fileManager.removeItem(at: artifactURL)

        XCTAssertEqual(mkfifo(artifactURL.path, 0o600), 0)
        XCTAssertThrowsError(try store.read(key: key))
        try fileManager.removeItem(at: artifactURL)

        XCTAssertEqual(try store.write(key: key, outcome: .readyNoSymbols), .inserted)
        XCTAssertEqual(chmod(artifactURL.path, 0o644), 0)
        XCTAssertThrowsError(try store.read(key: key))

        let traversalRoot = root.appendingPathComponent("missing/..", isDirectory: true)
        XCTAssertThrowsError(try CodeMapArtifactFileStore(rootURL: traversalRoot))
    }

    func testMaintenanceLockAndShardReplacementAreNeverFollowed() throws {
        let fileManager = FileManager.default
        let root = try makeSecureRoot()
        let external = try makeSecureRoot()
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: external)
        }
        let store = try CodeMapArtifactFileStore(rootURL: root)
        let key = try makeKey(sourceText: "component replacement")
        let versionURL = root.appendingPathComponent("CodeMapArtifacts/v1")
        let lockURL = versionURL.appendingPathComponent("maintenance.lock")
        try fileManager.removeItem(at: lockURL)
        XCTAssertEqual(symlink(external.appendingPathComponent("lock").path, lockURL.path), 0)
        XCTAssertThrowsError(try CodeMapArtifactFileStore(rootURL: root))
        try fileManager.removeItem(at: lockURL)
        _ = try CodeMapArtifactFileStore(rootURL: root)

        let shardURL = store.artifactURL(for: key).deletingLastPathComponent()
        XCTAssertEqual(symlink(external.path, shardURL.path), 0)
        XCTAssertThrowsError(try store.write(key: key, outcome: .readyNoSymbols))
        XCTAssertTrue(fileManager.fileExists(atPath: external.path))
    }

    func testIndependentConcurrentReadersObserveOnlyCompleteImmutableContainers() throws {
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CodeMapArtifactFileStore(rootURL: root)
        let key = try makeKey(sourceText: "concurrent readers")
        let outcome = CodeMapSyntaxArtifactOutcome.ready(makeArtifact())

        let lock = NSLock()
        var failures: [String] = []
        var insertedCount = 0
        var alreadyPresentCount = 0
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            do {
                let independent = try CodeMapArtifactFileStore(rootURL: root)
                switch try independent.write(key: key, outcome: outcome) {
                case .inserted:
                    lock.withLock { insertedCount += 1 }
                case .alreadyPresent:
                    lock.withLock { alreadyPresentCount += 1 }
                }
            } catch {
                lock.withLock { failures.append(String(describing: error)) }
            }
        }
        XCTAssertEqual(insertedCount, 1)
        XCTAssertEqual(alreadyPresentCount, 31)
        XCTAssertEqual(failures, [])

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            do {
                let independent = try CodeMapArtifactFileStore(rootURL: root)
                guard try independent.read(key: key) == .hit(outcome) else {
                    lock.withLock { failures.append("miss") }
                    return
                }
            } catch {
                lock.withLock { failures.append(String(describing: error)) }
            }
        }
        XCTAssertEqual(failures, [])
        XCTAssertEqual(try store.read(key: key), .hit(outcome))
        XCTAssertFalse(
            try recursiveRelativePaths(at: root.appendingPathComponent("CodeMapArtifacts/v1/artifacts"))
                .contains { $0.contains(".tmp.") }
        )
    }

    func testRecoveryRemovesOnlyStrictInactiveOwnedRegularTempsAndLookupIgnoresPartials() throws {
        let fileManager = FileManager.default
        let root = try makeSecureRoot()
        defer { try? fileManager.removeItem(at: root) }
        let store = try CodeMapArtifactFileStore(rootURL: root)
        let key = try makeKey(sourceText: "partial temp")
        let shardURL = store.artifactURL(for: key).deletingLastPathComponent()
        try fileManager.createDirectory(at: shardURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        let inactivePID = Int32.max
        let strictName = ".tmp.\(inactivePID).00000000-0000-0000-0000-000000000001"
        let strictURL = shardURL.appendingPathComponent(strictName)
        try Data("partial".utf8).write(to: strictURL)
        XCTAssertEqual(chmod(strictURL.path, 0o600), 0)

        let privateRemovalURL = shardURL.appendingPathComponent(
            ".delete.\(inactivePID).00000000-0000-0000-0000-000000000004"
        )
        try Data("moved-before-crash".utf8).write(to: privateRemovalURL)
        XCTAssertEqual(chmod(privateRemovalURL.path, 0o600), 0)

        let activeName = ".tmp.\(getpid()).00000000-0000-0000-0000-000000000002"
        let activeURL = shardURL.appendingPathComponent(activeName)
        try Data("active".utf8).write(to: activeURL)
        XCTAssertEqual(chmod(activeURL.path, 0o600), 0)

        let malformedURL = shardURL.appendingPathComponent(".tmp.bad.not-a-uuid")
        try Data("malformed".utf8).write(to: malformedURL)
        XCTAssertEqual(chmod(malformedURL.path, 0o600), 0)

        let symlinkName = ".tmp.\(inactivePID).00000000-0000-0000-0000-000000000003"
        let symlinkURL = shardURL.appendingPathComponent(symlinkName)
        XCTAssertEqual(symlink(activeURL.path, symlinkURL.path), 0)

        XCTAssertEqual(try store.read(key: key), .miss)
        XCTAssertEqual(try store.recoverValidatedTemporaryFiles(), 2)
        XCTAssertFalse(fileManager.fileExists(atPath: strictURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: privateRemovalURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: activeURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: malformedURL.path))
        XCTAssertNotNil(try? fileManager.destinationOfSymbolicLink(atPath: symlinkURL.path))
    }

    func testArtifactAndQuarantineBytesAndNamesDoNotLeakSourcePathOrRuntimeIdentity() throws {
        let sentinel = "/private/Repository/Worktree/Session/source.swift"
        let root = try makeSecureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CodeMapArtifactFileStore(rootURL: root)
        let key = try makeKey(sourceText: sentinel)
        XCTAssertEqual(try store.write(key: key, outcome: .readyNoSymbols), .inserted)

        let namespace = root.appendingPathComponent("CodeMapArtifacts")
        for relativePath in try recursiveRelativePaths(at: namespace) {
            XCTAssertFalse(relativePath.localizedCaseInsensitiveContains("repository"))
            XCTAssertFalse(relativePath.localizedCaseInsensitiveContains("worktree"))
            XCTAssertFalse(relativePath.localizedCaseInsensitiveContains("session"))
            XCTAssertFalse(relativePath.contains("source.swift"))
        }
        let bytes = try Data(contentsOf: store.artifactURL(for: key))
        XCTAssertNil(bytes.range(of: Data(sentinel.utf8)))
        XCTAssertNil(bytes.range(of: Data("worktree".utf8)))
        XCTAssertNil(bytes.range(of: Data("session".utf8)))
    }

    private struct ContainerLayout {
        let headerByteCount: Int
        let keyOffset: Int
        let schemaOffset: Int
        let kindOffset: Int
        let payloadLengthOffset: Int
        let checksumOffset: Int
        let summaryVersionOffset: Int
        let summaryCountOffset: Int
        let summaryFieldsOffset: Int
    }

    private func parseLayout(_ data: Data) -> ContainerLayout {
        let keyOffset = 28
        let keyLength = Int(readUInt32(data, at: 24))
        let schemaOffset = keyOffset + keyLength
        return ContainerLayout(
            headerByteCount: Int(readUInt32(data, at: 20)),
            keyOffset: keyOffset,
            schemaOffset: schemaOffset,
            kindOffset: schemaOffset + 4,
            payloadLengthOffset: schemaOffset + 5,
            checksumOffset: schemaOffset + 13,
            summaryVersionOffset: schemaOffset + 45,
            summaryCountOffset: schemaOffset + 49,
            summaryFieldsOffset: schemaOffset + 53
        )
    }

    private func assertDecode(
        _ data: Data,
        key: CodeMapArtifactKey,
        filenameDigest: String? = nil,
        policy: CodeMapArtifactContainerPolicy = .default,
        throws expected: CodeMapArtifactContainerError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try CodeMapArtifactContainer.decode(
                data,
                expectedKey: key,
                filenameDigest: filenameDigest ?? key.storageDigestHex,
                policy: policy
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? CodeMapArtifactContainerError, expected, file: file, line: line)
        }
    }

    private func rewritePayloadChecksum(_ data: inout Data, layout: ContainerLayout) {
        let payload = data.subdata(in: layout.headerByteCount ..< data.count)
        data.replaceSubrange(
            layout.checksumOffset ..< layout.checksumOffset + 32,
            with: Data(SHA256.hash(data: payload))
        )
    }

    private func makeKey(sourceText: String) throws -> CodeMapArtifactKey {
        let identity = try SyntaxManager().pipelineIdentity(for: .swift, decoderPolicy: .workspaceAutomaticV1)
        return try CodeMapArtifactKey(source: makeSource(text: sourceText), pipelineIdentity: identity)
    }

    private func makeSource(text: String) -> CodeMapSourceSnapshot {
        let data = Data(text.utf8)
        let fingerprint = FileContentFingerprint(
            deviceID: 1,
            fileNumber: 2,
            byteSize: Int64(data.count),
            modificationSeconds: 3,
            modificationNanoseconds: 0,
            statusChangeSeconds: 4,
            statusChangeNanoseconds: 0
        )
        return CodeMapSourceSnapshot(
            validatedContent: ValidatedRawFileContentSnapshot(
                data: data,
                modificationDate: fingerprint.modificationDate,
                fingerprint: fingerprint
            )
        )
    }

    private func makeArtifact() -> CodeMapSyntaxArtifact {
        CodeMapSyntaxArtifact(
            imports: ["Foundation", "CryptoKit"],
            exports: ["Example"],
            classes: [
                ClassInfo(
                    name: "Example",
                    methods: [
                        FunctionInfo(
                            name: "run",
                            parameters: [ParameterInfo(externalName: nil, localName: "value", typeName: "Int")],
                            returnType: "Void",
                            definitionLine: "func run(value: Int) -> Void",
                            lineNumber: 4
                        )
                    ],
                    properties: [PropertyInfo(name: "count", typeName: "Int")]
                )
            ],
            interfaces: [InterfaceInfo(name: "Runnable")],
            aliases: [TypeAliasInfo(name: "Count", definitionLine: "typealias Count = Int")],
            literalUnions: ["one | two"],
            functions: [
                FunctionInfo(
                    name: "helper",
                    parameters: [],
                    returnType: nil,
                    definitionLine: "func helper()",
                    lineNumber: nil
                )
            ],
            enums: [EnumInfo(name: "State", cases: ["ready", "done"])],
            globalVars: [VariableInfo(name: "global", typeName: "Int", definitionLine: "let global: Int")],
            macros: ["DEBUG"],
            referencedTypes: ["Int", "Void"]
        )
    }

    private func makeSecureRoot() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeMapArtifactContainerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let resolvedPath = try XCTUnwrap(base.path.withCString { pointer -> String? in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        })
        let resolved = URL(fileURLWithPath: resolvedPath, isDirectory: true)
        XCTAssertEqual(chmod(resolved.path, 0o700), 0)
        return resolved
    }

    private func permissions(at url: URL) -> Int {
        var status = stat()
        XCTAssertEqual(lstat(url.path, &status), 0)
        return Int(status.st_mode & mode_t(0o777))
    }

    private func recursiveRelativePaths(at root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { value in
            guard let url = value as? URL else { return nil }
            return String(url.path.dropFirst(root.path.count + 1))
        }
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset ..< offset + 4].reduce(into: UInt32(0)) { result, byte in
            result = (result << 8) | UInt32(byte)
        }
    }

    private func replaceUInt32(_ data: inout Data, at offset: Int, with value: UInt32) {
        data[offset] = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    private func replaceUInt64(_ data: inout Data, at offset: Int, with value: UInt64) {
        for index in 0 ..< 8 {
            data[offset + index] = UInt8((value >> UInt64(56 - index * 8)) & 0xFF)
        }
    }
}

private extension NSLock {
    func withLock(_ body: () -> Void) {
        lock()
        defer { unlock() }
        body()
    }
}
