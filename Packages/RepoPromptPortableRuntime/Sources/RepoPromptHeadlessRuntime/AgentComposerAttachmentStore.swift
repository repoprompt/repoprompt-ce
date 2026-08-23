import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel
import RepoPromptShared

public actor AgentComposerAttachmentStore {
    public struct Configuration: Hashable, Sendable {
        public let stagingRoot: String
        public let acceptedRoot: String
        public let maximumItemBytes: Int
        public let maximumItemsPerTurn: Int
        public let maximumStagedBytesPerActor: Int
        public let maximumGlobalStagedBytes: Int
        public let unclaimedTTL: TimeInterval
        public let maximumAcceptedBytesPerSession: Int
        public let maximumGlobalAcceptedBytes: Int
        public let minimumFreeBytes: Int64
        public let maximumPixelCount: Int
        public let maximumDimension: Int

        public init(
            stagingRoot: String = "/tmp/repoprompt-agent-attachments/staged",
            acceptedRoot: String,
            maximumItemBytes: Int = 10 * 1024 * 1024,
            maximumItemsPerTurn: Int = 4,
            maximumStagedBytesPerActor: Int = 40 * 1024 * 1024,
            maximumGlobalStagedBytes: Int = 192 * 1024 * 1024,
            unclaimedTTL: TimeInterval = 24 * 60 * 60,
            maximumAcceptedBytesPerSession: Int = 256 * 1024 * 1024,
            maximumGlobalAcceptedBytes: Int = 2 * 1024 * 1024 * 1024,
            minimumFreeBytes: Int64 = 1 * 1024 * 1024 * 1024,
            maximumPixelCount: Int = 100_000_000,
            maximumDimension: Int = 32768
        ) {
            self.stagingRoot = stagingRoot
            self.acceptedRoot = acceptedRoot
            self.maximumItemBytes = maximumItemBytes
            self.maximumItemsPerTurn = maximumItemsPerTurn
            self.maximumStagedBytesPerActor = maximumStagedBytesPerActor
            self.maximumGlobalStagedBytes = maximumGlobalStagedBytes
            self.unclaimedTTL = unclaimedTTL
            self.maximumAcceptedBytesPerSession = maximumAcceptedBytesPerSession
            self.maximumGlobalAcceptedBytes = maximumGlobalAcceptedBytes
            self.minimumFreeBytes = minimumFreeBytes
            self.maximumPixelCount = maximumPixelCount
            self.maximumDimension = maximumDimension
        }
    }

    private let store: any ComposerAttachmentStore
    private let configuration: Configuration
    private let files: FileManager

    public init(store: any ComposerAttachmentStore, configuration: Configuration, files: FileManager = .default) throws {
        self.store = store
        self.configuration = configuration
        self.files = files
        try Self.ensurePrivateDirectory(configuration.stagingRoot, files: files)
        try Self.ensurePrivateDirectory(configuration.acceptedRoot, files: files)
    }

    public func recover(now: Date = Date()) async throws {
        let records = try await store.composerAttachments(actorID: nil, projectID: nil, lifecycle: nil)
        for record in records {
            switch record.wire.lifecycle {
            case .staged:
                guard let path = record.stagedPath, files.fileExists(atPath: path), record.wire.expiresAt.map({ $0 > now }) == true else {
                    try await expire(record, now: now)
                    continue
                }
                if record.leaseSubmissionID != nil, let persistent = record.persistentPath, !files.fileExists(atPath: persistent) {
                    try await store.upsertComposerAttachment(replacing(record, stagedPath: .some(path), persistentPath: .some(nil), leaseSubmissionID: .some(nil), updatedAt: now))
                }
            case .accepted:
                if let persistent = record.persistentPath, !files.fileExists(atPath: persistent) {
                    try await store.upsertComposerAttachment(replacing(record, lifecycle: .failed, updatedAt: now))
                } else if let stagedPath = record.stagedPath {
                    try? files.removeItem(atPath: stagedPath)
                    try await store.upsertComposerAttachment(replacing(record, stagedPath: .some(nil), updatedAt: now))
                }
            case .expired, .failed:
                if let path = record.stagedPath { try? files.removeItem(atPath: path) }
            }
        }
        try sweepUnreferencedFiles(records: records)
    }

    public func stage(data: Data, displayName: String, declaredMediaType: String?, actorID: String, projectID: UUID, now: Date = Date()) async throws -> ComposerAttachmentWire {
        guard !actorID.isEmpty, !data.isEmpty, data.count <= configuration.maximumItemBytes else {
            throw ServiceAPIError(code: .invalidRequest, message: "Image exceeds the 10 MiB item limit")
        }
        let raster = try Self.validateRaster(data, declaredMediaType: declaredMediaType, maximumPixelCount: configuration.maximumPixelCount, maximumDimension: configuration.maximumDimension)
        let staged = try await store.composerAttachments(actorID: nil, projectID: nil, lifecycle: .staged)
        let actorBytes = staged.filter { $0.actorID == actorID }.reduce(0) { $0 + $1.wire.byteSize }
        let globalBytes = staged.reduce(0) { $0 + $1.wire.byteSize }
        guard actorBytes + data.count <= configuration.maximumStagedBytesPerActor,
              globalBytes + data.count <= configuration.maximumGlobalStagedBytes
        else { throw ServiceAPIError(code: .dependencyUnavailable, message: "attachment_quota_exceeded", retryable: true) }
        let attachmentID = UUID()
        let path = URL(fileURLWithPath: configuration.stagingRoot).appendingPathComponent(attachmentID.uuidString.lowercased()).path
        guard files.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Unable to stage image")
        }
        do {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.synchronize()
            try handle.close()
            let wire = ComposerAttachmentWire(attachmentID: attachmentID, displayName: Self.sanitizedName(displayName, mediaType: raster.mediaType), mediaType: raster.mediaType, byteSize: data.count, digest: PortableContentDigest.sha256Hex(data), pixelWidth: raster.width, pixelHeight: raster.height, lifecycle: .staged, expiresAt: now.addingTimeInterval(configuration.unclaimedTTL))
            try await store.upsertComposerAttachment(.init(wire: wire, actorID: actorID, projectID: projectID, stagedPath: path, createdAt: now, updatedAt: now))
            return wire
        } catch {
            try? files.removeItem(atPath: path)
            throw error
        }
    }

    public func resolve(attachmentIDs: [UUID], actorID: String, projectID: UUID, now: Date = Date()) async throws -> [ComposerAttachmentResolveResult] {
        guard attachmentIDs.count <= 32 else { throw ServiceAPIError(code: .invalidRequest, message: "Attachment resolve batch exceeds its bound") }
        var results: [ComposerAttachmentResolveResult] = []
        for id in attachmentIDs {
            guard let record = try await store.composerAttachment(attachmentID: id) else {
                results.append(.init(attachmentID: id, errorCode: "forbidden"))
                continue
            }
            guard record.actorID == actorID || record.projectID == projectID else {
                results.append(.init(attachmentID: id, errorCode: "forbidden"))
                continue
            }
            guard record.actorID == actorID else {
                results.append(.init(attachmentID: id, errorCode: ServiceErrorCode.resourceOwnerMismatch.rawValue))
                continue
            }
            guard record.projectID == projectID else {
                results.append(.init(attachmentID: id, errorCode: ServiceErrorCode.resourceContextMismatch.rawValue))
                continue
            }
            if record.wire.lifecycle == .expired || (record.wire.lifecycle == .staged && record.wire.expiresAt.map { $0 <= now } == true) {
                if record.wire.lifecycle == .staged { try await expire(record, now: now) }
                results.append(.init(attachmentID: id, errorCode: ServiceErrorCode.expiredResource.rawValue))
            } else {
                results.append(.init(attachmentID: id, attachment: record.wire))
            }
        }
        return results
    }

    public func preview(attachmentID: UUID, actorID: String, projectID: UUID, visibleSessionID: UUID? = nil, maximumBytes: Int = 10 * 1024 * 1024, now: Date = Date()) async throws -> (ComposerAttachmentWire, Data) {
        guard let record = try await store.composerAttachment(attachmentID: attachmentID), record.projectID == projectID else {
            throw ServiceAPIError(code: .notFound, message: "Attachment is unavailable")
        }
        let owner = record.actorID == actorID
        let acceptedVisible = record.wire.lifecycle == .accepted && visibleSessionID != nil && record.sessionID == visibleSessionID
        guard owner || acceptedVisible else { throw ServiceAPIError(code: .notFound, message: "Attachment is unavailable") }
        guard record.wire.lifecycle != .expired, record.wire.expiresAt.map({ $0 > now }) != false || record.wire.lifecycle == .accepted else {
            throw ServiceAPIError(code: .expiredResource, message: "Attachment expired")
        }
        guard record.wire.byteSize <= maximumBytes, let path = record.persistentPath ?? record.stagedPath else {
            throw ServiceAPIError(code: .invalidRequest, message: "Attachment preview exceeds its bound")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
        guard data.count == record.wire.byteSize, PortableContentDigest.sha256Hex(data) == record.wire.digest else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Attachment content integrity failed")
        }
        return (record.wire, data)
    }

    public func delete(attachmentID: UUID, actorID: String, projectID: UUID) async throws {
        guard let record = try await store.composerAttachment(attachmentID: attachmentID), record.actorID == actorID, record.projectID == projectID else {
            throw ServiceAPIError(code: .notFound, message: "Attachment is unavailable")
        }
        guard record.wire.lifecycle != .accepted, record.leaseSubmissionID == nil else {
            throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Accepted or leased attachment cannot be deleted as a draft")
        }
        if let path = record.stagedPath { try? files.removeItem(atPath: path) }
        try await store.deleteComposerAttachment(attachmentID: attachmentID)
    }

    public func prepareAcceptance(attachmentIDs: [UUID], submissionID: UUID, actorID: String, projectID: UUID, sessionID: UUID, turnID: UUID, supportsNativeImages: Bool, now: Date = Date()) async throws -> AgentTurnAttachmentManifest {
        guard attachmentIDs.count <= configuration.maximumItemsPerTurn else {
            throw ServiceAPIError(code: .invalidRequest, message: "Turn exceeds the four-image limit")
        }
        guard supportsNativeImages || attachmentIDs.isEmpty else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Selected model does not support native image input")
        }
        let accepted = try await store.composerAttachments(actorID: nil, projectID: nil, lifecycle: .accepted)
        let sessionBytes = accepted.filter { $0.sessionID == sessionID }.reduce(0) { $0 + $1.wire.byteSize }
        let globalAcceptedBytes = accepted.reduce(0) { $0 + $1.wire.byteSize }
        var records: [StoredComposerAttachment] = []
        for id in attachmentIDs {
            guard let record = try await store.composerAttachment(attachmentID: id) else {
                throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Attachment is unavailable")
            }
            guard record.actorID == actorID || record.projectID == projectID else {
                throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Attachment is unavailable")
            }
            guard record.actorID == actorID else {
                throw ServiceAPIError(code: .resourceOwnerMismatch, message: "Attachment belongs to another actor")
            }
            guard record.projectID == projectID else {
                throw ServiceAPIError(code: .resourceContextMismatch, message: "Attachment belongs to another project")
            }
            if record.wire.lifecycle == .expired || (record.wire.lifecycle == .staged && record.wire.expiresAt.map { $0 <= now } == true) {
                throw ServiceAPIError(code: .expiredResource, message: "Attachment expired")
            }
            guard record.wire.lifecycle == .staged, record.wire.expiresAt.map({ $0 > now }) == true, record.leaseSubmissionID == nil || record.leaseSubmissionID == submissionID else {
                throw ServiceAPIError(code: .resourceContextMismatch, message: "Attachment is already bound to another turn")
            }
            records.append(record)
        }
        let newBytes = records.reduce(0) { $0 + $1.wire.byteSize }
        guard sessionBytes + newBytes <= configuration.maximumAcceptedBytesPerSession, globalAcceptedBytes + newBytes <= configuration.maximumGlobalAcceptedBytes else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "attachment_quota_exceeded", retryable: true)
        }
        try requireFreeSpace(bytesNeeded: Int64(newBytes))
        let turnDirectory = URL(fileURLWithPath: configuration.acceptedRoot).appendingPathComponent(sessionID.uuidString.lowercased()).appendingPathComponent(turnID.uuidString.lowercased()).path
        try Self.ensurePrivateDirectory(turnDirectory, files: files)
        var prepared: [StoredComposerAttachment] = []
        do {
            for record in records {
                guard let stagedPath = record.stagedPath else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Staged attachment path is unavailable") }
                let stagedData = try Data(contentsOf: URL(fileURLWithPath: stagedPath), options: [.mappedIfSafe])
                guard stagedData.count == record.wire.byteSize, PortableContentDigest.sha256Hex(stagedData) == record.wire.digest else {
                    throw ServiceAPIError(code: .persistenceUnavailable, message: "Staged attachment content integrity failed")
                }
                let extensionName = Self.fileExtension(for: record.wire.mediaType)
                let destination = URL(fileURLWithPath: turnDirectory).appendingPathComponent("\(record.wire.attachmentID.uuidString.lowercased()).\(extensionName)").path
                if !files.fileExists(atPath: destination) { try files.copyItem(atPath: stagedPath, toPath: destination) }
                let persistentData = try Data(contentsOf: URL(fileURLWithPath: destination), options: [.mappedIfSafe])
                guard persistentData.count == record.wire.byteSize, PortableContentDigest.sha256Hex(persistentData) == record.wire.digest else {
                    throw ServiceAPIError(code: .persistenceUnavailable, message: "Persistent attachment copy integrity failed")
                }
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination)
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: destination))
                try handle.synchronize()
                try handle.close()
                let leased = replacing(record, sessionID: sessionID, turnID: turnID, persistentPath: destination, leaseSubmissionID: submissionID, updatedAt: now)
                try await store.upsertComposerAttachment(leased)
                prepared.append(leased)
            }
        } catch {
            for record in prepared {
                if let path = record.persistentPath { try? files.removeItem(atPath: path) }
                try? await store.upsertComposerAttachment(replacing(record, sessionID: .some(nil), turnID: .some(nil), persistentPath: .some(nil), leaseSubmissionID: .some(nil), updatedAt: now))
            }
            throw error
        }
        return .init(attachments: prepared.map(\.wire), nativeImages: prepared.compactMap { record in
            guard let path = record.persistentPath else { return nil }
            return ProviderNativeImageDescriptor(attachmentID: record.wire.attachmentID, mediaType: record.wire.mediaType, byteSize: record.wire.byteSize, digest: record.wire.digest, filePath: path)
        })
    }

    public func finalizeCommittedAcceptance(manifest: AgentTurnAttachmentManifest, sessionID: UUID, turnID: UUID, now: Date = Date()) async throws {
        for wire in manifest.attachments {
            guard let record = try await store.composerAttachment(attachmentID: wire.attachmentID), record.wire.lifecycle == .accepted, record.sessionID == sessionID, record.turnID == turnID, record.persistentPath != nil else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Accepted attachment claim is incomplete")
            }
            if let path = record.stagedPath { try? files.removeItem(atPath: path) }
            try await store.upsertComposerAttachment(replacing(record, stagedPath: .some(nil), updatedAt: now))
        }
    }

    public func releasePreparation(submissionID: UUID, now: Date = Date()) async throws {
        let staged = try await store.composerAttachments(actorID: nil, projectID: nil, lifecycle: .staged)
        for record in staged where record.leaseSubmissionID == submissionID {
            if let path = record.persistentPath { try? files.removeItem(atPath: path) }
            try await store.upsertComposerAttachment(replacing(record, sessionID: .some(nil), turnID: .some(nil), persistentPath: .some(nil), leaseSubmissionID: .some(nil), updatedAt: now))
        }
    }

    private func expire(_ record: StoredComposerAttachment, now: Date) async throws {
        if let path = record.stagedPath { try? files.removeItem(atPath: path) }
        try await store.upsertComposerAttachment(replacing(record, lifecycle: .expired, stagedPath: .some(nil), persistentPath: .some(nil), leaseSubmissionID: .some(nil), updatedAt: now))
    }

    private func requireFreeSpace(bytesNeeded: Int64) throws {
        let url = URL(fileURLWithPath: configuration.acceptedRoot)
        let available = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard Int64(available) - bytesNeeded >= configuration.minimumFreeBytes else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Accepted attachment storage reserve would be crossed", retryable: true)
        }
    }

    private func sweepUnreferencedFiles(records: [StoredComposerAttachment]) throws {
        let known = Set(records.compactMap(\.persistentPath))
        guard let enumerator = files.enumerator(at: URL(fileURLWithPath: configuration.acceptedRoot), includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && !known.contains(url.path) {
            try? files.removeItem(at: url)
        }
    }

    private func replacing(_ record: StoredComposerAttachment, lifecycle: ComposerAttachmentLifecycle? = nil, sessionID: UUID?? = nil, turnID: UUID?? = nil, stagedPath: String?? = nil, persistentPath: String?? = nil, leaseSubmissionID: UUID?? = nil, updatedAt: Date) -> StoredComposerAttachment {
        let nextLifecycle = lifecycle ?? record.wire.lifecycle
        let wire = ComposerAttachmentWire(attachmentID: record.wire.attachmentID, displayName: record.wire.displayName, mediaType: record.wire.mediaType, byteSize: record.wire.byteSize, digest: record.wire.digest, pixelWidth: record.wire.pixelWidth, pixelHeight: record.wire.pixelHeight, lifecycle: nextLifecycle, expiresAt: nextLifecycle == .staged ? record.wire.expiresAt : nil)
        return .init(wire: wire, actorID: record.actorID, projectID: record.projectID, sessionID: sessionID ?? record.sessionID, turnID: turnID ?? record.turnID, stagedPath: stagedPath ?? record.stagedPath, persistentPath: persistentPath ?? record.persistentPath, leaseSubmissionID: leaseSubmissionID ?? record.leaseSubmissionID, createdAt: record.createdAt, updatedAt: updatedAt)
    }

    private static func ensurePrivateDirectory(_ path: String, files: FileManager) throws {
        try files.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    private static func sanitizedName(_ value: String, mediaType: String) -> String {
        let leaf = URL(fileURLWithPath: value).lastPathComponent.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
        let trimmed = String(leaf.prefix(128)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "image.\(fileExtension(for: mediaType))" : trimmed
    }

    private static func fileExtension(for mediaType: String) -> String {
        switch mediaType { case "image/png": "png"
        case "image/jpeg": "jpg"
        case "image/webp": "webp"
        default: "img" }
    }

    private struct RasterMetadata { let mediaType: String
        let width: Int
        let height: Int
    }

    private static func validateRaster(_ data: Data, declaredMediaType: String?, maximumPixelCount: Int, maximumDimension: Int) throws -> RasterMetadata {
        let metadata: RasterMetadata
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            metadata = try pngMetadata(data)
        } else if data.starts(with: [0xFF, 0xD8]) {
            metadata = try jpegMetadata(data)
        } else if data.count >= 30, String(data: data[0 ..< 4], encoding: .ascii) == "RIFF", String(data: data[8 ..< 12], encoding: .ascii) == "WEBP" {
            guard littleEndian32(data, 4) + 8 == data.count else { throw invalidRaster() }
            metadata = try webPMetadata(data)
        } else {
            throw invalidRaster()
        }
        guard declaredMediaType == nil || declaredMediaType == metadata.mediaType,
              metadata.width > 0, metadata.height > 0,
              metadata.width <= maximumDimension, metadata.height <= maximumDimension,
              metadata.width <= maximumPixelCount / metadata.height
        else { throw invalidRaster() }
        return metadata
    }

    private static func pngMetadata(_ data: Data) throws -> RasterMetadata {
        guard data.count >= 45 else { throw invalidRaster() }
        var index = 8
        var width = 0, height = 0
        var sawHeader = false, sawImageData = false, sawEnd = false
        while index + 12 <= data.count {
            let length = bigEndian32(data, index)
            guard length >= 0, index + 12 + length <= data.count,
                  let kind = String(data: data[index + 4 ..< index + 8], encoding: .ascii)
            else { throw invalidRaster() }
            if !sawHeader {
                guard kind == "IHDR", length == 13 else { throw invalidRaster() }
                width = bigEndian32(data, index + 8)
                height = bigEndian32(data, index + 12)
                sawHeader = true
            } else if kind == "IDAT" { sawImageData = true }
            else if kind == "IEND" { guard length == 0 else { throw invalidRaster() }
                sawEnd = true
                index += 12
                break
            }
            index += 12 + length
        }
        guard sawHeader, sawImageData, sawEnd, index == data.count else { throw invalidRaster() }
        return .init(mediaType: "image/png", width: width, height: height)
    }

    private static func jpegMetadata(_ data: Data) throws -> RasterMetadata {
        guard data.count >= 4, data.suffix(2) == Data([0xFF, 0xD9]) else { throw invalidRaster() }
        var index = 2
        let sof: Set<UInt8> = [0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF]
        while index + 9 < data.count {
            guard data[index] == 0xFF else { index += 1
                continue
            }
            let marker = data[index + 1]
            if marker == 0xD9 || marker == 0xDA { break }
            guard index + 4 <= data.count else { break }
            let length = Int(data[index + 2]) << 8 | Int(data[index + 3])
            guard length >= 2, index + 2 + length <= data.count else { throw invalidRaster() }
            if sof.contains(marker) {
                let height = Int(data[index + 5]) << 8 | Int(data[index + 6])
                let width = Int(data[index + 7]) << 8 | Int(data[index + 8])
                return .init(mediaType: "image/jpeg", width: width, height: height)
            }
            index += 2 + length
        }
        throw invalidRaster()
    }

    private static func webPMetadata(_ data: Data) throws -> RasterMetadata {
        let kind = String(data: data[12 ..< 16], encoding: .ascii)
        if kind == "VP8X", data.count >= 30 {
            let width = 1 + littleEndian24(data, 24)
            let height = 1 + littleEndian24(data, 27)
            return .init(mediaType: "image/webp", width: width, height: height)
        }
        if kind == "VP8 ", data.count >= 30, data[23] == 0x9D, data[24] == 0x01, data[25] == 0x2A {
            let width = (Int(data[26]) | Int(data[27]) << 8) & 0x3FFF
            let height = (Int(data[28]) | Int(data[29]) << 8) & 0x3FFF
            return .init(mediaType: "image/webp", width: width, height: height)
        }
        if kind == "VP8L", data.count >= 25, data[20] == 0x2F {
            let width = 1 + Int(data[21]) + ((Int(data[22]) & 0x3F) << 8)
            let height = 1 + (Int(data[22]) >> 6) + (Int(data[23]) << 2) + ((Int(data[24]) & 0x0F) << 10)
            return .init(mediaType: "image/webp", width: width, height: height)
        }
        throw invalidRaster()
    }

    private static func bigEndian32(_ data: Data, _ offset: Int) -> Int {
        (Int(data[offset]) << 24) | (Int(data[offset + 1]) << 16) | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
    }

    private static func littleEndian24(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16)
    }

    private static func littleEndian32(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) | (Int(data[offset + 1]) << 8) | (Int(data[offset + 2]) << 16) | (Int(data[offset + 3]) << 24)
    }

    private static func invalidRaster() -> ServiceAPIError {
        ServiceAPIError(code: .invalidRequest, message: "Attachment is not a valid bounded PNG, JPEG, or WebP raster image")
    }
}
