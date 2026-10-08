import AppKit
import SwiftUI

/// Window shell: hosts the AppKit terminal surface and provides a sane
/// minimum size so the grid never collapses below usable dimensions.
struct ContentView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel

    var body: some View {
        TerminalViewRepresentable(settings: settings)
            .frame(minWidth: 480, minHeight: 320)
            .background(.background)
            .navigationTitle(model.windowTitle ?? "iNeovim")
            .alert(
                "Neovim exited",
                isPresented: Binding(
                    get: { model.crash != nil },
                    set: { if !$0 { model.dismissCrash() } }
                ),
                presenting: model.crash
            ) { _ in
                Button("Restart") { model.restart() }
                Button("Quit", role: .destructive) { NSApp.terminate(nil) }
            } message: { crash in
                Text("The embedded Neovim process exited unexpectedly (status \(crash.status)).")
            }
    }
}

struct TerminalViewRepresentable: NSViewRepresentable {
    @ObservedObject var settings: AppSettings

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(metrics: FontMetrics(font: settings.resolvedFont()))
        view.apply(settings: settings)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        nsView.apply(settings: settings)
    }
}

#Preview {
    ContentView(settings: AppSettings.shared, model: AppModel.shared)
}
