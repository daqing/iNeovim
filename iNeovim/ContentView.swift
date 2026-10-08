import SwiftUI

/// Window shell: hosts the AppKit terminal surface and provides a sane
/// minimum size so the grid never collapses below usable dimensions.
struct ContentView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        TerminalViewRepresentable(settings: settings)
            .frame(minWidth: 480, minHeight: 320)
            .background(.background)
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
    ContentView(settings: AppSettings.shared)
}
