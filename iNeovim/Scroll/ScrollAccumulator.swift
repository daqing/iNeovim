import Foundation

/// One whole-line wheel step the controller should forward to Neovim.
enum ScrollLineRequest: Equatable, Sendable {
    case up, down
}

/// Pixel-to-line bookkeeping for smooth scrolling, in points (y down).
///
/// Three signed values track a scroll gesture:
/// - `credit`: every pixel the gesture has moved, so the content layer can
///   follow the finger exactly;
/// - `sent`: the portion already requested from Neovim as whole-line steps;
/// - `confirmed`: the portion Neovim actually scrolled, reported back through
///   `grid_scroll`.
///
/// The visual offset is `credit - confirmed`, capped at `maxLead` so fast
/// scrolling never reveals blank space.
struct ScrollAccumulator: Equatable, Sendable {
    var maxLead: CGFloat
    private(set) var credit: CGFloat = 0
    private(set) var sent: CGFloat = 0
    private(set) var confirmed: CGFloat = 0

    init(maxLead: CGFloat = .greatestFiniteMagnitude) {
        self.maxLead = maxLead
    }

    var offset: CGFloat {
        let lead = credit - confirmed
        return min(max(lead, -maxLead), maxLead)
    }

    var isSettled: Bool { offset == 0 }

    /// Fold a new pixel delta in and return the whole-line requests for the
    /// not-yet-requested remainder.
    mutating func addDelta(_ delta: CGFloat, lineHeight: CGFloat) -> [ScrollLineRequest] {
        guard lineHeight > 0, delta.isFinite, delta != 0 else { return [] }
        credit += delta
        discardLeadBeyondCap()

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
    /// response to a `.down` request), shrinking the visual lead.
    mutating func confirmScroll(rows: Int, lineHeight: CGFloat) {
        guard lineHeight > 0 else { return }
        confirmed += CGFloat(-rows) * lineHeight
        discardLeadBeyondCap()
    }

    /// Start a new gesture, preserving the current visual offset.
    mutating func beginGesture() {
        credit = offset
        sent = 0
        confirmed = 0
    }

    /// Give up on the unconfirmed remainder (snap-back).
    mutating func collapse() {
        credit = confirmed
    }

    private mutating func discardLeadBeyondCap() {
        let lead = credit - confirmed
        if lead > maxLead {
            credit -= lead - maxLead
        } else if lead < -maxLead {
            credit -= lead + maxLead
        }
    }
}
