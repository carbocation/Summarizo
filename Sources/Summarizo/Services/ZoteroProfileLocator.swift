import Foundation

struct ZoteroProfileLocation: Equatable, Sendable {
    var profileURL: URL
    var dataDirectoryURL: URL
    var source: String
}

enum ZoteroProfileLocatorError: LocalizedError {
    case profilesNotFound(URL)
    case profileNotFound
    case prefsNotFound(URL)

    var errorDescription: String? {
        switch self {
        case .profilesNotFound(let url):
            "Zotero profiles.ini was not found at \(url.path)."
        case .profileNotFound:
            "No Zotero profile could be resolved from profiles.ini."
        case .prefsNotFound(let url):
            "Zotero prefs.js was not found at \(url.path)."
        }
    }
}

enum ZoteroProfileLocator {
    static func suggestedDataDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let standard = standardDataDirectory(homeDirectory: homeDirectory)
        if looksLikeZoteroDataDirectory(standard) {
            return standard
        }

        if let located = try? locate(homeDirectory: homeDirectory),
           looksLikeZoteroDataDirectory(located.dataDirectoryURL) {
            return located.dataDirectoryURL
        }

        return nil
    }

    static func standardDataDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.appending(path: "Zotero", directoryHint: .isDirectory)
    }

    static func looksLikeZoteroDataDirectory(_ url: URL) -> Bool {
        let fm = FileManager.default
        let database = url.appending(path: "zotero.sqlite")
        let storage = url.appending(path: "storage", directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: database.path)
            && fm.fileExists(atPath: storage.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func locate(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> ZoteroProfileLocation {
        let appSupport = homeDirectory
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Zotero", directoryHint: .isDirectory)
        let profilesIni = appSupport.appending(path: "profiles.ini")
        guard FileManager.default.fileExists(atPath: profilesIni.path) else {
            throw ZoteroProfileLocatorError.profilesNotFound(profilesIni)
        }

        let text = try String(contentsOf: profilesIni, encoding: .utf8)
        guard let profilePath = parseDefaultProfilePath(from: text) else {
            throw ZoteroProfileLocatorError.profileNotFound
        }

        let profileURL = profilePath.isRelative
            ? appSupport.appending(path: profilePath.path, directoryHint: .isDirectory)
            : URL(fileURLWithPath: profilePath.path)
        let prefsURL = profileURL.appending(path: "prefs.js")
        guard FileManager.default.fileExists(atPath: prefsURL.path) else {
            throw ZoteroProfileLocatorError.prefsNotFound(prefsURL)
        }

        let prefs = try String(contentsOf: prefsURL, encoding: .utf8)
        if parseBoolPref("extensions.zotero.useDataDir", in: prefs) == true,
           let dataDir = parseStringPref("extensions.zotero.dataDir", in: prefs)?.nilIfBlank {
            return ZoteroProfileLocation(
                profileURL: profileURL,
                dataDirectoryURL: URL(fileURLWithPath: dataDir),
                source: "Zotero profile preference"
            )
        }

        return ZoteroProfileLocation(
            profileURL: profileURL,
            dataDirectoryURL: standardDataDirectory(homeDirectory: homeDirectory),
            source: "Default macOS Zotero location"
        )
    }

    static func parseDefaultProfilePath(from text: String) -> (path: String, isRelative: Bool)? {
        let sections = parseINISections(text)
        let profileSections = sections.filter { $0.name.hasPrefix("Profile") }
        let selected = profileSections.first { $0.values["Default"] == "1" } ?? profileSections.first
        guard let selected, let path = selected.values["Path"]?.nilIfBlank else { return nil }
        let isRelative = selected.values["IsRelative"] != "0"
        return (path, isRelative)
    }

    static func parseStringPref(_ key: String, in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"user_pref\("\#(escaped)",\s*"((?:\\"|[^"])*)"\);"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range]).replacingOccurrences(of: #"\""#, with: #"""#)
    }

    static func parseBoolPref(_ key: String, in text: String) -> Bool? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"user_pref\("\#(escaped)",\s*(true|false)\);"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range]) == "true"
    }

    private static func parseINISections(_ text: String) -> [(name: String, values: [String: String])] {
        var sections: [(name: String, values: [String: String])] = []
        var currentName: String?
        var currentValues: [String: String] = [:]

        func flush() {
            guard let currentName else { return }
            sections.append((currentName, currentValues))
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix(";"), !line.hasPrefix("#") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                flush()
                currentName = String(line.dropFirst().dropLast())
                currentValues = [:]
            } else if let equals = line.firstIndex(of: "=") {
                let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
                currentValues[key] = value
            }
        }
        flush()
        return sections
    }
}
