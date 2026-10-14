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
/// The visual offset is the *unconfirmed* part of `credit`, so the content
/// layer can follow the finger while Neovim's scroll is in flight. Neovim
/// only ever draws the visible screenful, so a lead of a whole line or more
/// is space Neovim has not painted: blank space, and the longer the lead
/// stands the more blank lines appear. A gesture that wants such a lead means
/// Neovim is not keeping up with it — a stalled session, or a scroll at the
/// buffer's edge, where nothing is ever confirmed — so the lead is suspended
/// (the content then moves with Neovim's confirmations alone) until the next
/// confirmation proves Neovim is scrolling again. Whole-line wheel steps trip
/// this on their first step, so a wheel never draws ahead of Neovim at all;
/// trackpad gestures keep the sub-line part, which is what makes a drag look
/// smooth.
struct ScrollAccumulator: Equatable, Sendable {
    /// Largest visual lead allowed — one cell height, i.e. the sub-line part
    /// of the gesture. A gesture that reaches it suspends the lead.
    var maxLead: CGFloat
    private(set) var credit: CGFloat = 0
    private(set) var sent: CGFloat = 0
    private(set) var confirmed: CGFloat = 0
    /// Suppressed because Neovim has not confirmed a whole line of the lead;
    /// cleared by the next confirmation.
    private(set) var leadSuspended = false

    init(maxLead: CGFloat = 0) {
        self.maxLead = maxLead
    }

    var offset: CGFloat {
        guard !leadSuspended else { return 0 }
        let lead = credit - confirmed
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
        if maxLead > 0, abs(credit - confirmed) >= maxLead {
            leadSuspended = true
        }

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
    /// response to a `.down` request), shrinking the visual lead. The lead
    /// only resumes once the backlog is gone: Neovim catching up a line while
    /// still behind must not re-expose space it has not drawn.
    mutating func confirmScroll(rows: Int, lineHeight: CGFloat) {
        guard lineHeight > 0 else { return }
        confirmed += CGFloat(-rows) * lineHeight
        leadSuspended = maxLead > 0 && abs(credit - confirmed) >= maxLead
    }

    /// Start a new gesture, preserving the current visual offset.
    mutating func beginGesture() {
        credit = offset
        sent = 0
        confirmed = 0
        leadSuspended = false
    }

    /// Give up on the unconfirmed lead (snap-back). The request accounting is
    /// left alone, so a confirmation still in flight cannot move the content
    /// against the gesture; the direction clamp keeps it at rest.
    mutating func collapse() {
        confirmed = credit
        leadSuspended = true
    }
}
