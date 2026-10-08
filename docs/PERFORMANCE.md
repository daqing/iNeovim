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

Core Text shaping (`CTLineCreateWithAttributedString` per run) remains the
dominant cost and is intentionally not cached: run text changes constantly and
ligatures are shaped across a whole run, so a line cache would rarely hit and
would be invalidated by every `hl_attr_define`.

**RPC (`RPCSession.feed`/`handleMessage`)** — the incremental `MsgPackDecoder`
is the hot path; encoding is batched per notification and cheap. No changes
were needed; baselines below guard regressions.

**Scroll (`ScrollAnimator.tick`)** — driven by `CVDisplayLink`; the cost is a
single exponential step plus a `CATransform3D` write. Time-based easing keeps
it identical at 60 Hz and 120 Hz (see `ScrollAnimationSettings`).

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
| `testRunGroupingFullScreen` (200×60 rows) | ~5.8 ms |
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
