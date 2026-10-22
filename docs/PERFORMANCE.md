# Performance

Phase 9 reviewed the three hot paths named in T9.2 — the render path, RPC
throughput, and scroll frame pacing. This file records what was changed, the
measured baselines, and how to profile with Instruments.

## Hot-path review

**Render (`GridContentLayer.draw(in:)`)** — runs per dirty region per frame.
Two avoidable costs were removed:

- Rows were copied into a fresh `[GridCell]` before run grouping. `Grid` now
  exposes a zero-copy `rowSlice(_:)` and `CellRenderer.runs(forRow:)` is
  generic over the row storage, so no per-row array is allocated.
- `resolvedColors(for:)` built `NSColor`s (and walked the highlight store)
  once per run. The layer now resolves each highlight id once per frame and
  caches it, so a row with many same-attribute runs resolves one color.

Core Text shaping (`CTLineCreateWithAttributedString` per run plus
`CellRenderer.shiftGroups`) turned out to be the dominant cost of wheel
scrolling, because every scroll step repaints the whole viewport. Those rows
are the ones that were already on screen a line earlier, so their shaping is
reused: `GridContentLayer` keeps a `lineCache` keyed by the run's text, font
variant, and foreground color (the foreground is baked into the `CTLine` —
Core Text does not inherit the context fill color). The cache is dropped on
any highlight/default-color change, a font change, and an appearance change
(the adaptive `.textColor` fallback resolves at shaping time). Only shapes
whose color actually differs can collide across theme flips, and those
collisions are ruled out by the key.

Two more scroll-frame costs were removed:

- The per-run background fill skipped runs that resolve to nvim's default
  background; the view's layer already paints it. Filling it per run repainted
  every cell on every scroll step.
- `CellRenderer.runs(forRow:)` accumulates the current run in locals and
  appends it only when the run ends. Writing through `runs[last]` on each cell
  copied the run's text and slot array per cell (both were shared with the
  stored value), costing ~6 ms per full-screen frame in a Debug build.

`TerminalView` also coalesces flush applies: while one main-actor apply is
queued, later flushes only accumulate dirty cells, and the apply reads the
newest snapshot. A wheel burst that nvim answers with several flushes now
costs one repaint instead of one per flush.

The layer repaints the display clip, not a per-flush list of cells. Core
Animation clears the whole dirty clip before `draw(in:)`, so a pass that
merges a flush with another invalidation (a cursor glide, say) would
otherwise leave the unrepainted part of the clip blank.

**RPC (`RPCSession.feed`/`handleMessage`)** — the incremental `MsgPackDecoder`
is the hot path; encoding is batched per notification and cheap. No changes
were needed; baselines below guard regressions.

**Scroll (`ScrollAnimator.tick`)** — driven by `CVDisplayLink`; the cost is a
single exponential step plus a `CATransform3D` write. Time-based easing keeps
it identical at 60 Hz and 120 Hz (see `ScrollAnimationSettings`). The link is
created, started, and stopped only when the presentation has to move.
`CVDisplayLinkCreateWithActiveCGDisplays` + start + stop measures ~0.5 ms on
its own, and a wheel confirmation's offset is applied directly with its
repaint rather than eased, so the old unconditional start ran that cycle once
per wheel step and queued a tick on the main thread at frame time for an
animation that had nothing to animate.

Measured full-viewport draw after caching (`GridContentLayer` into an offscreen
bitmap, 12 runs per row):

| Grid | Release | Debug |
|------|---------|-------|
| 200×60 | 4.9 ms | 8.0 ms |
| 120×40 | 2.2 ms | 3.8 ms |
| 80×24  | 1.1 ms | 1.9 ms |

## Signposts

`Signpost` (in `Logging.swift`) emits `os_signpost` intervals:

| Category | Interval | Where |
|----------|----------|-------|
| `render` | `gridDraw` | `GridContentLayer.draw(in:)` |
| `rpc`    | `decode`  | `RPCSession.feed(_:)` |
| `scroll` | `chase`   | `ScrollAnimator.tick(timestamp:)` |

## XCTest baselines

`iNeovimTests/PerformanceTests.swift` measures the pure hot paths. Run them
from Xcode (they are part of the normal test run) and check the reported
averages against these recorded values on an Apple-silicon Mac:

| Test | Steady-state average |
|------|----------------------|
| `testRunGroupingFullScreen` (200×60 rows) | ~3.5 ms (was ~5.8 ms) |
| `testGridScrollThroughput` (60×200 region) | ~2.2 ms |
| `testMsgPackEncodeThroughput` (24-row redraw) | ~0.2 ms |
| `testMsgPackDecodeThroughput` (24-row redraw) | ~0.3 ms |

A full-screen run grouping is the worst case (first paint, resize, `Ctrl-L`);
normal frames redraw only the dirty rows.

## Profiling with Instruments

Instruments needs an interactive session and cannot run in CI. To profile:

1. In Xcode choose **Product ▸ Profile** (⌘I) and pick a template.
2. **Time Profiler** — attribute CPU under `GridContentLayer.draw`,
   `CellRenderer.runs`, `CTLineCreateWithAttributedString`, and
   `MsgPackDecoder.nextValue`.
3. **Core Animation** (or `os_signpost`) — watch FPS and the `render`/`scroll`
   signposts while scrolling; frame pacing should stay flat at the display
   refresh rate.
4. **os_signpost** instrument — filter to the `render`, `rpc`, and `scroll`
   categories to see exactly how long each measured interval takes during a
   scroll or a large redraw.
