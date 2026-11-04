-- Tests for utils.gpsFilterUpdate (GPS plausibility filter).
-- Run from the repo root: lua build/tests/test_gps_filter.lua

local utils = dofile("src/scripts/ethosmaps/lib/utils.lua")
local fails = 0

local function check(name, cond, detail)
  if cond then
    print("ok   " .. name)
  else
    fails = fails + 1
    print("FAIL " .. name .. (detail and ("  " .. detail) or ""))
  end
end

-- Moves (lat, lon) by metres north/east (small-distance approximation).
local function offset(lat, lon, north, east)
  return lat + north / 111320, lon + east / (111320 * math.cos(math.rad(lat)))
end

-- Feeds one sample per second for `seconds`, calling the filter 3x per second like wakeup().
local function feed(f, t, seconds, sampleAt)
  local lat, lon, ev
  for s = 0, seconds - 1 do
    local sLat, sLon = sampleAt(s)
    for k = 0, 2 do
      lat, lon, ev = utils.gpsFilterUpdate(f, sLat, sLon, t + s * 100 + k * 33)
    end
  end
  return lat, lon, t + seconds * 100
end

local HOME_LAT, HOME_LON = 51.442148, 11.576354

do
  local f = utils.newGpsFilter()
  local lat = feed(f, 0, 2, function() return HOME_LAT, HOME_LON end)
  check("first fix not accepted before confirm time", lat == nil)
  lat = feed(f, 200, 2, function() return HOME_LAT, HOME_LON end)
  check("stationary first fix confirmed after ~3 s", lat == HOME_LAT)
end

do
  local f = utils.newGpsFilter()
  local seed = 7
  local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
  local lat = feed(f, 0, 30, function() return rnd() * 130 - 60, rnd() * 340 - 170 end)
  check("30 s of world-wide garbage never accepted", lat == nil, tostring(lat))
  local t
  lat, _, t = feed(f, 3000, 2, function(s) return offset(HOME_LAT, HOME_LON, s * 20, 0) end)
  check("valid track after garbage not yet accepted after 2 s", lat == nil)
  lat = feed(f, t, 3, function(s) return offset(HOME_LAT, HOME_LON, (s + 2) * 20, 0) end)
  check("valid track after garbage accepted within 5 s", lat ~= nil and math.abs(lat - HOME_LAT) < 0.01)
end

do
  local f = utils.newGpsFilter()
  local _, _, t = feed(f, 0, 4, function() return HOME_LAT, HOME_LON end)
  local accepted = 0
  for s = 1, 20 do
    local sLat, sLon = offset(HOME_LAT, HOME_LON, 0, s * 300)
    local lat = utils.gpsFilterUpdate(f, sLat, sLon, t + s * 100)
    if lat == sLat then accepted = accepted + 1 end
  end
  check("300 m/s flight at 1 Hz accepted on every sample", accepted == 20, accepted .. "/20")
end

do
  local f = utils.newGpsFilter()
  local _, _, t = feed(f, 0, 4, function() return HOME_LAT, HOME_LON end)
  local lat = utils.gpsFilterUpdate(f, -33.8688, 151.2093, t + 100)
  check("single mid-flight glitch rejected, position held", lat == HOME_LAT)
  local nLat = offset(HOME_LAT, HOME_LON, 30, 0)
  lat = utils.gpsFilterUpdate(f, nLat, HOME_LON, t + 200)
  check("next valid sample after glitch accepted", lat == nLat)
end

do
  local f = utils.newGpsFilter()
  local _, _, t = feed(f, 0, 4, function() return HOME_LAT, HOME_LON end)
  local farLat, farLon = 48.1351, 11.5820
  local lat = feed(f, t, 2, function() return farLat, farLon end)
  check("relocation 370 km not accepted immediately", lat == HOME_LAT)
  lat = feed(f, t + 200, 2, function() return farLat, farLon end)
  check("relocation accepted once stable ~3 s", lat == farLat)
end

do
  local f = utils.newGpsFilter()
  local lat, _, ev = utils.gpsFilterUpdate(f, 0, 0, 0)
  check("0/0 ignored", lat == nil and ev == nil)
  lat = utils.gpsFilterUpdate(f, nil, nil, 10)
  check("nil ignored", lat == nil)
end

-- Replay CSV used for the simulator repro: no garbage position may ever be accepted.
do
  local path = "Docs/development/tools/ETHOS VSCode Sim Telemetry Injection/Synthetic_Logs/DemoTelemetry_Synthetic_GpsColdstartGarbage_250ms.csv"
  local fh = io.open(path, "r")
  if not fh then
    check("replay CSV present", false, path)
  else
    local header = fh:read("*line")
    local col = 0
    local i = 0
    for name in (header .. ","):gmatch("([^,]*),") do
      i = i + 1
      if name == "GPS" then col = i end
    end
    local f = utils.newGpsFilter()
    local row, firstAccept, badAccept = 0, nil, 0
    local line = fh:read("*line")
    while line do
      row = row + 1
      local j, gps = 0, nil
      for v in (line .. ","):gmatch("([^,]*),") do
        j = j + 1
        if j == col then gps = v break end
      end
      local sLat, sLon = gps:match("^(%S+) (%S+)$")
      local lat = utils.gpsFilterUpdate(f, tonumber(sLat), tonumber(sLon), row * 25)
      if lat ~= nil then
        firstAccept = firstAccept or row
        if math.abs(lat - HOME_LAT) > 0.05 then badAccept = badAccept + 1 end
      end
      line = fh:read("*line")
    end
    fh:close()
    check("replay CSV: no garbage position accepted", badAccept == 0, badAccept .. " bad")
    check("replay CSV: valid track accepted within 4 s of garbage end (row 121)",
      firstAccept ~= nil and firstAccept <= 121 + 16, "first accept row " .. tostring(firstAccept))
  end
end

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
