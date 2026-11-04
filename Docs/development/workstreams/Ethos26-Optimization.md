# ETHOS 26.x — Platform Status and Optimization Candidates

**Created:** 2026-09-15 · **Updated:** 2026-11-04
**Status:** Planned — O9 (swipe mode) is next, O4 (GC) leads the following optimization round
**Scope:** Performance and RAM on ETHOS 26.1/26.2 without dropping 1.6. Every item needs a
hardware measurement (PERF WINDOW) before and after.

**Compatibility rule:** the widget stays ETHOS 1.6 compatible and uses 26.1/26.2 APIs where
available. Gate new calls by feature detection (`type(lcd.isSwiping) == "function"`), cached once,
not by version string parsing.

---

## 1. ETHOS platform status

| Item | Finding |
|---|---|
| Public releases (2026-09-15) | **26.1.2** latest (2026-09-10). 1.6 line still maintained (1.6.7, 2026-08-26). |
| 26.2 | 26.2.0-RC7 tested on X20RS (2026-11-04, see §3). Not released. |
| Instruction limit | Widgets: ~40K per `paint()`, no public change. `wakeup()` is preempted, not killed (since 1.5.10, issue #4103). |
| Storage limit | Issue #5462 (tiny `storage.write` buffer) still open → `state.dat` stays necessary. |
| 26.1.0 APIs relevant to us | `lcd.isSwiping()` (boolean, "check if the window is swiping"), `lcd.isConfiguring()`, `lcd.getContrastingColor()`, theme colour constants, `system.getSources()`, `task.done()`. |
| 26.2 API | `system.getInstructionsUsage()` (percent of the paint budget, see §3 for what it counts). |
| Older APIs still unused | `lcd.loadBitmap(path, lazy)` second parameter (default **lazy = true**), `lcd.isVisible()` (1.5.0), `lcd.invalidate(x,y,w,h)`, `system.getMemoryUsage()` (1.1.0), `lcd.loadMask`/`drawMask`. |
| Bitmap API | `Bitmap` has only `width()`, `height()`, `rotate()` (26.1.2 doc). No resize, no offscreen target, no bitmap from memory — scaled icons cannot be pre-rendered at runtime. |

---

## 2. Optimization candidates

### O9 — Swipe mode: freeze background math while the home screen swipes  `NEXT · UX · easy`

ETHOS does **not** keep showing the last widget frame during a swipe (tested earlier with a
manual swipe detection) — `paint()` has to keep running. What can stop is the background work,
so `paint()` gets the maximum draw rate the visible map allows and the radio UI feels less
sluggish.

Design:
- `create()`: cache `swipeFn = type(lcd.isSwiping) == "function" and lcd.isSwiping or nil`
  (nil on 1.6 → feature off, no behaviour change).
- `wakeupInner()`: `local swiping = swipeFn and swipeFn()`; store as `mapStatus.swiping`.
  - Keep while swiping: `msp.poll()` loop (SmartPort buffer overflow otherwise), `bgtasks()`
    telemetry reads, `updateTrail()` (cheap, avoids a gap in the trail), `lcd.invalidate()`.
  - Skip while swiping: `compute.update()` (incl. the every-cycle `needsTileGrid`),
    `tileLoader.processQueue()`, RC zoom channel handling, periodic GC, log flush.
  - On the falling edge (swipe ended): `markMapDirty()` so the next cycle reprojects.
- `paint()`: while `mapStatus.swiping`, use the existing reduced draw path of active panning
  (overlays skipped, bar content frozen) so the frame only blits tiles, bars and icons.
- Debug: one `SWIPE` log line per edge (start/end, duration) to confirm `isSwiping()` actually
  reports home-screen swipes for a widget window — verify this first on hardware.

Verify (hardware, 26.1.2): PERF `fps` and `wakeup totMs` during 20–30 s of continuous swiping,
with and without the change. Map must be correct immediately after the swipe ends; MSP must not
report errors during swipes. On 1.6.x: no change at all.

### O4 — GC strategy  `HIGH (first item of the next optimization round) · CPU`

`wakeup()` runs two full `collectgarbage()` every 10 wakeups (`main.lua`, introduced in "Step B"
of `PerformanceExperimentsPlan.md` to get GC out of the hot paths). `tileloader.processQueue()`
additionally runs two full collects before loading after an eviction (`pendingGCBeforeLoad`,
bitmap safety — stays untouched).

1. Measure: `gc_ms` metric around the periodic collect, shown in the PERF table. Correlate with
   `frame100ms`.
2. If it is significant (rule of thumb > 15 ms per occurrence): replace the periodic double full
   collect by `collectgarbage("step", n)` every wakeup — constant small cost instead of a spike
   every ~3 s.
3. Fallback if `step` misbehaves: split the two passes over two consecutive wakeups (halves the
   spike, same total work).
4. `collectgarbage("generational")` only as a later experiment (least tested with userdata finalizers).

Reference: doombench measured ~97 ms for 2× full GC right after freeing 64 bitmaps — that is the
eviction case, not the periodic one, so it does not predict our number.

### PERF additions  `HIGH · tooling · easy`

- `gc_ms` (see O4).
- 26.2: `system.getInstructionsUsage()` at the end of `paint()` → `instr%` avg/max. In a system
  tool it counts drawing work, not VM instructions (§3); check what it counts for a widget before
  using it for decisions.
- `system.getMemoryUsage()` → `luaFree` / `bmpFree` row, logging only. The tile cache ring is
  tuned and stays as is.

### O3 — Skip work when the widget is not visible  `MEDIUM · CPU · easy`

No `lcd.isVisible()` check anywhere. While another screen is shown, the widget still loads tiles,
runs compute, invalidates and GCs. Same keep/skip split as O9 (MSP, telemetry, trail keep running)
plus skip `lcd.invalidate()`. Verify first that ETHOS calls `wakeup()` for off-screen widgets.
Natural follow-up to O9 (shares the skip path).

### O6 — MSP poll early-out  `LOW · CPU · easy`

`msp.poll()` is called 10× per wakeup unconditionally. In DONE/ERROR/OFF with the next
arming/nav poll seconds away, return after one call.

### O2 — Idle invalidation  `LOW · experiment`

`lcd.invalidate()` runs every wakeup **on purpose**: the dirty-flag scheduler from "Step A" was
removed in a2ab3c6 because ETHOS couples touch events to render cycles and short taps were missed
at 2 Hz. In flight the fastest input is 5 Hz GPS/heading telemetry, which the widget already
renders; panning needs a full redraw every frame anyway. Remaining idea, only as a test:
when nothing is dirty, call `lcd.invalidate(0, 0, 1, 1)` instead of a full invalidate and check
(a) taps are still delivered and (b) whether ETHOS limits the repaint to that rect (PERF
`drawTilesMs` drops). If (a) fails, drop O2.

### O1 — Eager bitmap decode  `PARKED · tile loader`

`tryLoadBitmap()` calls `lcd.loadBitmap(path)` → lazy: the handle is created in `wakeup()`
(~1 ms), the JPEG decode happens at the first `lcd.drawBitmap()` inside `paint()`. This has been
the case since the beginning (also before ff0005e; its 19.7 → 1.2 ms came from dropping the
`fileExists()` opens and failed probes). doombench P14 confirms the behaviour on 26.2: 64 lazy
JPGs, first frame 501 ms, following frames 10 ms.

Parked: the loader fills a full zoom refresh in < 2 s on 1.6.x and < 1 s on 26.1 and keeps up
with slow-to-medium finger panning. Do not touch without a concrete problem. If it is ever
revisited: `loadBitmap(path, false)` moves the decode into the time budget, but prefetched tiles
would then occupy bitmap RAM before they are drawn — the cache ring tuning must be re-checked
with the `bmpFree` row.

### O8 — UI icons  `LATER · paint · easy`

Zoom/lock/pin icons are 52×52 PNGs drawn scaled (`floor(52 * scaleFactor)`, 49 px at full
screen). Scaled blits are expensive on 26.2 (doombench P21: ~1.3 ms for a 48 px blit), but during
panning only 3 icons are on screen, so the gain is a few ms. Options when this comes up: draw at
native size when `btnSize` is within a few px of 52, ship pre-scaled PNGs in 3–4 sizes, or
`lcd.loadMask`/`drawMask` (8-bit masks, theme-coloured, less bitmap RAM).

### O7 — Clipping: let the firmware do it  `LOW · experiment`

Keep the trivial reject in `clipLine()`, drop the intersection math and rely on `lcd.setClipping`.
Needs an A/B with a dense mission and a long trail.

### O10 — Tile format re-check on 26.x  `INFO`

Re-run `TILE-LOADING-BENCHMARK.md` (JPG vs PNG, internal vs SD) on 26.1.2. BMP: see B1.

---

## 3. Reference measurements: doombench on 26.2.0-RC7 (X20RS, 2026-11-04)

Taken with a Lua **system tool** (private Doom-on-ETHOS experiment), not a widget — use as
orientation, not as widget numbers.

| Measurement | Result |
|---|---|
| Lua VM | ~2.7 µs per VM instruction; Lua function call ~30 µs, C call ~18 µs |
| Lua in `paint()` vs `wakeup()` | 13 vs 5.7 µs per loop iteration → `paint()` Lua is ~2.3× slower |
| Lazy load (P14) | handle ~0.4 ms, decode (~8 ms per 32×32 JPG) at first draw in `paint()` |
| Eager load (W02/W03) | JPG ~8 ms, PNG ~8 ms per 32×32; 2 KB `bmpFree` each, ~120 B Lua heap |
| Blits | Unscaled 32×32 JPG ~116 µs; scaled ~2 Mpx/s (48 px 1.3 ms, 96 px 4.5 ms, 192 px 17 ms) |
| `getInstructionsUsage()` in a system tool | counts drawing work, not VM instructions: ~2 100 rects = 100 %, weights ≈ rect 1, color 0.55, clip 1, blit 1.5. After hitting 100 % the counter stays 0 until the tool exits (RC7 bug) |
| BMP | 24-bit BI_RGB: `loadBitmap` returns a handle, `width()` = 0, nothing is drawn, no bitmap RAM used |
| RAM | Lua heap and bitmap pool behave as separate pools (~720 KB vs ~2.5 MB free at tool start) |

---

## 4. Bugs / compatibility

### B1 — BMP tiles not drawn on 26.2.0-RC7  `OPEN · reported to bsongis 2026-11-04`

`tryLoadBitmap()` accepts any non-nil handle, so a BMP tile that loads with `width() == 0`
counts as loaded: no fallback to JPG/PNG, and `cachedTileFormat` then sends every following
tile to `.bmp` → empty map for BMP users on 26.2. Pending the answer from bsongis: either it is
fixed before 26.2 final, or `tryLoadBitmap()` rejects handles with `width() == 0` and
MapTilesGuide drops the BMP recommendation for 26.2.

---

## 5. Housekeeping

- `resetLib.lua` lacks the GPL header.
- `main.lua` periodic GC comment is German ("Step B: Periodische Garbage Collection") → English when O4 touches it.

## 6. Order

1. **O9** swipe mode (+ the `SWIPE` debug line) → hardware test on 26.1.2 and 1.6.x.
2. **PERF additions** (`gc_ms`, `instr%`, mem row) — can ship together with O9.
3. Next optimization round: **O4** first, then O3 + O6.
4. B1 as soon as bsongis answers.
5. Later / experiments: O2, O8, O7, O10. O1 stays parked.
