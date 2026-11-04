# Map Tiles Guide

This guide covers everything about map tiles: supported providers and formats, folder structure, the Yaapu fallback system, and how to download new tiles.

## Supported Map Providers

| Provider | Map Types | Coordinate Layout | Notes |
|----------|-----------|-------------------|-------|
| **GOOGLE** | Map, Satellite, Hybrid, Terrain | `z/x/y` | Also falls back to Yaapu Google tiles |
| **GMapCatcher (Yaapu)** | Satellite, Hybrid, Map, Terrain | GMapCatcher | Reads existing Yaapu/GMapCatcher folders directly, see below |
| **ESRI** | Satellite, Hybrid, Street | `z/y/x` | Note: **y before x** |
| **OSM** | Street | `z/x/y` | OpenStreetMap |
| **MAPTILER** | Satellite, Hybrid, Street, Outdoor, Topo, Winter, OSM Style | `z/x/y` | Outdoor, Topo and Winter read well in daylight |

Supported tile formats: **JPG**, **PNG**, **BMP** (24-bit). The widget auto-detects the format per tile.

## Recommended Format

| Radio Generation | Models | Recommended |
|---|---|---|
| **TANDEM / TWIN (STM32H7)** | X20, X20S, X20R, X20HD, X18, X18S, X14, X14S, Twin X Lite | **JPG** |
| **Horus (STM32F4)** | X10, X10S, X10S Express, X12S | **JPG** or **BMP** |

- **JPG** — Best balance of speed, quality, and storage. Up to 33% faster than PNG on H7 radios.
- **BMP** (24-bit) — Zero CPU decode cost, but ~3× larger files. May outperform JPG on older F4 radios where software JPEG decoding is slower. Only practical for smaller map areas.
- **PNG** — Slowest decode performance. Existing PNG tiles continue to work, but prefer JPG for new downloads.

## Folder Structure

### Native EthosMaps Format (Primary)

```
bitmaps/ethosmaps/maps/
├── GOOGLE/
│   ├── Map/{z}/{x}/{y}.jpg
│   ├── Satellite/{z}/{x}/{y}.jpg
│   ├── Hybrid/{z}/{x}/{y}.jpg
│   └── Terrain/{z}/{x}/{y}.jpg
├── ESRI/
│   ├── Satellite/{z}/{y}/{x}.jpg
│   ├── Hybrid/{z}/{y}/{x}.jpg
│   └── Street/{z}/{y}/{x}.jpg
├── OSM/
│   └── Street/{z}/{x}/{y}.jpg
└── MAPTILER/
    ├── Satellite/{z}/{x}/{y}.jpg
    ├── Hybrid/{z}/{x}/{y}.jpg
    ├── Street/{z}/{x}/{y}.jpg
    ├── Outdoor/{z}/{x}/{y}.jpg
    ├── Topo/{z}/{x}/{y}.jpg
    ├── Winter/{z}/{x}/{y}.jpg
    └── OSM Style/{z}/{x}/{y}.jpg
```

### Naming Rules (Strict)

- **Provider folders**: UPPERCASE — `GOOGLE`, `ESRI`, `OSM`, `MAPTILER`
- **Map type folders**: Title Case — `Satellite`, `Hybrid`, `Street`, `Map`, `Terrain`, `Outdoor`, `Topo`, `Winter`, `OSM Style`
- **Zoom folders**: Plain numbers — `6`, `12`, `17`
- **Tile files**: Plain numbers — `12345.jpg`

Case matters. `google` or `satellite` will **not** be detected.

### Coordinate Layout

- **Google / OSM / MapTiler**: `{z}/{x}/{y}.ext` — zoom / column / row
- **ESRI**: `{z}/{y}/{x}.ext` — zoom / row / column (swapped!)

The [High Resolution Map Generator](https://martinovem.github.io/High-Resolution-Map-Generator/) handles this automatically when you select the correct output target.

## Yaapu Tile Compatibility

The widget supports a **transparent fallback system** for existing Yaapu tile layouts. This means:

- Existing Yaapu Google tiles are used automatically — no duplication needed
- You can mix EthosMaps and Yaapu tiles on the same map
- Migration is gradual — new tiles go to EthosMaps format, Yaapu tiles continue to work

### Tile Loading Priority

1. **EthosMaps path** (`bitmaps/ethosmaps/maps/`) — checked first
2. **Yaapu Google path** (`bitmaps/yaapu/maps/`) — fallback for Google provider only
3. **No tile found** — `nomap.png` placeholder is shown

### Supported Yaapu Folder Layouts

**Yaapu Google (auto-detected):**
```
bitmaps/yaapu/maps/
├── GoogleMap/{z}/{y}/s_{x}.jpg
├── GoogleSatelliteMap/{z}/{y}/s_{x}.jpg
├── GoogleHybridMap/{z}/{y}/s_{x}.jpg
└── GoogleTerrainMap/{z}/{y}/s_{x}.jpg
```

**GMapCatcher (separate provider "GMapCatcher (Yaapu)" in the settings):**
```
bitmaps/yaapu/maps/
├── sat_tiles/...   (Satellite)
├── tiles/...       (Map / Hybrid)
└── ter_tiles/...   (Terrain)
```

> The automatic fallback applies to the **Google** provider only. GMapCatcher tiles are selected
> as their own provider. ESRI, OSM and MapTiler are native EthosMaps folders only.

### Common Scenarios

| Scenario | What to do |
|----------|------------|
| **Existing Yaapu user** | Just install the widget — your tiles in `bitmaps/yaapu/maps/` are found automatically |
| **Gradual migration** | Download new EthosMaps tiles alongside existing Yaapu tiles. The widget uses EthosMaps where available, Yaapu for gaps |
| **Fresh setup** | Use `bitmaps/ethosmaps/maps/` exclusively with the native format |

## Downloading Tiles

Use the **[High Resolution Map Generator](https://martinovem.github.io/High-Resolution-Map-Generator/)** ([Repository](https://github.com/MartinovEm/High-Resolution-Map-Generator)):

1. Open the online tool
2. Set **Output Target** to `b14ckyy ETHOS Mapping Widget`
3. Choose provider, map type, and zoom range
4. Navigate to your flying field
5. Draw a rectangle around the area to download
6. In Chrome/Edge, link the **root directory** of your SD card — the tool creates the correct folder paths automatically
7. Alternatively, use ZIP download and extract to the SD card root

The downloader handles all folder naming and coordinate layout differences. Always use the latest version of the tool.

## Important Notes

- Scripts and map tiles must be on the **same drive** (both on SD or both on internal storage)
- The widget scans for available providers on startup. If you add tiles while the radio is running, restart the radio or re-enter widget settings
- If no valid provider or map type is found, the settings dropdown shows **NONE**
- Zoom levels not covered by your tiles will show the `nomap.png` placeholder — download additional zoom levels as needed
