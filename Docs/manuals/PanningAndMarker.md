# Map Panning & Observation Marker

> **Version**: 2.0 — This feature was introduced in version 2.0 and is not available in 1.x releases.

The widget supports touch-based map panning and a custom observation marker feature. This allows free exploration of the map while the UAV continues to fly, and the ability to pin a marker at any position for reference.

## Panning

### Overview

By default, the map is locked to follow the UAV position (follow-lock). When panning is enabled (fullscreen widget), you can drag the map to explore the surrounding area. The map enters **detached mode** and stops following the UAV.

### Touch Controls

| Gesture       | Action                                        |
|---------------|-----------------------------------------------|
| Touch & drag  | Pan the map in any direction                  |
| Tap (no drag) | No map action (passed on to ETHOS)            |
| Release       | Map stays briefly, then re-centers on UAV     |

After releasing the touch, the map holds its position for about 5 seconds before automatically re-centering on the UAV.

### Performance During Panning

To maintain smooth scrolling during active dragging, waypoint detail rendering is temporarily reduced. Only flight path lines and essential markers (UAV, home, observation marker) remain visible. Full detail returns as soon as dragging stops.

## Follow-Lock

The lock button (visible in fullscreen mode) toggles the follow-lock behavior:

### Locked (default)
- Map follows UAV position in real time
- Panning via touch is available (temporarily breaks lock during drag)

### Unlocked (detached mode)
- Map freezes at the current viewport position
- UAV marker still updates on the frozen map
- No auto-recenter after dragging
- Pin button becomes available for placing observation markers

### Re-Locking
Pressing the lock button again snaps the map back to the UAV position.

## Observation Marker

The observation marker is a persistent, user-placed pin on the map. It can be used to mark a point of interest such as a landing zone, a reference location, or any custom position.

### Placement

1. Unlock the map (press the lock button)
2. A crosshair appears at the viewport center to indicate detached mode
3. Pan the map so the desired location aligns with the crosshair
4. Press the **pin button**
5. A green marker appears at the position
6. A line is drawn from the UAV to the marker for reference

### Removal

Press the pin button again while an observation marker is active. It toggles off.

### Persistence

The observation marker persists across widget restarts and power cycles until explicitly removed.

## UI Buttons

The panning and marker controls are rendered as overlay buttons in fullscreen mode:

| Button | Condition                    | Action                            |
|--------|------------------------------|-----------------------------------|
| Lock   | Fullscreen + panning enabled  | Toggle follow-lock on/off        |
| Pin    | Unlocked + panning enabled    | Place/remove observation marker  |
| Zoom + | Unless zoom is RC-controlled  | Increase map zoom level          |
| Zoom - | Unless zoom is RC-controlled  | Decrease map zoom level          |

The lock button sits at the right edge (middle), the pin button above it at the right edge.

> **Note**: The pin button is only available when the map is **unlocked** (detached mode). This ensures you are panning to the desired position before placing the marker.
