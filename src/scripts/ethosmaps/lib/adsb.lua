--
-- adsb.lua — ADS-B threat contact from INAV (experimental, INAV 10+)
--
-- Polls INAV's ADS-B warning (MSP2_ADSB_WARNING_VEHICLE_ICAO) and fetches only the contact the
-- FC flags, with MSP2_ADSB_VEHICLE. Slots are addressed by index, not ICAO, so a new threat
-- starts a short slot scan; the found slot is then refreshed directly. An error reply or
-- repeated timeouts while probing switch the feature off for this session (FC firmware too old
-- or built without ADS-B). msp.lua owns the transport and calls nextRequest / onReply /
-- onTimeout from its idle (STATE_DONE) scheduler. Protocol details:
-- Docs/development/workstreams/AdsbTraffic.md
--
-- Author: b14ckyy (Marc Hoffmann), https://github.com/b14ckyy
-- Based on the Yaapu Mapping Widget by Alessandro Apostoli, https://github.com/yaapu
--
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation; either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, see <http://www.gnu.org/licenses>.

local adsb = {}

local char = string.char
local fmt = string.format
local pcall = pcall

local MSP2_ADSB_WARNING_VEHICLE_ICAO = 0x2092
local MSP2_ADSB_VEHICLE              = 0x2093
local MSP2_ADSB_VEHICLE_COUNT        = 0x2094

adsb.CMD_WARNING = MSP2_ADSB_WARNING_VEHICLE_ICAO
adsb.CMD_VEHICLE = MSP2_ADSB_VEHICLE
adsb.CMD_COUNT   = MSP2_ADSB_VEHICLE_COUNT

local WARN_POLL_IDLE_S   = 5.0
local WARN_POLL_THREAT_S = 2.0
local CONTACT_STALE_S    = 15.0
local MAX_PROBE_TIMEOUTS = 20   -- lossy S.Port links lose 3 probes in a row often
local VEHICLE_REPLY_LEN  = 23
local CALLSIGN_LEN       = 9

local PHASE_OFF         = 0
local PHASE_PROBE       = 1
local PHASE_RUN         = 2
local PHASE_UNSUPPORTED = 3

local status = nil
local libs = nil

local phase = PHASE_OFF
local slotCount = 0
local probeTimeouts = 0
local lastWarnPoll = nil
local threatIcao = 0
local threatAlert = false
local trackSlot = nil
local scanIdx = nil
local refreshDue = false
local requestedSlot = nil
local lastContactRx = nil

local contact = {
  valid = false, icao = 0, lat = 0, lon = 0, altM = 0, headingDeg = 0, speedMps = 0,
  tslc = 0, emitter = 0, callsign = "", alert = false, rxTime = 0,
}

local function log(msg)
  if status and status.debugEnabled and libs and libs.utils then
    libs.utils.logDebug("ADSB", msg, true)
  end
end

-- Float arithmetic: ETHOS integers are 32-bit (Docs/development/helper/ETHOS-LUA-NUMBERS-AND-TIME.md).
local function u32(b, o)
  return b[o] + b[o + 1] * 256.0 + b[o + 2] * 65536.0 + b[o + 3] * 16777216.0
end

local function s32(b, o)
  local v = u32(b, o)
  if v >= 2147483648.0 then v = v - 4294967296.0 end
  return v
end

local function u16(b, o)
  return b[o] + b[o + 1] * 256
end

local function callsignOf(b, o)
  local bytes = {}
  for i = 0, CALLSIGN_LEN - 1 do
    local c = b[o + i]
    if c == nil or c == 0 then break end
    if c >= 32 and c < 127 then bytes[#bytes + 1] = c end
  end
  if #bytes == 0 then return "" end
  return (char(table.unpack(bytes)):gsub("%s+$", ""))
end

--- Parses an MSP2_ADSB_VEHICLE reply. Returns a table or nil when the reply is too short.
function adsb.parseVehicle(buf)
  if buf == nil or #buf < VEHICLE_REPLY_LEN then return nil end
  return {
    icao       = u32(buf, 1),
    lat        = s32(buf, 5) / 1e7,
    lon        = s32(buf, 9) / 1e7,
    altM       = s32(buf, 13) / 100,
    headingDeg = u16(buf, 17) / 100,
    speedMps   = u16(buf, 19) / 100,
    tslc       = buf[21],
    emitter    = buf[22],
    ttl        = buf[23],
    callsign   = callsignOf(buf, 24),
  }
end

local function clearThreat()
  threatIcao = 0
  threatAlert = false
  trackSlot = nil
  scanIdx = nil
  refreshDue = false
  contact.valid = false
end

local function playAlert(level)
  if status == nil or not status.flagEnabled(status.conf.adsbEnabled) then return end
  local file = level == 2 and "/scripts/ethosmaps/audio/err.wav" or "/scripts/ethosmaps/audio/inf.wav"
  pcall(system.playFile, file)
  pcall(system.playHaptic, level == 2 and 300 or 100)
end

local function setUnsupported(reason)
  phase = PHASE_UNSUPPORTED
  clearThreat()
  log("disabled for this session: " .. reason)
end

--- Enables or disables polling. Re-enabling after "unsupported" probes the FC again.
function adsb.setEnabled(on)
  if on then
    if phase == PHASE_OFF or phase == PHASE_UNSUPPORTED then
      phase = PHASE_PROBE
      probeTimeouts = 0
      lastWarnPoll = nil
      clearThreat()
    end
  else
    phase = PHASE_OFF
    clearThreat()
  end
end

--- Next MSP request for msp.lua's idle scheduler: returns cmd, payload or nil.
function adsb.nextRequest(now)
  if phase == PHASE_PROBE then
    return MSP2_ADSB_VEHICLE_COUNT, {}
  end
  if phase ~= PHASE_RUN then return nil end

  if contact.valid and lastContactRx and now - lastContactRx > CONTACT_STALE_S then
    contact.valid = false
    trackSlot = nil
  end
  if scanIdx ~= nil then
    requestedSlot = scanIdx
    return MSP2_ADSB_VEHICLE, { scanIdx }
  end
  if refreshDue and trackSlot ~= nil then
    refreshDue = false
    requestedSlot = trackSlot
    return MSP2_ADSB_VEHICLE, { trackSlot }
  end
  local interval = threatIcao ~= 0 and WARN_POLL_THREAT_S or WARN_POLL_IDLE_S
  if lastWarnPoll == nil or now - lastWarnPoll >= interval then
    lastWarnPoll = now
    return MSP2_ADSB_WARNING_VEHICLE_ICAO, {}
  end
  -- Between warning polls keep refreshing the tracked contact: on a lossy link most refreshes fail
  if threatIcao ~= 0 and trackSlot ~= nil then
    requestedSlot = trackSlot
    return MSP2_ADSB_VEHICLE, { trackSlot }
  end
  return nil
end

local function onWarning(buf)
  if #buf < 5 then return end
  local icao = u32(buf, 1)
  local alert = buf[5] ~= 0
  if icao == 0 then
    if threatIcao ~= 0 then log("threat cleared") end
    clearThreat()
    return
  end
  local oldLevel = threatIcao == 0 and 0 or (threatAlert and 2 or 1)
  local newLevel = alert and 2 or 1
  if icao ~= threatIcao then
    threatIcao = icao
    trackSlot = nil
    contact.valid = false
    scanIdx = 0
    log(fmt("threat ICAO %06X (%s), scanning %d slots", icao, alert and "ALERT" or "warning", slotCount))
  elseif trackSlot ~= nil then
    refreshDue = true
  elseif scanIdx == nil then
    scanIdx = 0
  end
  threatAlert = alert
  contact.alert = alert
  if newLevel > oldLevel then playAlert(newLevel) end
end

local function onVehicle(buf, err, now)
  local slot = requestedSlot
  requestedSlot = nil
  local v = (not err) and adsb.parseVehicle(buf) or nil
  if v and v.ttl > 0 and v.icao == threatIcao and threatIcao ~= 0 then
    contact.valid = true
    contact.icao = v.icao
    contact.lat, contact.lon = v.lat, v.lon
    contact.altM = v.altM
    contact.headingDeg = v.headingDeg
    contact.speedMps = v.speedMps
    contact.tslc = v.tslc
    contact.emitter = v.emitter
    contact.callsign = v.callsign
    contact.alert = threatAlert
    contact.rxTime = status and status.getTime() or 0
    lastContactRx = now
    if trackSlot ~= slot then
      log(fmt("tracking %s (%06X) in slot %d", v.callsign ~= "" and v.callsign or "?", v.icao, slot or -1))
    end
    trackSlot = slot
    scanIdx = nil
    return
  end
  if scanIdx ~= nil then
    scanIdx = scanIdx + 1
    if scanIdx >= slotCount then
      log(fmt("threat ICAO %06X not found in %d slots", threatIcao, slotCount))
      scanIdx = nil
    end
  elseif slot ~= nil and slot == trackSlot then
    trackSlot = nil
    scanIdx = 0
  end
end

--- Reply from msp.lua for a request issued by nextRequest().
function adsb.onReply(cmd, buf, err, now)
  if cmd == MSP2_ADSB_VEHICLE_COUNT then
    if err or buf == nil or #buf < 1 then
      setUnsupported("MSP2_ADSB_VEHICLE_COUNT not supported (INAV < 10)")
    elseif buf[1] == 0 then
      setUnsupported("FC built without ADS-B")
    else
      slotCount = buf[1]
      phase = PHASE_RUN
      lastWarnPoll = nil
      log(fmt("FC reports %d ADS-B slots", slotCount))
    end
  elseif cmd == MSP2_ADSB_WARNING_VEHICLE_ICAO then
    if err then
      setUnsupported("MSP2_ADSB_WARNING_VEHICLE_ICAO returned an error (INAV < 10)")
    elseif buf ~= nil then
      onWarning(buf)
    end
  elseif cmd == MSP2_ADSB_VEHICLE then
    onVehicle(buf, err, now)
  end
end

--- Request issued by nextRequest() got no reply in time.
function adsb.onTimeout(cmd)
  if phase == PHASE_PROBE then
    probeTimeouts = probeTimeouts + 1
    if probeTimeouts >= MAX_PROBE_TIMEOUTS then
      setUnsupported("no reply to MSPv2 ADS-B request (INAV < 9 or link issue)")
    end
  elseif cmd == MSP2_ADSB_VEHICLE then
    requestedSlot = nil
  end
end

--- Tracked threat contact or nil.
function adsb.getContact()
  if contact.valid then return contact end
  return nil
end

--- "off" | "probing" | "active" | "unsupported"
function adsb.getPhase()
  if phase == PHASE_PROBE then return "probing" end
  if phase == PHASE_RUN then return "active" end
  if phase == PHASE_UNSUPPORTED then return "unsupported" end
  return "off"
end

function adsb.init(param_status, param_libs)
  status = param_status
  libs = param_libs
  return adsb
end

return adsb
