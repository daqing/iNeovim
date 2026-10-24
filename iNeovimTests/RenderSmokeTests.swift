import AppKit
import XCTest
@testable import iNeovim

/// Renders a sample screen through the real `GridContentLayer` offscreen.
/// Doubles as a render smoke test (the bitmap must be non-empty) and as the
/// generator for `docs/screenshots/editor.png` (it writes the PNG to the
/// temporary directory and prints the path).
@MainActor
final class RenderSmokeTests: XCTestCase {
    func testRendersSnapshotToBitmap() throws {
        let (grid, highlights) = Self.sampleScreen()
        let snapshot = ScreenSnapshot(
            grid: grid,
            highlights: highlights,
            defaultForeground: 0xC8D3E0,
            defaultBackground: 0x0F1419,
            defaultSpecial: nil,
            cursor: CursorState(grid: 1, row: 6, col: 14),
            modes: [ModeInfo(name: "normal", cursorShape: .block)],
            modeIndex: 0
        )

        let metrics = FontMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let layer = GridContentLayer(metrics: metrics)
        let scale: CGFloat = 2
        layer.contentsScale = scale
        layer.update(snapshot: snapshot)

        let size = layer.bounds.size
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0x0F / 255, green: 0x14 / 255, blue: 0x19 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        layer.draw(in: context)

        let image = try XCTUnwrap(context.makeImage())
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)

        let attachment = XCTAttachment(image: NSImage(cgImage: image, size: size))
        attachment.name = "editor"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Sample screen

    private static let keywords: Set<String> = ["import", "struct", "var", "let", "func", "@main"]
    private static let types: Set<String> = ["App", "Scene", "WindowGroup", "ContentView", "String", "NvimClient"]

    private static func sampleScreen() -> (Grid, HighlightStore) {
        let width = 76
        let height = 20
        var grid = Grid(id: 1, width: width, height: height)
        var highlights = HighlightStore()
        highlights.define(HlAttr(foreground: 0x3B4A5A), for: 1)                       // line number
        highlights.define(HlAttr(foreground: 0xC792EA, bold: true), for: 2)           // keyword
        highlights.define(HlAttr(foreground: 0x7FDBCA), for: 3)                       // type
        highlights.define(HlAttr(foreground: 0x546E7A, italic: true), for: 4)         // comment
        highlights.define(HlAttr(foreground: 0xFFCB6B), for: 5)                       // string
        highlights.define(HlAttr(), for: 6)                                           // default text
        highlights.define(HlAttr(foreground: 0x0F1419, background: 0x2AA198, bold: true), for: 7) // status
        highlights.define(HlAttr(foreground: 0xC8D3E0, background: 0x1E2A38), for: 8) // tabline

        let source = [
            "",
            "import AppKit",
            "import SwiftUI",
            "",
            "@main struct MyApp: App {",
            "    var body: some Scene {",
            "        WindowGroup {",
            "            ContentView()",
            "        }",
            "    }",
            "}",
            "",
            "// The embedded nvim is driven over msgpack-RPC.",
            "// 中文注释：宽字符应与网格对齐，emoji 👋 占两格。",
            "let greeting = \"hello, iNeovim\"",
            "",
        ]

        // Tabline.
        let tabline = " iNeovim " + String(repeating: " ", count: width - 9)
        grid.applyLine(row: 0, colStart: 0, runs: cellRuns(tabline, attr: 8))

        for (index, line) in source.enumerated() {
            let row = index + 1
            let number = String(format: " %2d ", row)
            var runs = cellRuns(number, attr: 1)
            runs.append(contentsOf: tokenRuns(for: line, width: width - number.count))
            grid.applyLine(row: row, colStart: 0, runs: runs)
        }

        let status = " NORMAL  iNeovim/App/AppModel.swift    utf-8    swift  ln 12, col 24 "
        let padded = status.count < width
            ? status + String(repeating: " ", count: width - status.count)
            : String(status.prefix(width))
        grid.applyLine(row: height - 1, colStart: 0, runs: cellRuns(padded, attr: 7))

        return (grid, highlights)
    }

    /// One `GridCellRun` per cell, with double-width characters followed by
    /// an empty-text continuation cell the way nvim sends them. Multi-
    /// character runs must be split because `Grid.applyLine` repeats a run's
    /// text into every cell it counts; `CellRenderer.runs` merges them back.
    private static func cellRuns(_ text: String, attr: Int) -> [GridCellRun] {
        var runs: [GridCellRun] = []
        for character in text {
            runs.append(GridCellRun(text: String(character), attrId: attr, count: 1))
            if CellRenderer.isDoubleWidth(String(character)) {
                runs.append(GridCellRun(text: "", attrId: attr, count: 1))
            }
        }
        return runs
    }

    private static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { $0 + (CellRenderer.isDoubleWidth(String($1)) ? 2 : 1) }
    }

    private static func tokenRuns(for line: String, width: Int) -> [GridCellRun] {
        guard !line.isEmpty else {
            return cellRuns(String(repeating: " ", count: width), attr: 6)
        }
        var runs: [GridCellRun] = []
        var remaining = width
        var inComment = false
        for token in line.split(separator: " ", omittingEmptySubsequences: false) {
            let word = String(token)
            let text = word + " "
            let attr: Int
            if inComment || word.hasPrefix("//") {
                inComment = true
                attr = 4
            } else if keywords.contains(word) {
                attr = 2
            } else if types.contains(word) {
                attr = 3
            } else if word.hasPrefix("\"") {
                attr = 5
            } else {
                attr = 6
            }
            runs.append(contentsOf: cellRuns(text, attr: attr))
            remaining -= displayWidth(text)
        }
        if remaining > 0 {
            runs.append(contentsOf: cellRuns(String(repeating: " ", count: remaining), attr: 6))
        }
        return runs
    }
}
