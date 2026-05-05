import Foundation

enum AppPaths {
    static let sharedGroupID = "group.com.carbocation.shared"

    static var applicationSupportRootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var applicationSupportDirectory: URL {
        let dir = applicationSupportRootDirectory.appending(path: "Summarizo", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var swiftDataStoreURL: URL {
        applicationSupportDirectory.appending(path: "Summarizo.store")
    }

    static var snapshotsDirectory: URL {
        directory(named: "Snapshots")
    }

    static var ocrResultsDirectory: URL {
        directory(named: "OCRResults")
    }

    static var exportsDirectory: URL {
        directory(named: "Exports")
    }

    static var diagnosticsDirectory: URL {
        directory(named: "Diagnostics")
    }

    static var zoteroPluginInstallerDirectory: URL {
        directory(named: "ZoteroPlugin")
    }

    static var zoteroPluginSharedDirectory: URL {
        let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedGroupID)
            ?? applicationSupportDirectory
        let dir = root.appending(path: "ZoteroPlugin", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var zoteroPluginConfigURL: URL {
        zoteroPluginSharedDirectory.appending(path: "config.json")
    }

    static var zoteroPluginStatusURL: URL {
        zoteroPluginSharedDirectory.appending(path: "status.json")
    }

    static var modelsDirectory: URL {
        let dir = ModelStorage.modelsDirectory(
            sharedGroupIdentifier: sharedGroupID,
            appSupportFolderName: "Summarizo"
        )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func ocrResultURL(forAttachmentKey key: String) -> URL {
        ocrResultsDirectory.appending(path: "\(key).txt")
    }

    static func ensureDirectories() throws {
        for url in [
            applicationSupportDirectory,
            snapshotsDirectory,
            ocrResultsDirectory,
            exportsDirectory,
            diagnosticsDirectory,
            zoteroPluginInstallerDirectory,
            modelsDirectory
        ] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private static func directory(named name: String) -> URL {
        let dir = applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
