# ADS-B Alert from INAV (issue #47)

**Created:** 2026-11-04
**Status:** Implemented as experimental setting (default off), 2026-11-04 — not yet tested against a real INAV 10 FC. Tests: `build/tests/test_adsb.lua`, `build/tests/test_msp_adsb.lua` (simulated INAV 8/9/10 FC over CRSF).
**Issue:** https://github.com/b14ckyy/ETHOSMappingWidget-Revisited/issues/47

## Goal

Show the ADSB contact that INAV flags as warning/alert on the map, at minimal MSP load.

## Protocol facts (INAV source, `maintenance-10.x`, checked 2026-11-04)

All commands are MSPv2 (`> 254`) → our native MSPv2 path. MSP over SmartPort/CRSF telemetry
accepts MSPv2 since INAV 9.0. Our MSPv2 path has never run on hardware — ADSB is its first user.
INAV 10 is not tagged yet; the new commands exist only on `maintenance-10.x` (not on `master`).

| ID | Command | Request | Reply |
|---|---|---|---|
| `0x2090` | `MSP2_ADSB_VEHICLE_LIST` | – | 10 + 5 × 30 = 160 B, all slots (INAV ≥ 8.0). Not used. |
| `0x2091` | `MSP2_ADSB_LIMITS` | – | u16 warning distance, u16 alert distance, u16 ignore-above limit (m, FC OSD settings) |
| `0x2092` | `MSP2_ADSB_WARNING_VEHICLE_ICAO` | – | u32 ICAO of the most threatening contact (0 = none), u8 1 = alert / 0 = warning |
| `0x2093` | `MSP2_ADSB_VEHICLE` | u8 slot index | 32 B, see below; error if index ≥ slot count |
| `0x2094` | `MSP2_ADSB_VEHICLE_COUNT` | – | u8 `MAX_ADSB_VEHICLES` (5) — the **slot count**, not the number of active contacts (source comment: "iteration bound for the client"); 0 without `USE_ADSB` |

`0x2093`/`0x2094` come from INAV PR #11663 (merged into `maintenance-10.x` 2026-08-29).

`MSP2_ADSB_VEHICLE` reply (little-endian, 32 B):

| Offset | Type | Field |
|---|---|---|
| 0 | u32 | ICAO |
| 4 | s32 | lat (1e-7 deg) |
| 8 | s32 | lon (1e-7 deg) |
| 12 | s32 | altitude, cm MSL |
| 16 | u16 | heading, centidegrees |
| 18 | u16 | horizontal velocity, cm/s (not in the bulk list) |
| 20 | u8 | tslc — seconds since last communication |
| 21 | u8 | emitter type |
| 22 | u8 | ttl (0 = empty slot) |
| 23 | char[9] | callsign |

FC slot logic: 5 unordered slots; a new contact takes an empty slot or replaces the farthest one
if it is closer. `ttl` counts down per second without updates (10 s keep time); contacts beyond
64 km are dropped. Slot index order says nothing about distance.
`MSP2_ADSB_WARNING_VEHICLE_ICAO` uses the FC's own warning/alert distances, vertical limit and a
closest-point-of-approach estimate — the widget does not need its own thresholds.

## Polling design: threat-driven

Only the contact the FC flags as warning/alert is fetched and shown — no general traffic picture.

1. On FC detect with INAV ≥ 10 (from `MSP_FC_VERSION`): `VEHICLE_COUNT` once (slot bound,
   0 → feature off) and `LIMITS` once.
2. Poll `WARNING_VEHICLE_ICAO` (no request payload, 5 B reply, ~1–2 SmartPort frames). Adaptive rate:
   ~5–10 s while clear, ~2 s while a warning/alert is active (a contact at 70 m/s covers 700 m in 10 s).
3. ICAO ≠ 0 → fetch that contact with `MSP2_ADSB_VEHICLE` (32 B), refresh it at the warning rate,
   check the ICAO in every reply. ICAO = 0 → drop the contact from the map.
4. Priority below `MSP_NAV_STATUS`/arming polls, paused during WP download.

`MSP2_ADSB_VEHICLE` takes a **slot index, not an ICAO** (by design, see INAV PR #11663). The FC
side is frozen (INAV 10 is in RC, no functional changes), so ICAO → slot is resolved client-side:
- New threat ICAO → fetch slots 0, 1, 2 … one per poll until the ICAO matches (early stop; worst
  case 5 × 32 B, once per new threat). Cache the slot, then refresh only that slot.
- Rescan on ICAO mismatch or `ttl == 0` in a refresh reply.
- Starting at index 0 is the right order: free slots are taken lowest index first
  (`findFreeSpaceInList` returns the first `ttl == 0` slot), so with light traffic the contacts
  sit in the low slots.
- The slot is stable while the contact is tracked: the FC updates a known ICAO in place
  (`findVehicleByIcao`) and only evicts the farthest contact, which a threat is not.

Slot order is **not** distance order — neither in `MSP2_ADSB_VEHICLE` nor in the bulk
`MSP2_ADSB_VEHICLE_LIST` (both iterate `findVehicle(0..n-1)`; no sorting in `adsb.c` 9.0/10.x,
none in the configurator's parser). Full traffic tracking is out of scope — that is a GCS job.

Notes: the FC returns ICAO 0 whenever its own GPS is not good enough
(`isEnvironmentOkForCalculatingADSBDistanceBearing`: > 4 sats …). Alert has priority over warning
in the FC's selection.

## Widget side

- **New lib `lib/adsb.lua`** owns everything ADSB: poll scheduling (warning rate, slot scan,
  tracked slot), reply parsing, contact state. `msp.lua` only provides the transport (send a
  request, hand back the reply); `main.lua` loads it like the other libs (after `msp`).
- **compute.lua:** project contacts with the WP/trail machinery; extrapolate between updates
  with heading + horizontal velocity (`tslc` caps the extrapolation).
- **Drawing (maplib):** aircraft symbol rotated by heading, colour by FC threat state, label with
  callsign and relative altitude (strings pre-formatted in `wakeup()`). Off-screen threat →
  edge arrow (reuse `layout_default.lua`). Faded when `tslc` > ~5 s.
- **Alert:** `audio/` sound + haptic once per threat change (none → warning → alert).
- **Altitude:** ADSB altitude is MSL; own telemetry altitude is usually relative to home →
  relative altitude only with an MSL source, "?" otherwise.
- **Setting:** `adsbEnabled` (bool, default off), appended to storage. Thresholds come from the FC.

## Later: full traffic display

Showing all tracked contacts (not only the alert) is out of scope for this feature. It only makes
sense on fast telemetry links (e.g. a modified mLRS) or with a leaner MSP telemetry scheme that is
in development separately; revisit once ADS-B Alert has been verified on hardware.

## Open questions

- INAV 9 support (bulk list, 160 B every poll): not supported — INAV ≥ 10 only. On INAV 9 the first request (`MSP2_ADSB_VEHICLE_COUNT`) returns an error, on INAV < 9 it times out (no MSPv2 over telemetry); both switch ADS-B off for the session.
- Real update rate over SmartPort with the staggered scan.
- Testing without a receiver: INAV SITL with simulated ADSB, or recorded replies replayed through a stub.

## Verification

- `build/tests/`: parser tests for `MSP2_ADSB_VEHICLE` (signed lat/lon, empty slot, callsign
  padding) and the warning reply.
- Hardware: INAV 10 FC with ADSB receiver over CRSF and SmartPort; PERF `mspPollMs`, MSP errors,
  contact positions against a flight tracking reference.
