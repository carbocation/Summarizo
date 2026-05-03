import Foundation

enum ZoteroDatabaseSnapshotter {
    static func snapshotDatabase(
        in dataDirectory: URL,
        destinationDirectory: URL = AppPaths.snapshotsDirectory
    ) throws -> ZoteroDatabaseSnapshot {
        let source = dataDirectory.appending(path: "zotero.sqlite")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw SnapshotError.databaseNotFound(source)
        }

        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appending(path: "zotero-snapshot.sqlite")

        try SQLiteDatabase.copyFileSnapshot(source: source, destination: destination)
        return ZoteroDatabaseSnapshot(
            url: destination,
            note: "Summarizo copied Zotero's SQLite files before opening SQLite. If Zotero is actively writing, very recent changes may require closing Zotero and rescanning."
        )
    }
}

struct ZoteroDatabaseSnapshot {
    var url: URL
    var note: String?
}

enum SnapshotError: LocalizedError {
    case databaseNotFound(URL)

    var errorDescription: String? {
        switch self {
        case .databaseNotFound(let url):
            "No zotero.sqlite database was found at \(url.path)."
        }
    }
}
