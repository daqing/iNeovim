import AppKit

/// The native "Open Quickly" panel: a search field plus a results table,
/// styled like the completion panel (vibrancy, rounded corners). Runs its
/// own filtering pipeline (`FuzzyMatcher`) and reports the chosen absolute
/// path through `onOpen`; focus stays inside the panel while presented.
final class OpenQuicklyPanel: NSView {
    /// Fired with the chosen absolute path (Enter or double-click).
    var onOpen: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let clipView = NSView()
    private let effect = NSVisualEffectView()
    private let searchField = NSSearchField()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let previewField = NSTextField(labelWithString: "")
    private var allEntries: [QuicklyEntry] = []
    /// Displayed rows: `..` (go up) plus the in-scope entries.
    private var matches: [QuicklyEntry] = []
    private var showsUpRow = false
    /// Directory the panel is narrowed into; nil lists the working tree.
    private var scope: String?
    private var cwd = ""
    private var filterTask: Task<Void, Never>?

    static let panelSize = CGSize(width: 500, height: 360)

    init() {
        super.init(frame: CGRect(origin: .zero, size: Self.panelSize))
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: 4)

        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = 12
        clipView.layer?.masksToBounds = true
        clipView.layer?.borderWidth = 1
        clipView.layer?.borderColor = NSColor.separatorColor.usingColorSpace(.sRGB)?.cgColor
        clipView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clipView)

        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(effect)

        searchField.placeholderString = "Open Quickly"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        clipView.addSubview(searchField)

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 24
        // Row clicks must select without moving focus, so Enter afterwards
        // still routes through the search field's key handling.
        tableView.refusesFirstResponder = true
        // The table never gains focus, so AppKit would paint its
        // unemphasized (gray) selection and backgroundStyle never reaches
        // .emphasized — rows paint their own accent highlight instead.
        tableView.selectionHighlightStyle = .none
        tableView.action = #selector(openSelected)
        tableView.doubleAction = #selector(openSelected)
        tableView.target = self
        tableView.usesAlternatingRowBackgroundColors = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        tableView.addTableColumn(column)
        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(scrollView)

        previewField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        previewField.textColor = .secondaryLabelColor
        previewField.lineBreakMode = .byTruncatingHead
        previewField.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(previewField)

        NSLayoutConstraint.activate([
            clipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            clipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            clipView.topAnchor.constraint(equalTo: topAnchor),
            clipView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            effect.topAnchor.constraint(equalTo: clipView.topAnchor),
            effect.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            searchField.topAnchor.constraint(equalTo: clipView.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -8),
            previewField.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            previewField.leadingAnchor.constraint(equalTo: clipView.leadingAnchor, constant: 12),
            previewField.trailingAnchor.constraint(equalTo: clipView.trailingAnchor, constant: -12),
            previewField.bottomAnchor.constraint(equalTo: clipView.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The view to focus when the panel appears.
    var preferredFocus: NSView { searchField }

    /// Load candidates and reset to the unfiltered state.
    func present(files: [QuicklyEntry], workingDirectory: String) {
        allEntries = files
        cwd = workingDirectory
        scope = nil
        searchField.stringValue = ""
        refresh()
    }

    private func selectFirst() {
        if !matches.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        } else {
            tableView.deselectAll(nil)
        }
        updatePreview()
    }

    /// Rows: `..` when narrowed into a directory, then the filtered entries.
    private var rows: [QuicklyEntry] {
        (showsUpRow ? [QuicklyEntry(path: "..", isDirectory: true)] : []) + matches
    }

    @objc private func openSelected() {
        let current = rows
        guard current.indices.contains(tableView.selectedRow) else { return }
        let entry = current[tableView.selectedRow]
        if entry.path == ".." {
            goUp()
        } else if entry.isDirectory {
            rescope(entry.path)
        } else {
            onOpen?(entry.path)
        }
    }

    /// One directory up, leaving scope nil at the working directory.
    private func goUp() {
        guard let current = scope else { return }
        let parent = (current as NSString).deletingLastPathComponent
        rescope(parent == cwd ? nil : parent)
    }

    /// Narrow into a directory (nil = the working directory): re-read its
    /// first-level children, so the listing is never a recursive walk.
    private func rescope(_ directory: String?) {
        scope = directory
        searchField.stringValue = ""
        matches = []
        tableView.reloadData()
        updatePreview()
        let target = directory ?? cwd
        Task { @MainActor in
            let entries = await QuicklyFileSource.collect(cwd: target)
            guard scope == directory else { return }
            allEntries = entries
            refresh()
        }
    }

    private func updatePreview() {
        let current = rows
        let row = tableView.selectedRow
        previewField.stringValue = current.indices.contains(row) ? current[row].path : ""
    }

    private func refresh() {
        showsUpRow = scope != nil
        let scoped = allEntries
        let query = searchField.stringValue
        filterTask?.cancel()
        filterTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let results = await FuzzyMatcher.filter(
                query,
                candidates: scoped.map(\.path)
            )
            guard !Task.isCancelled else { return }
            let byPath = Dictionary(uniqueKeysWithValues: scoped.map { ($0.path, $0) })
            matches = results.compactMap { byPath[$0] }
            tableView.reloadData()
            selectFirst()
        }
    }

    private func refilter() {
        refresh()
    }
}

extension OpenQuicklyPanel: NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    nonisolated func controlTextDidChange(_ obj: Notification) {
        MainActor.assumeIsolated {
            refilter()
        }
    }

    /// Arrows, Enter, and Esc arrive as field-editor command selectors while
    /// the search field holds focus.
    nonisolated func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        MainActor.assumeIsolated {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                step(-1)
                return true
            case #selector(NSResponder.moveDown(_:)):
                step(1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                openSelected()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onClose?()
                return true
            default:
                return false
            }
        }
    }

    private func step(_ delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        let current = tableView.selectedRow
        let next = min(max(current + delta, 0), count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    nonisolated func numberOfRows(in tableView: NSTableView) -> Int {
        MainActor.assumeIsolated { rows.count }
    }

    nonisolated func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        MainActor.assumeIsolated {
            let current = rows
            guard current.indices.contains(row) else { return nil }
            let entry = current[row]
            let identifier = NSUserInterfaceItemIdentifier("file")
            let view = (tableView.makeView(withIdentifier: identifier, owner: nil) as? FileRowView)
                ?? FileRowView()
            view.identifier = identifier
            let base = scope ?? cwd
            let text = entry.path == ".." ? ".." : Self.displayPath(entry.path, cwd: base)
            view.configure(
                path: entry.isDirectory ? text + "/" : text,
                selected: tableView.selectedRow == row
            )
            return view
        }
    }

    nonisolated func tableViewSelectionDidChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            updatePreview()
            refreshRowHighlights()
        }
    }

    /// Re-tint the visible rows after the selection moves (rows paint
    /// their own highlight, see FileRowView).
    private func refreshRowHighlights() {
        let visible = tableView.rows(in: tableView.visibleRect)
        for row in visible.location..<min(visible.location + visible.length, tableView.numberOfRows) {
            if let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileRowView {
                view.isSelected = row == tableView.selectedRow
            }
        }
    }

    /// Show the part after the working directory; the full path lives in
    /// the preview line.
    private static func displayPath(_ path: String, cwd: String) -> String {
        guard !cwd.isEmpty, path.hasPrefix(cwd + "/") else { return path }
        return String(path.dropFirst(cwd.count + 1))
    }
}

/// A row that paints its own selection fill: the table never becomes first
/// responder (the search field keeps focus), and an unfocused NSTableView
/// draws its selection highlight nearly invisibly.
private final class FileRowView: NSTableCellView {
    var isSelected = false {
        didSet { updateHighlight() }
    }

    init() {
        super.init(frame: .zero)
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byTruncatingMiddle
        textField = field
        addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4).isActive = true
        field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4).isActive = true
        field.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(path: String, selected: Bool) {
        textField?.stringValue = path
        isSelected = selected
        updateHighlight()
    }

    private func updateHighlight() {
        wantsLayer = true
        let selected = isSelected
        // The OS accent color (user-configurable): it must contrast with
        // the dark vibrancy material, which selectedContentBackgroundColor
        // does not in dark windows.
        layer?.backgroundColor = selected
            ? NSColor.controlAccentColor.cgColor
            : nil
        textField?.textColor = selected ? .white : .labelColor
    }
}
