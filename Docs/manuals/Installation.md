# Installation

> **Minimum requirement**: ETHOS 1.6 or newer.

## What You Need

- A FrSky radio running ETHOS 1.6+
- The widget release ZIP (`ETHOSMappingWidget-<version>.zip`)
- A way to access the radio's SD card (USB cable or SD card reader)

## Steps

1. **Connect your radio** to the computer via USB, or remove the SD card and insert it into a card reader.

2. **Extract the ZIP** to the root of the SD card. The ZIP already contains the correct folder structure — no renaming or rearranging needed.

3. **Verify** that the files land in the right places. Your SD card should look like this:

```
SD Card (root)
├── bitmaps/
│   └── ethosmaps/
│       └── bitmaps/
│           ├── flockoff.png
│           ├── flockon.png
│           ├── gpsicon.png
│           ├── loading.png
│           ├── minihomeorange.png
│           ├── nogpsicon.png
│           ├── nomap.png
│           ├── pinbutton.png
│           ├── zoom_minus.png
│           └── zoom_plus.png
├── scripts/
│   └── ethosmaps/
│       ├── main.lua
│       ├── audio/
│       │   ├── err.wav
│       │   └── inf.wav
│       └── lib/
│           ├── compute.lua
│           ├── drawlib.lua
│           ├── layout_default.lua
│           ├── maplib.lua
│           ├── msp.lua
│           ├── resetLib.lua
│           ├── tileloader.lua
│           └── utils.lua
```

4. **Safely eject** the SD card or disconnect USB.

5. **Reboot the radio** to pick up the new widget.

## Adding the Widget

1. Go to **System → Widgets** on your radio.
2. Create or open a screen where you want the widget.
3. Select the **ETHOS Maps** widget from the list.
4. The widget works best in **fullscreen** mode (touch panning requires it).

## Map Tiles

The widget does **not** include map tiles. You need to prepare them separately:

1. Download tiles for your area using a tile downloader tool such as the [High Resolution Map Generator](https://martinovem.github.io/High-Resolution-Map-Generator/).
2. Place the tile folders on the SD card under:
   ```
   bitmaps/ethosmaps/maps/<MapProvider>/
   ```

Without map tiles, the widget will display a "NO MAP DATA" placeholder where tiles are missing.

## Updating

To update to a newer version, repeat steps 1–5. The ZIP will overwrite the existing files. Your widget settings (configured on the radio) will be reset between major releases (1.x --> 2.x) but preserved between minor releases (2.0 --> 2.1).

## Uninstalling

Delete these two folders from the SD card:

- `bitmaps/ethosmaps/`
- `scripts/ethosmaps/`

Then remove the widget from any screens where it was added.
