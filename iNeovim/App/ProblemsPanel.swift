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

    private var problems: [DiagnosticsStore.Problem] = []
    private let tableView = NSTableView()
    private let countsLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No errors or warnings")

    init(store: DiagnosticsStore, onJump: @escaping (DiagnosticsStore.Problem) -> Void) {
        self.store = store
        self.onJump = onJump
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

            countsLabel.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            countsLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
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

    private func rebuild() {
        problems = store.problems
        countsLabel.stringValue = Self.countsText(problems)
        emptyLabel.isHidden = !problems.isEmpty
        tableView.reloadData()
    }

    private static func countsText(_ problems: [DiagnosticsStore.Problem]) -> String {
        let errors = problems.filter { $0.diagnostic.severity == .error }.count
        let warnings = problems.count - errors
        var parts: [String] = []
        if errors > 0 { parts.append(errors == 1 ? "1 error" : "\(errors) errors") }
        if warnings > 0 { parts.append(warnings == 1 ? "1 warning" : "\(warnings) warnings") }
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
