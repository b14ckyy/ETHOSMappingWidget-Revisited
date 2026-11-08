# ETHOS Lua API quirks

## storage: positional slots

`storage.read(key)` ignores the key and returns the next slot. Every `storage.write()` takes one
slot, also with `nil`.

- Exactly one `storage.read()` per key. A second read for a legacy key name consumes the slot of
  the next setting and shifts everything after it. Builds before 2.2.1 did this for the three zoom
  keys, because `mapZoomDefault` is always stored as `nil`.
- Values read one slot off could be saved again by `write()` at the right position, so
  `sanitizeLoadedConfig()` in `main.lua` drops values no setting can hold.
- Reading past the stored data happens after an update adds keys. ETHOS 1.6.4 to 26.2 log
  `storage.read error: Read error` and return `nil`. Older firmware is untested, so reads go
  through `pcall`.

## lcd.loadBitmap: lazy handles and missing files

`lcd.loadBitmap(path)` is lazy by default: it returns a handle in well under a millisecond, and the
file is decoded at the first draw in `paint()`.

- `bitmap:width()` on a fresh handle forces the decode in the caller. Never call it in the tile
  load path: with the wakeup time budget only one tile per loop gets through.
- A missing file does not raise and does not return `nil`. It returns a handle with `width()` 0
  that draws nothing (simulator: ETHOS 1.6.4, 1.6.8, 26.1.2).

`loadFirstExisting()` in `tileloader.lua` therefore finds the tile format with `io.open`. Once the
format is known, the fast path loads tiles without any check, which keeps the time-budgeted batch
load fast. In wakeups where the load queue is empty, `mapLib.verifyNextVisibleTile()` checks one
visible tile and a width of 0 swaps in `nomap.png`. Only visible tiles: they are already decoded by
the draw, while `width()` on a cache-zone tile would decode it early and cost bitmap RAM.

## BMP tiles

Tested in the simulator on 1.6.8, 26.1.2 and 26.2.0-RC9. `width()` after `lcd.loadBitmap()` shows
whether the file was accepted, the colors were checked on a drawn map.

| Format (uncompressed, bottom-up unless noted) | 1.6.8 | 26.1.2 | 26.2.0-RC9 |
|---|---|---|---|
| **16-bit BI_RGB header with RGB565 pixels** (recommended, smallest) | ok | ok | ok |
| 16-bit BI_RGB header with RGB555 pixels | wrong colors | wrong colors | wrong colors |
| 16-bit RGB565 BI_BITFIELDS | rejected | rejected | ok |
| 24-bit BI_RGB | rejected | rejected | rejected |
| 32-bit BI_RGB | ok | ok | ok |
| 32-bit BI_RGB, top-down | ok | ok | rejected |
| 32-bit BI_BITFIELDS | rejected | rejected | ok |

A rejected file returns a handle with `width()` 0 and draws nothing. ETHOS reads 16-bit BI_RGB as
RGB565, although the BMP format defines it as RGB555.
