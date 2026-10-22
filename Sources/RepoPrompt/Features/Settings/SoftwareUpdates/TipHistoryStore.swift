import AppKit
import Combine
import Foundation

/// History has its own request identities; it never alters Sparkle's latest-only
/// check state machine or any update/channel/defaults preference.
enum TipHistorySource: String, Equatable {
    case signedCatalog, githubReleases
}

enum TipHistoryCatalogState: Equatable {
    case idle, loading, loaded(refreshedAt: Date), failed(TipHistoryLoadError)
}

enum TipHistoryOlderPageState: Equatable {
    case none, available, loading, failed(TipHistoryLoadError), exhausted, pageLimitReached
}

enum TipHistoryDownloadState: Equatable {
    case idle
    case choosingDestination(tag: String)
    case downloading(tag: String, receivedBytes: Int64, totalBytes: Int64)
    case verifying(tag: String)
    case committing(tag: String)
    case ready(tag: String, appURL: URL, folderURL: URL)
    case failed(tag: String, TipHistoryDownloadError)

    var tag: String? {
        switch self {
        case .idle: nil
        case let .choosingDestination(tag), let .downloading(tag, _, _), let .verifying(tag), let .committing(tag), let .ready(tag, _, _), let .failed(tag, _): tag
        }
    }

    var isActive: Bool {
        switch self {
        case .choosingDestination, .downloading, .verifying, .committing: true
        default: false
        }
    }
}

struct TipHistoryRow: Identifiable, Equatable {
    let entry: TipHistoryEntry
    let availability: TipHistoryAvailability
    var id: String {
        entry.tag
    }
}

@MainActor
final class TipHistoryStore: ObservableObject {
    typealias PageDecoder = @Sendable (Data, String?, String?, String, TipHistoryRepository) throws -> TipHistoryPage

    @Published private(set) var historySource: TipHistorySource?
    @Published private(set) var releaseOmittedCount = 0
    @Published private(set) var acquiredForInspectionOnly = false
    var isInspectionOnlyContext: Bool {
        context.runningIdentity == .nonOfficial
    }

    @Published private(set) var catalogState: TipHistoryCatalogState = .idle
    @Published private(set) var olderPageState: TipHistoryOlderPageState = .none
    @Published private(set) var rows: [TipHistoryRow] = []
    @Published private(set) var historyStartBuild: String?
    @Published var selectedTag: String?
    @Published var confirmationEntry: TipHistoryEntry?
    @Published private(set) var downloadState: TipHistoryDownloadState = .idle
    @Published private(set) var retryAfter: Date?
    @Published private(set) var catalogRetryAfter: Date?
    @Published private(set) var downloadHTTPStatus: Int?
    var offersDownloadRetry: Bool {
        guard case let .failed(_, error) = downloadState, error.permitsRetry || error == .accessDenied else { return false }
        if let status = downloadHTTPStatus, status != 403, status != 408, status != 429, !(500 ... 599).contains(status) { return false }
        return true
    }

    var canRetryDownload: Bool {
        offersDownloadRetry && (retryAfter.map { clock() >= $0 } ?? true)
    }

    @Published private(set) var lastRefreshedAt: Date?
    @Published private(set) var pageCount = 0
    @Published private(set) var context: TipHistoryInstallationContext
    private(set) var catalogGeneration: UInt64 = 0
    private(set) var downloadGeneration: UInt64 = 0
    private(set) var acquiredEntry: TipHistoryEntry?

    let repository: TipHistoryRepository
    private let fetcher: any TipHistoryCatalogFetching
    private let releaseProvider: any TipHistoryReleaseDiscovering
    private let downloader: any TipHistoryArtifactDownloading
    private let publicKey: String
    private let contextProvider: @MainActor () -> TipHistoryInstallationContext
    private let channelProvider: @MainActor () -> UpdateChannel
    private let latestNoticeProvider: @MainActor () -> AvailableUpdateNotice?
    private let clock: @MainActor () -> Date
    private let automaticChecksProvider: @MainActor () -> Bool
    var automaticallyChecksForUpdates: Bool {
        automaticChecksProvider()
    }

    private let chooseDestination: @MainActor () async -> URL?
    private let cancelDestination: @MainActor () -> Void
    private let commitApplication: @MainActor (URL, URL, TipHistoryEntry) throws -> URL
    private let decode: PageDecoder
    private var entries: [TipHistoryEntry] = []
    /// Refresh replaces display pages, not already authenticated safety evidence.
    private var knownBarriers: [String: TipHistoryEntry] = [:]
    // A 404/410 disables the exact authenticated entry without removing its row.
    // Only an explicit refresh followed by matching entry revalidation from the
    // active source may clear it; TTL reloads and channel changes cannot. Release
    // metadata revalidation is not a catalog signature or archive verification.
    private var missingAssets: [String: TipHistoryEntry] = [:]
    private var missingAssetsAwaitingRevalidation: Set<String> = []
    private var olderReference: TipHistoryPageReference?
    private var visitedReferences: Set<TipHistoryPageReference> = []
    private var visitedTags: Set<String> = []
    private var highestHead: TipHistoryEntry?
    // Unsigned release metadata never establishes or regresses this authority.
    private var hasAuthenticatedSignedCatalog = false
    private var releaseNextPage: Int?
    private var releaseFetchedPages: Set<Int> = []
    private var headRequest: UUID?
    private var olderRequest: UUID?
    private var headTask: Task<Void, Never>?
    private var olderTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var ownedTasks: [UUID: Task<Void, Never>] = [:]
    private var attempt: Attempt?
    private var shuttingDown = false
    private var subscriptions: Set<AnyCancellable> = []

    private struct Attempt {
        let id: UUID
        let generation: UInt64
        let entry: TipHistoryEntry
        let context: TipHistoryInstallationContext
        let acknowledgedUnknownCoverage: Bool
        var committed = false
    }

    init(
        repository: TipHistoryRepository,
        fetcher: any TipHistoryCatalogFetching = TipHistoryCatalogFetcher(),
        releaseProvider: any TipHistoryReleaseDiscovering = TipHistoryReleaseDiscovery(),
        downloader: any TipHistoryArtifactDownloading,
        publicKey: String = SparkleUpdaterManager.pinnedPublicEdKey,
        contextProvider: @escaping @MainActor () -> TipHistoryInstallationContext,
        channelProvider: @escaping @MainActor () -> UpdateChannel,
        latestNoticeProvider: @escaping @MainActor () -> AvailableUpdateNotice? = { nil },
        clock: @escaping @MainActor () -> Date = { Date() },
        automaticChecksProvider: @escaping @MainActor () -> Bool = { false },
        chooseDestination: (@MainActor () async -> URL?)? = nil,
        cancelDestination: (@MainActor () -> Void)? = nil,
        commitApplication: @escaping @MainActor (URL, URL, TipHistoryEntry) throws -> URL = {
            try TipHistoryOwnedStaging.commit(payload: $0, destination: $1, build: $2.buildNumber, shortSHA: $2.shortSHA)
        },
        decode: @escaping PageDecoder = {
            try TipHistoryCatalogDecoder.decodePage(envelopeData: $0, expectedTag: $1, expectedSHA256: $2, publicKeyBase64: $3, repository: $4)
        }
    ) {
        self.repository = repository
        self.fetcher = fetcher
        self.releaseProvider = releaseProvider
        self.downloader = downloader
        self.publicKey = publicKey
        self.contextProvider = contextProvider
        self.channelProvider = channelProvider
        self.latestNoticeProvider = latestNoticeProvider
        self.clock = clock
        self.automaticChecksProvider = automaticChecksProvider
        let picker = TipHistoryDestinationPicker()
        self.chooseDestination = chooseDestination ?? { await picker.choose() }
        self.cancelDestination = cancelDestination ?? { picker.cancel() }
        self.commitApplication = commitApplication
        self.decode = decode
        context = contextProvider()
    }

    convenience init(manager: SparkleUpdaterManager, registry: TipHistoryStagingRegistry) {
        self.init(
            repository: UpdateChannel.tip.historyRepository!,
            downloader: TipHistoryDownloader(registry: registry),
            contextProvider: {
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
                let os = ProcessInfo.processInfo.operatingSystemVersion
                #if arch(arm64)
                    let architecture = "arm64"
                #else
                    let architecture = "x86_64"
                #endif
                return TipHistoryInstallationContext(
                    installedBuild: SparkleBuildVersion(build), installedBuildString: build,
                    runningIdentity: .current,
                    osVersion: SparkleBuildVersion("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")!, architecture: architecture,
                    migrationBlockedMessage: manager.updateInstallationBlockedMessage,
                    sparkleConfigurationValid: manager.sparkleConfigurationValid
                )
            },
            channelProvider: { manager.updateChannel },
            latestNoticeProvider: { manager.availableUpdate },
            automaticChecksProvider: { manager.automaticallyChecksForUpdates }
        )
        manager.$updateChannel.dropFirst().sink { [weak self] channel in
            self?.channelDidChange(channel)
        }.store(in: &subscriptions)
        // @Published emits before assignment. Schedule observation on MainActor
        // after the manager's mutation, then rederive against the actual authority.
        manager.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.contextDidChange() }
        }.store(in: &subscriptions)
    }

    func loadIfNeeded() {
        guard channelProvider() == .tip, !shuttingDown, headRequest == nil else { return }
        if let lastRefreshedAt, clock().timeIntervalSince(lastRefreshedAt) < 600 { return }
        startRefresh(revalidatingMissingAssets: false)
    }

    func refresh() {
        startRefresh(revalidatingMissingAssets: true)
    }

    private func startRefresh(revalidatingMissingAssets: Bool) {
        guard channelProvider() == .tip, !shuttingDown, catalogRetryAfter.map({ clock() >= $0 }) ?? true else { return }
        catalogRetryAfter = nil
        cancelLoad()
        contextDidChange()
        let id = UUID()
        let generation = catalogGeneration
        let missingTagsToRevalidate = revalidatingMissingAssets ? Set(missingAssets.keys) : []
        headRequest = id
        catalogState = .loading
        let fetcher = fetcher, repository = repository, key = publicKey, decoder = decode
        let task = Task.detached(priority: .utility) { [weak self] in
            let result: Result<TipHistoryPage, Error>
            do {
                let data = try await fetcher.fetch(repository.headURL, repository: repository, olderPage: false)
                try Task.checkCancellation()
                result = try .success(decoder(data, nil, nil, key, repository))
            } catch { result = .failure(error) }
            await self?.receiveHead(result, generation: generation, id: id, missingTagsToRevalidate: missingTagsToRevalidate)
            await self?.finishedTask(id)
        }
        headTask = task
        ownedTasks[id] = task
    }

    func cancelLoad() {
        catalogGeneration &+= 1
        headRequest = nil
        olderRequest = nil
        headTask?.cancel()
        olderTask?.cancel()
        headTask = nil
        olderTask = nil
        if catalogState == .loading {
            catalogState = lastRefreshedAt.map { .loaded(refreshedAt: $0) } ?? .idle
        }
        updateOlderState()
    }

    func loadOlderPage() {
        if historySource == .githubReleases {
            guard !shuttingDown, channelProvider() == .tip, headRequest == nil, olderRequest == nil,
                  pageCount < 10, catalogRetryAfter.map({ clock() >= $0 }) ?? true,
                  let page = releaseNextPage, page <= 10 else { return }
            startReleasePage(page, generation: catalogGeneration, missingTagsToRevalidate: [])
            return
        }
        guard !shuttingDown, channelProvider() == .tip, headRequest == nil, olderRequest == nil,
              pageCount < 10, catalogRetryAfter.map({ clock() >= $0 }) ?? true,
              let reference = olderReference else { return }
        catalogRetryAfter = nil
        guard !visitedReferences.contains(reference), !visitedTags.contains(reference.tag) else {
            olderPageState = .failed(.integrityMismatch)
            return
        }
        guard let url = repository.historyPageURL(tag: reference.tag) else {
            olderPageState = .failed(.malformed)
            return
        }
        let id = UUID(), generation = catalogGeneration
        olderRequest = id
        olderPageState = .loading
        let fetcher = fetcher, repository = repository, key = publicKey, decoder = decode
        let task = Task.detached(priority: .utility) { [weak self] in
            let result: Result<TipHistoryPage, Error>
            do {
                let data = try await fetcher.fetch(url, repository: repository, olderPage: true)
                try Task.checkCancellation()
                result = try .success(decoder(data, reference.tag, reference.sha256, key, repository))
            } catch { result = .failure(error) }
            await self?.receiveOlder(result, reference: reference, generation: generation, id: id)
            await self?.finishedTask(id)
        }
        olderTask = task
        ownedTasks[id] = task
    }

    /// Release pagination is deliberately not a signed page chain. It has its
    /// own integer cursor and never changes highestHead or authenticated safety
    /// evidence. Only a first catalog 404 may enter this path.
    private func startReleasePage(_ number: Int, generation: UInt64, missingTagsToRevalidate: Set<String>) {
        guard generation == catalogGeneration, !shuttingDown, channelProvider() == .tip,
              !hasAuthenticatedSignedCatalog, (1 ... 10).contains(number) else { return }
        if number != 1, releaseFetchedPages.contains(number) {
            olderPageState = .failed(.integrityMismatch)
            return
        }
        let id = UUID()
        catalogRetryAfter = nil
        if number == 1 {
            headRequest = id
            historySource = .githubReleases
            catalogState = .loading
        } else {
            olderRequest = id
            olderPageState = .loading
        }
        guard generation == catalogGeneration, !shuttingDown else { return }
        let provider = releaseProvider, repository = repository
        let task = Task.detached(priority: .utility) { [weak self] in
            let result: Result<TipHistoryReleasePage, Error>
            do {
                if number == 1 {
                    try Task.checkCancellation()
                    await provider.invalidateCache()
                    try Task.checkCancellation()
                }
                let page = try await provider.fetchPage(repository: repository, page: number)
                try Task.checkCancellation()
                result = .success(page)
            } catch { result = .failure(error) }
            await self?.receiveReleasePage(result, number: number, generation: generation, id: id, missingTagsToRevalidate: missingTagsToRevalidate)
            await self?.finishedTask(id)
        }
        if number == 1 { headTask = task }
        else { olderTask = task }
        ownedTasks[id] = task
    }

    private func receiveReleasePage(_ result: Result<TipHistoryReleasePage, Error>, number: Int, generation: UInt64, id: UUID, missingTagsToRevalidate: Set<String>) {
        guard generation == catalogGeneration, channelProvider() == .tip, !shuttingDown,
              !hasAuthenticatedSignedCatalog, historySource == .githubReleases else { return }
        if number == 1 {
            guard headRequest == id else { return }
            headRequest = nil
            headTask = nil
        } else {
            guard olderRequest == id, releaseNextPage == number else { return }
            olderRequest = nil
            olderTask = nil
        }
        do {
            let page = try result.get()
            // Page ten may advertise eleven as an overflow sentinel. It is
            // accepted here, displayed as pageLimitReached, and never fetched.
            guard page.entries.count <= 30, page.omittedCount >= 0,
                  page.nextPage == nil || page.nextPage == number + 1 else { throw TipHistoryLoadError.malformed }
            var merged = number == 1 ? [] : entries
            for entry in page.entries {
                guard entry.origin == .githubRelease else { throw TipHistoryLoadError.malformed }
                if let duplicate = merged.first(where: { $0.tag == entry.tag }) {
                    guard duplicate.matchesImmutableFields(of: entry) else { throw TipHistoryLoadError.integrityMismatch }
                    continue
                }
                // API pages may shift while a release is published. Never show
                // two rows for numerically equal builds, even with different tags.
                if merged.contains(where: { $0.build == entry.build }) { continue }
                merged.append(entry)
            }
            merged.sort { $0.build > $1.build }
            let (omitted, overflow) = (number == 1 ? 0 : releaseOmittedCount).addingReportingOverflow(page.omittedCount)
            guard !overflow else { throw TipHistoryLoadError.malformed }
            if number == 1 {
                releaseFetchedPages = [1]
                pageCount = 1
                missingAssetsAwaitingRevalidation = missingTagsToRevalidate
                lastRefreshedAt = clock()
                catalogState = .loaded(refreshedAt: lastRefreshedAt!)
            } else {
                releaseFetchedPages.insert(number)
                pageCount += 1
            }
            entries = merged
            releaseNextPage = page.nextPage
            releaseOmittedCount = omitted
            olderReference = nil
            // An API terminal page is not proof of a complete signed interval.
            historyStartBuild = nil
            revalidateMissingAssets(in: page.entries)
            if !entries.contains(where: { $0.tag == selectedTag }) { selectedTag = nil }
            updateOlderState()
            contextDidChange()
        } catch {
            if error is CancellationError { return }
            let failure = error as? TipHistoryCatalogFetchFailure
            let transfer = error as? TipHistoryTransferFailure
            catalogRetryAfter = failure?.retryAfter ?? transfer?.retryAfter
            let reason = failure?.reason ?? (error as? TipHistoryLoadError) ??
                transfer?.httpStatus.map { TipHistoryLoadError.httpStatus($0) } ??
                (transfer?.reason == .timeout ? .timeout : .network)
            if number == 1 { catalogState = .failed(reason) }
            else { olderPageState = .failed(reason) }
            contextDidChange()
        }
    }

    private func receiveHead(_ result: Result<TipHistoryPage, Error>, generation: UInt64, id: UUID, missingTagsToRevalidate: Set<String>) {
        guard generation == catalogGeneration, headRequest == id, channelProvider() == .tip, !shuttingDown else { return }
        headRequest = nil
        headTask = nil
        do {
            let page = try result.get()
            guard let head = page.entries.first else { throw TipHistoryLoadError.malformed }
            if let highestHead {
                guard head.build >= highestHead.build else { throw TipHistoryLoadError.integrityMismatch }
                // Keep this fence even across leaving/re-entering Tip, when the
                // displayed rows have been cleared. Numeric equality cannot
                // substitute a different release tag, nor can a tag be reused.
                if head.build == highestHead.build || head.tag == highestHead.tag {
                    guard head.tag == highestHead.tag, head.matchesImmutableFields(of: highestHead) else {
                        throw TipHistoryLoadError.integrityMismatch
                    }
                }
            }
            var previous = knownBarriers
            for entry in entries where entry.origin != .githubRelease {
                previous[entry.tag] = entry
            }
            // Leaving Tip clears displayed rows, not authenticated head identity
            // or safety barriers. The prior head may still acquire its catalog
            // digest when it is retained under a newer signed head on return.
            let previousHeadTag = entries.first?.tag ?? highestHead?.tag
            for entry in page.entries {
                guard let old = previous[entry.tag] else { continue }
                // A newer head is not authority to rewrite already verified
                // notes, barriers, or provenance. Only the previous page's own
                // head may gain its previously-null immutable catalog digest.
                let validDigest = old.historyCatalogSha256 == entry.historyCatalogSha256 ||
                    (old.tag == previousHeadTag && old.historyCatalogSha256 == nil && entry.historyCatalogSha256 != nil)
                guard old.matchesImmutableFields(of: entry), validDigest else { throw TipHistoryLoadError.integrityMismatch }
            }
            highestHead = head
            hasAuthenticatedSignedCatalog = true
            historySource = .signedCatalog
            releaseNextPage = nil
            releaseFetchedPages = []
            releaseOmittedCount = 0
            missingAssetsAwaitingRevalidation = missingTagsToRevalidate
            revalidateMissingAssets(in: page.entries)
            entries = page.entries
            olderReference = page.olderPage
            visitedReferences = []
            visitedTags = [page.generatedForTag]
            pageCount = 1
            lastRefreshedAt = clock()
            catalogState = .loaded(refreshedAt: lastRefreshedAt!)
            historyStartBuild = page.olderPage == nil ? entries.last?.buildNumber : nil
            if !entries.contains(where: { $0.tag == selectedTag }) { selectedTag = nil }
            updateOlderState()
            contextDidChange()
        } catch {
            if error is CancellationError { return }
            let failure = error as? TipHistoryCatalogFetchFailure
            let reason = failure?.reason ?? (error as? TipHistoryLoadError) ?? .network
            if reason == .notPublishedYet, !hasAuthenticatedSignedCatalog {
                startReleasePage(1, generation: generation, missingTagsToRevalidate: missingTagsToRevalidate)
                return
            }
            catalogRetryAfter = failure?.retryAfter
            catalogState = .failed(reason)
            contextDidChange()
        }
    }

    private func receiveOlder(_ result: Result<TipHistoryPage, Error>, reference: TipHistoryPageReference, generation: UInt64, id: UUID) {
        guard generation == catalogGeneration, olderRequest == id, olderReference == reference,
              channelProvider() == .tip, !shuttingDown else { return }
        olderRequest = nil
        olderTask = nil
        do {
            let page = try result.get()
            let existing = Dictionary(uniqueKeysWithValues: entries.map { ($0.tag, $0) })
            for overlap in page.entries where existing[overlap.tag] != nil {
                let previous = existing[overlap.tag]!
                let left = previous.historyCatalogSha256, right = overlap.historyCatalogSha256
                let validDigest = left == right ||
                    (right == nil && overlap.tag == page.generatedForTag && left == reference.sha256) ||
                    (left == nil && previous.tag == entries.first?.tag && right != nil)
                guard previous.matchesImmutableFields(of: overlap), validDigest else { throw TipHistoryLoadError.integrityMismatch }
                if overlap.tag == reference.tag, let digest = previous.historyCatalogSha256, digest != reference.sha256 {
                    throw TipHistoryLoadError.integrityMismatch
                }
            }
            let additions = page.entries.filter { existing[$0.tag] == nil }
            guard additions.allSatisfy({ entry in entries.last.map { entry.build < $0.build } ?? false }) else {
                throw TipHistoryLoadError.integrityMismatch
            }
            guard page.olderPage?.tag != reference.tag,
                  !(page.olderPage.map { visitedReferences.contains($0) || visitedTags.contains($0.tag) } ?? false)
            else {
                throw TipHistoryLoadError.integrityMismatch
            }
            if additions.isEmpty, page.olderPage != nil { throw TipHistoryLoadError.integrityMismatch }
            visitedReferences.insert(reference)
            visitedTags.insert(reference.tag)
            entries.append(contentsOf: additions)
            revalidateMissingAssets(in: page.entries)
            pageCount += 1
            olderReference = additions.isEmpty ? nil : page.olderPage
            historyStartBuild = olderReference == nil ? entries.last?.buildNumber : nil
            updateOlderState()
            contextDidChange()
        } catch {
            if error is CancellationError { return }
            let failure = error as? TipHistoryCatalogFetchFailure
            catalogRetryAfter = failure?.retryAfter
            olderPageState = .failed(failure?.reason ?? (error as? TipHistoryLoadError) ?? .network)
        }
    }

    private func updateOlderState() {
        if historySource == .githubReleases {
            if releaseNextPage == nil { olderPageState = pageCount == 0 ? .none : .exhausted }
            else if pageCount >= 10 || (releaseNextPage ?? 0) > 10 { olderPageState = .pageLimitReached }
            else { olderPageState = .available }
            return
        }
        if olderReference == nil { olderPageState = entries.isEmpty ? .none : .exhausted }
        else if pageCount >= 10 { olderPageState = .pageLimitReached }
        else { olderPageState = .available }
    }

    var historyBehindLatestNotice: Bool {
        guard let head = entries.first, let notice = latestNoticeProvider(), notice.channel == .tip,
              let text = notice.buildNumber, let build = SparkleBuildVersion(text) else { return false }
        return build > head.build
    }

    private func availability(_ entry: TipHistoryEntry) -> TipHistoryAvailability {
        let covered = (entries.filter { knownBarriers[$0.tag] == nil } + Array(knownBarriers.values)).sorted { $0.build > $1.build }
        var value = TipHistoryCompatibility.evaluate(entry, in: covered, context: context)
        if entry.origin == .githubRelease, case let .available(.older, cautions) = value,
           !cautions.contains(.barrierUnknownInstalledOutsideHistory)
        {
            value = .available(direction: .older, cautions: cautions + [.barrierUnknownInstalledOutsideHistory])
        }
        if case .available = value, missingAssets[entry.tag] != nil { return .unavailable(.missingAsset) }
        if case let .available(.older, cautions) = value, historyBehindLatestNotice,
           !cautions.contains(.downloadOnlyNonOfficial) { return .unavailable(.historyBehindInstalled) }
        return value
    }

    private func makeRow(_ entry: TipHistoryEntry) -> TipHistoryRow {
        TipHistoryRow(entry: entry, availability: availability(entry))
    }

    private func revalidateMissingAssets(in verifiedEntries: [TipHistoryEntry]) {
        for entry in verifiedEntries where missingAssetsAwaitingRevalidation.contains(entry.tag) {
            guard let missing = missingAssets[entry.tag], matchesMissingArtifact(missing, entry) else { continue }
            missingAssets[entry.tag] = nil
            missingAssetsAwaitingRevalidation.remove(entry.tag)
        }
    }

    private func matchesMissingArtifact(_ old: TipHistoryEntry, _ new: TipHistoryEntry) -> Bool {
        guard old.origin == .githubRelease, new.origin == .githubRelease else {
            return old.matchesImmutableFields(of: new)
        }
        // Commit lookup is best effort: title, notes, date and other display
        // annotations may improve on refresh without changing the missing ZIP.
        // Keep every acquisition constraint and provenance/identity binding.
        return old.tag == new.tag && old.releaseCommit == new.releaseCommit && old.shortSHA == new.shortSHA &&
            old.buildNumber == new.buildNumber && old.build == new.build && old.marketingVersion == new.marketingVersion &&
            old.role == new.role && old.signingIdentity == new.signingIdentity &&
            old.bundleIdentifier == new.bundleIdentifier && old.teamIdentifier == new.teamIdentifier &&
            old.migrationPhase == new.migrationPhase && old.installationType == new.installationType &&
            old.minimumSystemVersion == new.minimumSystemVersion && old.minimumSystemVersionString == new.minimumSystemVersionString &&
            old.architectures == new.architectures && old.download == new.download && old.metadataProblem == new.metadataProblem &&
            old.downgradeBarrier == new.downgradeBarrier && old.downgradeBarrierReasons == new.downgradeBarrierReasons
    }

    func contextDidChange() {
        context = contextProvider()
        for entry in entries where entry.origin != .githubRelease && (entry.downgradeBarrier || entry.metadataProblem != nil) {
            knownBarriers[entry.tag] = entry
        }
        rows = entries.map { TipHistoryRow(entry: $0, availability: availability($0)) }
        if let attempt, !attempt.committed, !attemptIsAdmitted(attempt) { cancelDownload() }
    }

    func channelDidChange(_ channel: UpdateChannel) {
        cancelLoad()
        guard channel != .tip else { contextDidChange()
            return
        }
        entries = []
        rows = []
        historySource = nil
        releaseNextPage = nil
        releaseFetchedPages = []
        releaseOmittedCount = 0
        selectedTag = nil
        confirmationEntry = nil
        olderReference = nil
        visitedReferences = []
        visitedTags = []
        pageCount = 0
        lastRefreshedAt = nil
        historyStartBuild = nil
        missingAssetsAwaitingRevalidation = []
        catalogState = .idle
        olderPageState = .none
        cancelDownload()
    }

    func canCheckLatest(_ entry: TipHistoryEntry, notice: AvailableUpdateNotice?, canInstall: Bool) -> Bool {
        guard channelProvider() == .tip, !isInspectionOnlyContext, canInstall, entries.first?.tag == entry.tag,
              case .available(.newer, _) = availability(entry),
              let notice, notice.channel == .tip, let number = notice.buildNumber,
              SparkleBuildVersion(number) == entry.build, let download = entry.download,
              notice.downloadURL == download.url,
              repository.trustsDownload(download.url, tag: entry.tag, name: download.name)
        else { return false }
        return true
    }

    func requestDownload(tag: String) {
        guard !shuttingDown, downloadTask == nil else { return }
        contextDidChange()
        guard let row = rows.first(where: { $0.id == tag }), case let .available(direction, cautions) = row.availability else { return }
        if direction == .older || cautions.contains(.barrierUnknownInstalledOutsideHistory) || cautions.contains(.downloadOnlyNonOfficial) {
            confirmationEntry = row.entry
        } else { beginDownload(tag: tag) }
    }

    /// Consent is not a preference. Both acknowledgements must be supplied by
    /// the explicit older-build confirmation UI and are rechecked at commit.
    func beginDownload(tag: String, acknowledgedBackup: Bool = false, acknowledgedUnknownCoverage: Bool = false) {
        guard !shuttingDown, channelProvider() == .tip, downloadTask == nil else { return }
        contextDidChange()
        guard let row = rows.first(where: { $0.id == tag }),
              case let .available(direction, cautions) = row.availability,
              direction != .older || acknowledgedBackup,
              !cautions.contains(.barrierUnknownInstalledOutsideHistory) || acknowledgedUnknownCoverage,
              retryAfter.map({ clock() >= $0 }) ?? true else { return }
        downloadGeneration &+= 1
        let token = Attempt(
            id: UUID(),
            generation: downloadGeneration,
            entry: row.entry,
            context: context,
            acknowledgedUnknownCoverage: acknowledgedUnknownCoverage
        )
        attempt = token
        acquiredEntry = row.entry
        acquiredForInspectionOnly = isInspectionOnlyContext
        retryAfter = nil
        downloadHTTPStatus = nil
        downloadState = .choosingDestination(tag: tag)
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishedDownload(token) }
            guard let destination = await chooseDestination() else {
                if isCurrent(token) { downloadState = .idle }
                return
            }
            do {
                try Task.checkCancellation()
                guard attemptIsAdmitted(token) else { throw CancellationError() }
                let downloader = downloader, key = publicKey
                _ = try await downloader.obtain(token.entry, destination: destination, publicKey: key, progress: { [weak self] progress in
                    Task { @MainActor [weak self] in self?.receiveProgress(progress, token: token) }
                }, commit: { [weak self] payload in
                    guard let self else { throw CancellationError() }
                    try Task.checkCancellation()
                    context = contextProvider()
                    guard isCurrent(token), !shuttingDown, attemptIsAdmitted(token) else { throw CancellationError() }
                    downloadState = .committing(tag: tag)
                    // @Published subscribers run synchronously and may cancel,
                    // change context, or replace this attempt during publication.
                    try Task.checkCancellation()
                    guard isCurrent(token), !shuttingDown, attemptIsAdmitted(token) else { throw CancellationError() }
                    // No suspension between the final fences, exclusive rename,
                    // and ready publication: commit wins over later cancellation.
                    let folder = try commitApplication(payload, destination, token.entry)
                    attempt?.committed = true
                    downloadState = .ready(tag: tag, appURL: folder.appendingPathComponent(TipHistoryArchive.appName), folderURL: folder)
                    return folder
                })
            } catch {
                guard isCurrent(token), attempt?.committed != true else {
                    // Cancellation during @Published's willSet can be followed
                    // by the outer committing assignment. Settle that cancelled
                    // attempt without changing a replacement attempt's state.
                    if attempt == nil, downloadState == .committing(tag: tag) { downloadState = .idle }
                    return
                }
                if error is CancellationError { downloadState = .idle }
                else if let failure = error as? TipHistoryTransferFailure {
                    retryAfter = failure.retryAfter
                    downloadHTTPStatus = failure.httpStatus
                    if failure.httpStatus == 404 || failure.httpStatus == 410 {
                        missingAssets[tag] = token.entry
                        missingAssetsAwaitingRevalidation.remove(tag)
                        rows = entries.map(makeRow)
                    }
                    downloadState = .failed(tag: tag, failure.reason)
                } else {
                    downloadState = .failed(tag: tag, error as? TipHistoryDownloadError ?? .fileSystem)
                }
            }
        }
        downloadTask = task
        ownedTasks[token.id] = task
    }

    private func isCurrent(_ token: Attempt) -> Bool {
        attempt?.id == token.id && downloadGeneration == token.generation
    }

    private func attemptIsAdmitted(_ token: Attempt) -> Bool {
        guard isCurrent(token), channelProvider() == .tip, contextProvider() == token.context else { return false }
        if let current = entries.first(where: { $0.tag == token.entry.tag }), !current.matchesImmutableFields(of: token.entry) { return false }
        guard case let .available(_, cautions) = availability(token.entry) else { return false }
        return !cautions.contains(.barrierUnknownInstalledOutsideHistory) || token.acknowledgedUnknownCoverage
    }

    private func receiveProgress(_ progress: TipHistoryAcquisitionProgress, token: Attempt) {
        guard isCurrent(token), attempt?.committed != true, !Task.isCancelled else { return }
        switch progress {
        case let .downloading(received, total): downloadState = .downloading(tag: token.entry.tag, receivedBytes: received, totalBytes: total)
        case .verifying: downloadState = .verifying(tag: token.entry.tag)
        }
    }

    func cancelDownload() {
        guard attempt?.committed != true else { return }
        downloadGeneration &+= 1
        attempt = nil
        cancelDestination()
        downloadTask?.cancel()
        downloadTask = nil
        if downloadState.isActive { downloadState = .idle }
        // The cancelled task remains in ownedTasks until transport/process exit
        // and attempt-owned cleanup have drained. It cannot publish into B.
    }

    private func finishedDownload(_ token: Attempt) {
        ownedTasks[token.id] = nil
        if isCurrent(token) {
            attempt = nil
            downloadTask = nil
        }
    }

    private func finishedTask(_ id: UUID) {
        ownedTasks[id] = nil
    }

    func revealDownload() {
        guard case let .ready(_, appURL, _) = downloadState else { return }
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }

    func clearDownloadResult() {
        guard !downloadState.isActive else { return }
        downloadState = .idle
        acquiredEntry = nil
        acquiredForInspectionOnly = false
        retryAfter = nil
    }

    func shutdown() async {
        shuttingDown = true
        confirmationEntry = nil
        cancelLoad()
        cancelDownload()
        let tasks = Array(ownedTasks.values)
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
    }

    #if DEBUG
        func debugPublishedSnapshot() -> [String: Any] {
            [
                "history_source": historySource?.rawValue ?? "none",
                "signed_catalog_authenticated": hasAuthenticatedSignedCatalog,
                "release_omitted_count": releaseOmittedCount,
                "catalog_state": String(describing: catalogState),
                "older_page_state": String(describing: olderPageState),
                "row_count": rows.count,
                "catalog_generation": catalogGeneration,
                "download_generation": downloadGeneration,
                "download_state": String(describing: downloadState),
                "page_count": pageCount,
                "owned_task_count": ownedTasks.count,
                "missing_asset_count": missingAssets.count
            ]
        }
    #endif
}

@MainActor
private final class TipHistoryDestinationPicker {
    private var panel: NSOpenPanel?

    func choose() async -> URL? {
        let panel = NSOpenPanel()
        self.panel = panel
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Verified Build Here"
        panel.message = "Choose where to save the verified app for manual reinstallation. RepoPrompt will not replace or open it."
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let response = await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response) }
        }
        if self.panel === panel { self.panel = nil }
        return response == .OK ? panel.url : nil
    }

    func cancel() {
        panel?.cancel(nil)
    }
}
