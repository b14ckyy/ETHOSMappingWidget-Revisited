-- Tests for lib/adsb.lua: reply parsing and the warning -> scan -> track polling flow.
-- Run from the repo root: lua build/tests/test_adsb.lua

local played = {}
system = {
  playFile = function(f) played[#played + 1] = f end,
  playHaptic = function() end,
}
local clockCs = 100000
local status = {
  debugEnabled = false,
  conf = { adsbEnabled = true },
  flagEnabled = function(v) return v == true end,
  getTime = function() return clockCs end,
}
local adsb = dofile("src/scripts/ethosmaps/lib/adsb.lua").init(status, {})
local fails = 0

local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    fails = fails + 1
    print("FAIL " .. name .. (detail and ("  " .. detail) or ""))
  end
end

local function le32(v)
  if v < 0 then v = v + 4294967296 end
  return v % 256, (v // 256) % 256, (v // 65536) % 256, (v // 16777216) % 256
end
local function le16(v) return v % 256, (v // 256) % 256 end

local function vehicle(icao, lat, lon, altCm, hdgCd, velCms, tslc, emitter, ttl, callsign)
  local b = {}
  local function push(...) for _, x in ipairs({ ... }) do b[#b + 1] = x end end
  push(le32(icao)); push(le32(lat)); push(le32(lon)); push(le32(altCm))
  push(le16(hdgCd)); push(le16(velCms)); push(tslc, emitter, ttl)
  for i = 1, 9 do b[#b + 1] = callsign:byte(i) or 0 end
  return b
end
local function warning(icao, alert)
  local b = { le32(icao) }
  b[5] = alert and 1 or 0
  return b
end

do
  local v = adsb.parseVehicle(vehicle(0x3C6A12, -338688000, 1512093000, 152400, 27050, 23150, 2, 3, 9, "DLH4AB"))
  check("parse icao", v and v.icao == 0x3C6A12)
  check("parse negative lat", v and math.abs(v.lat - (-33.8688)) < 1e-6, v and tostring(v.lat))
  check("parse lon", v and math.abs(v.lon - 151.2093) < 1e-6)
  check("parse alt m", v and math.abs(v.altM - 1524) < 1e-6)
  check("parse heading deg", v and math.abs(v.headingDeg - 270.5) < 1e-6)
  check("parse speed m/s", v and math.abs(v.speedMps - 231.5) < 1e-6)
  check("parse tslc/emitter/ttl", v and v.tslc == 2 and v.emitter == 3 and v.ttl == 9)
  check("parse callsign", v and v.callsign == "DLH4AB", v and ("'" .. v.callsign .. "'"))
  check("short reply -> nil", adsb.parseVehicle({ 1, 2, 3 }) == nil)
end

local t = 0
local function step(dt) t = t + (dt or 0.1) return t end

do
  adsb.setEnabled(true)
  local cmd = adsb.nextRequest(step())
  check("probe asks VEHICLE_COUNT", cmd == adsb.CMD_COUNT)
  adsb.onReply(adsb.CMD_COUNT, { 5 }, false, step())
  check("count reply -> active", adsb.getPhase() == "active")

  cmd = adsb.nextRequest(step())
  check("first poll asks WARNING", cmd == adsb.CMD_WARNING)
  adsb.onReply(adsb.CMD_WARNING, warning(0), false, step())
  check("no threat -> no contact", adsb.getContact() == nil)
  check("idle poll waits", adsb.nextRequest(step(1)) == nil)
  cmd = adsb.nextRequest(step(5))
  check("idle poll after 5 s", cmd == adsb.CMD_WARNING)

  adsb.onReply(adsb.CMD_WARNING, warning(0x3C6A12, true), false, step())
  check("alert plays sound", #played == 1 and played[1]:find("err.wav", 1, true) ~= nil)
  local c, p = adsb.nextRequest(step())
  check("scan starts at slot 0", c == adsb.CMD_VEHICLE and p[1] == 0)
  adsb.onReply(adsb.CMD_VEHICLE, vehicle(0x111111, 0, 0, 0, 0, 0, 0, 0, 9, "OTHER"), false, step())
  c, p = adsb.nextRequest(step())
  check("scan continues with slot 1", c == adsb.CMD_VEHICLE and p[1] == 1)
  adsb.onReply(adsb.CMD_VEHICLE, vehicle(0, 0, 0, 0, 0, 0, 0, 0, 0, ""), false, step())
  c, p = adsb.nextRequest(step())
  check("empty slot skipped -> slot 2", c == adsb.CMD_VEHICLE and p[1] == 2)
  adsb.onReply(adsb.CMD_VEHICLE, vehicle(0x3C6A12, 514000000, 115000000, 30000, 9000, 6000, 1, 1, 9, "TEST1"), false, step())
  local ct = adsb.getContact()
  check("threat found and tracked", ct ~= nil and ct.callsign == "TEST1" and ct.alert == true)
  check("no request right after track", adsb.nextRequest(step()) == nil)

  c = adsb.nextRequest(step(2))
  check("threat poll every 2 s", c == adsb.CMD_WARNING)
  adsb.onReply(adsb.CMD_WARNING, warning(0x3C6A12, true), false, step())
  c, p = adsb.nextRequest(step())
  check("known threat refreshes tracked slot directly", c == adsb.CMD_VEHICLE and p[1] == 2)
  check("no second sound for same level", #played == 1)
  adsb.onReply(adsb.CMD_VEHICLE, vehicle(0x222222, 0, 0, 0, 0, 0, 0, 0, 9, "MOVED"), false, step())
  c, p = adsb.nextRequest(step())
  check("slot reassigned -> rescan from 0", c == adsb.CMD_VEHICLE and p[1] == 0)
  for slot = 0, 4 do
    adsb.onReply(adsb.CMD_VEHICLE, vehicle(0x222222, 0, 0, 0, 0, 0, 0, 0, 9, "X"), false, step())
    if slot < 4 then adsb.nextRequest(step()) end
  end
  check("scan gives up after all slots", adsb.nextRequest(step()) == nil)

  adsb.nextRequest(step(2))
  adsb.onReply(adsb.CMD_WARNING, warning(0), false, step())
  check("threat cleared -> no contact", adsb.getContact() == nil)
end

do
  adsb.setEnabled(false)
  adsb.setEnabled(true)
  adsb.nextRequest(step())
  adsb.onReply(adsb.CMD_COUNT, nil, true, step())
  check("error on VEHICLE_COUNT -> unsupported", adsb.getPhase() == "unsupported")
  check("unsupported sends nothing", adsb.nextRequest(step(10)) == nil)

  adsb.setEnabled(true)
  adsb.nextRequest(step()); adsb.onReply(adsb.CMD_COUNT, { 5 }, false, step())
  adsb.nextRequest(step())
  adsb.onReply(adsb.CMD_WARNING, {}, true, step())
  check("error on WARNING -> unsupported", adsb.getPhase() == "unsupported")

  adsb.setEnabled(true)
  for _ = 1, 3 do adsb.nextRequest(step()); adsb.onTimeout(adsb.CMD_COUNT) end
  check("3 probe timeouts keep probing (lossy S.Port)", adsb.getPhase() == "probing")
  for _ = 4, 10 do adsb.nextRequest(step()); adsb.onTimeout(adsb.CMD_COUNT) end
  check("10 probe timeouts -> unsupported", adsb.getPhase() == "unsupported")

  adsb.setEnabled(true)
  adsb.nextRequest(step())
  adsb.onReply(adsb.CMD_COUNT, { 0 }, false, step())
  check("count 0 (no USE_ADSB) -> unsupported", adsb.getPhase() == "unsupported")
end

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
