# Ethos Suite Install Packaging Plan

**Target version:** 2.2  
**Created:** 2026-09-29  
**Status:** Planned — not started  
**Spec:** `Docs/development/tools/ethos_good_lua.md` (FrSky Local Lua Script Package Specification V1)

## Goal

Make the widget installable through **Ethos Suite → Lua Library → Install from local `.zip`**
while keeping the classic "extract to SD card" path working.

## Findings (current state vs. spec)

The Suite installs strictly by `ethos_lua_manifest.json`: it copies the paths listed in `files`
into `RADIO:/scripts/{folder}/`, preserving the relative paths from the ZIP root. Anything outside
`/scripts/{folder}/` cannot be installed this way.

| Item | Current state (2.1.0) | Spec requirement | Impact |
|---|---|---|---|
| Manifest | none | `ethos_lua_manifest.json` in ZIP root, `manifestVersion = 1` | Suite refuses the ZIP |
| ZIP layout | `scripts/ethosmaps/...` + `bitmaps/ethosmaps/...` prefixes | script files at ZIP root | would install to `/scripts/ethosmaps/scripts/ethosmaps/` |
| UI icons | `/bitmaps/ethosmaps/bitmaps/*.png` | must live under `/scripts/ethosmaps/` | Suite cannot install them → no zoom/lock/home/loading/nomap icons |
| Version | `WIDGET_VERSION = "2.1.0"` | 3-part numeric | OK; `2.x-RC1` / `-beta` strings would make the manifest invalid |
| Package key | none | stable reverse-domain ID | must be chosen once and never changed |
| Map tiles | `/bitmaps/ethosmaps/maps/`, `/bitmaps/yaapu/maps/` | n/a (user data, not part of the package) | unaffected |
| `state.dat`, `debug.log` | in `/scripts/ethosmaps/` | Suite deletes only files from the previous `files` list on update | survive updates as long as they are never listed |
| `scriptinfo.json` | none | legacy, no longer read | nothing to do |
| `LAYOUTS.zip` | separate download | n/a | out of scope |

ZIP entries created by `Compress-Archive` contain backslashes (visible in the 2.1.0 ZIP). The spec
says matching is normalized, but forward slashes are the safe choice.

## Plan

### 1. Move UI icons into the script folder (code change)

- `src/bitmaps/ethosmaps/bitmaps/*.png` → `src/scripts/ethosmaps/bitmaps/*.png`
- Update the two load sites:
  - `lib/drawlib.lua` `getBitmap()` (`/bitmaps/ethosmaps/bitmaps/` → `/scripts/ethosmaps/bitmaps/`)
  - `lib/tileloader.lua` `nomap.png` / `loading.png` lookups
- Keep the `/bitmaps/ethosmaps/maps/notiles.png` fallback in `tileloader.lua` as is (user-provided tile folder).
- No fallback to the old icon path: a stale `/bitmaps/ethosmaps/bitmaps/` folder is harmless and
  can be deleted by the user (MigrationGuide note).

### 2. Package key and version rules

- `key`: `com.github.b14ckyy.ethosmaps` (package identity; **not** the widget key `ethosmw`, which
  stays as is). Fixed forever after the first Suite release.
- `name`: `ETHOS Mapping Widget`
- `folder`: `ethosmaps` (must stay for Yaapu coexistence)
- `version`: taken from `WIDGET_VERSION`; must remain `x.y.z` numeric. Release candidates either
  use a plain numeric version with the RC status in the release notes, or are not distributed via
  Suite. The build script must fail if `WIDGET_VERSION` is not 3-part numeric.

### 3. Build script (`build/Build-Release.ps1`)

Produce two ZIPs from the same staged tree:

| ZIP | Layout | Audience |
|---|---|---|
| `ETHOSMappingWidget-<ver>-<hash>-suite.zip` | `ethos_lua_manifest.json`, `main.lua`, `lib/`, `audio/`, `bitmaps/` at ZIP root | Ethos Suite install |
| `ETHOSMappingWidget-<ver>-<hash>-sdcard.zip` | `scripts/ethosmaps/{main.lua,lib,audio,bitmaps}` | manual extraction to SD root |

- Generate the manifest in the build script:
  - `manifestVersion: 1`, `name`, `key`, `folder`, `version` as above
  - `files`: `["main.lua", "lib/*", "audio/*", "bitmaps/*"]` — explicit, never `**` on the root,
    so `state.dat` / `debug.log` can never end up in a `files` list
  - `releaseNotes`: `{ "format": "markdown", "content": <matching "## x.y.z" section from CHANGELOG.md> }`;
    build fails if the section is missing (keeps CHANGELOG discipline)
- Write ZIPs with `System.IO.Compression.ZipFile` (UTF-8, forward-slash entries) instead of
  `Compress-Archive`.
- `RADIO/` deploy stays unchanged apart from the new bitmap location.

### 4. Documentation

- `Docs/manuals/Installation.md`: new "Install via Ethos Suite" section (preferred path), updated
  SD-card tree with `scripts/ethosmaps/bitmaps/`, note that updates via Suite keep settings and `state.dat`.
- `Docs/manuals/MigrationGuide.md`: 2.1 → 2.2 note that `/bitmaps/ethosmaps/bitmaps/` is obsolete
  and may be deleted; map tiles stay where they are.
- `Docs/manuals/Troubleshooting.md`: "icons missing" → check `/scripts/ethosmaps/bitmaps/`.
- `Docs/development/CHANGELOG.md`: entry under 2.2.0 (icon relocation, Suite package, two ZIPs).
- GitHub release: attach both ZIPs, name the Suite one clearly.

### 5. Verification

Static (Claude):
- `luac -p` on `drawlib.lua`, `tileloader.lua`
- Unzip both ZIPs and diff their file lists against `src/`
- Validate the generated manifest against the spec (required fields, version regex, `files`
  expands to at least `main.lua`)

Hardware (maintainer, real radio):
1. Fresh install via Suite → Lua Library → Install from local `.zip` with the `-suite.zip`.
2. Check `/scripts/ethosmaps/ethos_lua_manifest.json` was written by the Suite and contains `key`, `version`, `files`.
3. Widget shows all icons (zoom ±, lock, home, loading, nomap) — confirms the new bitmap path.
4. Update over an existing manual 2.1.0 install: settings and `state.dat` intact, old
   `/bitmaps/ethosmaps/bitmaps/` left untouched, widget still works.
5. Second Suite install of the same package: no duplicate entry in the Lua Library (key matching).
6. SD-card ZIP: extract to root, same checks as 3.

## Open questions

- Does the Suite show the widget under the manifest `name` or the `system.registerWidget` name?
  Only relevant for docs wording — check on first install.
- Whether `lcd.loadBitmap()` resolves paths relative to the script folder in ETHOS 26.x. Not
  needed (absolute paths are used), but would allow dropping the hardcoded folder name later.
