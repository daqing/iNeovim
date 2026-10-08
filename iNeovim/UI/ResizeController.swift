import Foundation

/// Converts view size changes into `nvim_ui_try_resize` calls: point size is
/// divided by the cell size to get a cell count, and bursts of live-resize
/// callbacks are coalesced into one debounced request.
actor ResizeController {
    typealias ResizeHandler = @Sendable (Int, Int) async -> Void

    static let defaultDebounceDelay: Duration = .milliseconds(120)

    private(set) var cellSize: CGSize
    var debounceDelay: Duration
    private let handler: ResizeHandler
    private var debounceTask: Task<Void, Never>?

    init(
        cellSize: CGSize,
        debounceDelay: Duration = Self.defaultDebounceDelay,
        client: NvimClient = NvimClient()
    ) {
        self.cellSize = cellSize
        self.debounceDelay = debounceDelay
        self.handler = { cols, rows in
            try? await client.uiTryResize(width: cols, height: rows)
        }
    }

    init(
        cellSize: CGSize,
        debounceDelay: Duration = Self.defaultDebounceDelay,
        handler: @escaping ResizeHandler
    ) {
        self.cellSize = cellSize
        self.debounceDelay = debounceDelay
        self.handler = handler
    }

    func viewDidResize(to size: CGSize) {
        let (cols, rows) = Self.cellCount(for: size, cellSize: cellSize)
        debounceTask?.cancel()
        debounceTask = Task { [handler, debounceDelay] in
            do {
                try await Task.sleep(for: debounceDelay)
            } catch {
                return
            }
            await handler(cols, rows)
        }
    }

    func setCellSize(_ size: CGSize) {
        cellSize = size
    }

    static func cellCount(for size: CGSize, cellSize: CGSize) -> (cols: Int, rows: Int) {
        let cols = max(1, Int(size.width / cellSize.width))
        let rows = max(1, Int(size.height / cellSize.height))
        return (cols, rows)
    }
}
