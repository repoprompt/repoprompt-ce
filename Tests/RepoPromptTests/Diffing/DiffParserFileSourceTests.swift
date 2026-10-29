import Foundation
import RepoPromptApp
import XCTest

final class DiffParserFileSourceTests: XCTestCase {
    private let location = DiffParserFileLocation(rootPath: "/workspace", correctedPath: "File.swift", rootIdentifier: UUID())

    func testCreateRejectsDeeperCorrectionBeforeReadingAndDeleteUsesExactLookup() async throws {
        let deeper = DiffParserFileLocation(rootPath: "/workspace", correctedPath: "Nested/New.swift", rootIdentifier: UUID())
        let source = RecordingDiffParserFileSource(locations: ["New.swift": deeper, "Gone.swift": location])
        let files = try await DiffParser(fileSource: source).parse("""
        <file path="New.swift" action="create"><content>new</content></file>
        <file path="Gone.swift" action="delete" />
        """)
        XCTAssertEqual(files.count, 2)
        let created = try XCTUnwrap(files.first { $0.action == .create })
        XCTAssertEqual(created.fileName, "New.swift")
        XCTAssertTrue(created.canBeLoaded)
        let deleted = try XCTUnwrap(files.first { $0.action == .delete })
        XCTAssertEqual(deleted.fileName, "/workspace/File.swift")
        XCTAssertFalse(deleted.canBeLoaded)
        let events = await source.events
        XCTAssertEqual(events, [.resolve("New.swift", true), .resolve("Gone.swift", true), .read(location, false)])
    }

    func testFoundFileWithUnavailableContentIsNotMissing() async throws {
        let missing = DiffParserFileLocation(rootPath: "/other", correctedPath: "File.swift", rootIdentifier: UUID())
        let source = RecordingDiffParserFileSource(
            locations: ["existing": location, "missing": missing],
            contents: [location: [DiffParserFileContent(content: nil)]]
        )
        let files = try await DiffParser(fileSource: source).parse("""
        <file path="existing" action="create"><content>replacement</content></file>
        <file path="missing" action="rewrite"><content>new</content></file>
        """)
        let existing = try XCTUnwrap(files.first { $0.fileName == "/workspace/File.swift" })
        let created = try XCTUnwrap(files.first { $0.fileName == "/other/File.swift" })
        XCTAssertEqual(existing.action, .rewrite)
        XCTAssertEqual(existing.fileContent, "replacement")
        XCTAssertTrue(existing.canBeLoaded)
        XCTAssertEqual(created.action, .create)
        XCTAssertEqual(created.fileContent, "new")
        XCTAssertTrue(created.canBeLoaded)
        let events = await source.events
        XCTAssertEqual(events, [
            .resolve("existing", true), .read(location, false),
            .resolve("missing", false), .read(missing, false)
        ])
    }

    func testEntriesResolveAndReadSequentiallyWithFreshRenameContent() async throws {
        let source = RecordingDiffParserFileSource(
            locations: ["File.swift": location],
            contents: [location: [DiffParserFileContent(content: "before\n"), DiffParserFileContent(content: "\tafter\r\n")]]
        )
        let files = try await DiffParser(fileSource: source).parse("""
        <file path="File.swift" action="modify"><content>ignored by rename</content></file>
        <file path="File.swift" action="rename"><new path="Moved.swift" /></file>
        """)
        XCTAssertEqual(files.count, 2)
        let deleted = try XCTUnwrap(files.first { $0.action == .delete })
        let created = try XCTUnwrap(files.first { $0.action == .create })
        XCTAssertEqual(deleted.fileName, "/workspace/File.swift")
        XCTAssertEqual(deleted.fileContent, "\tafter\r\n")
        XCTAssertEqual(deleted.lineEnding, "\r\n")
        XCTAssertEqual(created.fileContent, deleted.fileContent)
        XCTAssertEqual(created.lineEnding, deleted.lineEnding)
        XCTAssertEqual(created.changes.first?.content, deleted.changes.first?.content)
        XCTAssertTrue(files.flatMap(\.changes).allSatisfy(\.isSelected))
        let events = await source.events
        XCTAssertEqual(events, [
            .resolve("File.swift", false), .read(location, false),
            .resolve("File.swift", true), .read(location, false)
        ])
    }

    func testCancellationReachesLiveReadWithoutChangingBestEffortParsing() async throws {
        let source = GatedDiffParserFileSource(location: location)
        let task = Task {
            try await DiffParser(fileSource: source).parse("""
            <file path="File.swift" action="create"><content>replacement</content></file>
            """)
        }
        await source.waitUntilResolving()
        task.cancel()
        await source.releaseResolution()
        let files = try await task.value
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(file.action, .rewrite)
        XCTAssertEqual(file.fileName, "/workspace/File.swift")
        XCTAssertEqual(file.fileContent, "replacement")
        XCTAssertTrue(file.canBeLoaded)
        let readWasCancelled = await source.readWasCancelled
        XCTAssertTrue(readWasCancelled)
    }
}

private actor RecordingDiffParserFileSource: DiffParserFileSource {
    enum Event: Equatable {
        case resolve(String, Bool)
        case read(DiffParserFileLocation, Bool)
    }

    let locations: [String: DiffParserFileLocation]
    var contents: [DiffParserFileLocation: [DiffParserFileContent]]
    private(set) var events: [Event] = []

    init(locations: [String: DiffParserFileLocation], contents: [DiffParserFileLocation: [DiffParserFileContent]] = [:]) {
        self.locations = locations
        self.contents = contents
    }

    func pathLocation(_ path: String, exactMatchOnly: Bool) async -> DiffParserFileLocation? {
        events.append(.resolve(path, exactMatchOnly))
        return locations[path]
    }

    func readFile(at location: DiffParserFileLocation) async -> DiffParserFileContent? {
        events.append(.read(location, Task.isCancelled))
        guard var snapshots = contents[location], !snapshots.isEmpty else { return nil }
        let snapshot = snapshots.removeFirst()
        contents[location] = snapshots
        return snapshot
    }
}

private actor GatedDiffParserFileSource: DiffParserFileSource {
    let location: DiffParserFileLocation
    private var resolving = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var resolution: CheckedContinuation<Void, Never>?
    private(set) var readWasCancelled = false

    init(location: DiffParserFileLocation) {
        self.location = location
    }

    func pathLocation(_ path: String, exactMatchOnly: Bool) async -> DiffParserFileLocation? {
        resolving = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { resolution = $0 }
        return location
    }

    func waitUntilResolving() async {
        if !resolving { await withCheckedContinuation { observers.append($0) } }
    }

    func releaseResolution() {
        resolution?.resume()
        resolution = nil
    }

    func readFile(at location: DiffParserFileLocation) async -> DiffParserFileContent? {
        readWasCancelled = Task.isCancelled
        return DiffParserFileContent(content: nil)
    }
}
