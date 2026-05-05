import AppKit
import Darwin
import Foundation

struct ZoteroPluginInstallPreparation: Identifiable {
    var pluginURL: URL

    var id: String {
        pluginURL.path
    }
}

enum ZoteroPluginInstallerError: LocalizedError {
    case bundledPluginNotFound

    var errorDescription: String? {
        switch self {
        case .bundledPluginNotFound:
            "Summarizo Zotero Importer.xpi was not found in the app bundle. Rebuild the Zotero plugin package before distributing Summarizo."
        }
    }
}

enum ZoteroPluginInstaller {
    static let pluginID = "summarizo-importer@carbocation.com"
    static let pluginVersion = "0.1.4"
    static let pluginFileName = "Summarizo Zotero Importer.xpi"

    static func prepareInstall(
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared
    ) throws -> ZoteroPluginInstallPreparation {
        let source = try bundledPluginURL(fileManager: fileManager)
        let destinationDirectory = AppPaths.zoteroPluginInstallerDirectory
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appending(path: pluginFileName)

        try writeInstallCopy(from: source, to: destination, fileManager: fileManager)

        workspace.activateFileViewerSelecting([destination])
        openZoteroIfInstalled(workspace: workspace)
        refocusSummarizo()

        return ZoteroPluginInstallPreparation(
            pluginURL: destination
        )
    }

    private static func bundledPluginURL(fileManager: FileManager) throws -> URL {
        if let direct = Bundle.main.url(
            forResource: "Summarizo Zotero Importer",
            withExtension: "xpi",
            subdirectory: "Zotero"
        ) {
            return direct
        }

        guard let resourceURL = Bundle.main.resourceURL,
              let enumerator = fileManager.enumerator(
                at: resourceURL,
                includingPropertiesForKeys: nil
              )
        else {
            throw ZoteroPluginInstallerError.bundledPluginNotFound
        }

        for case let url as URL in enumerator where url.lastPathComponent == pluginFileName {
            return url
        }

        throw ZoteroPluginInstallerError.bundledPluginNotFound
    }

    static func writeInstallCopy(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        let pluginData = try Data(contentsOf: source)
        try pluginData.write(to: destination, options: .atomic)
        removeQuarantineMetadata(from: destination)
    }

    private static func openZoteroIfInstalled(workspace: NSWorkspace) {
        guard let zoteroURL = workspace.urlForApplication(withBundleIdentifier: "org.zotero.zotero") else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        workspace.openApplication(
            at: zoteroURL,
            configuration: configuration
        )
    }

    private static func refocusSummarizo() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static func removeQuarantineMetadata(from url: URL) {
        url.path.withCString { path in
            _ = removexattr(path, "com.apple.quarantine", 0)
        }
    }
}

struct ZoteroPluginConfig: Codable, Equatable {
    var schemaVersion: Int
    var pluginID: String
    var exportDirectory: String
    var updatedAt: String
}

enum ZoteroPluginConfigWriter {
    static let schemaVersion = 1

    @discardableResult
    static func writeExportDirectoryConfig(
        exportDirectory: URL = AppPaths.exportsDirectory,
        configURL: URL = AppPaths.zoteroPluginConfigURL,
        updatedAt: Date = .now,
        fileManager: FileManager = .default
    ) throws -> ZoteroPluginConfig {
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let config = ZoteroPluginConfig(
            schemaVersion: schemaVersion,
            pluginID: ZoteroPluginInstaller.pluginID,
            exportDirectory: exportDirectory.path,
            updatedAt: ISO8601DateFormatter().string(from: updatedAt)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
        return config
    }
}
