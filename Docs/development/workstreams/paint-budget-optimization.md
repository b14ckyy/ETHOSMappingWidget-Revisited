# Paint() Instruction Budget Optimization Plan

**Target version:** 2.2  
**Created:** 2026-04-02  
**Status:** Backlog — do not touch for 2.1 release  

## Context

ETHOS enforces a hard 40K Lua instruction limit per `paint()` call. The items below
are operations still running inside `paint()` that could be moved to `wakeup()` or
precomputed/cached.

## Audit Results

Call chain traced:  
`paint()` → `paintInner()` → `checkSize()` + `layout.draw()` + `drawNoGPSData()`  
`layout.draw()` → `mapLib.drawMap()` + `drawLib.drawTopBar()` + `drawBarSensor()` × 2-4 + `drawLib.drawBitmap()` × 3-5 + `mapLib.calculateScale()` + `drawLib.drawRArrow()` × 0-4  
`mapLib.drawMap()` → `activateVpCtx()` + `setupMaps()` + `loadAndCenterTiles()` (edge case) + `drawTiles()` + `drawVehicle()` + `drawWaypoints()` + `deactivateVpCtx()`

---

### HIGH — Potential Budget Killers

| # | File | Location | Problem | Details | Fix |
|---|------|----------|---------|---------|-----|
| 1 | drawlib.lua | ~L636 | `lcd.loadBitmap()` SD I/O | First access to any icon (zoom_plus, flockon etc.) reads + decodes PNG from SD card. Only first frame but can blow 40K | Preload all named bitmaps in `wakeup()`/`init()` |
| 5 | drawlib.lua | ~L305-335 | Font-selection loop in `drawTopBar()` | Up to 3 fonts × 5 sensors = **60× `lcd.font()` + `lcd.getTextSize()`** on cache miss | Move font selection to `wakeup()` — only depends on widget width + sensor count |
| 7 | maplib.lua | ~L1693-1704 | `setupMaps()` clears tile cache on zoom change | Entire tile cache + path index cleared inside paint | Move zoom/provider change detection to `wakeup()` |
| 8 | maplib.lua | ~L1363-1373 | `loadAndCenterTiles()` on viewport resize | Full tile grid rebuild (24+ `fmt()` calls) executed in paint | Flag resize in paint, handle rebuild in `wakeup()` |

### MEDIUM-HIGH

| # | File | Location | Problem | Details | Fix |
|---|------|----------|---------|---------|-----|
| 2 | drawlib.lua | ~L119-125 | `pcall(function()...end)` per sensor | 5-10 closure allocations + pcall overhead per frame for sensor reads | Move sensor reads to `wakeup()`, cache formatted text strings |
| 10 | maplib.lua | ~L685-724 | `tostring()` + `getTextSize()` per WP marker | 20 visible WPs = 20 string allocs + 40 getTextSize calls | Pre-compute WP label strings + text sizes in `wakeup()` when mission changes |

### MEDIUM

| # | File | Location | Problem | Details | Fix |
|---|------|----------|---------|---------|-----|
| 3 | drawlib.lua | ~L81, L106 | `tostring(sensor)` for cache keys | Creates "userdata: 0x..." garbage strings per sensor per frame | Use sensor object directly as table key, or cache tostring result |
| 4 | drawlib.lua | ~L297 | `model.name()` system API fallback | Called every frame when `status.modelString` is nil | Cache model name once in `create()`/`wakeup()` |
| 6 | layout_default.lua | ~L77-83 | `drawBarSensor` font switches | 3 font switches + 4 getTextSize per sensor bar (×4 = 16 switches) | Cache label/unit widths per font — they never change |
| 9 | maplib.lua | ~L571 | `fmt()` in `getScreenCoordinates` | String formatting for tile_path every frame | Cache last tile_path→screen result or pass tile indexes directly |
| 12 | maplib.lua | ~L1808 | `calculateScale()` string every frame | `fmt("%.0f%s", ...)` only changes on zoom change | Cache scaleLen/scaleLabel by zoom level, invalidate in `wakeup()` |

### LOW-MEDIUM

| # | File | Location | Problem | Fix |
|---|------|----------|---------|-----|
| 11 | maplib.lua | ~L1099-1103 | JUMP annotation: `tostring()` + font switch in WP loop | Pre-compute in wakeup or cache |
| 15 | drawlib.lua | ~L586-634 | Vehicle sin/cos 8-20 trig ops per frame (heading rarely changes) | Cache trig results by heading, invalidate in `wakeup()` |
| 16 | layout_default.lua | ~L441-468 | Edge arrow atan2 + 2×8 trig ops per arrow | Precompute arrow direction in `wakeup()` |

### LOW (acceptable / defensive only)

| # | File | Problem |
|---|------|---------|
| 13 | layout_default.lua ~L296 | "zoom N" string concat every frame |
| 14 | maplib.lua ~L784 | logDebug fmt args evaluated even when guarded (debug only) |
| 17 | maplib.lua ~L1510, L1624 | `lcd.RGB()` fallback — only if ensureWpColors missed |
| 18 | main.lua ~L805-835 | Perf profiling instrumentation cost (opt-in, acceptable) |

---

## Suggested Approach for 2.2

1. **Batch 1 (highest impact, moderate risk):** Move #7 setupMaps and #8 loadAndCenterTiles to wakeup. These are edge-case paths but when they fire, they are the most likely to exceed 40K.
2. **Batch 2 (high impact, safe):** Move #5 font-selection and #2 sensor reads to wakeup. Large instruction savings on every frame.
3. **Batch 3 (medium, incremental):** Cache strings (#3, #9, #12, #13), preload bitmaps (#1), cache model name (#4).
4. **Batch 4 (nice-to-have):** Trig caching (#15, #16), WP label precomputation (#10, #11).

Each batch should be tested separately on hardware before moving to the next.

## Notes

- Line numbers are approximate and may shift as code evolves.
- The pcall wrapper around paint() absorbs instruction limit errors gracefully; removing it is only useful for testing.

## Reverted Changes (2.1 → 2.2 backlog)

The following two changes were implemented and tested on hardware during 2.1 development
but **reverted** (commit `d7971e7` → `a40d386`) due to a massive performance regression:
wakeup() baseline rose from 24ms to >40ms, fps dropped from 3.6 to 2.6.

### R1 — Move loadLayout (dofile) from paint() to wakeup()

- **What:** Split `loadLayout()` into `ensureLayout()` (dofile + init, called in wakeup)
  and `drawLoadingOverlay()` (lightweight text splash, called in paint when layout not ready).
- **Why reverted:** Moving layout loading to wakeup increased wakeup duration significantly.
  The `dofile()` call parses and executes an entire Lua module — adding this to the already
  busy wakeup cycle caused the FPS drop. Needs investigation: perhaps defer to a dedicated
  "init wakeup" that runs only once, or spread across multiple wakeup cycles.
- **For 2.2:** Test with a one-shot flag so `ensureLayout` only runs on the very first wakeup
  (or after a screen change), not every cycle. Measure wakeup impact in isolation.

### R2 — Remove resolveWidget() from paint() and event()

- **What:** ETHOS guarantees valid widget in `paint()` and `event()`. `resolveWidget()` was
  removed from both and kept only in `wakeup()` (where background scheduling may pass nil).
- **Why reverted:** Reverted together with R1 as a single commit. The resolveWidget change
  itself is likely safe and has negligible performance impact, but needs to be tested
  independently.
- **For 2.2:** Re-apply as a standalone change and verify on hardware. Should be low risk.
