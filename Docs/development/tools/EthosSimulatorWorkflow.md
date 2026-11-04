# ETHOS Simulator Workflow (VS Code)

Goal: fast local test cycle for widget changes without copying to hardware every time.
Performance numbers from the simulator are **not** meaningful — fps, tile I/O, GC and RAM are
validated on the real radio only.

**Updated 2026-09-29** for `bsongis.ethos` 0.6.x. The pre-0.6 setup (`ethos.root = RADIO`,
`ethos.firmware`, `ethos.version`, the locally patched `extension.js` for live `sensors.json`
reload, the PowerShell replay script) is obsolete — see [What changed](#what-changed-vs-the-old-setup).

---

## 1) Prerequisites

VS Code extensions:

| Extension | Purpose |
|---|---|
| `bsongis.ethos` (≥ 0.6.2) | The simulator itself: display, controls, telemetry panel, `ethos.injectTelemetry` API |
| `flyingeek.ethos-devtools` (≥ 0.9.5) | Companion: CSV telemetry playback, single-value injection, deploy to simulator, deploy to radio over USB, log colorizing |

Workspace configuration (`.vscode/settings.json`, gitignored, already set up):

```json
"ethos.server": "https://ethos.studio1247.com",
"ethos.board": "X20RS",
"ethos.protocol": "FCC",
"ethos.release": "26.1.2",
"ethos.simulatorsFolder": "simulators",
"ethos.logfile": "simulators/ethos.log",
"ethos-devtools.deploy": { "app": "src/scripts/ethosmaps" }
```

The simulator's SD card is `simulators/<board>_<protocol>@<release>/` — for this project
`simulators/X20RS_FCC@26.1.2/`. It contains `scripts/`, `bitmaps/` (incl. the test tiles under
`bitmaps/ethosmaps/maps/`), `models/`, `radio.bin` and `sensors.json`. The whole `simulators/`
folder is gitignored. Switching board or release (`Ethos: Set Simulator` / `Add Simulator`) creates
a **new, empty** folder — copy tiles, models and `sensors.json` over if you need them there.

Available releases on the server for X20RS (2026-09-29): `26.1.2`, `26.1.0`, `nightly26`, `1.6.7`, `1.6.6`, `1.6.5`, `1.6.4`.

---

## 2) Entry point: the status bar menu

Click the **`X20RS_FCC`** item in the VS Code status bar (bottom right). The quick pick is defined
in `.vscode/ethos-menu.json` and bundles everything:

| Entry | What it does |
|---|---|
| ▶️ Start SIM / 🛑 Stop SIM | `ethos.start` / `ethos.stop` |
| 🔄 Reload SIM | stop → deploy `src/scripts/ethosmaps` (scripts + icons) → start |
| 🏗️ Build & Deploy [SIM] | Task: `build/Build-Release.ps1` — stages `src/`, generates the manifest, builds both release ZIPs, deploys to the active simulator folder, removes stale files and `.luac` caches |
| 🚀 Deploy scripts only | `ethos-devtools.deploySimulator` (copies `src/scripts/ethosmaps`, no manifest, no ZIP) |
| 🖥️ / 🎛️ / 📡 | Open Display / Controls / Telemetry panel |
| 📊 Play Telemetry CSV | replay a flight log into the running sim (see §5) |
| ✏️ Set Telemetry Value | inject one sensor value |
| 📻 Deploy to Radio | copy the app to the X20RS over USB (radio in Ethos Suite or Serial mode) |
| 📖 Open Lua Doc | Lua reference for the selected release |
| 🆑 Clear log | truncates `simulators/ethos.log` |
| ⚙️ Change SIM | select / add a simulator |

All entries are also in the Command Palette under **Ethos** / **Ethos DevTools**.
There are no workspace keybindings — VS Code does not support `.vscode/keybindings.json`;
bind `ethos.showMenu` in your user keybindings if you want a shortcut.

---

## 3) Deploy: two paths

- **Scripts only** (`ethos-devtools.deploySimulator`, part of 🔄 Reload): copies
  `src/scripts/ethosmaps/` (Lua, audio, UI icons) → `simulators/…/scripts/ethosmaps/`. Fastest loop.
  Does not remove files that were deleted in `src/`.
- **Full** (`Build & Deploy [SIM]` task or `.\build\Build-Release.ps1`): stages the package, writes
  `ethos_lua_manifest.json`, produces `build/ETHOSMappingWidget-<ver>-<hash>-suite.zip` and
  `-sdcard.zip`, validates the Suite ZIP against the package spec and mirrors the staged folder into
  the simulator (stale files and `.luac` caches removed). Fails if `WIDGET_VERSION` is not `x.y.z`
  or `CHANGELOG.md` has no `## x.y.z` section (manifest release notes). `-NoDeploy` skips the
  simulator, `-SimDir <path>` overrides the target. `-Release` drops the commit hash from the
  file names (GitHub release files) and refuses to run on an uncommitted working tree.

`Build-Release.ps1` reads board/protocol/release from `.vscode/settings.json`, so it always deploys to
the simulator that is active in VS Code.

---

## 4) Recommended test sequence (fast & reproducible)

1. 🔄 Reload SIM (or 🏗️ Build & Deploy, then ▶️ Start)
2. 🖥️ Open Display
3. Load the widget and run a fixed sequence:
   - Home → widget (initial entry)
   - Zoom `+/-`
   - Provider / map type switch
   - 20–30 s of normal use (with telemetry playback running, §5)
4. Check logs (§6)
5. Repeat from step 1 after each code change

Comparable A/B runs need the same sequence and a clean restart.

---

## 5) Telemetry playback

Requirements: simulator running, and the sensors you need declared in
`simulators/X20RS_FCC@26.1.2/sensors.json` (edit via 📡 Open Telemetry; the file already contains
RSSI, GPS, RxBatt, …). Only frames present in `sensors.json` are injected; other CSV columns are ignored.

1. 📊 **Play Telemetry CSV** → pick a CSV → speed (1×/2×/5×/10×/20×) → Play once / Loop
2. A progress notification shows row, percentage and injected frame names; cancel there or via
   ⏹️ Stop Telemetry.

Supported formats: **EdgeTX logs** (`GPS` column as `lat lon`, `Alt(m)`, `RxBt(V)`, `1RSS(dB)`,
`GSpd(kmh)`, `Hdg(°)`, `Sats`, …) and **Ethos logs**. Our demo logs are EdgeTX format:

| File | Content |
|---|---|
| `Docs/development/tools/ETHOS VSCode Sim Telemetry Injection/DemoTelemetry.csv` | real flight, ~3180 rows |
| `…/Synthetic_Logs/DemoTelemetry_Synthetic_1min_straightLine_250ms.csv` | 240 rows, 20 m/s straight line, 250 ms cadence |
| `…/Synthetic_Logs/DemoTelemetry_Synthetic_5min_pattern_250ms.csv` | 1200 rows, circle + direction segments, 250 ms cadence |

Widget side: set **Telemetry source = ETHOS** (default) — the GPS sensor from `sensors.json` is what
the widget reads. The *Sensors* mode with user-assigned sources is for the on-radio
`ETHOS-Telemetry-Replay` Lua widget (see `Docs/development/helper/DebugTelemetryInput.md`).

---

## 6) Logs

| Log | Where | Content |
|---|---|---|
| Simulator / ETHOS console | Output panel **Ethos Logs**, and `simulators/ethos.log` (append-only, clear via 🆑) | Lua errors (`SCRIPTS:/ethosmaps/…lua:NN:`), ETHOS system messages, `print()` |
| Widget debug log | `simulators/X20RS_FCC@26.1.2/scripts/ethosmaps/debug.log` | our `logDebug()` output; needs *Enable debug log* in the widget settings |
| Perf table | same `debug.log`, `PERF WINDOW` block every 5 s | needs *Enable perf profile* additionally |

Both files are plain text in the workspace, so Claude can read them directly.

---

## 7) Troubleshooting

- **Status bar item missing / "No simulator configured"** → Command Palette `Ethos: Set Simulator`,
  pick `X20RS_FCC@26.1.2`.
- **First start downloads ~28 MB** (`X20RS_FCC.js/.wasm`) into the extension's global cache — normal.
- **Widget not listed in the simulator** → check `simulators/X20RS_FCC@26.1.2/scripts/ethosmaps/main.lua`
  exists (run 🏗️ Build & Deploy) and the Ethos Logs panel for a Lua error at startup.
- **No icons (zoom, lock, home)** → only 🚀 scripts-only deploy was used; run 🏗️ Build & Deploy once.
- **Changes not active** → 🔄 Reload SIM; ETHOS caches compiled `.luac` — the build script removes
  stale ones in the sim folder.
- **Telemetry playback does nothing** → simulator must be running; the frame names must exist in
  `sensors.json`; open 📡 Telemetry once so the extension loads the file.
- **Old models fail to load after a release bump** → `models/*.bin` in the sim folder were written by
  the previous ETHOS version; delete them and re-create the test model.

---

## 8) When hardware testing is still required

The simulator is for functional iteration. Hardware (X20RS) is mandatory for:
- everything performance-related (fps, paint budget, tile I/O, GC, RAM)
- real touch latency and UI stutter during screen swipes
- SD-card I/O behaviour and timing spikes
- MSP over a real SmartPort/CRSF link
- final verification before a release

📻 **Deploy to Radio** (Ethos DevTools) copies `src/scripts/ethosmaps/` (including the UI icons) to
`RADIO:/scripts/ethosmaps/` over USB. To test the real install path, install the `-suite.zip` with
Ethos Suite instead.

---

## What changed vs. the old setup

| Before (bsongis.ethos 0.1.x) | Now (0.6.x) |
|---|---|
| `ethos.root = RADIO`, `ethos.firmware = X20S_FCC`, `ethos.version = nightly26` | `ethos.board` / `ethos.protocol` / `ethos.release`; SD card at `simulators/<board>_<protocol>@<release>/` |
| `RADIO/` folder | moved to `simulators/X20RS_FCC@26.1.2/` (tiles, models, `sensors.json` included) |
| locally patched `extension.js` polling `sensors.json` | official `ethos.injectTelemetry` API, driven by Ethos DevTools |
| `replay-telemetry-log.ps1` writing `sensors.json` | 📊 Play Telemetry CSV (same CSV files) |
| `.vscode/keybindings.json` shortcuts | status bar menu (`.vscode/ethos-menu.json`) |
| Build script deploys to `RADIO/` | deploys to the active simulator folder from `.vscode/settings.json` |
