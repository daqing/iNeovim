import SwiftUI

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView(settings: settings, model: model)
        }
        .commands {
            EditorCommands()
        }

        Settings {
            SettingsView(settings: settings)
        }
    }
}
