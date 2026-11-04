# Custom Fullscreen Layouts

> Available since version 1.0

ETHOS radios come with built-in screen layouts, but those leave a border
around the widgets.  The custom layouts included in this project remove that
border so the map widget can use the **entire screen**.

## Available layouts

| Layout | Description | Resolutions |
|--------|-------------|-------------|
| **FULL 1:1** | Two equal halves, side by side | all |
| **FULL 2:1** | Two thirds left, one third right | all |
| **FULL 1+2** | Two thirds left, two stacked panels right | 800 × 480 only |

## Supported resolutions

The layout folder you need depends on your radio's screen resolution.
You can verify it in **System → Hardware → LCD** on your radio.

| Resolution | Confirmed radios |
|------------|------------------|
| 480 × 272 | Horus X10/X10S Express, Horus X12S |
| 480 × 320 | Tandem X18, X18S |
| 640 × 360 | X14RS |
| 800 × 480 | Tandem X20, X20S, X20 HD, X20S HD, TWIN X Lite RII |

## Installation

1. Download `LAYOUTS.zip` from the [release page](https://github.com/b14ckyy/ETHOSMappingWidget-Revisited/releases).
2. Pick the folder that matches your radio's screen resolution
   (e.g. `800x480`).
3. Copy the **`scripts`** folder from inside that resolution folder to the
   **root of your SD card** (or internal storage).  
   Merge with the existing `scripts` folder if prompted.

   Your SD card should look like this afterwards:

   ```
   /scripts/
       FULL11/
           main.lua
       FULL21/
           main.lua
       FULL1P2/          ← only on 800×480
           main.lua
       ethosmaps/
           main.lua
           ...
   ```

4. Reboot the radio or long-press the screen setup area so ETHOS
   rescans the scripts folder.

## Using a custom layout

1. Open **System → Screens** and select the screen you want to edit.
2. Tap the layout selector (top of the screen setup).
3. The new layouts appear as **FULL 1:1**, **FULL 2:1**, or **FULL 1+2**.
4. Select one, then assign the mapping widget to the desired slot.

## Removing custom layouts

Delete the `FULL11`, `FULL21`, or `FULL1P2` folders from `scripts/` on
your SD card and reboot.
