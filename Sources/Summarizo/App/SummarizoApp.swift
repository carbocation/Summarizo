import AppKit
import SwiftData
import SwiftUI

@main
struct SummarizoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let modelContainer: ModelContainer

    init() {
        do {
            try AppPaths.ensureDirectories()
            _ = try? ZoteroPluginConfigWriter.writeExportDirectoryConfig()
            let schema = Schema([SummarizedPaper.self])
            let configuration = ModelConfiguration(schema: schema, url: AppPaths.swiftDataStoreURL)
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to initialize Summarizo store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1120, minHeight: 720)
        }
        .defaultSize(width: 1240, height: 820)
        .modelContainer(modelContainer)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}
