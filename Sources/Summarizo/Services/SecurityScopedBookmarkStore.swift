import AppKit
import Foundation

@MainActor
final class SecurityScopedBookmarkStore: ObservableObject {
    static let shared = SecurityScopedBookmarkStore()

    private let defaults: UserDefaults
    private let zoteroDirectoryKey = "zotero.dataDirectory.bookmark"
    private let linkedRootKey = "zotero.linkedAttachmentRoot.bookmark"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func resolvedZoteroDirectory() -> URL? {
        guard let data = defaults.data(forKey: zoteroDirectoryKey) else { return nil }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale {
                try saveZoteroDirectory(url)
            }
            return url
        } catch {
            return nil
        }
    }

    func saveZoteroDirectory(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: zoteroDirectoryKey)
    }

    func chooseZoteroDirectory(suggestedURL: URL?) throws -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Zotero Data Directory"
        panel.message = "Choose the folder containing zotero.sqlite and storage."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = suggestedURL

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try saveZoteroDirectory(url)
        return url
    }

    func resolvedLinkedAttachmentRoot() -> URL? {
        resolvedURL(forKey: linkedRootKey)
    }

    func withGrantedFileAccess<T>(_ operation: () throws -> T) rethrows -> T {
        let urls = [
            resolvedZoteroDirectory(),
            resolvedLinkedAttachmentRoot()
        ].compactMap { $0 }

        let scopedAccess = urls.map { url in
            (url, url.startAccessingSecurityScopedResource())
        }

        defer {
            for (url, didAccess) in scopedAccess where didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try operation()
    }

    func chooseLinkedAttachmentRoot() throws -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Linked Attachment Root"
        panel.message = "Choose a folder that contains linked Zotero PDF attachments."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: linkedRootKey)
        return url
    }

    private func resolvedURL(forKey key: String) -> URL? {
        guard let data = defaults.data(forKey: key) else { return nil }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return url
        } catch {
            return nil
        }
    }
}
