import SwiftUI

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        // The id lets the app delegate's openWindow capture create the
        // windows behind native tabs (⌘T / the tab bar's + button).
        WindowGroup(id: "editor") {
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
