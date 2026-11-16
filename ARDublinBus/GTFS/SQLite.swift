import Foundation
import SQLite3

enum SQLiteError: LocalizedError {
    case open(String)
    case prepare(String, sql: String)
    case step(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): "Couldn't open the timetable database: \(message)"
        case .prepare(let message, let sql): "Timetable database error: \(message) (\(sql.prefix(60)))"
        case .step(let message): "Timetable database error: \(message)"
        }
    }
}

/// A minimal wrapper around the system SQLite library.
///
/// Not thread-safe by itself: callers serialise access (see `StaticTimetable`).
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL, readOnly: Bool) throws {
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        guard sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw SQLiteError.open(message)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    /// Runs one or more statements that return no rows.
    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.prepare(errorMessage, sql: sql)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepare(errorMessage, sql: sql)
        }
        return Statement(statement: statement, database: self)
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    final class Statement {
        private let statement: OpaquePointer
        private unowned let database: SQLiteDatabase

        fileprivate init(statement: OpaquePointer, database: SQLiteDatabase) {
            self.statement = statement
            self.database = database
        }

        deinit {
            sqlite3_finalize(statement)
        }

        // MARK: Binding (1-based indices, as in SQLite)

        func bind(_ value: Int, at index: Int32) {
            sqlite3_bind_int64(statement, index, Int64(value))
        }

        func bind(_ value: Double, at index: Int32) {
            sqlite3_bind_double(statement, index, value)
        }

        func bind(_ value: String, at index: Int32) {
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        }

        func bind(_ value: Data, at index: Int32) {
            _ = value.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
            }
        }

        func bindNull(at index: Int32) {
            sqlite3_bind_null(statement, index)
        }

        func bind(_ value: Int?, at index: Int32) {
            if let value { bind(value, at: index) } else { bindNull(at: index) }
        }

        /// Binds every value in order, starting at index 1.
        func bind(_ values: [Any?]) {
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                switch value {
                case let value as Int: bind(value, at: index)
                case let value as Int32: bind(Int(value), at: index)
                case let value as Double: bind(value, at: index)
                case let value as String: bind(value, at: index)
                case let value as Data: bind(value, at: index)
                default: bindNull(at: index)
                }
            }
        }

        // MARK: Stepping

        /// Advances to the next row. Returns `false` when done.
        func step() throws -> Bool {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return true
            case SQLITE_DONE: return false
            default: throw SQLiteError.step(database.errorMessage)
            }
        }

        /// Runs a statement that returns no rows, then resets it for reuse.
        func run(_ values: Any?...) throws {
            bind(values)
            defer { reset() }
            _ = try step()
        }

        func reset() {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }

        // MARK: Columns (0-based indices, as in SQLite)

        func int(_ column: Int32) -> Int {
            Int(sqlite3_column_int64(statement, column))
        }

        func optionalInt(_ column: Int32) -> Int? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : int(column)
        }

        func double(_ column: Int32) -> Double {
            sqlite3_column_double(statement, column)
        }

        func optionalDouble(_ column: Int32) -> Double? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : double(column)
        }

        func string(_ column: Int32) -> String {
            guard let text = sqlite3_column_text(statement, column) else { return "" }
            return String(cString: text)
        }

        func data(_ column: Int32) -> Data {
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: bytes, count: count)
        }
    }
}

/// Tells SQLite to copy bound strings and blobs.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
