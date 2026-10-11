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
        tableView.style = .inset
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

        let cell = NSView()

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = Self.severityColor(diagnostic.severity).cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(dot)

        let message = NSTextField(labelWithString: diagnostic.message.replacingOccurrences(of: "\n", with: " "))
        message.font = .systemFont(ofSize: 12)
        message.lineBreakMode = .byTruncatingTail
        message.toolTip = diagnostic.message
        message.translatesAutoresizingMaskIntoConstraints = false
        // The message gives way first so a long location never pushes it out.
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Info and hint rows read dimmed, Xcode-style.
        message.textColor = diagnostic.severity == .info || diagnostic.severity == .hint
            ? .secondaryLabelColor
            : .labelColor
        cell.addSubview(message)

        let location = NSTextField(labelWithString: Self.locationText(problem))
        location.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingHead
        location.toolTip = problem.path.isEmpty ? "unnamed buffer" : problem.path
        location.translatesAutoresizingMaskIntoConstraints = false
        location.setContentCompressionResistancePriority(.required, for: .horizontal)
        cell.addSubview(location)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            message.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            message.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

            location.leadingAnchor.constraint(greaterThanOrEqualTo: message.trailingAnchor, constant: 12),
            location.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            location.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            location.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
        ])

        return cell
    }
}
