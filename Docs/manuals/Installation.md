# Installation

> **Minimum requirement**: ETHOS 1.6 or newer.

Each release comes as two ZIPs with the same content:

| ZIP | Use it for |
|---|---|
| `ETHOSMappingWidget-<version>-<hash>-suite.zip` | **Ethos Suite** (recommended) |
| `ETHOSMappingWidget-<version>-<hash>-sdcard.zip` | Manual install by copying to the SD card |

## Option A: Install with Ethos Suite (recommended)

1. Connect the radio to the computer via USB and start **Ethos Suite**.
2. Open **Lua Library → Install from local `.zip`** and select the `-suite.zip`.
3. The Suite installs the widget to `SCRIPTS:/ethosmaps/` and records name, version and file list.
4. Disconnect and **reboot the radio**.

Updating works the same way: install the newer `-suite.zip`. The Suite replaces the widget files
and keeps your widget settings and `state.dat` (zoom level, observation marker, default position).

## Option B: Install manually on the SD card

1. **Connect your radio** to the computer via USB, or remove the SD card and insert it into a card reader.
2. **Extract the `-sdcard.zip`** to the root of the SD card. The ZIP already contains the correct folder structure.
3. **Verify** that the files land in the right places:

```
SD Card (root)
└── scripts/
    └── ethosmaps/
        ├── main.lua
        ├── ethos_lua_manifest.json
        ├── audio/
        │   ├── err.wav
        │   └── inf.wav
        ├── bitmaps/
        │   ├── flockoff.png
        │   ├── flockon.png
        │   ├── gpsicon.png
        │   ├── loading.png
        │   ├── minihomeorange.png
        │   ├── nogpsicon.png
        │   ├── nomap.png
        │   ├── pinbutton.png
        │   ├── zoom_minus.png
        │   └── zoom_plus.png
        └── lib/
            ├── adsb.lua
            ├── compute.lua
            ├── drawlib.lua
            ├── layout_default.lua
            ├── maplib.lua
            ├── msp.lua
            ├── resetLib.lua
            ├── tileloader.lua
            └── utils.lua
```

4. **Safely eject** the SD card or disconnect USB.
5. **Reboot the radio** to pick up the new widget.

To update, repeat the steps; the ZIP overwrites the existing files.

## Adding the Widget

1. Open the screen configuration of your model (on ETHOS 26.x: press **DISP** and use the widget manager; see the ETHOS documentation on widgets for your version).
2. Create or open a screen where you want the widget.
3. Select **ETHOS Mapping Widget** from the widget list.
4. The widget works best in **fullscreen** mode (touch panning requires it).

## Map Tiles

The widget does **not** include map tiles. You need to prepare them separately:

1. Download tiles for your area using a tile downloader tool such as the [High Resolution Map Generator](https://martinovem.github.io/High-Resolution-Map-Generator/).
2. Place the tile folders on the SD card under:
   ```
   bitmaps/ethosmaps/maps/<MapProvider>/
   ```

Map tiles are user data: neither ZIP contains them and neither install path touches them.
Without map tiles, the widget displays a "NO MAP DATA" placeholder where tiles are missing.

## Settings Across Updates

Widget settings are reset between major releases (1.x → 2.x) and preserved between minor releases (2.0 → 2.1 → 2.2).

## Uninstalling

- **Ethos Suite:** remove the widget in the Lua Library, or
- **Manually:** delete `scripts/ethosmaps/` from the SD card.

Map tiles under `bitmaps/ethosmaps/maps/` stay until you delete them. Then remove the widget from
any screens where it was added.
