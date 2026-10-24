import AppKit

/// Non-modal issues sidebar (Xcode issue navigator style), docked at the
/// window's left edge by `EditorSplitView`: every error and warning the
/// embedded nvim's language servers reported, live-updating from
/// `DiagnosticsStore`. Selecting a row jumps the editor to the issue; the
/// panel keeps focus, so the arrow keys walk the list like in Xcode.
@MainActor
final class ProblemsPanelController: NSViewController {
    private static let rowHeight: CGFloat = 26

    private let store: DiagnosticsStore
    private let onJump: (DiagnosticsStore.Problem) -> Void
    private let onClose: () -> Void

    private var problems: [DiagnosticsStore.Problem] = []
    private let tableView = NSTableView()
    private let countsLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No problems")
    /// Table width the rows were last measured at; a resize has to re-wrap
    /// every message, so the cached row heights are invalidated then.
    private var measuredWidth: CGFloat = 0

    init(
        store: DiagnosticsStore,
        onJump: @escaping (DiagnosticsStore.Problem) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.onJump = onJump
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        store.onChange = { [weak self] in self?.rebuild() }
        rebuild()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))

        let title = NSTextField(labelWithString: "Problems")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)

        let closeButton = NSButton()
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close problems panel"
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        closeButton.isBordered = false
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(closeButton)

        countsLabel.font = .systemFont(ofSize: 11)
        countsLabel.textColor = .secondaryLabelColor
        countsLabel.lineBreakMode = .byTruncatingTail
        countsLabel.translatesAutoresizingMaskIntoConstraints = false
        countsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addSubview(countsLabel)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(separator)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("problem"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.headerView = nil
        // A plain table puts the cell 8 pt in from the panel edge, so the
        // row content starts near the header's 12 pt title leading; the
        // inset style's 16 pt margin made every row read as indented.
        tableView.style = .plain
        tableView.rowHeight = Self.rowHeight
        tableView.dataSource = self
        tableView.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),

            closeButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),

            countsLabel.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            countsLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            countsLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            separator.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        // Columns exist only after loadView, so reload here again for the
        // snapshot taken in init.
        rebuild()

        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = tableView.bounds.width
        guard width > 0, width != measuredWidth else { return }
        measuredWidth = width
        // The single column fills the panel; setting it here (instead of
        // relying on the table's autoresizing, which the headless check
        // showed can lag a resize) keeps the wrap width, the row heights,
        // and the cell frames on one number.
        tableView.tableColumns.first?.width = width
        guard !problems.isEmpty else { return }
        // Dragging the panel divider re-wraps every message. Invalidating the
        // heights after the width settles re-measures them; the next pass sees
        // the same width and stops, so this cannot loop.
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<problems.count))
    }

    @objc private func closeClicked() {
        onClose()
    }

    private func rebuild() {
        problems = store.problems
        countsLabel.stringValue = Self.countsText(problems)
        emptyLabel.isHidden = !problems.isEmpty
        tableView.reloadData()
    }

    private static func countsText(_ problems: [DiagnosticsStore.Problem]) -> String {
        var counts = [NvimDiagnostic.Severity: Int]()
        for problem in problems {
            counts[problem.diagnostic.severity, default: 0] += 1
        }
        func part(_ n: Int, _ singular: String, _ plural: String) -> String? {
            guard n > 0 else { return nil }
            return n == 1 ? "1 \(singular)" : "\(n) \(plural)"
        }
        let parts = [
            part(counts[.error] ?? 0, "error", "errors"),
            part(counts[.warning] ?? 0, "warning", "warnings"),
            part(counts[.info] ?? 0, "info", "info"),
            part(counts[.hint] ?? 0, "hint", "hints"),
        ].compactMap { $0 }
        return parts.joined(separator: ", ")
    }

    private static func locationText(_ problem: DiagnosticsStore.Problem) -> String {
        let file = problem.path.isEmpty ? "[No name]" : (problem.path as NSString).lastPathComponent
        return "\(file):\(problem.diagnostic.line + 1)"
    }

    private static func severityColor(_ severity: NvimDiagnostic.Severity) -> NSColor {
        switch severity {
        case .error: .systemRed
        case .warning: .systemYellow
        case .info: .systemBlue
        case .hint: .systemGray
        }
    }
}

extension ProblemsPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        problems.count
    }

    /// Messages wrap, so a row is as tall as its text at the table's current
    /// width. The data source measures it (rather than the cell describing
    /// its own size) so the row height and the cell's wrap width come from
    /// the same number: the column width.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < problems.count else { return Self.rowHeight }
        let width = tableView.tableColumns.first?.width ?? tableView.bounds.width
        return ProblemsRowView.height(for: problems[row].diagnostic.message, width: width)
    }

    /// Any selection change — mouse click or arrow keys — jumps the editor;
    /// the panel keeps first-responder status either way.
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < problems.count else { return }
        onJump(problems[row])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < problems.count else { return nil }
        let problem = problems[row]
        let diagnostic = problem.diagnostic

        let cell = ProblemsRowView()
        cell.dot.layer?.backgroundColor = Self.severityColor(diagnostic.severity).cgColor
        // The message wraps instead of truncating: the panel is narrow, and
        // a compiler message cut at the tail hides the part that matters
        // (e.g. "… found 1" ending at "found "). The location moves under the
        // message so the text can use the panel's full width.
        cell.message.stringValue = diagnostic.message.replacingOccurrences(of: "\n", with: " ")
        cell.message.toolTip = diagnostic.message
        // Info and hint rows read dimmed, Xcode-style.
        cell.message.textColor = diagnostic.severity == .info || diagnostic.severity == .hint
            ? .secondaryLabelColor
            : .labelColor
        cell.location.stringValue = Self.locationText(problem)
        cell.location.toolTip = problem.path.isEmpty ? "unnamed buffer" : problem.path
        return cell
    }
}

/// One problem row: severity dot, a message wrapped to the panel's width, and
/// the `file:line` beneath it. Laid out by hand (like the completion panel)
/// so the wrap width in the cell is exactly the width `height(for:width:)`
/// measured the row at — Auto Layout's fitting in a narrow, resizing table
/// column produced heights and cell widths that disagreed.
private final class ProblemsRowView: NSView {
    static let messageFont = NSFont.systemFont(ofSize: 12)
    static let locationFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    // The plain table style places its cells at x = 8; 4 more puts the dot's
    // left edge at the 12 pt leading of the header title.
    private static let dotLeading: CGFloat = 4
    private static let dotSize: CGFloat = 8
    private static let textLeading: CGFloat = dotLeading + dotSize + 8
    private static let textTrailing: CGFloat = 10
    private static let verticalPadding: CGFloat = 5
    private static let lineSpacing: CGFloat = 2
    private static let minimumTextWidth: CGFloat = 40
    private static let messageLineHeight = ceil(messageFont.ascender - messageFont.descender + messageFont.leading)
    private static let locationLineHeight = ceil(locationFont.ascender - locationFont.descender + locationFont.leading)

    private static let measuringLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = messageFont
        return label
    }()

    let dot = NSView()
    let message = NSTextField(wrappingLabelWithString: "")
    let location = NSTextField(labelWithString: "")

    /// Top-down coordinates, so the rows' vertical math reads in order.
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Self.dotSize / 2
        addSubview(dot)

        message.font = Self.messageFont
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 0
        addSubview(message)

        location.font = Self.locationFont
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingHead
        addSubview(location)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Height of a row holding `message` when its cell is `width` wide. The
    /// label cell is the authoritative measure: it insets text by 2 pt per
    /// side, and `NSString`-based sizes under-measure the last wrapped line.
    static func height(for message: String, width: CGFloat) -> CGFloat {
        measuringLabel.stringValue = message.replacingOccurrences(of: "\n", with: " ")
        let measured = measuringLabel.cell?.cellSize(forBounds: NSRect(
            x: 0,
            y: 0,
            width: max(width - textLeading - textTrailing, minimumTextWidth),
            height: .greatestFiniteMagnitude
        )).height ?? messageLineHeight
        return verticalPadding * 2 + max(ceil(measured), messageLineHeight)
            + lineSpacing + locationLineHeight
    }

    override func layout() {
        super.layout()
        let textWidth = max(bounds.width - Self.textLeading - Self.textTrailing, Self.minimumTextWidth)
        // The row height was measured for this text width, so the message
        // gets everything the row has left above the location line.
        let messageHeight = max(
            bounds.height - Self.verticalPadding * 2 - Self.lineSpacing - Self.locationLineHeight,
            Self.messageLineHeight
        )
        dot.frame = CGRect(
            x: Self.dotLeading,
            y: Self.verticalPadding + 3,
            width: Self.dotSize,
            height: Self.dotSize
        )
        message.frame = CGRect(
            x: Self.textLeading,
            y: Self.verticalPadding,
            width: textWidth,
            height: messageHeight
        )
        location.frame = CGRect(
            x: Self.textLeading,
            y: Self.verticalPadding + messageHeight + Self.lineSpacing,
            width: textWidth,
            height: Self.locationLineHeight
        )
    }
}
