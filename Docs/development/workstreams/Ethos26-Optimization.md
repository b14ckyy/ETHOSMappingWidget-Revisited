# ETHOS 26.x — Platform Status and Optimization Candidates

**Created:** 2026-09-15
**Status:** Analysis — nothing implemented yet
**Scope:** Performance and RAM. Ordered by expected impact. Every item needs a hardware
measurement (PERF WINDOW) before and after; none of the numbers below are measured yet.

---

## 1. ETHOS platform status (public information, 2026-09-15)

| Item | Finding |
|---|---|
| Latest public release | **26.1.2** (2026-09-10, "for early adopters"). 26.1.0 came out 2026-08-18. |
| 26.2 | **Not public.** No release, pre-release or nightly notes exist on GitHub. |
| 1.6 line | **Still maintained**: 1.6.7 was released 2026-08-26, *after* 26.1.0. Raising the minimum to 26.1 would drop users who stay on 1.6.x. |
| Lua interpreter | Reference guide still says "based on Lua 5.4.3". No 26.1.x release note mentions interpreter optimizations. |
| Instruction limit | No 26.1.x release note mentions a change. `paint()` still has the ~40K limit as far as public information goes. `wakeup()` has been *preempted* (not killed) since 1.5.10 (issue #4103) — this matches the compute.lua design. The "replace limit by timeout" idea is not documented anywhere public; ask bsongis for the status/nightly before planning around it. |
| Storage limit | Issue #5462 (tiny `storage.write` buffer) is still **open** → `state.dat` stays necessary. |
| 26.1.0 changes relevant to us | Bitmaps moved into firmware ("RAM saved"); UI main delay reduced; new NAND cache (X18RS/X14/XERS — read/write regression fixed in 26.1.2); Lua errors shown with details and listed in System/Information; ELRS 4.0 sensors; `lcd.isSwiping()`, `lcd.isConfiguring()`, `lcd.getContrastingColor()`, theme colour constants, `system.getSources()`, `task.done()`. |
| APIs that exist since 1.x but are unused here | `lcd.loadBitmap(path, lazy)` second parameter (default **lazy = true**), `lcd.isVisible()` (1.5.0), `lcd.invalidate(x,y,w,h)`, `system.getMemoryUsage()` (1.1.0, returns `luaRamAvailable` and `luaBitmapsRamAvailable`), `lcd.loadMask`/`drawMask`, `os.stat()`. |

**Minimum version recommendation:** keep ETHOS 1.6 for 2.2. Gate 26.1-only calls with
`mapStatus.ethosVersion.major >= 26`. Revisit for 3.0 once 26.x is the default shipped firmware.

---

## 2. Optimization candidates

### O1 — Tiles are probably decoded inside paint() (lazy loadBitmap)  `HIGH · paint budget · easy`

`lcd.loadBitmap(path, lazy)` defaults to `lazy = true` ("only loaded when needed"). `tileloader.lua`
calls `lcd.loadBitmap(path)` without the second argument, so the file is only probed in `wakeup()`
and the JPEG/PNG decode most likely happens at the first `lcd.drawBitmap()` — inside `paint()`.
The ff0005e measurement (`loadMs/tile 19.7 → 1.2 ms`) is consistent with that: the decode did not
get 16× faster, it moved.

- Fix: `lcd.loadBitmap(path, false)` in `tryLoadBitmap()` and for the sentinel bitmaps.
- Verify: PERF `tileIO loadMs` must go back up (~12–20 ms/tile) and `paint drawTilesMs` must drop
  on the first frame after zoom/pan. Keep the time budget in `processQueue()` — it now measures real work.
- Side effect: with lazy loading, bitmap RAM is not allocated at load time, so the cache-ring / GC
  reasoning in `ETHOS-BITMAP-GC-TIMING.md` was reasoning about handles, not pixels. Re-check after the fix.

### O2 — `lcd.invalidate()` on every wakeup  `HIGH · CPU · medium`

`wakeup()` ends with an unconditional `lcd.invalidate()`, so `paint()` runs every cycle even when
nothing changed (idle on the bench: ~5 fps × 150 ms = the CPU is ~75 % busy painting a static map).

- Fix: invalidate only when something is dirty — GPS position changed, tile loaded, pan/zoom, MSP
  publish, bar tick (1 Hz), blink toggle, telemetry-lost flag. `markMapDirty()` already exists as
  the hook; add `tilesLoaded > 0` and the bar tick.
- Optional: `lcd.invalidate(x, y, w, h)` for the bars only when only bar values changed.
- Verify: PERF `paints` per window drops sharply when idle; unchanged during pan/flight.
  Watch for stale overlays (blink, telemetry-lost colour) — those must set the flag.

### O3 — Skip work when the widget is not visible  `HIGH · CPU+RAM · easy`

No `lcd.isVisible()` check anywhere. While another screen is shown, the widget still loads tiles,
runs compute, invalidates and GCs.

- Fix: at the top of `wakeupInner()`, if `not lcd.isVisible()` → run only MSP poll, `bgtasks()`
  (telemetry + trail) and log flush; skip compute, tile queue, invalidate, GC.
- Verify first: add a one-shot log line to confirm ETHOS calls `wakeup()` for off-screen widgets
  at all (expected yes, same as sources/tasks).

### O4 — GC strategy  `MEDIUM · CPU · medium`

Full `collectgarbage()` runs twice every 10 wakeups (`main.lua`) and twice before every tile batch
(`tileloader.processQueue`). Each full mark-and-sweep over a multi-MB heap costs 5–50 ms and shows
up as `frame ≥ 100 ms`.

- Measure first: add `gc_ms` to the perf metrics around every `collectgarbage()` call.
- Options (Lua 5.4): `collectgarbage("generational")` once in `create()` (short-lived tables die
  cheaply); replace the periodic full collect with `collectgarbage("step", N)`; keep exactly one full
  collect only after `trimCache()` evicted bitmaps (bitmap userdata needs a finalizer pass).
- Risk: generational mode + userdata finalizers is the least tested combination; watch RAM in PERF.

### O5 — Adaptive tile cache from `system.getMemoryUsage()`  `MEDIUM · RAM · medium`

The cache ring size and the ~831 KB OOM cliff are guesswork today.

- Log `luaRamAvailable` and `luaBitmapsRamAvailable` in the PERF table (new `mem` row).
- Size `cacheRing` / prefetch depth from `luaBitmapsRamAvailable`: stop prefetching below a floor,
  shrink the ring when low, grow it on radios with headroom (X20 vs X14 vs XE).
- This also gives the RAM metric that has been missing for every tuning decision so far.

### O6 — MSP poll early-out  `LOW · CPU · easy`

`msp.poll()` is called 10× per wakeup unconditionally. When the state is DONE/ERROR/OFF and the
next arming/nav poll is seconds away, the loop should return after one call. Cheap, but it is 10
function calls + state checks every cycle for nothing.

### O7 — Clipping: let the firmware do it  `LOW-MEDIUM · paint budget · experiment`

`drawMap()` already sets `lcd.setClipping(x, y, w, h)`. The Lua-side Cohen-Sutherland
`clipLine()` then computes intersection points for every trail/WP segment that crosses the edge.
Keep the trivial-reject (saves draw calls for fully off-screen segments), drop the intersection
math and let the firmware clip. Needs an A/B with a dense mission and a long trail — the firmware
clipper may be slower for very long lines.

### O8 — UI icons as masks  `LOW · RAM · easy`

Zoom/lock/pin/home icons are RGBA PNGs loaded as bitmaps. `lcd.loadMask` + `lcd.drawMask` uses
8-bit masks, colours them with the current `lcd.color()` and needs less bitmap RAM. With 26.1
theme constants the icons could follow the theme. Small win, cosmetic bonus.

### O9 — 26.1-only: `lcd.isSwiping()`  `LOW · UX · easy`

Skip `drawMap()` (draw only the last frame's bars, or nothing) while the home screen is being
swiped. Directly targets the "UI stutter during screen swipes" hardware-only test item. Gate by
`ethosVersion.major >= 26`.

### O10 — Tile format re-check on 26.1  `INFO`

26.1 changed the flash/NAND layer. Re-run `TILE-LOADING-BENCHMARK.md` (JPG vs BMP vs PNG,
internal vs SD) on 26.1.2 before assuming the 1.6 numbers still hold — especially on NAND radios.

---

## 3. Housekeeping found on the way

- `RADIO/scripts/ethosmaps/lib/prepaint.lua` is a stale file from March that the build never
  removes — `Build-Release.ps1` copies but does not clean `RADIO/scripts/ethosmaps/lib/`.
- `msp.lua`, `compute.lua`, `resetLib.lua` lack the GPL header.
- MapTiler (PR #49) and the ff0005e tile-I/O change have no CHANGELOG/README/MapTilesGuide entry.

## 4. Suggested order

1. O1 (one-line change, biggest suspected paint win) → measure.
2. O3 + O6 (safe, small) → measure idle CPU.
3. O2 (dirty-flag invalidation) → measure idle vs pan.
4. O5 logging first (mem row), then O4 GC experiments with the numbers in hand.
5. O7/O8/O9 as time permits.
