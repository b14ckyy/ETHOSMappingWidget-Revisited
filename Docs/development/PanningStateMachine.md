# Panning & Observation Marker — Technical Reference

> **Version**: 2.0

Technical implementation details for the map panning system and observation marker feature. For user-facing documentation, see `Docs/manuals/PanningAndMarker.md`.

## Pan State Machine

### States

```
PAN_IDLE     = 0   -- Map follows UAV (follow-lock active)
PAN_DRAGGING = 1   -- Finger down, map scrolling with touch movement
PAN_GRACE    = 2   -- Finger released, map stays at offset for grace period
PAN_PENDING  = 3   -- Touch detected, waiting for drag movement or release
```

### Timing Constants

```lua
PAN_TOUCH_TIMEOUT_CS  = 50   -- 500 ms: no touch events → finger up
PAN_GRACE_DURATION_CS = 500  -- 5 s: grace period before auto-recenter
```

### State Transitions

```
IDLE ──(touch down)──► PENDING
PENDING ──(drag detected)──► DRAGGING
PENDING ──(timeout / release)──► IDLE
DRAGGING ──(finger up)──► GRACE
GRACE ──(timeout 5s)──► IDLE
GRACE ──(touch down)──► PENDING
```

## isPanning Flag

Computed in `maplib.lua` and controls rendering complexity:

```lua
local isActivePan = panState == 1 or panState == 2  -- DRAGGING or GRACE
local isDetached  = not status.followLock and (panState == 0 or panState == 3)
local isPanning   = isActivePan or isDetached
```

In `main.lua`, the argument passed to `drawMap()`:

```lua
local isPanning = (panState == PAN_DRAGGING)
```

This means Pass 2 of `drawWaypoints()` is only skipped during active finger drag — NOT during grace period or detached-idle.

## Rendering Behavior

When `isPanning == true` (active drag):
- Pass 1 rendered: Path lines, JUMP connections
- Pass 2 skipped: WP circles, numbers, chevrons, RTH lines, altitude labels

When `isPanning == false` (idle, grace, detached-idle):
- Both passes rendered fully

## Observation Marker

### Rendering (`maplib.lua`)

```lua
-- Green line from UAV to observation marker (clipped to viewport)
lcd.color(status.colors.observationGreen)
lcd.drawLine(cx1, cy1, cx2, cy2)

-- Marker circle
local mr = floor(5 * min(scaleX, scaleY))
lcd.color(lcd.RGB(0, 200, 0, 0.6))    -- semi-transparent medium green
lcd.drawFilledCircle(markerX, markerY, mr)
lcd.color(BLACK)
lcd.drawCircle(markerX, markerY, mr)   -- black outline
```

Color: `RGB(0, 200, 0)` with alpha 0.6 (semi-transparent).

### Crosshair (detached mode)

A red "+" crosshair is drawn at the viewport center when `panDragEnabled AND not followLock`.

### Persistence

Stored immediately via:
```lua
storage.write("observationLat", mapStatus.observationLat)
storage.write("observationLon", mapStatus.observationLon)
```

Loaded at widget init from storage.

## UI Button Layout (`layout_default.lua`)

| Button | Position       | Visibility                              | Icon                    |
|--------|----------------|-----------------------------------------|-------------------------|
| Zoom + | Left, 27% h   | Always (`zoomControl == 0`)             | `zoom_plus`             |
| Zoom - | Left, 73% h   | Always (`zoomControl == 0`)             | `zoom_minus`            |
| Lock   | Right, center  | `panDragEnabled`                        | `flockon` / `flockoff`  |
| Pin    | Right, top     | `panDragEnabled AND not followLock`     | `pinbutton`             |
