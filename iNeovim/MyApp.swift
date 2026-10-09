import SwiftUI

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings)
        }
        .commands {
            EditorCommands()
        }

        Settings {
            SettingsView(settings: settings)
        }
    }
}
