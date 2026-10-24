import Foundation
import RepoPromptSecureStorage

protocol TipHistoryReleaseDiscovering: Sendable {
    func fetchPage(repository: TipHistoryRepository, page: Int) async throws -> TipHistoryReleasePage
    func invalidateCache() async
}

extension TipHistoryReleaseDiscovering {
    func invalidateCache() async {}
}

struct TipHistoryReleasePage {
    let entries: [TipHistoryEntry]
    let nextPage: Int?
    let omittedCount: Int
}

/// Public GitHub/TLS metadata, NOT a signed history catalog or a compatibility
/// review. Archive acquisition still belongs exclusively to the verified worker.
actor TipHistoryReleaseDiscovery: TipHistoryReleaseDiscovering {
    typealias Fetch = @Sendable (URL, Int) async throws -> Data
    static let repositoryPath = "repoprompt/repoprompt-ce-tip-updates"
    static let sourceRepositoryPath = "repoprompt/repoprompt-ce"
    static let maximumPages = 10
    private let fetch: Fetch
    private var index: Index?
    private var indexTask: Task<Index, Error>?
    private var pageTasks: [Int: Task<TipHistoryReleasePage, Error>] = [:]
    private var commitTexts: [String: CommitText] = [:]
    private var cacheGeneration: UInt64 = 0

    private struct Candidate {
        let release: Release
        let buildNumber: String
        let build: SparkleBuildVersion
    }

    private struct Index {
        let createdAt: Date
        let candidates: [Candidate]
        let omittedCount: Int
        var offset = 0
        var pages: [Int: TipHistoryReleasePage] = [:]
    }

    init(fetch: Fetch? = nil) {
        if let fetch {
            self.fetch = fetch
        } else {
            let transport = TipHistoryPublicReleaseTransport()
            self.fetch = { url, maximumBytes in
                try await transport.receive(url, maximumBytes: maximumBytes)
            }
        }
    }

    func invalidateCache() async {
        guard !Task.isCancelled else { return }
        cacheGeneration &+= 1
        for task in pageTasks.values {
            task.cancel()
        }
        indexTask?.cancel()
        pageTasks.removeAll()
        indexTask = nil
        index = nil
        // Immutable SHA-keyed successful commit text remains reusable. Stale
        // work is generation-fenced before every index/page cache publication.
    }

    func fetchPage(repository: TipHistoryRepository, page: Int) async throws -> TipHistoryReleasePage {
        guard repository.path == Self.repositoryPath, (1 ... Self.maximumPages).contains(page) else {
            throw TipHistoryLoadError.malformed
        }
        let generation = cacheGeneration
        if let task = pageTasks[page] {
            let result = try await task.value
            try requireGeneration(generation)
            return result
        }
        // Coalesce refreshes; a short-lived index also preserves successful-page
        // boundaries when missing metadata is skipped. No persistent cache.
        let task = Task { try await self.loadPage(repository: repository, page: page, generation: generation) }
        pageTasks[page] = task
        do {
            let result = try await withTaskCancellationHandler {
                let result = try await task.value
                try Task.checkCancellation()
                return result
            } onCancel: { task.cancel() }
            try requireGeneration(generation)
            pageTasks[page] = nil
            return result
        } catch {
            if generation == cacheGeneration {
                pageTasks[page] = nil
            }
            throw error
        }
    }

    private func requireGeneration(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == cacheGeneration else { throw CancellationError() }
    }

    private func loadPage(repository: TipHistoryRepository, page: Int, generation: UInt64) async throws -> TipHistoryReleasePage {
        try requireGeneration(generation)
        if let index, let result = index.pages[page], page != 1 || Date().timeIntervalSince(index.createdAt) < 600 {
            return result
        }
        if index == nil || (page == 1 && Date().timeIntervalSince(index!.createdAt) >= 600) {
            if indexTask == nil {
                indexTask = Task { try await self.loadIndex(generation: generation) }
            }
            guard let task = indexTask else { throw TipHistoryLoadError.network }
            do {
                let loadedIndex = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try requireGeneration(generation)
                index = loadedIndex
                indexTask = nil
            } catch {
                if generation == cacheGeneration {
                    indexTask = nil
                }
                throw error
            }
        }
        try Task.checkCancellation()
        guard var snapshot = index, page == snapshot.pages.count + 1 else { throw TipHistoryLoadError.malformed }
        var entries: [TipHistoryEntry] = []
        var omitted = page == 1 ? snapshot.omittedCount : 0
        while entries.count < 30, snapshot.offset < snapshot.candidates.count {
            try Task.checkCancellation()
            // Never request commit text for more than thirty successful entries
            // per UI page. Failed metadata candidates do not consume commit API.
            let end = min(snapshot.candidates.count, snapshot.offset + min(4, 30 - entries.count))
            let candidates = Array(snapshot.candidates[snapshot.offset ..< end].enumerated())
            let batch = try await withThrowingTaskGroup(of: (Int, TipHistoryEntry?).self) { group in
                for (position, candidate) in candidates {
                    group.addTask {
                        do {
                            let entry = try await self.entry(candidate.release, repository: repository, expectedBuild: candidate.buildNumber)
                            return (position, entry)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            if Self.isTransientMetadataFailure(error) {
                                throw error
                            }
                            return (position, nil)
                        }
                    }
                }
                var result: [(Int, TipHistoryEntry?)] = []
                for try await value in group {
                    result.append(value)
                }
                return result.sorted { $0.0 < $1.0 }
            }
            for (_, entry) in batch {
                if let entry {
                    entries.append(entry)
                } else {
                    omitted += 1
                }
            }
            snapshot.offset = end
        }
        try Task.checkCancellation()
        entries.sort { $0.build == $1.build ? $0.tag < $1.tag : $1.build < $0.build }
        let result = TipHistoryReleasePage(entries: entries, nextPage: snapshot.offset < snapshot.candidates.count ? page + 1 : nil, omittedCount: omitted)
        try requireGeneration(generation)
        snapshot.pages[page] = result
        index = snapshot
        return result
    }

    private static func isTransientMetadataFailure(_ error: Error) -> Bool {
        let reason = (error as? TipHistoryCatalogFetchFailure)?.reason ?? (error as? TipHistoryLoadError)
        switch reason {
        case .network, .timeout: return true
        case let .httpStatus(status): return status == 403 || status == 408 || status == 429 || (500 ... 599).contains(status)
        default: return false
        }
    }

    private func loadIndex(generation: UInt64) async throws -> Index {
        var candidates: [Candidate] = []
        var tags = Set<String>()
        var omitted = 0
        // This repository's API is tag-ordered, not publication/build-ordered.
        // Enumerate a bounded index before choosing the newest numeric builds.
        for page in 1 ... Self.maximumPages {
            let url = URL(string: "https://api.github.com/repos/\(Self.repositoryPath)/releases?per_page=100&page=\(page)")!
            let data = try await boundedFetch(url, maximumBytes: 4_194_304)
            let records = try JSONDecoder().decode([ReleaseRecord].self, from: data)
            guard records.count <= 100 else { throw TipHistoryLoadError.malformed }
            for record in records {
                guard let release = record.release, !release.draft, release.published_at.flatMap(Self.date) != nil,
                      TipHistoryRepository.validTag(release.tag_name), tags.insert(release.tag_name).inserted,
                      let candidate = Self.candidate(release)
                else { omitted += 1
                    continue
                }
                candidates.append(candidate)
            }
            if records.count < 100 {
                break
            }
        }
        candidates.sort { $0.build == $1.build ? $0.release.tag_name < $1.release.tag_name : $1.build < $0.build }
        // Commit objects are immutable by full SHA. Keep successful text across
        // index refreshes, bounded to releases still in this discovery window.
        try requireGeneration(generation)
        let retainedTags = Set(candidates.map(\.release.tag_name))
        commitTexts = commitTexts.filter { retainedTags.contains("tip-" + $0.key.prefix(12)) }
        return Index(createdAt: Date(), candidates: candidates, omittedCount: omitted)
    }

    private static func candidate(_ release: Release) -> Candidate? {
        let prefix = "RepoPrompt-\(release.tag_name)-"
        let names = release.assets.map(\.name).filter { $0.hasPrefix(prefix) && $0.hasSuffix(".zip") }
        guard names.count == 1, let name = names.first else { return nil }
        let buildNumber = String(name.dropFirst(prefix.count).dropLast(4))
        guard matches(buildNumber, #"^[0-9]+(\.[0-9]+){0,3}$"#), let build = SparkleBuildVersion(buildNumber) else { return nil }
        return Candidate(release: release, buildNumber: buildNumber, build: build)
    }

    private func boundedFetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        let data = try await fetch(url, maximumBytes)
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw TipHistoryLoadError.malformed }
        return data
    }

    private func entry(_ release: Release, repository: TipHistoryRepository, expectedBuild: String) async throws -> TipHistoryEntry {
        var assets: [String: Asset] = [:]
        for asset in release.assets {
            guard assets[asset.name] == nil, asset.size > 0,
                  let url = URL(string: asset.browser_download_url),
                  repository.trustsDownload(url, tag: release.tag_name, name: asset.name)
            else { throw TipHistoryLoadError.malformed }
            assets[asset.name] = asset
        }
        func asset(_ name: String) throws -> Asset {
            guard let value = assets[name], value.state == "uploaded" else { throw TipHistoryLoadError.malformed }
            return value
        }
        let rolloutAsset = try asset("identity-rollout.json")
        let rolloutData = try await read(rolloutAsset, maximumBytes: 131_072)
        let rollout = try JSONDecoder().decode(Rollout.self, from: rolloutData)
        guard rollout.schemaVersion == 1, rollout.channel == "tip", rollout.updateRepository == repository.path,
              rollout.buildNumber == expectedBuild,
              rollout.sourceTag == release.tag_name,
              Self.matches(rollout.releaseCommit, #"^[0-9a-f]{40}$"#),
              "tip-" + rollout.releaseCommit.prefix(12) == release.tag_name,
              let build = SparkleBuildVersion(rollout.buildNumber),
              Self.matches(rollout.buildNumber, #"^[0-9]+(\.[0-9]+){0,3}$"#),
              Self.clean(rollout.marketingVersion, limit: 40) == rollout.marketingVersion, !rollout.marketingVersion.isEmpty,
              let role = TipHistoryRole(rawValue: rollout.currentRole), role != .unknown,
              let identity = TipHistorySigningIdentity(rawValue: rollout.signingIdentity),
              let official = OfficialApplicationIdentity(rawValue: rollout.signingIdentity),
              official.bundleIdentifier == rollout.bundleIdentifier, official.teamIdentifier == rollout.teamIdentifier,
              identity == ((role == .legacy || role == .preparer) ? .legacy : .successor),
              rollout.migrationPhase == (role == .preparer ? "legacy-preparer" : "disabled"),
              Self.matches(rollout.appArtifactManifest.sha256, #"^[0-9a-f]{64}$"#)
        else { throw TipHistoryLoadError.malformed }
        // A transition PKG is not an app ZIP and cannot use this download-only
        // path. Select the current role, never a sibling appcast enclosure.
        let items = rollout.appcastItems.filter { $0.role == rollout.currentRole }
        guard items.count == 1, let item = items.first,
              item.installationType == "application", role != .transition,
              item.tag == release.tag_name, item.buildNumber == rollout.buildNumber,
              item.marketingVersion == rollout.marketingVersion,
              let minimumOS = SparkleBuildVersion(item.minimumSystemVersion),
              item.enclosureName == "RepoPrompt-\(release.tag_name)-\(rollout.buildNumber).zip",
              rollout.appArtifactManifest.name == "RepoPrompt-\(release.tag_name)-\(rollout.buildNumber)-artifact-manifest.json",
              Self.matches(item.enclosureSha256, #"^[0-9a-f]{64}$"#),
              Data(base64Encoded: item.edSignature)?.count == 64,
              item.enclosureSize > 0, item.enclosureSize <= 2_147_483_648,
              let enclosureURL = URL(string: item.url),
              repository.trustsDownload(enclosureURL, tag: release.tag_name, name: item.enclosureName)
        else { throw TipHistoryLoadError.malformed }
        let enclosure = try asset(item.enclosureName)
        guard enclosure.size == item.enclosureSize, enclosure.browser_download_url == item.url else { throw TipHistoryLoadError.integrityMismatch }
        let manifestAsset = try asset(rollout.appArtifactManifest.name)
        let manifestData = try await read(manifestAsset, maximumBytes: 524_288)
        guard TipHistorySignatureVerifier.sha256(manifestData) == rollout.appArtifactManifest.sha256 else { throw TipHistoryLoadError.integrityMismatch }
        let manifest = try JSONDecoder().decode(ArtifactManifest.self, from: manifestData)
        let architectures = Set(manifest.bundle.architectures)
        guard manifest.schema_version == 1,
              manifest.bundle.identifier == rollout.bundleIdentifier,
              manifest.bundle.build_number == rollout.buildNumber,
              manifest.bundle.marketing_version == rollout.marketingVersion,
              manifest.bundle.signing_mode == "developer-id",
              manifest.bundle_signing.identifier == rollout.bundleIdentifier,
              manifest.bundle_signing.team_identifier == rollout.teamIdentifier,
              !architectures.isEmpty, architectures.isSubset(of: ["arm64", "x86_64"]),
              architectures.count == manifest.bundle.architectures.count
        else { throw TipHistoryLoadError.integrityMismatch }
        if let checksumAsset = assets["SHA256SUMS"] {
            let sums = try await read(checksumAsset, maximumBytes: 65536)
            let checksums = try Self.checksums(sums)
            guard checksums[item.enclosureName] == item.enclosureSha256,
                  checksums[manifestAsset.name] == rollout.appArtifactManifest.sha256,
                  checksums[rolloutAsset.name] == TipHistorySignatureVerifier.sha256(rolloutData)
            else { throw TipHistoryLoadError.integrityMismatch }
        }
        let text = try await commitText(rollout.releaseCommit)
        return TipHistoryEntry(
            tag: release.tag_name, releaseCommit: rollout.releaseCommit, shortSHA: String(rollout.releaseCommit.prefix(12)),
            commitDate: text.date, buildNumber: rollout.buildNumber, build: build, marketingVersion: rollout.marketingVersion,
            hasHistoryUI: false, origin: .githubRelease, role: role, signingIdentity: identity,
            bundleIdentifier: rollout.bundleIdentifier, teamIdentifier: rollout.teamIdentifier, migrationPhase: rollout.migrationPhase,
            installationType: .application, minimumSystemVersion: minimumOS, minimumSystemVersionString: item.minimumSystemVersion,
            commitRange: nil, architectures: architectures, title: text.title, titleSource: .commit, notes: text.notes,
            omittedNoteCount: text.omitted, downgradeBarrier: false, downgradeBarrierReasons: [],
            // This is an extraction LIMIT, not a claimed measured expanded size.
            // Existing release metadata does not publish expanded archive size.
            download: TipHistoryDownload(
                name: item.enclosureName,
                url: enclosureURL,
                size: item.enclosureSize,
                expandedSize: 8_589_934_592,
                sha256: item.enclosureSha256,
                edSignature: item.edSignature
            ),
            metadataProblem: nil, historyCatalogSha256: nil
        )
    }

    private func read(_ asset: Asset, maximumBytes: Int) async throws -> Data {
        guard asset.state == "uploaded", asset.size > 0, asset.size <= Int64(maximumBytes),
              let url = URL(string: asset.browser_download_url)
        else { throw TipHistoryLoadError.malformed }
        let data = try await boundedFetch(url, maximumBytes: maximumBytes)
        guard Int64(data.count) == asset.size else { throw TipHistoryLoadError.integrityMismatch }
        return data
    }

    private struct CommitText {
        let title: String
        let notes: [TipHistoryNote]
        let date: Date?
        let omitted: Int
    }

    private func commitText(_ sha: String) async throws -> CommitText {
        if let cached = commitTexts[sha] {
            return cached
        }
        do {
            let url = URL(string: "https://api.github.com/repos/\(Self.sourceRepositoryPath)/commits/\(sha)?per_page=1")!
            let data = try await boundedFetch(url, maximumBytes: 262_144)
            let commit = try JSONDecoder().decode(Commit.self, from: data)
            guard commit.sha == sha else { throw TipHistoryLoadError.integrityMismatch }
            let lines = commit.commit.message.components(separatedBy: .newlines).map { Self.clean($0, limit: 200) }.filter { !$0.isEmpty }
            guard let first = lines.first else { throw TipHistoryLoadError.malformed }
            let merge = Self.matches(first, #"^Merge pull request #[0-9]+.*$"#)
            let subjectIndex = merge && lines.count > 1 ? 1 : 0
            let title = Self.clean(lines[subjectIndex], limit: 90)
            var notes = lines.enumerated().filter { $0.offset != subjectIndex }.map(\.element)
            if notes.isEmpty {
                notes = ["Source change: \(title)"]
            }
            let text = CommitText(
                title: title,
                notes: notes.prefix(10).map { TipHistoryNote(text: $0, source: .commit) },
                date: commit.commit.committer.date.flatMap(Self.date),
                omitted: max(0, notes.count - 10)
            )
            commitTexts[sha] = text
            return text
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return CommitText(
                title: "Commit \(sha.prefix(12)) — source unavailable",
                notes: [TipHistoryNote(text: Self.clean("Source commit title and notes are unavailable (\(Self.failureDescription(error))). Public release metadata is not a signed history catalog or a safety review.", limit: 200), source: .commit)],
                date: nil,
                omitted: 0
            )
        }
    }

    private static func failureDescription(_ error: Error) -> String {
        if let failure = error as? TipHistoryCatalogFetchFailure {
            return failure.reason.message
        }
        if let error = error as? TipHistoryLoadError {
            return error.message
        }
        return "source request failed"
    }

    private static func checksums(_ data: Data) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { throw TipHistoryLoadError.malformed }
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { throw TipHistoryLoadError.malformed }
            let hash = String(fields[0])
            let name = String(fields[1]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"^\*"#, with: "", options: .regularExpression)
            guard matches(hash, #"^[0-9a-f]{64}$"#), result[name] == nil else { throw TipHistoryLoadError.malformed }
            result[name] = hash
        }
        return result
    }

    private static func clean(_ value: String, limit: Int) -> String {
        TipHistoryCatalogDecoder.sanitize(value, limit: limit)
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        TipHistoryRepository.matches(value, pattern)
    }

    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private struct ReleaseRecord: Decodable {
        let release: Release?
        init(from decoder: Decoder) throws {
            release = try? Release(from: decoder)
        }
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let published_at: String?
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let size: Int64
        let state: String
        let browser_download_url: String
    }

    private struct Rollout: Decodable {
        let schemaVersion: Int
        let channel, updateRepository, sourceTag, releaseCommit, buildNumber, marketingVersion: String
        let currentRole, signingIdentity, bundleIdentifier, teamIdentifier, migrationPhase: String
        let appArtifactManifest: ManifestReference
        let appcastItems: [Item]
    }

    private struct ManifestReference: Decodable { let name, sha256: String }
    private struct Item: Decodable {
        let role, tag, buildNumber, marketingVersion, installationType, minimumSystemVersion: String
        let enclosureName, enclosureSha256, edSignature, url: String
        let enclosureSize: Int64
    }

    private struct ArtifactManifest: Decodable {
        let schema_version: Int
        let bundle: Bundle
        let bundle_signing: Signing
        struct Bundle: Decodable {
            let identifier, build_number, marketing_version, signing_mode: String
            let architectures: [String]
        }

        struct Signing: Decodable { let identifier, team_identifier: String }
    }

    private struct Commit: Decodable {
        let sha: String
        let commit: Detail
        struct Detail: Decodable {
            let message: String
            let committer: Committer
        }

        struct Committer: Decodable { let date: String? }
    }
}

/// One discovery-provider anonymous API budget, including repeated refreshes and older
/// pages. Asset requests use browser_download_url/CDN and do not consume REST
/// quota. No tokens, cookies, user credentials, persistent cache, or retries.
private actor TipHistoryPublicReleaseTransport {
    private var apiRequests: [Date] = []

    func receive(_ url: URL, maximumBytes: Int) async throws -> Data {
        let api = Self.trustsAPI(url)
        guard api || Self.trustsAsset(url) else { throw TipHistoryLoadError.malformed }
        if api {
            let now = Date()
            apiRequests.removeAll { now.timeIntervalSince($0) >= 3600 }
            guard apiRequests.count < 60 else {
                throw TipHistoryCatalogFetchFailure(reason: .httpStatus(429), retryAfter: apiRequests.first?.addingTimeInterval(3600))
            }
            apiRequests.append(now)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TipHistoryRelease-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("metadata")
            let transfer = TipHistoryTransfer(destination: file, maximumBytes: Int64(maximumBytes), expectedBytes: nil, allowsRedirect: {
                $0 == url || (!api && TipHistoryTransfer.allowsReleaseCDN($0))
            })
            try await transfer.receive(url, requestTimeout: 15, resourceTimeout: 30)
            try Task.checkCancellation()
            return try Data(contentsOf: file)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as TipHistoryTransferFailure {
            if let status = failure.httpStatus {
                throw TipHistoryCatalogFetchFailure(reason: .httpStatus(status), retryAfter: failure.retryAfter)
            }
            if failure.reason == .timeout {
                throw TipHistoryLoadError.timeout
            }
            if failure.reason == .sizeMismatch || failure.reason == .untrustedRedirect {
                throw TipHistoryLoadError.integrityMismatch
            }
            throw TipHistoryLoadError.network
        }
    }

    private static func trustsAPI(_ url: URL) -> Bool {
        guard TipHistoryTransfer.isHTTPSWithoutCredentials(url), url.host == "api.github.com", url.fragment == nil else { return false }
        if url.path == "/repos/\(TipHistoryReleaseDiscovery.repositoryPath)/releases" {
            return (1 ... TipHistoryReleaseDiscovery.maximumPages).contains { page in
                url.absoluteString == "https://api.github.com/repos/\(TipHistoryReleaseDiscovery.repositoryPath)/releases?per_page=100&page=\(page)"
            }
        }
        let prefix = "/repos/\(TipHistoryReleaseDiscovery.sourceRepositoryPath)/commits/"
        guard url.query == "per_page=1", url.path.hasPrefix(prefix), !url.absoluteString.contains("%") else { return false }
        return TipHistoryRepository.matches(String(url.path.dropFirst(prefix.count)), #"^[0-9a-f]{40}$"#)
    }

    private static func trustsAsset(_ url: URL) -> Bool {
        let parts = url.pathComponents
        guard parts.count == 7,
              let repository = TipHistoryRepository(feedURL: URL(string: "https://github.com/\(TipHistoryReleaseDiscovery.repositoryPath)/releases/latest/download/appcast.xml"))
        else { return false }
        return repository.trustsDownload(url, tag: parts[5], name: parts[6])
    }
}
