-- Desktop harness: runs main.lua's create/read/wakeup/paint with stubbed ETHOS APIs.
-- Only checks control flow, log output and which texts get drawn — timings mean nothing here.
-- os.time() is chosen so that os.time() * 100 overflows desktop 64-bit integers, the same failure
-- class as ETHOS 32-bit integers (Docs/development/helper/ETHOS-LUA-NUMBERS-AND-TIME.md).
-- Run from the repo root: lua build/tests/stub_widget.lua [seconds]

local SRC = "src/scripts/ethosmaps/"
local OUT = os.getenv("TEMP") or os.getenv("TMPDIR") or "."
local LOG = OUT .. "/ethosmaps_stub_debug.log"
os.remove(LOG)

local clockMs = 34000000
local EPOCH = math.maxinteger // 64
os.time = function() return EPOCH + clockMs // 1000 end
os.clock = function() return clockMs / 1000 end
local drawn = {}
local gps = { lat = 51.409489, lon = 11.549406 }

local function noop() end
local function proxy(name, overrides)
  return setmetatable(overrides or {}, { __index = function(_, k) return noop end })
end

local realOpen = io.open
io.open = function(path, mode)
  if path == "/scripts/ethosmaps/debug.log" then return realOpen(LOG, mode) end
  if path:sub(1, 19) == "/scripts/ethosmaps/" then return realOpen(OUT .. "/ethosmaps_stub_" .. path:sub(20), mode) end
  return nil
end
local realDofile = dofile
dofile = function(path)
  if path:sub(1, 19) == "/scripts/ethosmaps/" then return realDofile(SRC .. path:sub(20)) end
  return realDofile(path)
end

local bitmap = setmetatable({}, { __index = function() return function() return 32 end end })
lcd = proxy("lcd", {
  getWindowSize = function() return 800, 480 end,
  getTextSize = function(t) return #tostring(t) * 10, 20 end,
  drawText = function(_, _, t) drawn[tostring(t)] = true end,
  loadBitmap = function() return bitmap end,
  RGB = function() return 0 end,
})
local widgetDef
local storageData = {
  _settingsVersion = 2, enableDebugLog = true, enablePerfProfile = false,
  mapProvider = 2, mapTypeId = 2, mapZoomDefault = 16, mapZoomMin = 1, mapZoomMax = 20,
  telemetrySourceMode = 1, wpDownload = false, zoomControl = 0, homeSource = 1,
}
storage = { read = function(k) return storageData[k] end, write = noop }
local function src(v) return { value = function() return v() end } end
system = proxy("system", {
  registerWidget = function(def) widgetDef = def end,
  getVersion = function() return { major = 26, minor = 1, revision = 2, board = "X20RS", lcdWidth = 800, lcdHeight = 480 } end,
  getSource = function(q)
    if q and q.options == OPTION_LATITUDE then return src(function() return gps.lat end) end
    if q and q.options == OPTION_LONGITUDE then return src(function() return gps.lon end) end
    return nil
  end,
  listFiles = function() return {} end,
})
form = proxy("form")
model = proxy("model", { name = function() return "Test" end })
setmetatable(_G, { __index = function(_, k)
  if type(k) == "string" and k:match("^[A-Z][A-Z0-9_]+$") then return #k end
  return nil
end })
OPTION_LATITUDE, OPTION_LONGITUDE = 1001, 1002

local main = realDofile(SRC .. "main.lua")
main.init()
assert(widgetDef, "registerWidget not called")

local w = widgetDef.create()
w.screen = 1
widgetDef.read(w)
local seconds = tonumber(arg and arg[1]) or 12
for _ = 1, seconds * 3 do
  clockMs = clockMs + 333
  local ok, err = pcall(widgetDef.wakeup, w)
  if not ok then print("WAKEUP ERROR: " .. tostring(err)) break end
  ok, err = pcall(widgetDef.paint, w)
  if not ok then print("PAINT ERROR: " .. tostring(err)) break end
end

local fails = 0
if drawn["ZOOM LIMIT"] then
  print("FAIL ZOOM LIMIT drawn without any touch")
  fails = fails + 1
end
local f = realOpen(LOG, "r")
if f then
  for line in f:lines() do
    if not line:find("| SETTINGS |", 1, true) then print(line) end
  end
  f:close()
else
  print("no debug log written")
end

local logText = ""
f = realOpen(LOG, "r")
if f then logText = f:read("a") f:close() end
if not logText:find("implausible jump dropped", 1, true) then
  print("FAIL interval-gated GPS_FILT log never written (now - 0 >= interval failed: time source broken?)")
  fails = fails + 1
end

-- Positional storage as on the radio: read() ignores the key, nil slots exist.
local KEYS = { "_settingsVersion", "horSpeedUnit", "vertSpeedUnit", "distUnit", "distUnitLong", "gpsFormat",
  "mapProvider", "mapTypeId", "mapZoomDefault", "mapZoomMin", "mapZoomMax", "enableDebugLog", "enablePerfProfile",
  "uavSymbol", "zoomControl", "zoomChannel", "mapTrailResolution", "mapTrailHeadingThreshold", "linkQualitySource",
  "userSensor1", "userSensor2", "userSensor3", "telemetrySourceMode", "sensorGpsLat", "sensorGpsLon", "sensorHeading",
  "sensorSpeed", "wpDownload", "homeSource", "homeSwitch", "adsbEnabled" }

local function roundTrip(stored, used, throwPastEnd)
  local reads, written = 0, {}
  storage = {
    read = function()
      reads = reads + 1
      if reads > used then
        if throwPastEnd then error("Read error") end
        return nil
      end
      return stored[reads]
    end,
    write = function(k, v) written[k] = v end,
  }
  widgetDef.read(w)
  widgetDef.write(w)
  return reads, written
end

local function expect(name, got, want)
  if got ~= want then
    print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
    fails = fails + 1
  end
end

local good = { 2, 2, 2, 2, 2, 1, 2, 1, nil, 3, 18, false, false, 2, 1, 7, 100, 9, nil, nil, nil, nil, 2, nil, nil, nil, nil, true, 2, nil, true }
local reads, out = roundTrip(good, #KEYS)
expect("one read per key with nil mapZoomDefault", reads, #KEYS)
for i, k in ipairs(KEYS) do
  if k ~= "mapZoomDefault" and k ~= "mapTypeId" and k ~= "mapProvider" then expect("round trip " .. k, out[k], good[i]) end
end

-- What 2.1/2.2 saved after reading one slot off.
local shifted = { 2, 1, 1, 1, 1, 2, 2, nil, nil, 20, 20, false, true, 0, 0, 50, 5, 5, nil, nil, nil, 1, 1, nil, nil, nil, false, true, 0, false, false }
reads, out = roundTrip(shifted, #KEYS)
expect("shifted zoomMin", out.mapZoomMin, 1)
expect("shifted zoomMax", out.mapZoomMax, 20)
expect("shifted uavSymbol", out.uavSymbol, 1)
expect("shifted trail", out.mapTrailResolution, 50)
expect("shifted userSensor3", out.userSensor3, nil)
expect("shifted homeSource", out.homeSource, 1)
expect("shifted homeSwitch", out.homeSwitch, nil)

-- Model saved by 2.1: the three newest keys are not stored, a firmware may raise instead of returning nil.
reads, out = roundTrip(good, 28, true)
expect("upgrade reads all keys", reads, #KEYS)
expect("upgrade homeSource default", out.homeSource, 1)
expect("upgrade adsbEnabled default", out.adsbEnabled, false)
expect("upgrade keeps trail", out.mapTrailResolution, 100)

print(fails == 0 and "STUB RUN PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
