import Foundation

/// One whole-line wheel step the controller should forward to Neovim.
enum ScrollLineRequest: Equatable, Sendable {
    case up, down

    /// The `nvim_input_mouse` button/action pair for this step. Neovim
    /// addresses the wheel as button `"wheel"` with the direction as the
    /// action; the terminfo-style `"wheelup"`/`"press"` pair is rejected with
    /// `invalid button or action`, which leaves the grid unscrolled while the
    /// visual lead keeps moving (blank space that later snaps back).
    var wheelButton: (button: String, action: String) {
        switch self {
        case .up: return (button: "wheel", action: "up")
        case .down: return (button: "wheel", action: "down")
        }
    }
}

/// Pixel-to-line bookkeeping for smooth scrolling, in points (y down).
///
/// Three signed values track a scroll gesture:
/// - `credit`: every pixel the gesture has moved;
/// - `sent`: the portion already requested from Neovim as whole-line steps;
/// - `confirmed`: the portion Neovim actually scrolled, reported back through
///   `grid_scroll`.
///
/// The visual offset is the *requested but not yet confirmed* part of the
/// gesture, so the content layer moves a whole line the moment a wheel step or
/// a trackpad delta crosses one, instead of waiting for Neovim's answer.
/// Neovim only ever draws the visible screenful, so a lead is space it has not
/// painted: the content may lead by at most one line, which is exactly one
/// wheel notch. A burst that gets further ahead is clamped to the same line
/// and caught up by the confirmations. A lead Neovim never confirms — the
/// buffer's edge — is given up by the controller once the gesture ends.
///
/// The lead is whole lines only, even for a trackpad's pixel deltas. Neovim
/// can only confirm whole lines, so a sub-line lead (`credit - confirmed`)
/// could never be paid back: it would sit there until the end of the gesture
/// and then have to be given up — the content visibly sliding back by up to
/// one line after every scroll. The sub-line part of the gesture stays in
/// `credit` instead, where it simply becomes the start of the next whole-line
/// step.
struct ScrollAccumulator: Equatable, Sendable {
    /// Largest visual lead allowed — one cell height, i.e. exactly one
    /// whole-line wheel step.
    var maxLead: CGFloat
    private(set) var credit: CGFloat = 0
    private(set) var sent: CGFloat = 0
    private(set) var confirmed: CGFloat = 0

    init(maxLead: CGFloat = 0) {
        self.maxLead = maxLead
    }

    var offset: CGFloat {
        let lead = sent - confirmed
        // Clamp to the gesture's direction as well as to the cap: a
        // confirmation that outruns the gesture (a late one, or Neovim
        // scrolling by itself) must not drag the content back the other way.
        if credit >= 0 {
            return min(max(lead, 0), maxLead)
        }
        return max(min(lead, 0), -maxLead)
    }

    var isSettled: Bool { offset == 0 }

    /// Fold a new pixel delta in and return the whole-line requests for the
    /// not-yet-requested remainder. Deltas are never dropped: throttling the
    /// requests would make the content lag the wheel, and the visual lead
    /// already bounds how far ahead of Neovim the content can be drawn.
    mutating func addDelta(_ delta: CGFloat, lineHeight: CGFloat) -> [ScrollLineRequest] {
        guard lineHeight > 0, delta.isFinite, delta != 0 else { return [] }
        credit += delta

        var requests: [ScrollLineRequest] = []
        var remainder = credit - sent
        while remainder >= lineHeight {
            requests.append(.up)
            sent += lineHeight
            remainder -= lineHeight
        }
        while remainder <= -lineHeight {
            requests.append(.down)
            sent -= lineHeight
            remainder += lineHeight
        }
        return requests
    }

    /// Neovim scrolled the grid by `rows` (positive moves content up — the
    /// response to a `.down` request), shrinking the visual lead. The clamp in
    /// `offset` bounds a catch-up that is itself behind: no more of the
    /// unpainted screen is exposed than the cap allows.
    mutating func confirmScroll(rows: Int, lineHeight: CGFloat) {
        guard lineHeight > 0 else { return }
        confirmed += CGFloat(-rows) * lineHeight
    }

    /// Start a new gesture, preserving the current visual offset. The part of
    /// that offset already requested is carried over as `sent`, not reset:
    /// re-requesting a line still in flight would scroll it twice when the
    /// new gesture's first step crosses a line.
    mutating func beginGesture() {
        let preserved = offset
        let inFlight = sent - confirmed
        credit = preserved
        sent = preserved >= 0
            ? min(max(inFlight, 0), preserved)
            : max(min(inFlight, 0), preserved)
        confirmed = 0
    }

    /// Give up on the unconfirmed lead (snap-back). The request accounting is
    /// left alone, so a confirmation still in flight cannot move the content
    /// against the gesture; the direction clamp keeps it at rest.
    mutating func collapse() {
        confirmed = sent
    }
}
