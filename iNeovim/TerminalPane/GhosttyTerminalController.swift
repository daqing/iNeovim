import AppKit
import GhosttySupport
import os

/// Process-wide owner of the embedded Ghostty app that powers every
/// window's native terminal pane: one `ghostty_app_t` hosts all surfaces.
/// The app config is generated under Application Support so the pane
/// matches the editor — the editor's font and nvim's default colors — and
/// is frozen when the first pane opens. Shell integration is disabled
/// because Ghostty's integration scripts are GPLv3 and must not ship
/// inside this MIT app.
@MainActor
final class GhosttyTerminalController {
    static let shared = GhosttyTerminalController()

    private var app: Ghostty.App?

    private init() {}

    /// Create the surface view for one terminal pane, starting the child
    /// process in `workingDirectory` (or running `command` instead of the
    /// login shell when nonempty). nil when the Ghostty app failed to start.
    func makeSurface(
        workingDirectory: String,
        command: String,
        font: NSFont,
        colors: AppModel.TerminalColors
    ) -> Ghostty.SurfaceView? {
        let app = ensureApp(font: font, colors: colors)
        guard let handle = app.app else { return nil }
        var config = Ghostty.SurfaceConfiguration()
        if !workingDirectory.isEmpty {
            config.workingDirectory = workingDirectory
        }
        if !command.isEmpty {
            config.command = command
        }
        config.fontSize = Float(font.pointSize)
        return Ghostty.SurfaceView(handle, baseConfig: config)
    }

    /// Rewrite the shared config with the editor's current font and nvim
    /// default colors and push it into the running app, so panes that are
    /// already open repaint when the editor flips between a dark and a light
    /// colorscheme. A no-op before the first pane creates the shared app (its
    /// config is written with the current colors at that point) and when the
    /// caller has no colors yet (a fresh session before nvim reports), which
    /// must not clobber a config another window already synced.
    func updateColors(font: NSFont, colors: AppModel.TerminalColors) {
        guard let app, colors.foreground != nil || colors.background != nil else { return }
        guard Self.writeConfig(font: font, colors: colors) != nil else { return }
        app.reloadConfig()
    }

    /// Begin the surface close cycle: libghostty asks the child to exit,
    /// then reports back through the close-surface notification.
    func requestClose(_ surfaceView: Ghostty.SurfaceView) {
        guard let app, let surface = surfaceView.surface else { return }
        app.requestClose(surface: surface)
    }

    private func ensureApp(font: NSFont, colors: AppModel.TerminalColors) -> Ghostty.App {
        if let app { return app }
        let app = Ghostty.App(configPath: Self.writeConfig(font: font, colors: colors))
        self.app = app
        return app
    }

    /// nvim's default colors are 0xRRGGBB packed ints; negative values are
    /// nvim's "unset" sentinel and map to Ghostty's own defaults.
    private static func hexColor(_ packed: Int?) -> String? {
        guard let packed, packed >= 0 else { return nil }
        return String(format: "#%06x", packed & 0xFFFFFF)
    }

    private static func writeConfig(font: NSFont, colors: AppModel.TerminalColors) -> String? {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("iNeovim", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("ghostty.conf")

        var lines = [
            "shell-integration = none",
            // ⌘1..⌘9 are the editor's Go to Tab shortcuts, but Ghostty's
            // default `goto_tab` (and `last_tab` on ⌘9) bindings swallow
            // them while the pane has focus; unbind the whole row so the
            // menu receives the events.
        ] + (1...9).map { "keybind = super+\($0)=unbind" } + [
            // Room between the pane divider and the text; the surface still
            // paints its background full-bleed, so no color seam appears.
            // Mirrors TerminalPaneView.contentInset for the title alignment.
            // Interpolated via Int: CGFloat would render "8.0", which
            // Ghostty's integer parser rejects (option silently dropped).
            "window-padding-x = \(Int(TerminalPaneView.contentInset))",
            "font-size = \(font.pointSize)",
        ]
        // System-mono fonts report private family names (".AppleSystem…")
        // Ghostty cannot resolve; leave those at Ghostty's default font.
        if let family = font.familyName, !family.hasPrefix(".") {
            lines.append("font-family = \(family)")
        }
        if let background = hexColor(colors.background) {
            lines.append("background = \(background)")
            if let foreground = hexColor(colors.foreground) {
                lines.append("foreground = \(foreground)")
            } else if let isDark = TerminalView.hasDarkBackground(colors.background) {
                lines.append("foreground = \(isDark ? "#ffffff" : "#000000")")
            }
        }

        do {
            try lines.joined(separator: "\n").appending("\n")
                .write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            Log.app.error("Failed to write Ghostty config: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
