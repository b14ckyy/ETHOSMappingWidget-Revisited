# EthosMappingWidget

**Scalable Mapping Widget for FrSky Ethos**

A modern, fully scalable version of the popular Yaapu Mapping Widget.  
Real-time GPS position on satellite or street maps — works on **any** widget size, from Fullscreen down to small custom layouts.

![Overview](images/screenshots/overview.png)

## Video Overview

https://www.youtube.com/watch?v=QHtjaexGUEo

## Download

- **Releases:** https://github.com/b14ckyy/ETHOSMappingWidget-Revisited/releases
- **Latest dev version:** download from `main` branch (usually working, roughly tested)
- Other branches are in active development — do not use.

## Features

- **Moving map** — real-time UAV position with heading, home marker, home arrow, trail history and scale bar
- **Multiple map providers** — Google, ESRI, OSM, MapTiler with various map types (Satellite, Hybrid, Street, Terrain, Topo, Outdoor, Winter)
- **Zoom** — on-screen +/- buttons, context menu, or an RC channel (3-position switch or proportional)
- **Map panning** — drag to scroll, observation marker, detached mode ([details](Docs/manuals/PanningAndMarker.md))
- **INAV waypoint missions** — automatic MSP download, path overlay, active WP tracking via SmartPort or CRSF/ELRS ([details](Docs/manuals/WaypointMission.md))
- **Automatic home position** — on INAV arming via MSP, or with a switch (works without flight controller)
- **ADS-B Alert** (experimental, INAV 10) — shows the aircraft INAV warns about
- **GPS plausibility filter** — ignores cold-start garbage positions
- **Split-screen & custom layouts** — dynamic scaling, smart element hiding ([details](Docs/manuals/CustomLayouts.md))
- **Yaapu tile compatibility** — existing Yaapu Google tiles are used as fallback, GMapCatcher tiles as own provider
- **Configurable telemetry** — top bar with up to 4 custom fields, bottom bar with speed/heading/distance
- **One widget per screen** (multiple instances on the same screen are not supported)

For a complete guide to the user interface, all settings, and the context menu, see the **[Overview](Docs/manuals/Overview.md)**.

## Installation

Install with **Ethos Suite** (Lua Library → Install from local `.zip`) or copy the files to the SD card, add map tiles, and configure — requires **ETHOS 1.6** or later.

For step-by-step instructions, folder structure, and map tile setup, see the **[Installation Guide](Docs/manuals/Installation.md)**.

### Map Tiles

Use the **[High Resolution Map Generator](https://martinovem.github.io/High-Resolution-Map-Generator/)** ([Repository](https://github.com/MartinovEm/High-Resolution-Map-Generator)) to download tiles. Set the output target to `b14ckyy ETHOS Mapping Widget` — the tool handles folder structure and naming automatically.

Recommended format: **JPG** for all radios. Existing Yaapu tiles (Google, GMapCatcher) are detected and used automatically without duplication.

## Documentation

| Document | Description |
|----------|-------------|
| [Installation Guide](Docs/manuals/Installation.md) | Setup, folder structure, map tiles, updates |
| [Overview](Docs/manuals/Overview.md) | User interface, all settings, context menu |
| [Map Tiles Guide](Docs/manuals/MapTilesGuide.md) | Providers, formats, folder structure, Yaapu fallback |
| [Panning & Marker](Docs/manuals/PanningAndMarker.md) | Map panning, observation marker, detached mode |
| [Waypoint Missions](Docs/manuals/WaypointMission.md) | INAV MSP waypoint overlay |
| [Custom Layouts](Docs/manuals/CustomLayouts.md) | Split-screen and custom widget sizes |
| [Troubleshooting](Docs/manuals/Troubleshooting.md) | Common problems and solutions |
| [Migration Guide](Docs/manuals/MigrationGuide.md) | Upgrading between versions (1.x → 2.0 → 2.1 → 2.2) |
| [Changelog](Docs/development/CHANGELOG.md) | Version history with all notable changes |

## Credits

- Original concept and base code: Yaapu (Alessandro Apostoli)
- Heavy modifications and enhancements: b14ckyy
