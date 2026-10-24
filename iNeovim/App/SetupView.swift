import AppKit
import SwiftUI

/// First-run guidance when no nvim is installed: install Neovim via Homebrew,
/// or Homebrew itself first (brew.sh) when that is missing too.
struct SetupView: View {
    let setup: NvimSetupGuide
    let recheck: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Neovim is not installed", systemImage: "terminal")
        } description: {
            Text(setup.homebrewInstalled
                ? "iNeovim embeds Neovim as its editor engine. Install it with Homebrew, then recheck."
                : "iNeovim embeds Neovim as its editor engine, and Homebrew is not installed either. Visit brew.sh to install Homebrew first, then install Neovim with it.")
        } actions: {
            VStack(spacing: 14) {
                commandBox
                HStack {
                    if !setup.homebrewInstalled {
                        Button("Open brew.sh") { openBrewSite() }
                    }
                    Button("Recheck") { recheck() }
                }
            }
        }
    }

    private var commandBox: some View {
        HStack(spacing: 6) {
            Text(Self.installCommand)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.installCommand, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
    }

    private func openBrewSite() {
        if let url = URL(string: "https://brew.sh") {
            NSWorkspace.shared.open(url)
        }
    }

    private static let installCommand = "brew install neovim"
}
