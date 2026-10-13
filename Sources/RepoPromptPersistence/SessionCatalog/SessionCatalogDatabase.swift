import Foundation
import RepoPromptC

/// Owned by one catalog core. No SQLite statement or connection escapes its actor/lock owner.
final class SessionCatalogDatabase {
    enum Binding {
        case text(String)
        case integer(Int64)
        case real(Double)
        case bytes(Data)
        case null
    }

    private let connection: OpaquePointer
    private(set) var counters = SessionCatalogReadCounters()

    init(url: URL, readOnly: Bool = false) throws {
        guard url.isFileURL else { throw SessionCatalogError.invalidRecord }
        // macOS temporary roots use /var -> /private/var. Resolve only the existing parent:
        // SQLite's NOFOLLOW must still reject a symlink at the database file itself.
        var resolvedParent = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = url.deletingLastPathComponent().path.withCString { rpce_catalog_resolve_directory($0, &resolvedParent) }
        guard resolved == 0 else { throw SessionCatalogError.filesystem(resolved) }
        let path = String(cString: resolvedParent) + "/" + url.lastPathComponent
        if !readOnly {
            let created = path.withCString { rpce_catalog_create_private($0) }
            guard created == 0 else { throw SessionCatalogError.filesystem(created) }
        }
        var pointer: OpaquePointer?
        let access = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        let result = sqlite3_open_v2(path, &pointer, access | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard result == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            throw SessionCatalogError.database(result)
        }
        connection = pointer
        sqlite3_extended_result_codes(pointer, 1)
        sqlite3_busy_timeout(pointer, 50)
    }

    deinit { sqlite3_close_v2(connection) }

    func resetCounters() {
        counters = SessionCatalogReadCounters()
    }

    func execute(_ sql: String, _ bindings: [Binding] = []) throws {
        _ = try rows(sql, bindings) { _ in () }
    }

    func rows<T>(_ sql: String, _ bindings: [Binding] = [], map: (OpaquePointer) throws -> T) throws -> [T] {
        var pointer: OpaquePointer?
        let prepared = sqlite3_prepare_v2(connection, sql, -1, &pointer, nil)
        guard prepared == SQLITE_OK, let statement = pointer else {
            if let pointer { sqlite3_finalize(pointer) }
            throw SessionCatalogError.database(prepared)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_parameter_count(statement) == Int32(bindings.count) else { throw SessionCatalogError.invalidRecord }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case let .text(value):
                guard value.utf8.count <= Int(Int32.max) else { throw SessionCatalogError.invalidRecord }
                result = value.withCString { rpce_catalog_bind_text(statement, index, $0, Int32(value.utf8.count)) }
            case let .integer(value): result = sqlite3_bind_int64(statement, index, value)
            case let .real(value): result = sqlite3_bind_double(statement, index, value)
            case let .bytes(value):
                guard value.count <= Int(Int32.max) else { throw SessionCatalogError.invalidRecord }
                result = value.withUnsafeBytes { rpce_catalog_bind_blob(statement, index, $0.baseAddress, Int32(value.count)) }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw SessionCatalogError.database(result) }
        }
        counters.statements += 1
        var values: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW else { throw SessionCatalogError.database(result) }
            counters.returnedRows += 1
            try values.append(map(statement))
        }
    }

    func integer(_ sql: String, _ bindings: [Binding] = []) throws -> Int64? {
        try rows(sql, bindings) { sqlite3_column_int64($0, 0) }.first
    }

    static func integerValue(_ statement: OpaquePointer, column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    static func data(_ statement: OpaquePointer, column: Int32 = 0) throws -> Data {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB else { throw SessionCatalogError.corruptSchema }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(statement, column) else { throw SessionCatalogError.corruptSchema }
        return Data(bytes: bytes, count: count)
    }

    static func string(_ statement: OpaquePointer, column: Int32 = 0) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let value = sqlite3_column_text(statement, column)
        else { throw SessionCatalogError.corruptSchema }
        let bytes = UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, column)))
        guard let string = String(bytes: bytes, encoding: .utf8) else { throw SessionCatalogError.corruptSchema }
        return string
    }
}
