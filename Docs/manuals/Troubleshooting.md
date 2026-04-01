# Troubleshooting

Common problems and their solutions. If your issue is not listed here, check the [GitHub Issues](https://github.com/b14ckyy/ETHOSMappingWidget-Revisited/issues) page.

---

## Map Shows "...waiting for GPS"

**Red box with "...waiting for GPS" overlaid on the map.**

| Cause | Solution |
|-------|----------|
| No GPS sensor connected to the flight controller | Connect a GPS module and verify it reports a fix in the FC configurator |
| Telemetry link not active | Ensure the receiver is bound and telemetry is flowing (check ETHOS telemetry screen) |
| ETHOS does not see the GPS source | Go to **Model → Telemetry → Sensors** and verify that a GPS sensor is listed |
| Sensor mode misconfigured | In widget settings, ensure **Telemetry source** is set to `ETHOS` (default). The `Sensors` mode is a debug feature for custom source assignment |

> The widget reads GPS data via ETHOS's built-in `GPS` source. If no GPS source exists in the system, the widget will show this overlay indefinitely.

---

## UAV Symbol or GPS Coordinates Turn Red

**The UAV marker and/or the GPS coordinate overlay turn red during flight.**

This indicates **GPS telemetry loss** — the widget has not received a new GPS position for 5 seconds. The red color is a visual alert, not an error.

| Cause | Solution |
|-------|----------|
| Telemetry link temporarily dropped | Check that receiver is powered and telemetry is active |
| GPS module lost satellite fix | Ensure GPS module has clear sky view; wait for re-acquisition |
| Out of range | Reduce distance or check antenna orientation |

The indicators return to normal automatically when GPS telemetry resumes.

---

## Map Shows Gray Tiles / "NO MAP DATA" Placeholder

**The `nomap.png` placeholder image is shown instead of satellite imagery.**

| Cause | Solution |
|-------|----------|
| No map tiles on SD card | Download tiles using the [High Resolution Map Generator](https://martinovem.github.io/High-Resolution-Map-Generator/) and place them in `bitmaps/ethosmaps/maps/` |
| Tiles in wrong folder structure | Verify that the folder hierarchy matches `<PROVIDER>/<MapType>/<z>/<x>/<y>.jpg`. See [Map Tiles Guide](MapTilesGuide.md) |
| Wrong provider/map type selected | Open widget settings and check that the selected provider and map type match your tile folders |
| Tiles on a different drive | Scripts and tiles must be on the **same drive** (both on SD card or both on internal storage) |
| Zoom level not covered | Your tiles may not include the zoom level you're viewing. Zoom in or out until tiles appear, then download additional zoom levels |

---

## "WARNING: HOME NOT SET!"

**Yellow text on a dark overlay near the map center.**

This is **normal** before arming. The home position is set automatically when:

- The flight controller arms (detected via MSP, INAV only), or
- You manually set it via **long press → Set Home**

If the warning persists after arming, check that the FC is reporting arming status via MSP and that your RC Link supports MSP-Passthrough.

---

## "TOO SMALL!" Warning

**Yellow screen with "TOO SMALL!" and the current widget dimensions.**

The widget requires a minimum size of **200 × 100 pixels**. Resize the widget area or use a different screen layout (fullscreen works best).

---

## "ZOOM LIMIT" Message

**Briefly shown when tapping + or − at the zoom boundary.**

This is informational — you've reached the configured zoom min or max. Adjust the zoom range in widget settings if needed:

- **Map zoom min** — lower zoom limit
- **Map zoom max** — upper zoom limit

---

## Map Provider/Type Shows "NONE"

**The provider or map type dropdown shows "NONE" and cannot be changed.**

This means the widget found no tile folders matching any known provider. Ensure:

1. Tile folders exist at `bitmaps/ethosmaps/maps/GOOGLE/`, `bitmaps/ethosmaps/maps/ESRI/`, or `bitmaps/ethosmaps/maps/OSM/`
2. Provider folder names are **UPPERCASE** (`GOOGLE`, not `google`)
3. Map type folder names use **Title Case** (`Satellite`, `Hybrid`, `Street`, `Map`, `Terrain`)

The widget auto-detects available providers on startup. If folders are added later, restart the radio or re-enter the widget settings.

---

## Panning / Observation Marker Not Available

**The lock and pin buttons don't appear. Dragging does nothing.**

Touch panning is only available in **fullscreen** mode. In split-screen or smaller layouts, the widget automatically locks to follow-mode and hides panning controls. This is by design to prevent accidental map movement in tight layouts.

---

## Waypoint Mission Not Showing

**INAV waypoints don't appear on the map.**

| Cause | Solution |
|-------|----------|
| Setting disabled | Enable **Waypoint download (INAV)** in widget settings |
| No INAV FC detected | The MSP stack probes SmartPort first, then CRSF/ELRS. If neither responds within 5 seconds each, the widget enters ERROR state and retries after 5 seconds. Ensure your FC is connected and telemetry is bidirectional |
| Unsupported FC | Only **INAV** flight controllers support MSP waypoint download. Betaflight, ArduPilot, etc. are not supported |
| No mission on FC | Upload a waypoint mission to the FC via INAV Configurator before the flight and make sure its active (in RAM) |
| SmartPort passthrough not available | For SmartPort transport, ensure MSP passthrough is supported by your RC Link (SmartPort/FrSky, Crossfire, ELRS) and Telemetry is enabled in the FC's serial port and feature configuration |

Check the **debug log** (enable in widget settings) for detailed MSP state transitions and error messages.

---

## Existing Yaapu Tiles Not Found

**You have Yaapu tiles but the widget shows gray/no-map.**

The widget automatically detects Yaapu tiles in `bitmaps/yaapu/maps/`. This only works for **Google** provider tiles. Verify:

1. Tiles are in `bitmaps/yaapu/maps/GoogleSatelliteMap/`, `GoogleHybridMap/`, `GoogleMap/`, or `GoogleTerrainMap/`
2. In widget settings, select **Google** as the provider
3. Scripts and tiles are on the **same drive**

For GMapCatcher-style folders (`sat_tiles/`, `map_tiles/`, `ter_tiles/`), the same auto-detection applies.

> Yaapu fallback only works for Google. ESRI and OSM tiles must be in the native `bitmaps/ethosmaps/maps/` structure.

---

## Widget Loads Slowly / "loading layout..."

**Brief overlay on first paint showing "loading layout...".**

This is normal during cold start while Lua libraries are loaded. It should disappear within 1–2 seconds. If it persists:

- Check that all `.lua` files are present in `scripts/ethosmaps/lib/`
- Ensure the SD card is not corrupted (try formatting and re-copying)

---

## Top Bar Shows "---" Instead of Telemetry Values

**One or more top bar fields show dashes.**

The assigned ETHOS source is not available or not returning data. This can happen when:

- The telemetry link is not active (receiver off or not bound)
- The selected sensor name doesn't match any discovered source
- The source was renamed or removed in ETHOS

Re-assign the sensors in widget settings under the **Top Bar** section.

---

## Still Stuck?

1. **Enable the debug log** in widget settings to get detailed diagnostic output
2. **Check the log** on the SD card for error messages
3. **Open an issue** on [GitHub](https://github.com/b14ckyy/ETHOSMappingWidget-Revisited/issues) with your radio model, ETHOS version, and the debug log
