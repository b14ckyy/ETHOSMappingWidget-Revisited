# INAV Waypoint Mission Overlay

> **Version**: 2.0 — This feature was introduced in version 2.0 and is not available in 1.x releases.

The widget can automatically download and display INAV waypoint missions from your flight controller. Missions are shown as a path overlay on the map with markers for each waypoint and real-time tracking of the active waypoint during flight.

## Requirements

- INAV flight controller with a waypoint mission loaded
- SmartPort (FrSky ACCESS / ACCST / TD) **or** CRSF (Crossfire / ELRS) telemetry link
- "Waypoint download (INAV)" enabled in widget settings (default: on)

> Both transports are supported: SmartPort and CRSF (Crossfire / ELRS). Please report issues as GitHub tickets.

## How It Works

Once powered on and connected, the widget automatically:

1. Detects the telemetry transport (SmartPort or CRSF)
2. Identifies the flight controller and reads the firmware version
3. Downloads the stored waypoint mission
4. Displays the mission on the map
5. Starts polling for arming and navigation status

If the connection fails, the widget retries automatically.

## Waypoint Types

The following INAV waypoint actions are supported and displayed on the map:

| Action         | Description                      | Shown on Map        |
|----------------|----------------------------------|---------------------|
| WAYPOINT       | Fly to coordinate                | Circle with number  |
| POSHOLD_TIME   | Loiter at position for N seconds | Circle + duration   |
| LAND           | Landing position                 | Circle + "L" label  |
| RTH            | Return to home                   | Dotted line from the last waypoint to home |
| JUMP           | Jump to another waypoint index   | Dotted yellow line with arrow to the target, repeat count (`x3`, `∞`) |
| SET_HEAD       | Set heading direction            | Chevron at the preceding waypoint |
| SET_POI        | Point of interest (camera aim)   | Marker with yellow ring and "POI" label |

## Map Display

### Flight Path
Navigable waypoints (WAYPOINT, POSHOLD_TIME, LAND) are connected by path lines showing the planned flight route. JUMP connections are shown as separate arrow lines to their target waypoint.

### Waypoint Markers
Each waypoint is displayed as a numbered circle on the map. Special labels indicate waypoint type:
- **POSHOLD_TIME**: Shows the hold duration (e.g. "5s")
- **LAND**: Shows "L"

When waypoints are very close together at the current zoom level, the display automatically switches to compact dot-only mode.

### Active Waypoint Tracking
When the UAV is armed and navigating a mission, the currently active waypoint is highlighted with a bright green ring. This updates in real time as the UAV progresses through the mission.

### UAV Color During Navigation

The UAV symbol on the map changes color based on the current flight mode:

| Mode     | Color  | Meaning                         |
|----------|--------|----------------------------------|
| NAV      | Green  | Flying to waypoint               |
| HOLD     | Green  | Holding position at waypoint     |
| RTH      | Orange | Returning to home                |
| Idle     | White  | No active navigation             |

Red overrides all of these when GPS telemetry is lost (no position update for 5 seconds).
Arming state is polled every 5 seconds, navigation status every 2 seconds while armed.

## Widget Settings

### Waypoint download (INAV)
- **Type**: On / Off
- **Default**: On
- **Effect**: When disabled, the widget skips the waypoint download and only monitors arming state for home position detection. This saves telemetry bandwidth when the mission overlay is not needed.
