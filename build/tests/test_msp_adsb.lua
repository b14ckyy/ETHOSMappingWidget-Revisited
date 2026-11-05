-- End-to-end test: msp.lua (CRSF transport, MSPv1 + native MSPv2 framing) + adsb.lua against a
-- simulated INAV FC that answers like telemetry/msp_shared.c (INAV 10: status byte with version
-- bits and error flag 0x80, MSPv2 header flag/cmd16/size16, request CRC byte ignored).
-- Run from the repo root: lua build/tests/test_msp_adsb.lua

local fails = 0
local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    fails = fails + 1
    print("FAIL " .. name .. (detail and ("  " .. detail) or ""))
  end
end

local clockS = 1000
os.clock = function() return clockS end

local CRSF_MSP_REQ, CRSF_MSP_RESP = 0x7A, 0x7B

local function le32(v)
  if v < 0 then v = v + 4294967296 end
  return v % 256, (v // 256) % 256, (v // 65536) % 256, (v // 16777216) % 256
end

-- Simulated FC ---------------------------------------------------------------------------------
local fc = { inavMajor = 10, adsbSupported = true, threat = 0, alert = false, slots = {}, seen = {} }
local rxQueue = {}
local seqOut = 0

local function fcReply(version, cmd, payload, isError)
  local status = 0x10 + (seqOut % 16) + version * 32 + (isError and 0x80 or 0)
  seqOut = seqOut + 1
  local chunk = { status }
  if version == 1 then
    chunk[#chunk + 1] = #payload
    chunk[#chunk + 1] = cmd
  else
    chunk[#chunk + 1] = 0
    chunk[#chunk + 1] = cmd % 256
    chunk[#chunk + 1] = cmd // 256
    chunk[#chunk + 1] = #payload % 256
    chunk[#chunk + 1] = #payload // 256
  end
  for _, b in ipairs(payload) do chunk[#chunk + 1] = b end
  local data = { 0xEA, 0xC8 }
  for _, b in ipairs(chunk) do data[#data + 1] = b end
  rxQueue[#rxQueue + 1] = data
end

local function vehicleRecord(slot)
  local v = fc.slots[slot]
  local b = {}
  local function push(...) for _, x in ipairs({ ... }) do b[#b + 1] = x end end
  if not v then
    for _ = 1, 32 do b[#b + 1] = 0 end
    return b
  end
  push(le32(v.icao)); push(le32(v.lat)); push(le32(v.lon)); push(le32(v.alt))
  push(v.hdg % 256, v.hdg // 256, v.vel % 256, v.vel // 256, 1, 1, 9)
  for i = 1, 9 do b[#b + 1] = v.cs:byte(i) or 0 end
  return b
end

local function fcHandle(chunk)
  local status = chunk[1]
  local version = (status & 0x60) >> 5
  local cmd, payload = nil, {}
  if version == 1 then
    cmd = chunk[3]
    for i = 1, chunk[2] do payload[i] = chunk[3 + i] end
  else
    cmd = chunk[3] + chunk[4] * 256
    local size = chunk[5] + chunk[6] * 256
    for i = 1, size do payload[i] = chunk[6 + i] end
  end
  fc.seen[#fc.seen + 1] = cmd
  if version == 2 and fc.inavMajor < 9 then return end
  if cmd == 2 then fcReply(version, cmd, { 73, 78, 65, 86 })
  elseif cmd == 3 then fcReply(version, cmd, { fc.inavMajor, 0, 0 })
  elseif cmd == 101 then fcReply(version, cmd, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 })
  elseif cmd == 0x2094 and fc.inavMajor >= 10 then fcReply(version, cmd, { fc.adsbSupported and 5 or 0 })
  elseif cmd == 0x2092 and fc.inavMajor >= 10 then
    local a, b, c, d = le32(fc.threat)
    fcReply(version, cmd, { a, b, c, d, fc.alert and 1 or 0 })
  elseif cmd == 0x2093 and fc.inavMajor >= 10 then fcReply(version, cmd, vehicleRecord(payload[1]))
  else fcReply(version, cmd, {}, true)
  end
end

local sensor = {
  pushFrame = function(_, ftype, data)
    assert(ftype == CRSF_MSP_REQ)
    local chunk = {}
    for i = 3, #data do chunk[#chunk + 1] = data[i] end
    fcHandle(chunk)
    return true
  end,
  popFrame = function()
    local d = table.remove(rxQueue, 1)
    if d then return CRSF_MSP_RESP, d end
    return nil
  end,
  module = function() end,
}
crsf = { getSensor = function() return sensor end }
system = {
  getSource = function() return nil end,
  playFile = function() end,
  playHaptic = function() end,
}

-- Widget side ----------------------------------------------------------------------------------
local status = {
  debugEnabled = false,
  conf = { adsbEnabled = true },
  flagEnabled = function(v) return v == true end,
  getTime = function() return clockS * 100.0 end,
}
local libs = {}
local msp = dofile("src/scripts/ethosmaps/lib/msp.lua").init(status, libs)
local adsb = dofile("src/scripts/ethosmaps/lib/adsb.lua").init(status, libs)

local function run(seconds)
  for _ = 1, seconds * 10 do
    clockS = clockS + 0.1
    for _ = 1, 10 do msp.poll() end
  end
end

local function seenCount(cmd)
  local n = 0
  for _, c in ipairs(fc.seen) do if c == cmd then n = n + 1 end end
  return n
end

do
  msp.open({ armingOnly = true })
  adsb.setEnabled(true)
  msp.setClient(adsb)
  run(3)
  check("FC detected over CRSF, MSP idle", msp.isDone(), "state " .. tostring(msp.getState().state))
  check("ADS-B probed via MSPv2 0x2094", seenCount(0x2094) == 1)
  check("ADS-B active on INAV 10", adsb.getPhase() == "active")
  check("warning polled", seenCount(0x2092) >= 1)

  fc.slots[0] = { icao = 0xAAAAAA, lat = 0, lon = 0, alt = 0, hdg = 0, vel = 0, cs = "FAR" }
  fc.slots[3] = { icao = 0x3C6A12, lat = 514000000, lon = 115000000, alt = 45000, hdg = 18000, vel = 5000, cs = "DLH9X" }
  fc.threat, fc.alert = 0x3C6A12, true
  run(7)
  local c = adsb.getContact()
  check("threat contact tracked from slot 3", c ~= nil and c.callsign == "DLH9X" and c.alert, c and c.callsign)
  check("contact lat/lon decoded", c ~= nil and math.abs(c.lat - 51.4) < 1e-6 and math.abs(c.lon - 11.5) < 1e-6)
  check("arming poll still served", seenCount(101) >= 2)

  fc.threat = 0
  run(3)
  check("threat cleared", adsb.getContact() == nil)
  msp.close()
end

do
  fc.seen, rxQueue = {}, {}
  fc.inavMajor = 9
  adsb.setEnabled(false)
  msp.open({ armingOnly = true })
  adsb.setEnabled(true)
  msp.setClient(adsb)
  run(4)
  check("INAV 9: error reply -> ADS-B unsupported", adsb.getPhase() == "unsupported")
  local before = seenCount(0x2094) + seenCount(0x2092)
  run(10)
  check("INAV 9: no further ADS-B requests", seenCount(0x2094) + seenCount(0x2092) == before)
  check("INAV 9: arming poll unaffected", msp.isDone() and seenCount(101) >= 2)
  msp.close()
end

do
  fc.seen, rxQueue = {}, {}
  fc.inavMajor = 8
  adsb.setEnabled(false)
  msp.open({ armingOnly = true })
  adsb.setEnabled(true)
  msp.setClient(adsb)
  run(10)
  check("INAV 8: no MSPv2 reply -> unsupported after timeouts", adsb.getPhase() == "unsupported")
  check("INAV 8: MSP still idle/done", msp.isDone())
  msp.close()
end

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
