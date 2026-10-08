import SwiftUI

/// Window shell: hosts the AppKit terminal surface and provides a sane
/// minimum size so the grid never collapses below usable dimensions.
struct ContentView: View {
    var body: some View {
        TerminalViewRepresentable()
            .frame(minWidth: 480, minHeight: 320)
            .background(.background)
    }
}

struct TerminalViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalView {
        TerminalView()
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

#Preview {
    ContentView()
}
