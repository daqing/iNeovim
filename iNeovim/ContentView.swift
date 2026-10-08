import SwiftUI

struct ContentView: View {
    var body: some View {
        TerminalViewRepresentable()
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
