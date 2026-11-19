import Foundation
@testable import RepoPromptPersistence
import XCTest

final class AgentSessionLinkActivityRecorderTests: XCTestCase {
    private typealias Recorder = AgentSessionLinkActivityRecorder

    func testKindsDirectionRestartAndUnlink() async throws {
        let url = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let link = Recorder.Link(id: UUID(), observer: UUID(), target: UUID())
        let reverse = Recorder.Link(id: UUID(), observer: link.target, target: link.observer)
        let recorder = Recorder(databaseURL: url, interval: .milliseconds(100))
        for (kind, time) in [(Recorder.Kind.wake, 1.25), (.instruction, 2), (.watch, 3), (.attention, 4)] {
            await recorder.record(kind, links: [link], at: date(time)).value
        }
        await recorder.record(.watch, links: [reverse], at: date(10)).value
        try await settle(recorder)
        do {
            let db = try SessionCatalogDatabase(url: url, readOnly: true)
            XCTAssertEqual(try db.integer("PRAGMA user_version"), 1)
            XCTAssertEqual(try db.rows("PRAGMA journal_mode") { try SessionCatalogDatabase.string($0) }, ["delete"])
            XCTAssertEqual(try row(db, id: link.id), [link.observer.uuidString, link.target.uuidString, "1.25", "2.0", "3.0", "4.0"])
            XCTAssertEqual(try row(db, id: reverse.id), [link.target.uuidString, link.observer.uuidString, "-", "-", "10.0", "-"])
        }

        let reopened = Recorder(databaseURL: url, interval: .milliseconds(100))
        await reopened.record(.watch, links: [link], at: date(5)).value
        await reopened.record(.wake, links: [link], at: date(1)).value
        await reopened.retire(reverse.id).value
        await reopened.record(.watch, links: [reverse], at: date(11)).value
        try await settle(reopened)
        let db = try SessionCatalogDatabase(url: url, readOnly: true)
        XCTAssertEqual(try row(db, id: link.id), [link.observer.uuidString, link.target.uuidString, "1.25", "2.0", "5.0", "4.0"])
        XCTAssertNil(try row(db, id: reverse.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + "-shm"))
    }

    func testCorruptFileIsPreservedAndLockedWriteIsDropped() async throws {
        let url = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = Data("not SQLite".utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let recorder = Recorder(databaseURL: url, interval: .milliseconds(25))
        let link = Recorder.Link(id: UUID(), observer: UUID(), target: UUID())
        await recorder.record(.wake, links: [link], at: date(10)).value
        try await settle(recorder)
        let backups = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(url.lastPathComponent + ".corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
        let db = try SessionCatalogDatabase(url: url)
        let revision = try db.integer("SELECT revision FROM activity_state")
        XCTAssertEqual(revision, 1)
        try db.execute("BEGIN IMMEDIATE")
        await recorder.record(.watch, links: [link], at: date(20)).value
        try await settle(recorder)
        try db.execute("ROLLBACK")
        XCTAssertEqual(try db.integer("SELECT revision FROM activity_state"), revision)
        XCTAssertEqual(try row(db, id: link.id)?.suffix(4), ["10.0", "-", "-", "-"])
        await recorder.record(.instruction, links: [link], at: date(30)).value
        try await settle(recorder)
        XCTAssertEqual(try row(db, id: link.id)?.suffix(4), ["10.0", "30.0", "-", "-"])
    }

    func testFrequentWatchesAcross120SessionsCoalesce() async throws {
        let url = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let sessions = (0 ..< 120).map { _ in UUID() }
        let links = (0 ..< 60).map { index in
            Recorder.Link(id: UUID(), observer: sessions[index], target: sessions[index + 60])
        }
        let recorder = Recorder(databaseURL: url, interval: .milliseconds(200))
        let started = ContinuousClock.now
        let marks = (1 ... 80).flatMap { tick in
            links.map { recorder.record(.watch, links: [$0], at: date(Double(tick))) }
        }
        for mark in marks {
            await mark.value
        }
        try await settle(recorder)
        XCTAssertLessThan(started.duration(to: .now), .seconds(5))
        let db = try SessionCatalogDatabase(url: url, readOnly: true)
        XCTAssertEqual(try db.integer("SELECT count(*) FROM link_activity WHERE last_watch_at = 80"), 60)
        XCTAssertLessThanOrEqual(try XCTUnwrap(db.integer("SELECT revision FROM activity_state")), 5)
    }

    private func temporaryDatabase() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory.appendingPathComponent("link-activity.sqlite")
    }

    private func settle(_ recorder: Recorder) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await recorder.scheduled {
            guard ContinuousClock.now < deadline else { throw CocoaError(.fileWriteUnknown) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func date(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func row(_ db: SessionCatalogDatabase, id: UUID) throws -> [String]? {
        try db.rows("""
        SELECT observer_session_id, target_session_id,
            coalesce(cast(last_wake_at AS TEXT), '-'), coalesce(cast(last_instruction_at AS TEXT), '-'),
            coalesce(cast(last_watch_at AS TEXT), '-'), coalesce(cast(last_attention_at AS TEXT), '-')
        FROM link_activity WHERE link_id = ?
        """, [.text(id.uuidString)]) { statement in
            try (0 ..< 6).map { try SessionCatalogDatabase.string(statement, column: $0) }
        }.first
    }
}
