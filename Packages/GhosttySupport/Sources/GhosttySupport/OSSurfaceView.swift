import Foundation
import GhosttyKit
import SwiftUI

// Vendored from ghostty 1.3.2-main+246f702 (macos/Sources/Ghostty/Surface
// View/OSSurfaceView.swift) for embedding in iNeovim. Pruned: search state,
// progress reports, child-exited message bar, and the highlight effect —
// all displayed by Ghostty.app UI that this embedding does not host.

extension Ghostty {
    public class OSSurfaceView: NSView, ObservableObject {
        public typealias ID = UUID

        /// Unique ID per surface
        public let id: UUID

        // The current pwd of the surface as defined by the pty. This can be
        // changed with escape codes.
        @Published var pwd: String?

        // The cell size of this surface. This is set by the core when the
        // surface is first created and any time the cell size changes (i.e.
        // when the font size changes). This is used to allow windows to be
        // resized in discrete steps of a single cell.
        @Published var cellSize: CGSize = .zero

        // The health state of the surface. This currently only reflects the
        // renderer health. In the future we may want to make this an enum.
        @Published var healthy: Bool = true

        // Any error while initializing the surface.
        @Published var error: Error?

        // The hovered URL string
        @Published var hoverUrl: String?

        // The currently active key tables. Empty if no tables are active.
        @Published var keyTables: [String] = []

        // The time this surface last became focused. This is a ContinuousClock.Instant
        // on supported platforms.
        @Published var focusInstant: ContinuousClock.Instant?

        // Returns sizing information for the surface. This is the raw C
        // structure because I'm lazy.
        @Published var surfaceSize: ghostty_surface_size_s?

        /// True when the surface is in readonly mode.
        @Published private(set) var readonly: Bool = false

        public var surface: ghostty_surface_t? {
            nil
        }

        init(id: UUID?, frame: CGRect) {
            self.id = id ?? UUID()
            super.init(frame: frame)

            // Before we initialize the surface we want to register our notifications
            // so there is no window where we can't receive them.
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(ghosttyDidChangeReadonly(_:)),
                name: .ghosttyDidChangeReadonly,
                object: self,
            )
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }

        deinit {
            NotificationCenter.default
                .removeObserver(self)
        }

        @objc private func ghosttyDidChangeReadonly(_ notification: Foundation.Notification) {
            guard let value = notification.userInfo?[Foundation.Notification.Name.ReadonlyKey] as? Bool else { return }
            readonly = value
        }

        // MARK: - Placeholders

        func focusDidChange(_ focused: Bool) {}

        public func sizeDidChange(_ size: CGSize) {}
    }
}

extension Ghostty.OSSurfaceView {
    func navigateSearchToNext() -> Bool {
        guard let surface = self.surface else { return false }
        let action = "navigate_search:next"
        if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
            Ghostty.logger.warning("action failed action=\(action, privacy: .public)")
            return false
        }
        return true
    }

    func navigateSearchToPrevious() -> Bool {
        guard let surface = self.surface else { return false }
        let action = "navigate_search:previous"
        if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
            Ghostty.logger.warning("action failed action=\(action, privacy: .public)")
            return false
        }
        return true
    }
}
