import Darwin
import Foundation
import OSLog
import RepoPromptC

/// A disposable projection of accepted oversight activity. Never consulted by the app.
package actor AgentSessionLinkActivityRecorder {
    package enum Kind {
        case wake, instruction, watch, attention
    }

    package struct Link: Hashable {
        fileprivate struct Pair: Hashable {
            let observer: UUID
            let target: UUID

            var bindings: [SessionCatalogDatabase.Binding] {
                [.text(observer.uuidString), .text(target.uuidString)]
            }
        }

        let id: UUID
        let generation: UInt64
        fileprivate let pair: Pair

        package init(id: UUID, generation: UInt64 = 0, observer: UUID, target: UUID) {
            self.id = id
            self.generation = generation
            pair = Pair(observer: observer, target: target)
        }
    }

    private struct Times {
        var wake: Double?
        var instruction: Double?
        var watch: Double?
        var attention: Double?

        mutating func record(_ kind: Kind, at time: Double) {
            switch kind {
            case .wake: wake = max(wake ?? time, time)
            case .instruction: instruction = max(instruction ?? time, time)
            case .watch: watch = max(watch ?? time, time)
            case .attention: attention = max(attention ?? time, time)
            }
        }
    }

    private struct Batch {
        var updates: [Link: Times] = [:]
        var bindings: [Link: Bool] = [:]
        var removals: Set<Link> = []

        var links: Set<Link> {
            Set(updates.keys).union(bindings.keys).union(removals)
        }

        var isEmpty: Bool {
            updates.isEmpty && bindings.isEmpty && removals.isEmpty
        }
    }

    private let databaseURL: URL
    private let interval: Duration
    private var pending = Batch()
    /// Tasks from delivery and revocation can reach the actor out of order. Link UUIDs aren't reused.
    /// A true value also prevents a late binding from resurrecting removed history.
    private var retired: [UUID: Bool] = [:]
    // A late rebind from an older grant must never move a newer grant's row.
    private var latestWrittenGeneration: [Link.Pair: UInt64] = [:]
    private(set) var scheduled = false
    private static let logger = Logger(subsystem: "com.repoprompt.ce", category: "LinkActivity")

    package init(databaseURL: URL, interval: Duration = .seconds(5)) {
        self.databaseURL = databaseURL
        self.interval = interval > .zero ? interval : .seconds(5)
    }

    @discardableResult
    package nonisolated func record(_ kind: Kind, links: [Link], at date: Date = Date()) -> Task<Void, Never> {
        Task(priority: .utility) { await self.enqueue(kind, links: links, at: date.timeIntervalSince1970) }
    }

    @discardableResult
    package nonisolated func bind(_ link: Link, preservingHistory: Bool) -> Task<Void, Never> {
        Task(priority: .utility) { await self.enqueueBinding(link, preservingHistory: preservingHistory) }
    }

    @discardableResult
    package nonisolated func retire(_ link: Link, removingHistory: Bool = true) -> Task<Void, Never> {
        Task(priority: .utility) { await self.enqueueRetirement(link, removingHistory: removingHistory) }
    }

    func hasBufferedActivity(for link: Link) -> Bool {
        pending.updates[link] != nil
    }

    private func enqueue(_ kind: Kind, links: [Link], at time: Double) {
        guard time.isFinite else { return }
        for link in links where retired[link.id] == nil {
            pending.updates[link, default: Times()].record(kind, at: time)
        }
        scheduleIfNeeded()
    }

    private func enqueueBinding(_ link: Link, preservingHistory: Bool) {
        pending.bindings[link] = preservingHistory
        if retired[link.id] == true {
            pending.removals.insert(link)
        }
        scheduleIfNeeded()
    }

    private func enqueueRetirement(_ link: Link, removingHistory: Bool) {
        if retired[link.id] != true {
            retired[link.id] = removingHistory
            if removingHistory {
                pending.removals.insert(link)
                scheduleIfNeeded()
            }
        }
    }

    private func scheduleIfNeeded() {
        guard !scheduled, !pending.isEmpty else { return }
        scheduled = true
        let interval = interval
        Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: interval)
            await self?.flush()
        }
    }

    private func flush() async {
        let batch = pending
        pending = Batch()
        let generations = latestWrittenGeneration
        let url = databaseURL
        let didWrite = await Task.detached(priority: .utility) {
            do {
                try Self.write(batch, generations: generations, to: url)
                return true
            } catch {
                Self.logger.warning("Dropped a link activity batch after a SQLite or filesystem failure.")
                return false
            }
        }.value
        if didWrite {
            for link in batch.links {
                latestWrittenGeneration[link.pair] = max(latestWrittenGeneration[link.pair, default: 0], link.generation)
            }
        }
        scheduled = false
        scheduleIfNeeded()
    }

    private static func write(_ batch: Batch, generations: [Link.Pair: UInt64], to url: URL) throws {
        guard url.isFileURL else { throw SessionCatalogError.invalidRecord }
        let directory = url.deletingLastPathComponent()
        var ancestor = directory
        while ancestor.path != "/" {
            var info = stat()
            if lstat(ancestor.path, &info) == 0,
               (info.st_mode & S_IFMT) == S_IFLNK, !["/tmp", "/var"].contains(ancestor.path)
            {
                throw SessionCatalogError.invalidRecord
            }
            ancestor.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        // Serialize recovery with other app instances using this directory. The advisory lock
        // requires no sidecar file and does not participate in continuity's locking.
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw SessionCatalogError.filesystem(errno) }
        defer { close(directoryFD) }
        var info = stat()
        guard fstat(directoryFD, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw SessionCatalogError.invalidRecord
        }
        var filesystem = statfs()
        guard fstatfs(directoryFD, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw SessionCatalogError.invalidRecord
        }
        guard flock(directoryFD, LOCK_EX | LOCK_NB) == 0 else { throw SessionCatalogError.filesystem(errno) }
        let existingSuffixes = try ["", "-journal", "-wal", "-shm"].compactMap { suffix -> String? in
            let path = url.path + suffix
            var info = stat()
            if lstat(path, &info) != 0 {
                if errno == ENOENT {
                    return nil
                }
                throw SessionCatalogError.filesystem(errno)
            }
            guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0
            else { throw SessionCatalogError.invalidRecord }
            return suffix
        }
        do {
            try writeTransaction(batch, generations: generations, to: url)
        } catch let SessionCatalogError.database(code) where [SQLITE_CORRUPT, SQLITE_NOTADB].contains(code & 0xFF) {
            // SQLite closed the failed connection. A corrupt header cannot establish ownership,
            // so preserve the files under a shared backup name. Move the main file last.
            let backup = url.path + ".corrupt-" + UUID().uuidString
            for suffix in existingSuffixes.reversed() {
                if renamex_np(url.path + suffix, backup + suffix, UInt32(RENAME_EXCL)) != 0, errno != ENOENT {
                    throw SessionCatalogError.filesystem(errno)
                }
            }
            try writeTransaction(batch, generations: generations, to: url)
        }
    }

    private static func writeTransaction(_ batch: Batch, generations: [Link.Pair: UInt64], to url: URL) throws {
        let db = try SessionCatalogDatabase(url: url)
        try db.execute("PRAGMA trusted_schema = OFF")
        guard let version = try db.integer("PRAGMA user_version"), version == 0 || version == 1 else {
            throw SessionCatalogError.corruptSchema
        }
        let signature = try db.integer("PRAGMA application_id")
        guard (version == 0 && signature == 0) || (version == 1 && signature == 0x5250_4C41) else {
            throw SessionCatalogError.corruptSchema
        }
        let journal = try db.rows("PRAGMA journal_mode = DELETE") { try SessionCatalogDatabase.string($0) }
        guard journal == ["delete"] else { throw SessionCatalogError.corruptSchema }
        try db.execute("BEGIN IMMEDIATE")
        do {
            if try db.integer("PRAGMA user_version") == 0 {
                try db.execute("""
                CREATE TABLE link_activity (
                    link_id TEXT NOT NULL PRIMARY KEY,
                    observer_session_id TEXT NOT NULL,
                    target_session_id TEXT NOT NULL,
                    last_wake_at REAL,
                    last_instruction_at REAL,
                    last_watch_at REAL,
                    last_attention_at REAL
                ) STRICT
                """)
                try db.execute("CREATE TABLE activity_state (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), revision INTEGER NOT NULL) STRICT")
                try db.execute("INSERT INTO activity_state VALUES (1, 0)")
                try db.execute("PRAGMA application_id = 0x52504C41") // RPLA
                try db.execute("PRAGMA user_version = 1")
            }
            try db.execute("CREATE INDEX IF NOT EXISTS link_activity_pair ON link_activity (observer_session_id, target_session_id)")
            for link in batch.links.sorted(by: { $0.generation < $1.generation }) {
                let isCurrent = link.generation >= generations[link.pair, default: 0]
                if batch.removals.contains(link) {
                    if isCurrent {
                        // The restored grant may not yet have rebound the previous process's row.
                        try db.execute(
                            "DELETE FROM link_activity WHERE observer_session_id = ? AND target_session_id = ?",
                            link.pair.bindings
                        )
                    } else {
                        try db.execute("DELETE FROM link_activity WHERE link_id = ?", [.text(link.id.uuidString)])
                    }
                    continue
                }
                guard isCurrent else { continue }
                if let preservingHistory = batch.bindings[link] {
                    try bind(link, preservingHistory: preservingHistory, in: db)
                }
                if let times = batch.updates[link] {
                    try upsert(link, times: times, in: db)
                }
            }
            try db.execute("UPDATE activity_state SET revision = revision + 1 WHERE singleton = 1")
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            throw error
        }
    }

    private static func bind(_ link: Link, preservingHistory: Bool, in db: SessionCatalogDatabase) throws {
        let bindings = link.pair.bindings + [.text(link.id.uuidString)]
        let previousRows = "WHERE observer_session_id = ? AND target_session_id = ? AND link_id != ?"
        if preservingHistory {
            let values = try db.rows("""
            SELECT max(last_wake_at), max(last_instruction_at), max(last_watch_at), max(last_attention_at)
            FROM link_activity
            \(previousRows)
            GROUP BY observer_session_id, target_session_id
            """, bindings) { statement in
                func time(_ column: Int32) -> Double? {
                    sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
                }
                return Times(wake: time(0), instruction: time(1), watch: time(2), attention: time(3))
            }
            if let times = values.first {
                try upsert(link, times: times, in: db)
            }
        }
        try db.execute("DELETE FROM link_activity \(previousRows)", bindings)
    }

    private static func upsert(_ link: Link, times: Times, in db: SessionCatalogDatabase) throws {
        let bindings: [SessionCatalogDatabase.Binding] = [.text(link.id.uuidString)] + link.pair.bindings
            + [times.wake, times.instruction, times.watch, times.attention].map { $0.map(SessionCatalogDatabase.Binding.real) ?? .null }
        try db.execute("""
        INSERT INTO link_activity VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(link_id) DO UPDATE SET
            last_wake_at = max(coalesce(last_wake_at, excluded.last_wake_at), coalesce(excluded.last_wake_at, last_wake_at)),
            last_instruction_at = max(coalesce(last_instruction_at, excluded.last_instruction_at), coalesce(excluded.last_instruction_at, last_instruction_at)),
            last_watch_at = max(coalesce(last_watch_at, excluded.last_watch_at), coalesce(excluded.last_watch_at, last_watch_at)),
            last_attention_at = max(coalesce(last_attention_at, excluded.last_attention_at), coalesce(excluded.last_attention_at, last_attention_at))
        """, bindings)
    }
}
