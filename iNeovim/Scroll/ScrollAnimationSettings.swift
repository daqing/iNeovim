import Foundation

/// Central knobs for scroll and cursor animation.
///
/// All easing is time-based — progress is elapsed time over duration,
/// sampled from the display link's frame timestamps — so animation speed is
/// identical at 60 Hz and at 120 Hz ProMotion refresh rates; ProMotion
/// samples the same curve twice per frame interval instead.
struct ScrollAnimationSettings: Equatable {
    /// Whether the scroll offset animates; when off, offsets apply directly.
    var scrollEnabled = true
    /// Whether the cursor glides between cells; when off, it snaps.
    var cursorEnabled = true
    /// Chase time constant for the scroll-offset settle; three time
    /// constants (≈100 ms) bring it to rest.
    var scrollTimeConstant: TimeInterval = 0.033
    /// Grace period after a gesture ends during which in-flight
    /// `grid_scroll` confirmations may still claim the visual lead.
    var confirmationGrace: Duration = .milliseconds(250)
    /// How long the cursor glides between cells.
    var cursorGlideDuration: TimeInterval = 0.08
    /// Cursor jumps beyond this cell distance snap instead of gliding.
    var cursorGlideMaxCells: CGFloat = 4

    static let `default` = ScrollAnimationSettings()
}
