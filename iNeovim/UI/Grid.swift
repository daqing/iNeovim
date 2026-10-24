import Foundation

/// One cell of a grid: the text it holds plus its highlight id (0 = default).
nonisolated struct GridCell: Equatable, Sendable {
    var text: String = " "
    var attrId: Int = 0
}

/// Cell storage for a single nvim grid. Grid state is keyed by grid id
/// throughout (per the multigrid-ready design), even though v1 runs single-grid.
nonisolated struct Grid: Equatable, Sendable {
    let id: Int
    private(set) var width: Int
    private(set) var height: Int
    private var cells: [GridCell]

    init(id: Int = 1, width: Int = 0, height: Int = 0) {
        self.id = id
        self.width = max(0, width)
        self.height = max(0, height)
        self.cells = Array(repeating: GridCell(), count: self.width * self.height)
    }

    var isEmpty: Bool { cells.isEmpty }

    subscript(row: Int, col: Int) -> GridCell {
        cells[row * width + col]
    }

    /// A zero-copy view of one row, used by the renderer's run grouping.
    func rowSlice(_ row: Int) -> ArraySlice<GridCell> {
        let start = row * width
        return cells[start..<(start + width)]
    }

    /// Resize, preserving the overlapping top-left region; new cells are blank.
    mutating func resize(width: Int, height: Int) {
        let width = max(0, width)
        let height = max(0, height)
        guard width != self.width || height != self.height else { return }
        var newCells = Array(repeating: GridCell(), count: width * height)
        let copyRows = min(height, self.height)
        let copyCols = min(width, self.width)
        for row in 0..<copyRows {
            for col in 0..<copyCols {
                newCells[row * width + col] = cells[row * self.width + col]
            }
        }
        self.width = width
        self.height = height
        self.cells = newCells
    }

    mutating func clear() {
        for index in cells.indices {
            cells[index] = GridCell()
        }
    }

    /// Apply one `grid_line`: write each run left to right, clipping at the
    /// right edge.
    mutating func applyLine(row: Int, colStart: Int, runs: [GridCellRun]) {
        guard row >= 0, row < height, colStart >= 0, colStart < width else { return }
        var col = colStart
        for run in runs {
            for _ in 0..<run.count {
                guard col < width else { return }
                cells[row * width + col] = GridCell(text: run.text, attrId: run.attrId)
                col += 1
            }
        }
    }

    /// Scroll the [top, bot) x [left, right) region: positive `rows` move the
    /// content up, negative move it down; positive `cols` move it left,
    /// negative move it right. Vacated cells are cleared.
    mutating func scroll(top: Int, bot: Int, left: Int, right: Int, rows: Int, cols: Int) {
        guard rows != 0 || cols != 0 else { return }
        let top = max(top, 0)
        let bot = min(bot, height)
        let left = max(left, 0)
        let right = min(right, width)
        guard top < bot, left < right else { return }

        // Snapshot the region so overlapping moves read the pre-scroll content.
        let regionWidth = right - left
        var region = [GridCell]()
        region.reserveCapacity(regionWidth * (bot - top))
        for row in top..<bot {
            region.append(contentsOf: cells[(row * width + left)..<(row * width + right)])
        }

        for row in top..<bot {
            let sourceRow = row + rows
            for col in left..<right {
                let sourceCol = col + cols
                let value: GridCell
                if (top..<bot).contains(sourceRow), (left..<right).contains(sourceCol) {
                    value = region[(sourceRow - top) * regionWidth + (sourceCol - left)]
                } else {
                    value = GridCell()
                }
                cells[row * width + col] = value
            }
        }
    }
}
