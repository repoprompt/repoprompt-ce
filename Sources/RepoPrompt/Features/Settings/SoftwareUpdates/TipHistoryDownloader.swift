import CryptoKit
import Darwin
import Foundation
import RepoPromptProcess
import RepoPromptSecureStorage

enum TipHistoryAcquisitionProgress {
    case downloading(received: Int64, total: Int64)
    case verifying
}

protocol TipHistoryArtifactDownloading: Sendable {
    func obtain(
        _ entry: TipHistoryEntry, destination: URL, publicKey: String,
        progress: @escaping @Sendable (TipHistoryAcquisitionProgress) -> Void,
        commit: @escaping @MainActor @Sendable (URL) throws -> URL
    ) async throws -> URL
}

/// Dependencies allow offline fault/race tests. Production composition always
/// uses .live: no DEBUG bypass of signatures, URL trust, identity or Gatekeeper.
struct TipHistoryAcquisitionServices {
    let download: @Sendable (URL, URL, Int64, @escaping @Sendable (Int64) -> Void) async throws -> Void
    let run: @Sendable (String, [String], URL) async throws -> Void
    let validatesCode: @Sendable (URL, OfficialApplicationIdentity) -> Bool
    let assess: @Sendable (URL, URL) async throws -> Void

    static let live = Self(
        download: { source, target, size, progress in
            let transfer = TipHistoryTransfer(destination: target, maximumBytes: size, expectedBytes: size, allowsRedirect: { url in
                url == source || TipHistoryTransfer.allowsReleaseCDN(url)
            }, progress: progress)
            try await transfer.receive(source, requestTimeout: 30, resourceTimeout: 1800)
        },
        run: { command, args, workingDirectory in
            _ = try await runChecked(command, args: args, workingDirectory: workingDirectory)
        },
        validatesCode: { app, identity in identity.validatesOfficialApplication(at: app) },
        assess: { app, workingDirectory in
            let bytes = try await runChecked("/usr/sbin/spctl", args: ["--assess", "--type", "execute", "--raw", "--ignore-cache", "--no-cache", app.path], workingDirectory: workingDirectory)
            try validateAssessment(bytes)
        }
    )

    private static func runChecked(_ command: String, args: [String], workingDirectory: URL) async throws -> Data {
        let runner = CLIProcessRunner(config: CLIProcessConfiguration(command: command, processPurpose: .tool, workingDirectory: workingDirectory.path, shellLookupMode: .disabled))
        let result = try await runner.run(args: args, stdin: nil, outputMode: .none, timeout: 300, cancelChildOnTaskCancellation: true)
        guard !result.timedOut else { throw TipHistoryDownloadError.timeout }
        guard result.status == 0 else { throw TipHistoryDownloadError.extractionFailed }
        return result.stdout
    }

    static func validateAssessment(_ data: Data) throws {
        // Read-only spctl raw result; never treat globally bypassed Gatekeeper
        // or a local allow rule as successful notarization assessment.
        // Keys are owned by Apple's Security/SecAssessment.cpp.
        guard data.count <= 1_048_576,
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              value["assessment:verdict"] as? Bool == true,
              value["assessment:error"] == nil,
              let authority = value["assessment:authority"] as? [String: Any],
              authority["assessment:authority:source"] as? String == "Notarized Developer ID",
              authority["assessment:authority:override"] == nil,
              authority["assessment:authority:weak"] == nil
        else { throw TipHistoryDownloadError.assessmentFailed }
    }
}

/// Bounded, non-executing bundle metadata admission. Bundle/Foundation would
/// read Info.plist without a size bound, so read at most 1 MiB from a regular,
/// non-symlink file and bind every metadata field the catalog admits.
enum TipHistoryBundleMetadata {
    static let maximumInfoPlistBytes = 1_048_576
    static let maximumSlices: UInt32 = 8
    private static let machOMagic64: UInt32 = 0xFEED_FACF
    private static let fatMagic: UInt32 = 0xCAFE_BABE

    static func validate(root: URL, entry: TipHistoryEntry) throws {
        let contents = root.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try requireDirectory(root)
        try requireDirectory(contents)
        let bytes = try readRegularFile(contents.appendingPathComponent("Info.plist"), maximumBytes: maximumInfoPlistBytes)
        guard let info = try? PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == entry.bundleIdentifier,
              info["CFBundleVersion"] as? String == entry.buildNumber,
              !entry.marketingVersion.isEmpty, info["CFBundleShortVersionString"] as? String == entry.marketingVersion,
              let required = entry.minimumSystemVersion,
              let minimum = (info["LSMinimumSystemVersion"] as? String).flatMap(SparkleBuildVersion.init),
              equal(minimum, required),
              let executable = info["CFBundleExecutable"] as? String, isSingleComponent(executable)
        else { throw TipHistoryDownloadError.bundleMismatch }
        // Effective minimum OS: any per-architecture override must not differ.
        if let overrides = info["LSMinimumSystemVersionByArchitecture"] {
            guard let values = overrides as? [String: String],
                  values.values.allSatisfy({ SparkleBuildVersion($0).map { equal($0, required) } ?? false })
            else { throw TipHistoryDownloadError.bundleMismatch }
        }
        try requireDirectory(macOS)
        let architectures = try machOArchitectures(at: macOS.appendingPathComponent(executable))
        guard !entry.architectures.isEmpty, architectures == entry.architectures else { throw TipHistoryDownloadError.bundleMismatch }
    }

    private static func equal(_ lhs: SparkleBuildVersion, _ rhs: SparkleBuildVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    private static func isSingleComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\u{0}") && name.utf8.count <= 255
    }

    private static func requireDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw TipHistoryDownloadError.bundleMismatch }
    }

    private static func openRegular(_ url: URL) throws -> (Int32, UInt64) {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw TipHistoryDownloadError.bundleMismatch }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            close(descriptor)
            throw TipHistoryDownloadError.bundleMismatch
        }
        return (descriptor, UInt64(info.st_size))
    }

    private static func readExactly(_ descriptor: Int32, offset: UInt64, count: Int, fileSize: UInt64) throws -> [UInt8] {
        guard count >= 0, offset <= fileSize, UInt64(count) <= fileSize - offset else { throw TipHistoryDownloadError.bundleMismatch }
        var buffer = [UInt8](repeating: 0, count: count)
        var total = 0
        while total < count {
            let read = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress! + total, count - total, off_t(offset) + off_t(total)) }
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { throw TipHistoryDownloadError.bundleMismatch }
            total += read
        }
        return buffer
    }

    static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        let (descriptor, size) = try openRegular(url)
        defer { close(descriptor) }
        guard size <= UInt64(maximumBytes) else { throw TipHistoryDownloadError.bundleMismatch }
        let bytes = try readExactly(descriptor, offset: 0, count: Int(size), fileSize: size)
        // The file must not have grown past the bound after fstat.
        var extra: UInt8 = 0
        guard pread(descriptor, &extra, 1, off_t(size)) == 0 else { throw TipHistoryDownloadError.bundleMismatch }
        return Data(bytes)
    }

    /// Header-only Mach-O/fat parse (no execution, no dyld). Only the exact
    /// public architectures are recognized; anything else fails closed.
    static func machOArchitectures(at url: URL) throws -> Set<String> {
        let (descriptor, size) = try openRegular(url)
        defer { close(descriptor) }
        func big(_ bytes: [UInt8], _ index: Int) -> UInt32 {
            bytes[index ..< index + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        func little(_ bytes: [UInt8], _ index: Int) -> UInt32 {
            bytes[index ..< index + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        func slice(at offset: UInt64, cpu: UInt32?, subtype: UInt32?) throws -> String {
            let header = try readExactly(descriptor, offset: offset, count: 32, fileSize: size)
            let type = little(header, 4), sub = little(header, 8)
            guard little(header, 0) == machOMagic64, cpu.map({ $0 == type }) ?? true,
                  subtype.map({ $0 & 0x00FF_FFFF == sub & 0x00FF_FFFF }) ?? true,
                  let name = architecture(cpu: type, subtype: sub)
            else { throw TipHistoryDownloadError.bundleMismatch }
            return name
        }
        let header = try readExactly(descriptor, offset: 0, count: 8, fileSize: size)
        if big(header, 0) == fatMagic {
            let count = big(header, 4)
            guard (1 ... maximumSlices).contains(count) else { throw TipHistoryDownloadError.bundleMismatch }
            let tableEnd = 8 + UInt64(count) * 20
            let table = try readExactly(descriptor, offset: 8, count: Int(count) * 20, fileSize: size)
            var names = Set<String>()
            for index in 0 ..< Int(count) {
                let base = index * 20
                let cpu = big(table, base), subtype = big(table, base + 4)
                let offset = UInt64(big(table, base + 8)), length = UInt64(big(table, base + 12))
                guard offset >= tableEnd, length >= 32, offset + length <= size else { throw TipHistoryDownloadError.bundleMismatch }
                let name = try slice(at: offset, cpu: cpu, subtype: subtype)
                guard names.insert(name).inserted else { throw TipHistoryDownloadError.bundleMismatch }
            }
            return names
        }
        let thin = try slice(at: 0, cpu: nil, subtype: nil)
        return [thin]
    }

    private static func architecture(cpu: UInt32, subtype: UInt32) -> String? {
        switch (cpu, subtype & 0x00FF_FFFF) {
        case (0x0100_0007, 3): "x86_64"
        case (0x0100_000C, 0): "arm64"
        default: nil
        }
    }
}

struct TipHistoryDownloader: TipHistoryArtifactDownloading {
    let services: TipHistoryAcquisitionServices
    let registry: TipHistoryStagingRegistry

    init(services: TipHistoryAcquisitionServices = .live, registry: TipHistoryStagingRegistry) {
        self.services = services
        self.registry = registry
    }

    func obtain(
        _ entry: TipHistoryEntry, destination: URL, publicKey: String,
        progress: @escaping @Sendable (TipHistoryAcquisitionProgress) -> Void,
        commit: @escaping @MainActor @Sendable (URL) throws -> URL
    ) async throws -> URL {
        guard entry.metadataProblem == nil, entry.installationType == .application, entry.role != .transition,
              let download = entry.download, let identity = OfficialApplicationIdentity(rawValue: entry.signingIdentity.rawValue),
              identity.bundleIdentifier == entry.bundleIdentifier, identity.teamIdentifier == entry.teamIdentifier,
              SparkleUpdaterManager.isTrustedTipDownloadURL(download.url, tag: entry.tag, name: download.name),
              Data(base64Encoded: publicKey)?.count == 32
        else { throw TipHistoryDownloadError.bundleMismatch }
        try Task.checkCancellation()
        let destination = try TipHistoryOwnedStaging.validatedDestination(destination)
        try TipHistoryOwnedStaging.requireCapacity(at: destination, download: download)
        let temporaryVolume = try FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let temporaryCapacity = temporaryVolume.volumeAvailableCapacityForImportantUsage, temporaryCapacity >= download.size + 64 * 1024 * 1024 else { throw TipHistoryDownloadError.insufficientDiskSpace }
        let stage = try TipHistoryOwnedStaging(destination: destination, id: UUID())
        do { try await registry.register(stage.record) }
        catch {
            try? stage.remove()
            throw TipHistoryDownloadError.fileSystem
        }
        do {
            progress(.downloading(received: 0, total: download.size))
            try await services.download(download.url, stage.archiveURL, download.size) { received in
                progress(.downloading(received: received, total: download.size))
            }
            try Task.checkCancellation()
            progress(.verifying)
            try verifyArchive(stage.archiveURL, download: download, publicKey: publicKey)
            let entries = try TipHistoryArchive.validate(at: stage.archiveURL, declaredExpandedSize: download.expandedSize)
            try Task.checkCancellation()
            try TipHistoryOwnedStaging.requireCapacity(at: destination, download: download, allocationHeadroom: Int64(entries) * 16384)
            try quarantine(stage.archiveURL, origin: download.url)
            try FileManager.default.createDirectory(at: stage.payloadURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try await extract(stage: stage, download: download)
            try Task.checkCancellation()
            let root = try validateExtracted(stage.payloadURL, entry: entry, maximumBytes: download.expandedSize)
            guard getxattr(root.path, "com.apple.quarantine", nil, 0, 0, 0) > 0 else { throw TipHistoryDownloadError.assessmentFailed }
            guard services.validatesCode(root, identity) else { throw TipHistoryDownloadError.codeSignatureInvalid }
            do { try await services.assess(root, stage.url) }
            catch is CancellationError { throw CancellationError() }
            catch let error as CLIProcessRunnerError { throw error }
            catch { throw TipHistoryDownloadError.assessmentFailed }
            try Task.checkCancellation()
            try TipHistoryOwnedStaging.requireCapacity(at: destination, download: download)
            // Store-owned MainActor closure atomically rechecks generation,
            // consent, current compatibility and context, then renames exclusively.
            let saved = try await commit(stage.payloadURL)
            // This is after the commit point: cancellation or cleanup failure
            // must never delete or report failure for the durable user result.
            do {
                try stage.remove()
                await registry.remove(stage.record.id)
            } catch {
                // The saved app is durable; registry-driven cleanup may retry
                // the remaining private archive later without touching it.
            }
            return saved
        } catch {
            if let processError = error as? CLIProcessRunnerError, case .waitFailed = processError {
                // Physical child exit was not proven. Keep the owned staging
                // lock and require manual cleanup; never race an orphan writer.
                await registry.preserveUncertain(stage)
                throw TipHistoryDownloadError.fileSystem
            }
            do {
                try stage.remove()
                await registry.remove(stage.record.id)
            } catch {
                throw TipHistoryDownloadError.fileSystem
            }
            if error is CancellationError { throw CancellationError() }
            if let failure = error as? TipHistoryTransferFailure { throw failure }
            if let failure = error as? TipHistoryDownloadError { throw failure }
            let cocoa = error as NSError
            if cocoa.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(cocoa.code) { throw TipHistoryDownloadError.accessDenied }
            throw TipHistoryDownloadError.fileSystem
        }
    }

    private func verifyArchive(_ url: URL, download: TipHistoryDownload, publicKey: String) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length == UInt64(download.size) else { throw TipHistoryDownloadError.sizeMismatch }
        try handle.seek(toOffset: 0)
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == download.sha256 else { throw TipHistoryDownloadError.digestMismatch }
        let mapped = try Data(contentsOf: url, options: .alwaysMapped)
        guard TipHistorySignatureVerifier.isValid(signatureBase64: download.edSignature, message: mapped, publicKeyBase64: publicKey) else {
            throw TipHistoryDownloadError.invalidSparkleSignature
        }
    }

    private func extract(stage: TipHistoryOwnedStaging, download: TipHistoryDownload) async throws {
        let archive = stage.archiveURL
        let payload = stage.payloadURL
        let workingDirectory = stage.url
        let services = services
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await services.run("/usr/bin/ditto", ["-x", "-k", "--qtn", archive.path, payload.path], workingDirectory)
                }
                group.addTask {
                    while true {
                        try Task.checkCancellation()
                        try Self.scan(payload, maximumBytes: download.expandedSize)
                        try await Task.sleep(for: .milliseconds(250))
                    }
                }
                var failure: Error?
                do { _ = try await group.next() }
                catch { failure = error }
                group.cancelAll()
                // Drain every owned child before cleanup. In particular a
                // process-ownership failure must not be hidden by an earlier
                // monitor/cancellation error and followed by unsafe deletion.
                while !group.isEmpty {
                    do { _ = try await group.next() }
                    catch is CancellationError { continue }
                    catch {
                        if let processError = error as? CLIProcessRunnerError, case .waitFailed = processError { failure = error }
                        else if failure == nil { failure = error }
                    }
                }
                if let failure { throw failure }
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as CLIProcessRunnerError { throw error }
        catch let error as TipHistoryDownloadError { throw error }
        catch { throw TipHistoryDownloadError.extractionFailed }
    }

    private static func scan(_ payload: URL, maximumBytes: Int64) throws {
        guard let iterator = FileManager.default.enumerator(at: payload, includingPropertiesForKeys: nil) else { throw TipHistoryDownloadError.fileSystem }
        var bytes: Int64 = 0
        var entries = 0
        for case let url as URL in iterator {
            try Task.checkCancellation()
            entries += 1
            guard entries <= TipHistoryArchive.maximumEntries else { throw TipHistoryDownloadError.archiveLimitExceeded }
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                if errno == ENOENT { continue }
                throw TipHistoryDownloadError.fileSystem
            }
            if info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFLNK { bytes += info.st_size }
            guard bytes <= maximumBytes else { throw TipHistoryDownloadError.archiveLimitExceeded }
        }
    }

    private func validateExtracted(_ payload: URL, entry: TipHistoryEntry, maximumBytes: Int64) throws -> URL {
        try Self.scan(payload, maximumBytes: maximumBytes)
        let children = try FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
        guard children.count == 1, let root = children.first, root.lastPathComponent == TipHistoryArchive.appName else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else { throw TipHistoryDownloadError.bundleMismatch }
        // Resolve the boundary too: macOS temporary/item-replacement URLs can
        // use /var while enumerated children canonicalize through /private/var.
        // The lstat above already proved the app root itself is not a symlink.
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let boundary = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { throw TipHistoryDownloadError.fileSystem }
        var inodes: [UInt64: (links: Int, count: Int)] = [:]
        for case let path as URL in iterator {
            try Task.checkCancellation()
            var info = stat()
            guard lstat(path.path, &info) == 0, info.st_uid == geteuid() else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            let type = info.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR || type == S_IFLNK else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            let resolved = path.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved == canonicalRoot || resolved.hasPrefix(boundary) else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
            if type == S_IFREG {
                let previous = inodes[info.st_ino]
                inodes[info.st_ino] = (Int(info.st_nlink), (previous?.count ?? 0) + 1)
            }
        }
        guard inodes.values.allSatisfy({ $0.links == $0.count }) else { throw TipHistoryDownloadError.unexpectedArchiveLayout }
        // Metadata is read only after containment is proven, never via Bundle.
        try TipHistoryBundleMetadata.validate(root: root, entry: entry)
        return root
    }

    private func quarantine(_ url: URL, origin: URL) throws {
        let marker = "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));RepoPrompt CE;\(UUID().uuidString)"
        let attributes: [(String, Data)] = try [
            ("com.apple.quarantine", Data(marker.utf8)),
            ("com.apple.metadata:kMDItemWhereFroms", PropertyListSerialization.data(fromPropertyList: [origin.absoluteString], format: .binary, options: 0))
        ]
        for (name, value) in attributes {
            let result = value.withUnsafeBytes { bytes in setxattr(url.path, name, bytes.baseAddress, value.count, 0, 0) }
            guard result == 0 else { throw TipHistoryDownloadError.assessmentFailed }
        }
    }
}
