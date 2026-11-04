# ETHOS Lua: 32-bit integers and the time source

## 32-bit integers, double floats

ETHOS Lua (5.4) uses **32-bit integers** but double-precision floats. Desktop Lua 5.4 uses 64-bit
integers, so overflows do not show up in local tests.

- Integer arithmetic wraps silently: `os.time() * 100` = 1.79e9 × 100 overflows and comes out
  negative or positive depending on the date (the sign flips about every 248 days).
- Integer literals beyond `0x7FFFFFFF` wrap as well: `0xFFFFFFFF` is `-1`.
- Shifts `<< 24` on bytes ≥ 0x80 produce negative values (correct for signed `int32` MSP fields).
- Fix: force float arithmetic where the result can exceed ±2^31 (`os.time() * 100.0`), or keep
  values small.

## Time source

ETHOS has **no `system.getTimeCounter()`** (not in the 26.1.2 Lua reference). Available:

| Function | Resolution | Notes |
|---|---|---|
| `os.time()` | 1 s | Wall clock (RTC). Integer → multiply as float. |
| `os.clock()` | 1 ms | Used for perf durations. Measured as wall clock in a busy system tool on 26.1/26.2; behaviour while idle and on 1.6.x not verified. |

The widget's single time source is `getTime()` in `main.lua`: `os.time() * 100.0`
(centiseconds, 1 s resolution). Timeouts below one second (e.g. `PAN_TOUCH_TIMEOUT_CS = 50`)
therefore act as "up to 1 s".

Symptom of the old integer overflow (until 2026-11): `getTime()` negative → every
`now - (last or 0) >= interval` check never fired (bar refresh, non-forced debug logs, GPS log)
and `ZOOM LIMIT` (`end > getTime()` with `end = 0`) stayed on screen from widget start.

## Testing

`build/tests/stub_widget.lua` runs `main.lua` on desktop Lua with an `os.time()` that overflows
64-bit integers when multiplied by 100 — the same failure class as 32 bit on the radio.
