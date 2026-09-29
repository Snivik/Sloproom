//
//  SQLiteDatabase.swift
//  sloproom
//
//  Small, safe wrapper over the SQLite3 C API.
//  - Opens in WAL mode with foreign keys ON.
//  - Prepared statements are cached per SQL string.
//  - Thread-safe: every call takes an internal recursive lock, so a
//    `transaction {}` body can freely call `run`/`query` on the same database
//    from the same thread while other threads wait.
//

import Foundation
import SQLite3

/// A value that can be bound to a statement parameter.
nonisolated enum SQLValue: Sendable, Hashable {
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case null
}

/// Anything convertible to an `SQLValue`. Optionals of bindable types bind `NULL` when nil.
nonisolated protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

nonisolated extension SQLValue: SQLBindable { var sqlValue: SQLValue { self } }
nonisolated extension Int: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
nonisolated extension Int64: SQLBindable { var sqlValue: SQLValue { .int(self) } }
nonisolated extension Int32: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
nonisolated extension Bool: SQLBindable { var sqlValue: SQLValue { .int(self ? 1 : 0) } }
nonisolated extension Double: SQLBindable { var sqlValue: SQLValue { .double(self) } }
nonisolated extension String: SQLBindable { var sqlValue: SQLValue { .text(self) } }
nonisolated extension Data: SQLBindable { var sqlValue: SQLValue { .blob(self) } }
/// Dates are stored as Unix time (seconds since 1970, REAL).
nonisolated extension Date: SQLBindable { var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
nonisolated extension Optional: SQLBindable where Wrapped: SQLBindable {
    var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

nonisolated struct SQLiteError: Error, CustomStringConvertible, Sendable {
    let code: Int32
    let message: String
    let sql: String?
    var description: String { "SQLite error \(code): \(message)" + (sql.map { " [\($0)]" } ?? "") }
}

/// A row cursor handed to `query` mapping closures. Only valid inside the closure.
/// Column indexes are 0-based, in SELECT order.
nonisolated struct SQLRow {
    fileprivate let stmt: OpaquePointer

    var columnCount: Int { Int(sqlite3_column_count(stmt)) }
    func isNull(_ i: Int) -> Bool { sqlite3_column_type(stmt, Int32(i)) == SQLITE_NULL }

    func int(_ i: Int) -> Int64 { sqlite3_column_int64(stmt, Int32(i)) }
    func intOrNil(_ i: Int) -> Int64? { isNull(i) ? nil : int(i) }
    func double(_ i: Int) -> Double { sqlite3_column_double(stmt, Int32(i)) }
    func doubleOrNil(_ i: Int) -> Double? { isNull(i) ? nil : double(i) }
    func bool(_ i: Int) -> Bool { int(i) != 0 }
    func string(_ i: Int) -> String { stringOrNil(i) ?? "" }
    func stringOrNil(_ i: Int) -> String? {
        guard let c = sqlite3_column_text(stmt, Int32(i)) else { return nil }
        return String(cString: c)
    }
    func data(_ i: Int) -> Data? {
        guard let p = sqlite3_column_blob(stmt, Int32(i)) else { return isNull(i) ? nil : Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, Int32(i))))
    }
    func date(_ i: Int) -> Date? { doubleOrNil(i).map(Date.init(timeIntervalSince1970:)) }
}

nonisolated final class SQLiteDatabase: @unchecked Sendable {
    let path: String
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var statementCache: [String: OpaquePointer] = [:]
    private var transactionDepth = 0

    /// SQLITE_TRANSIENT tells SQLite to copy bound strings/blobs.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens (creating if needed) the database at `path`. Use ":memory:" for an in-memory DB.
    init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: msg, sql: nil)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")
    }

    deinit {
        for (_, stmt) in statementCache { sqlite3_finalize(stmt) }
        sqlite3_close_v2(handle)
    }

    // MARK: - Execution

    /// Executes one or more SQL statements with no parameters and no results (DDL, pragmas).
    func execute(_ sql: String) throws {
        try locked {
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(handle, sql, nil, nil, &err)
            if rc != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "exec failed"
                sqlite3_free(err)
                throw SQLiteError(code: rc, message: msg, sql: sql)
            }
        }
    }

    /// Runs a single statement (INSERT/UPDATE/DELETE) with bound parameters.
    /// Returns the number of rows changed.
    @discardableResult
    func run(_ sql: String, _ args: [any SQLBindable] = []) throws -> Int {
        try locked {
            let stmt = try prepared(sql)
            defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
            try bind(args, to: stmt, sql: sql)
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc, sql) }
            return Int(sqlite3_changes(handle))
        }
    }

    /// Runs a query and maps every row.
    func query<T>(_ sql: String, _ args: [any SQLBindable] = [], _ map: (SQLRow) throws -> T) throws -> [T] {
        try locked {
            let stmt = try prepared(sql)
            defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
            try bind(args, to: stmt, sql: sql)
            var result: [T] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW { result.append(try map(SQLRow(stmt: stmt))) }
                else if rc == SQLITE_DONE { break }
                else { throw error(rc, sql) }
            }
            return result
        }
    }

    /// Convenience: first row mapped, or nil.
    func queryFirst<T>(_ sql: String, _ args: [any SQLBindable] = [], _ map: (SQLRow) throws -> T) throws -> T? {
        try query(sql, args, map).first
    }

    /// Convenience: first column of first row as Int64 (e.g. COUNT(*)).
    func scalarInt(_ sql: String, _ args: [any SQLBindable] = []) throws -> Int64? {
        try queryFirst(sql, args) { $0.intOrNil(0) } ?? nil
    }

    /// Runs `body` inside BEGIN IMMEDIATE / COMMIT (ROLLBACK on throw).
    /// Nested calls on the same thread join the outer transaction.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try locked {
            if transactionDepth > 0 {
                transactionDepth += 1
                defer { transactionDepth -= 1 }
                return try body()
            }
            try execute("BEGIN IMMEDIATE")
            transactionDepth = 1
            defer { transactionDepth = 0 }
            do {
                let value = try body()
                try execute("COMMIT")
                return value
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    /// Row id of the most recent successful INSERT on this connection.
    /// Only meaningful when read inside the same `transaction {}` / locked sequence as the insert.
    var lastInsertRowID: Int64 { locked { sqlite3_last_insert_rowid(handle) } }

    /// Runs `body` while holding the database lock (use to make read-then-write sequences atomic
    /// without opening a transaction).
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - Private

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let s = statementCache[sql] { return s }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc, sql) }
        statementCache[sql] = stmt
        return stmt
    }

    private func bind(_ args: [any SQLBindable], to stmt: OpaquePointer, sql: String) throws {
        for (offset, arg) in args.enumerated() {
            let i = Int32(offset + 1)
            let rc: Int32
            switch arg.sqlValue {
            case .int(let v): rc = sqlite3_bind_int64(stmt, i, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, i, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, i, v, -1, Self.transient)
            case .blob(let v):
                rc = v.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, i, buf.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(buf.count), Self.transient)
                }
            case .null: rc = sqlite3_bind_null(stmt, i)
            }
            if rc != SQLITE_OK { throw error(rc, sql) }
        }
    }

    private func error(_ rc: Int32, _ sql: String?) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }
}
