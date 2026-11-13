import Foundation
import SQLite3

/// 系统自带 SQLite 的最小封装：只提供执行语句、绑定参数、逐行读取。不是线程安全的，由调用方加锁。
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        // 先建好 0600 的空文件，避免数据库文件按默认权限创建
        if !FileManager.default.fileExists(atPath: path) {
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 { close(fd) }
        }
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            sqlite3_close(handle)
            throw RelayError(.internalError, "打不开数据库：\(msg)")
        }
        sqlite3_busy_timeout(handle, 5_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(err)
            throw RelayError(.internalError, "数据库出错：\(msg)")
        }
    }

    /// 执行一条带参数的语句，返回所有结果行。
    @discardableResult
    func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw RelayError(.internalError, "数据库出错：\(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in params.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, Int64(v))
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLiteDatabase.transient)
            }
        }
        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw RelayError(.internalError, "数据库出错：\(String(cString: sqlite3_errmsg(handle)))")
            }
            var row = SQLRow()
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_NULL: row.values[name] = .null
                case SQLITE_INTEGER: row.values[name] = .int(Int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: row.values[name] = .double(sqlite3_column_double(stmt, c))
                default: row.values[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                }
            }
            rows.append(row)
        }
        return rows
    }

    var changes: Int { Int(sqlite3_changes(handle)) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

enum SQLValue: Equatable {
    case null
    case int(Int)
    case double(Double)
    case text(String)

    init(_ s: String?) { self = s.map { .text($0) } ?? .null }
    init(_ d: Date?) { self = d.map { .double($0.timeIntervalSince1970) } ?? .null }
    init(_ b: Bool) { self = .int(b ? 1 : 0) }
}

struct SQLRow {
    var values: [String: SQLValue] = [:]

    func string(_ k: String) -> String? {
        if case .text(let v) = values[k] { return v }
        return nil
    }

    func int(_ k: String) -> Int? {
        switch values[k] {
        case .int(let v): return v
        case .double(let v): return Int(v)
        default: return nil
        }
    }

    func date(_ k: String) -> Date? {
        switch values[k] {
        case .double(let v): return Date(timeIntervalSince1970: v)
        case .int(let v): return Date(timeIntervalSince1970: TimeInterval(v))
        default: return nil
        }
    }

    func bool(_ k: String) -> Bool { int(k).map { $0 != 0 } ?? false }
}
