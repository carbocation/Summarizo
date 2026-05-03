import Foundation
import SQLite3

enum SQLiteError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case backupFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Could not open SQLite database: \(message)"
        case .prepareFailed(let message): "Could not prepare SQLite statement: \(message)"
        case .stepFailed(let message): "Could not read SQLite rows: \(message)"
        case .backupFailed(let message): "Could not snapshot SQLite database: \(message)"
        }
    }
}

final class SQLiteDatabase {
    private var db: OpaquePointer?

    init(path: String, readOnly: Bool) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let db { sqlite3_close(db) }
            throw SQLiteError.openFailed(message)
        }
        sqlite3_busy_timeout(db, 5_000)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func rows<T>(sql: String, _ map: (SQLiteRow) throws -> T) throws -> [T] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        var result: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                result.append(try map(SQLiteRow(statement: statement)))
            } else if code == SQLITE_DONE {
                return result
            } else {
                throw SQLiteError.stepFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    func execute(_ sql: String) throws {
        guard let db else { return }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(error)
            throw SQLiteError.stepFailed(message)
        }
    }

    static func backup(source: URL, destination: URL) throws {
        let fm = FileManager.default
        removeDatabaseFiles(at: destination, fileManager: fm)

        var sourceDB: OpaquePointer?
        var destDB: OpaquePointer?
        let sourceOpenCode = sqlite3_open_v2(source.path, &sourceDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard sourceOpenCode == SQLITE_OK,
              let sourceDB
        else {
            let message = sqliteMessage(sourceOpenCode, database: sourceDB, operation: "open source database")
            if let sourceDB { sqlite3_close(sourceDB) }
            throw SQLiteError.openFailed(message)
        }
        defer { sqlite3_close(sourceDB) }
        sqlite3_busy_timeout(sourceDB, 5_000)

        let destinationOpenCode = sqlite3_open_v2(destination.path, &destDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard destinationOpenCode == SQLITE_OK,
              let destDB
        else {
            let message = sqliteMessage(destinationOpenCode, database: destDB, operation: "open snapshot database")
            if let destDB { sqlite3_close(destDB) }
            throw SQLiteError.openFailed(message)
        }
        defer { sqlite3_close(destDB) }
        sqlite3_busy_timeout(destDB, 5_000)

        guard let backup = sqlite3_backup_init(destDB, "main", sourceDB, "main") else {
            throw SQLiteError.backupFailed(sqliteMessage(sqlite3_errcode(destDB), database: destDB, operation: "initialize backup"))
        }

        let pagesPerStep: Int32 = 128
        let maxBusyRetries = 100
        var busyRetries = 0

        while true {
            let stepCode = sqlite3_backup_step(backup, pagesPerStep)
            switch stepCode {
            case SQLITE_DONE:
                let finishCode = sqlite3_backup_finish(backup)
                guard finishCode == SQLITE_OK else {
                    throw SQLiteError.backupFailed(sqliteMessage(finishCode, database: destDB, operation: "finish backup"))
                }
                try makeSnapshotReadOnlyFriendly(destDB)
                return
            case SQLITE_OK:
                busyRetries = 0
                continue
            case SQLITE_BUSY, SQLITE_LOCKED:
                guard busyRetries < maxBusyRetries else {
                    let remaining = sqlite3_backup_remaining(backup)
                    let total = sqlite3_backup_pagecount(backup)
                    let finishCode = sqlite3_backup_finish(backup)
                    let detail = sqliteMessage(stepCode, database: destDB, operation: "copy database pages")
                    throw SQLiteError.backupFailed("\(detail). Zotero may still be writing to zotero.sqlite; close Zotero and retry. Remaining pages: \(remaining) of \(total). Finish code: \(sqliteDescription(finishCode)).")
                }
                busyRetries += 1
                Thread.sleep(forTimeInterval: 0.05)
            default:
                let detail = sqliteMessage(stepCode, database: destDB, operation: "copy database pages")
                _ = sqlite3_backup_finish(backup)
                throw SQLiteError.backupFailed(detail)
            }
        }
    }

    static func copyFileSnapshot(source: URL, destination: URL, attempts: Int = 3) throws {
        let fm = FileManager.default
        var lastError: Error?

        for attempt in 1...max(attempts, 1) {
            do {
                removeDatabaseFiles(at: destination, fileManager: fm)
                try copyDatabaseFiles(source: source, destination: destination, fileManager: fm)
                try validateCopiedSnapshot(at: destination)
                return
            } catch {
                lastError = error
                removeDatabaseFiles(at: destination, fileManager: fm)
                if attempt < attempts {
                    Thread.sleep(forTimeInterval: 0.15)
                }
            }
        }

        throw SQLiteError.backupFailed("file-copy snapshot failed after \(max(attempts, 1)) attempt(s): \(lastError?.localizedDescription ?? "unknown error"). Close Zotero and retry.")
    }

    private static func sqliteMessage(_ code: Int32, database: OpaquePointer?, operation: String) -> String {
        var message = "\(operation): \(sqliteDescription(code))"
        if let database {
            let detail = String(cString: sqlite3_errmsg(database))
            if !detail.isEmpty, detail != "not an error" {
                message += " (\(detail))"
            }
        }
        return message
    }

    private static func sqliteDescription(_ code: Int32) -> String {
        "\(String(cString: sqlite3_errstr(code))) [code \(code)]"
    }

    private static func makeSnapshotReadOnlyFriendly(_ database: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(database, "PRAGMA journal_mode=DELETE;", nil, nil, &error)
        guard code == SQLITE_OK else {
            let detail = error.map { String(cString: $0) }
                ?? sqliteMessage(code, database: database, operation: "set snapshot journal mode")
            sqlite3_free(error)
            throw SQLiteError.backupFailed(detail)
        }
        sqlite3_free(error)
    }

    private static func removeDatabaseFiles(at url: URL, fileManager: FileManager) {
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + "-journal"))
    }

    private static func copyDatabaseFiles(source: URL, destination: URL, fileManager: FileManager) throws {
        try fileManager.copyItem(at: source, to: destination)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sourceSidecar = URL(fileURLWithPath: source.path + suffix)
            guard fileManager.fileExists(atPath: sourceSidecar.path) else { continue }

            let destinationSidecar = URL(fileURLWithPath: destination.path + suffix)
            do {
                try fileManager.copyItem(at: sourceSidecar, to: destinationSidecar)
            } catch CocoaError.fileReadNoSuchFile {
                continue
            } catch CocoaError.fileNoSuchFile {
                continue
            }
        }
    }

    private static func validateCopiedSnapshot(at url: URL) throws {
        let copied = try SQLiteDatabase(path: url.path, readOnly: false)
        try copied.execute("PRAGMA journal_mode=DELETE;")
        let checks = try copied.rows(sql: "PRAGMA quick_check;") { row in
            row.string(0) ?? ""
        }
        guard checks == ["ok"] else {
            throw SQLiteError.backupFailed("copied snapshot failed SQLite quick_check: \(checks.joined(separator: "; "))")
        }
    }
}

struct SQLiteRow {
    fileprivate var statement: OpaquePointer?

    func int(_ index: Int32) -> Int {
        Int(sqlite3_column_int64(statement, index))
    }

    func int64(_ index: Int32) -> Int64? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, index)
    }

    func string(_ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: text)
    }
}
