import Foundation

struct ZoteroPluginStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case unknown
        case notInstalled
        case installed
        case outdated
        case disabled
    }

    var kind: Kind
    var installedVersion: String?
    var expectedVersion: String
    var detail: String

    var canPrepareInstall: Bool {
        switch kind {
        case .unknown, .notInstalled, .outdated, .disabled:
            true
        case .installed:
            false
        }
    }
}

enum ZoteroPluginStatusDetector {
    static func detect(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        statusMarkerURL: URL? = AppPaths.zoteroPluginStatusURL
    ) -> ZoteroPluginStatus {
        let expectedVersion = ZoteroPluginInstaller.pluginVersion

        do {
            let profile = try ZoteroProfileLocator.locate(homeDirectory: homeDirectory)
            if let addon = try installedAddon(in: profile.profileURL, fileManager: fileManager) {
                return status(for: addon, expectedVersion: expectedVersion)
            }

            if let proxyVersion = try developmentProxyVersion(in: profile.profileURL, fileManager: fileManager) {
                return status(
                    for: InstalledZoteroPlugin(
                        version: proxyVersion,
                        isEnabled: true,
                        source: "development proxy"
                    ),
                    expectedVersion: expectedVersion
                )
            }

            return ZoteroPluginStatus(
                kind: .notInstalled,
                installedVersion: nil,
                expectedVersion: expectedVersion,
                detail: "Click to install the bundled plugin."
            )
        } catch {
            if let statusMarkerURL,
               let addon = try? installedAddonFromStatusMarker(at: statusMarkerURL, fileManager: fileManager) {
                return status(for: addon, expectedVersion: expectedVersion)
            }

            return ZoteroPluginStatus(
                kind: .unknown,
                installedVersion: nil,
                expectedVersion: expectedVersion,
                detail: "Click to install; profile could not be checked."
            )
        }
    }

    private static func installedAddonFromStatusMarker(
        at url: URL,
        fileManager: FileManager
    ) throws -> InstalledZoteroPlugin? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let marker = try JSONDecoder().decode(ZoteroPluginStatusMarker.self, from: data)
        guard marker.pluginID == ZoteroPluginInstaller.pluginID else { return nil }
        return InstalledZoteroPlugin(
            version: marker.version,
            isEnabled: marker.enabled != false,
            source: "plugin status marker"
        )
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = numericVersionComponents(lhs)
        let rhsParts = numericVersionComponents(rhs)
        let count = max(lhsParts.count, rhsParts.count)

        for index in 0..<count {
            let left = index < lhsParts.count ? lhsParts[index] : 0
            let right = index < rhsParts.count ? rhsParts[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }

        return .orderedSame
    }

    private static func status(
        for addon: InstalledZoteroPlugin,
        expectedVersion: String
    ) -> ZoteroPluginStatus {
        guard addon.isEnabled else {
            return ZoteroPluginStatus(
                kind: .disabled,
                installedVersion: addon.version,
                expectedVersion: expectedVersion,
                detail: versionDetail(prefix: "Disabled", version: addon.version, expectedVersion: expectedVersion)
            )
        }

        if let version = addon.version,
           compareVersions(version, expectedVersion) == .orderedAscending {
            return ZoteroPluginStatus(
                kind: .outdated,
                installedVersion: version,
                expectedVersion: expectedVersion,
                detail: "Installed \(version), bundled \(expectedVersion). Click to update."
            )
        }

        return ZoteroPluginStatus(
            kind: .installed,
            installedVersion: addon.version,
            expectedVersion: expectedVersion,
            detail: versionDetail(prefix: "Installed", version: addon.version, expectedVersion: expectedVersion)
        )
    }

    private static func installedAddon(
        in profileURL: URL,
        fileManager: FileManager
    ) throws -> InstalledZoteroPlugin? {
        let extensionsJSON = profileURL.appending(path: "extensions.json")
        guard fileManager.fileExists(atPath: extensionsJSON.path) else { return nil }

        let data = try Data(contentsOf: extensionsJSON)
        let registry = try JSONDecoder().decode(ZoteroExtensionsRegistry.self, from: data)
        guard let addon = registry.addons.first(where: { $0.id == ZoteroPluginInstaller.pluginID }) else {
            return nil
        }

        let disabled = addon.userDisabled == true || addon.appDisabled == true || addon.active == false
        return InstalledZoteroPlugin(
            version: addon.version,
            isEnabled: !disabled,
            source: addon.location
        )
    }

    private static func developmentProxyVersion(
        in profileURL: URL,
        fileManager: FileManager
    ) throws -> String? {
        let extensionsDirectory = profileURL.appending(path: "extensions", directoryHint: .isDirectory)
        let proxy = extensionsDirectory.appending(path: ZoteroPluginInstaller.pluginID)
        guard fileManager.fileExists(atPath: proxy.path) else { return nil }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: proxy.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return try manifestVersion(in: proxy)
        }

        let proxyText = try String(contentsOf: proxy, encoding: .utf8)
        let sourcePath = proxyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourcePath.isEmpty else { return nil }
        return try manifestVersion(in: URL(fileURLWithPath: sourcePath))
    }

    private static func manifestVersion(in pluginDirectory: URL) throws -> String? {
        let manifest = pluginDirectory.appending(path: "manifest.json")
        let data = try Data(contentsOf: manifest)
        return try JSONDecoder().decode(ZoteroPluginManifest.self, from: data).version
    }

    private static func versionDetail(prefix: String, version: String?, expectedVersion: String) -> String {
        if let version {
            return "\(prefix) version \(version)."
        }
        return "\(prefix); bundled version is \(expectedVersion)."
    }

    private static func numericVersionComponents(_ version: String) -> [Int] {
        version
            .split(separator: ".")
            .map { component in
                let digits = component.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }
}

private struct InstalledZoteroPlugin {
    var version: String?
    var isEnabled: Bool
    var source: String?
}

private struct ZoteroExtensionsRegistry: Decodable {
    var addons: [ZoteroExtensionAddon]
}

private struct ZoteroExtensionAddon: Decodable {
    var id: String
    var version: String?
    var active: Bool?
    var userDisabled: Bool?
    var appDisabled: Bool?
    var location: String?
}

private struct ZoteroPluginManifest: Decodable {
    var version: String?
}

private struct ZoteroPluginStatusMarker: Decodable {
    var pluginID: String
    var version: String?
    var enabled: Bool?
}
