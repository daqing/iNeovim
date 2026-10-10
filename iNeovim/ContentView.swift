import AppKit
import SwiftUI

/// Window shell: hosts the AppKit terminal surface and provides a sane
/// minimum size so the grid never collapses below usable dimensions.
struct ContentView: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var model = AppModel()

    var body: some View {
        TerminalViewRepresentable(settings: settings, model: model)
            .frame(minWidth: 480, minHeight: 320)
            .background(.background)
            .overlay { statusOverlay }
            .preferredColorScheme(model.themeIsDark.map { $0 ? .dark : .light })
            .navigationTitle(model.windowTitle ?? "iNeovim")
            .task { await model.bootstrap() }
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

    /// A blank grid can mean Neovim is still starting or failed to start; show
    /// that state instead of an empty window.
    @ViewBuilder
    private var statusOverlay: some View {
        if model.isReady || model.crash != nil {
            // A crash is surfaced by the alert; an empty grid is expected then.
            EmptyView()
        } else if let setup = model.setup {
            SetupView(setup: setup) { model.restart() }
        } else if let error = model.bootstrapError {
            ContentUnavailableView {
                Label("Could not start Neovim", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { model.restart() }
            }
        } else {
            ProgressView("Starting Neovim…")
                .controlSize(.small)
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct TerminalViewRepresentable: NSViewRepresentable {
    @ObservedObject var settings: AppSettings
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(model: model, metrics: FontMetrics(font: settings.resolvedFont()))
        view.apply(settings: settings)
        view.sessionDidChangeReady(model.isReady)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        nsView.apply(settings: settings)
        nsView.sessionDidChangeReady(model.isReady)
    }
}

#Preview {
    ContentView(settings: AppSettings.shared)
}
