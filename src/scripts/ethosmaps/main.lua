--
-- A FRSKY SPort/FPort/FPort2 and TBS CRSF telemetry widget for the Ethos OS
-- based on ArduPilot's passthrough telemetry protocol
--
-- Author: Alessandro Apostoli, https://github.com/yaapu
--
-- This program is free software; you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation; either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY, without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program; if not, see <http://www.gnu.org/licenses>.

-- Cached stdlib references for embedded Lua performance (avoid _ENV hash lookups).
local type = type
local tostring = tostring
local tonumber = tonumber
local pairs = pairs
local floor, abs, max, min, ceil = math.floor, math.abs, math.max, math.min, math.ceil
local fmt = string.format
local tinsert, tremove, tconcat = table.insert, table.remove, table.concat
local os_clock, os_time = os.clock, os.time

-- Widget version string shown in the settings UI.  Bump on every release.
local WIDGET_VERSION = "2.1.0"

-- Storage schema version.  Only bump this when storage keys are renamed,
-- reordered, or changed in a way that makes old stored values unreadable.
-- Adding or removing keys in a key-value store is backward-compatible
-- and does NOT require a schema bump.
local STORAGE_SCHEMA = 2


local _getTimeImpl = nil

local function getTime()
  -- Canonical time source for the entire widget, returning centiseconds.
  -- Caches the winning source on first successful call to avoid re-probing each frame.
  if _getTimeImpl ~= nil then
    return _getTimeImpl()
  end

  if system ~= nil and type(system.getTimeCounter) == "function" then
    local ms = system.getTimeCounter()
    if type(ms) == "number" and ms >= 0 then
      _getTimeImpl = function() return system.getTimeCounter() / 10 end
      return ms / 10
    end
  end

  local wallSec = os_time()
  if type(wallSec) == "number" and wallSec > 0 then
    _getTimeImpl = function() return os_time() * 100 end
    return wallSec * 100
  end

  _getTimeImpl = function() return os_clock() * 100 end
  return os_clock() * 100
end

-- Pan state constants
local PAN_IDLE     = 0
local PAN_DRAGGING = 1
local PAN_GRACE    = 2
local PAN_PENDING  = 3

-- Pan timing constants (centiseconds)
local PAN_TOUCH_TIMEOUT_CS   = 50   -- 500ms: no touch events → finger up
local PAN_GRACE_DURATION_CS  = 500  -- 5s: grace period before auto-recenter

-- Minimum height tolerance for fullscreen panning detection.
-- The widget title bar can consume a few rows, so allow 10% height reduction.
local PAN_HEIGHT_TOLERANCE = 0.90

-- GPS staleness: if lat/lon stop changing for this many centiseconds, mark telemetry lost.
local GPS_STALE_TIMEOUT = 500  -- 5 seconds

local logDebugSessionStart
local configRebuildInProgress = false


local mapStatus = {
  -- Canonical time helper published here so libraries loaded later can call
  -- status.getTime() without duplicating the implementation.
  getTime = getTime,
  -- Runtime telemetry cache populated from Ethos sources and consumed by layout and map drawing code.
  telemetry = {
    yaw = nil,
    roll = nil,
    pitch = nil,
    -- GPS position and derived navigation values.
    lat = nil,
    lon = nil,
    strLat = "---",
    strLon = "---",
    groundSpeed = 0,
    cog = 0,
    -- Home position and vector from aircraft to home.
    homeLat = nil,
    homeLon = nil,
    homeAngle = 0,
    homeDist = 0,
    -- Link quality values mirrored from radio telemetry.
    rssi = 0,
    rssiCRSF = 0,
  },

  -- Persistent widget settings loaded from storage and used by UI, map, and unit conversions.
  conf = {
    horSpeedUnit = 1,
    horSpeedMultiplier = 1,
    horSpeedLabel = "m/s",
    vertSpeedUnit = 1,
    vertSpeedMultiplier = 1,
    vertSpeedLabel = "m/s",
    distUnit = 1,
    distUnitLabel = "m",
    distUnitScale = 1,
    distUnitLong = 1,
    distUnitLongLabel = "km",
    distUnitLongScale = 0.001,
    language = "en",
    -- Map provider and rendering settings.
    mapProvider = 2, -- 1 = GMapCatcher, 2 = Google
    mapType = "Satellite",
    mapZoomLevel = 19,
    mapZoomMax = 20,
    mapZoomMin = 1,
    mapTrailResolution = 50, -- Trail waypoint distance in meters (0=off, 20, 50, 100, 500, 1000).
    mapTrailHeadingThreshold = 5, -- Minimum heading change (degrees) before committing a new trail waypoint.
    enableDebugLog = false,   -- Enables the on-device debug log.
    enablePerfProfile = false, -- Emits 5s performance summaries into debug.log.
    -- Telemetry source mode: 1 = ETHOS (hardcoded GPS), 2 = Sensors (user-assigned sources).
    -- "Sensors" mode is only available when debug logging is enabled.
    telemetrySourceMode = 1,
    sensorGpsLat = nil,    -- Source for GPS latitude (Sensors mode)
    sensorGpsLon = nil,    -- Source for GPS longitude (Sensors mode)
    sensorHeading = nil,   -- Source for heading/yaw (optional, nil = calculated from GPS)
    sensorSpeed = nil,     -- Source for ground speed (optional, nil = calculated from GPS)
    gpsFormat = 2, -- 2 = decimal, 1 = DMS
    uavSymbol = 1, -- 1 = Arrow, 2 = Airplane, 3 = Multirotor
    zoomControl = 0,  -- 0 = OFF (touch buttons), 1 = 3-POS switch, 2 = Proportional
    zoomChannel = 0,  -- RC channel number (1-64) for zoom input
    wpDownload = false,  -- Enable/disable INAV waypoint download and display
    -- Layout selection persisted for future layout variants.
    layout = 1,
  },

  -- Cached booleans derived from conf.enableDebugLog / conf.enablePerfProfile.
  -- Toggled once in applyConfig() and configure() callbacks so hot-path guards
  -- become a single boolean test instead of repeated flagEnabled() evaluations.
  debugEnabled = false,
  perfActive   = false,

  -- Layout module registry and shared lifecycle counters.
  layoutFilenames = { "layout_default" },
  counter = 0,

  -- Current screen bookkeeping and per-screen loaded layout modules.
  lastScreen = 1,
  loadCycle = 0,
  layout = { nil },

  -- Map state used for redraw throttling, trail updates, and debug logging.
  screenTogglePage = 1,
  mapZoomLevel = 19,
  lastLat = nil,
  lastLon = nil,
  mapLastLat = nil,   -- Dedicated to map redraw throttling so COG tracking can use its own history.
  mapLastLon = nil,
  mapLastZoom = 0,
  mapRedrawPending = false,
  mapTickSerial = 0,
  barTickSerial = 0,
  lastLoggedLat = 0,
  lastLoggedLon = 0,
  lastSelectionAutoFixKey = nil,
  cachedProviderChoices = nil,
  cachedMapTypeChoices = {},  -- keyed by provider
  consumeZoomRelease = false,
  menuOpenedAt = nil,        -- getTime() when menu() was called (event guard)

  -- Pan state for drag-to-pan (touch panning)
  panState = 0,             -- PAN_IDLE
  panLastX = 0,
  panLastY = 0,
  panOffsetX = 0,           -- Accumulated pixel offset from drag
  panOffsetY = 0,
  panAnchorPixelX = nil,    -- Absolute Mercator pixel X of UAV at pan start
  panAnchorPixelY = nil,    -- Absolute Mercator pixel Y of UAV at pan start
  lastPanOffsetX = nil,     -- Previous frame panOffsetX for delta-based lead
  lastPanOffsetY = nil,     -- Previous frame panOffsetY for delta-based lead
  panGraceEnd = 0,          -- getTime() timestamp when grace expires
  panLastTouchTime = 0,     -- getTime() timestamp of last touch event
  panDragEnabled = false,   -- true when at a fullscreen resolution
  zoomLimitMessageEnd = 0,  -- getTime() timestamp when "zoom limit" message disappears

  -- Zoom control via RC channel
  zoomControlTarget = nil,      -- Pending zoom level from channel input (nil = no change pending)
  zoomControlTimer = 0,         -- getTime() timestamp when target was last changed
  zoomControlLastDir = 0,       -- Last 3-POS direction (1=up, -1=down, 0=neutral) for edge detection
  cachedZoomChannelSrc = nil,   -- Cached system.getSource() for the zoom channel
  cachedZoomChannelNum = 0,     -- Channel number the cached source was created for

  -- Follow-lock toggle: when false the map stays detached from UAV GPS
  followLock = true,

  -- Observation marker: GPS position of user-placed pin (nil = no marker)
  observationLat = nil,
  observationLon = nil,

  -- MSP waypoint mission state (populated from msp.lua after download completes)
  mspMissions = {},       -- array of mission tables, each containing an ordered WP list
  mspMissionIdx = 1,      -- 1-based index of the currently displayed mission
  mspDownloadDone = false, -- true once mission data has been copied from msp lib
  mspArmedHomeSet = false, -- true once home was auto-set from arming detection
  mspNavMode = 0,         -- navSystemStatus_Mode_e: 0=NONE 1=HOLD 2=RTH 3=NAV
  mspActiveWp = 0,        -- FC's currently active WP index (1-based)

  avgSpeed = {
    lastSampleTime = nil,
    avgTravelDist = 0,
    avgTravelTime = 0,
    travelDist = 0,
    value = 0,
  },

  -- GPS staleness detection: telemetry is considered lost when lat/lon stop
  -- changing for GPS_STALE_TIMEOUT centiseconds (5 s).
  telemetryLost = false,
  _lastGpsLat = nil,        -- Last observed lat value for change detection
  _lastGpsLon = nil,        -- Last observed lon value for change detection
  _lastGpsChangeTime = 0,   -- getTime() when lat or lon last changed

  -- Optional top bar telemetry sources selected by the user.
  linkQualitySource = nil,
  userSensor1 = nil,
  userSensor2 = nil,
  userSensor3 = nil,

  -- Shared blink state consumed by drawing helpers.
  blinkon = false,

  -- Shared lookup tables and UI colors used across libraries.
  unitConversion = {},
  battPercByVoltage = {},
  colors = {
    white = WHITE,
    red = RED,
    green = GREEN,
    black = BLACK,
    yellow = lcd.RGB(255,206,0),
    warningYellow = lcd.RGB(255, 220, 0),
    labelGray = lcd.RGB(170,170,170),
    observationGreen = lcd.RGB(0, 200, 0),
    semiBlack45 = lcd.RGB(0, 0, 0, 0.45),
    semiBlack60 = lcd.RGB(0, 0, 0, 0.6),
    loadingOverlay = lcd.RGB(20, 20, 20),
    panelLabel = lcd.RGB(150,150,150),
    panelText = lcd.RGB(255,255,255),
    panelBackground = lcd.RGB(56,60,56),
    barBackground = BLACK,
    barText = WHITE,
    hudSky = lcd.RGB(123,157,255),
    hudTerrain = lcd.RGB(100,185,95),
    hudDashes = lcd.RGB(250, 205, 205),
    hudLines = lcd.RGB(220, 220, 220),
    hudSideText = lcd.RGB(0,238,49),
    hudText = lcd.RGB(255,255,255),
    rpmBar = lcd.RGB(240,192,0),
    background = lcd.RGB(60, 60, 60)
  },

  -- ETHOS version and hardware info cached once at widget creation via system.getVersion().
  ethosVersion = nil,  -- { major, minor, revision, board, lcdWidth, lcdHeight, ... }

  -- Current widget dimensions and scale factors propagated to layouts and libraries.
  widgetWidth = 800,
  widgetHeight = 480,
  scaleX = 1.0,
  scaleY = 1.0,
  widget = nil,
  compactWidthThreshold = 450,
  tinyWidthThreshold = 350,
  tinyHeightThreshold = 190,
  verticalMedium = false,
  sessionLogged = false,

  perfProfile = {
    windowMs = 5000,
    windowStartMs = 0,
    metrics = {},
    counters = {},
  },
}

-- Performance profiler helper functions (must be defined before paint/wakeup/event use them).
local function perfNowMs()
  return os_clock() * 1000
end

local function perfWindowNowMs()
  -- Use wall-clock seconds for window scheduling; os.clock() is CPU-time and can stall under low load.
  local wallSec = os_time()
  if type(wallSec) == "number" and wallSec > 0 then
    return wallSec * 1000
  end
  -- Fallback to widget timer when RTC is unavailable.
  return getTime() * 10
end

-- Dedicated perf window timer state, independent from mutable config/status tables.
local perfWindowStartMs = nil

-- Map redraws at full wakeup speed for responsive tile fill and reliable touch event delivery.
-- Bars update at ~1s intervals since telemetry values change slowly.
local frameWakeupCount = 0
local scheduledRenderCount = 0
local lastBarTickCs = 0
local BAR_TICK_INTERVAL_CS = 100  -- centiseconds (1 second)

-- markMapDirty() is defined after mapLibs declaration (see below line ~480)
-- so the closure can capture the local mapLibs table.

local function resolveWidget(widget)
  -- ETHOS can invoke callbacks with a nil widget in some contexts (non-fullscreen,
  -- background scheduling). Keep the last valid instance as fallback so wakeup/paint
  -- continue to run.
  if widget ~= nil then
    mapStatus.widget = widget
    return widget
  end
  return mapStatus.widget
end

local function perfEnsureMetric(metricName)
  local metrics = mapStatus.perfProfile.metrics
  local metric = metrics[metricName]
  if metric == nil then
    metric = { sum = 0, count = 0, max = 0 }
    metrics[metricName] = metric
  end
  return metric
end

local function perfAddMs(metricName, elapsedMs)
  if not mapStatus.perfActive then
    return
  end
  if type(elapsedMs) ~= "number" then
    return
  end
  if elapsedMs < 0 then
    elapsedMs = 0
  end
  local metric = perfEnsureMetric(metricName)
  metric.sum = metric.sum + elapsedMs
  metric.count = metric.count + 1
  if elapsedMs > metric.max then
    metric.max = elapsedMs
  end
  if metric.min == nil or elapsedMs < metric.min then
    metric.min = elapsedMs
  end
end

local function perfInc(counterName, delta)
  if not mapStatus.perfActive then
    return
  end
  if mapStatus.perfProfile.counters[counterName] == nil then
    mapStatus.perfProfile.counters[counterName] = 0
  end
  mapStatus.perfProfile.counters[counterName] = mapStatus.perfProfile.counters[counterName] + (delta or 1)
end

local function perfResetWindow(nowMs)
  mapStatus.perfProfile.metrics = {}
  mapStatus.perfProfile.counters = {}
  perfWindowStartMs = nowMs
  mapStatus.perfProfile.windowStartMs = nowMs
end

local function perfMetricAvg(metricName)
  local metric = mapStatus.perfProfile.metrics[metricName]
  if metric == nil or metric.count == 0 then
    return 0
  end
  return metric.sum / metric.count
end

local function perfValueText(value, decimals)
  local scale = 10 ^ (decimals or 0)
  return tostring(floor(value * scale + 0.5) / scale)
end

local function perfTableCell(label, value)
  return fmt("%-16s", label .. "=" .. tostring(value))
end

local function perfTableRow(rowLabel, firstCell, secondCell, thirdCell)
  return fmt("| %-8s | %-16s | %-16s | %-16s |", rowLabel, firstCell, secondCell, thirdCell)
end

-- Export performance profiler callbacks to mapStatus so libraries can access them.
mapStatus.perfProfileInc = perfInc
mapStatus.perfProfileAddMs = perfAddMs

-- Maps exported source names to default values, formatting metadata, and the telemetry field they mirror.
mapStatus.luaSourcesConfig = {}
mapStatus.luaSourcesConfig.HomeDistance =  {0, 0, UNIT_METER, "homeDist", 1}
mapStatus.luaSourcesConfig.CourseOverGround =  {0, 0, UNIT_DEGREE, "cog", 1}
mapStatus.luaSourcesConfig.GroundSpeed =  {0, 1, UNIT_METER_PER_SECOND, "groundSpeed", 1}

local function makeSourceWakeup(sourceName)
  -- Returns a wakeup callback bound to a single source config entry to avoid relying on source:name() at runtime.
  return function(source)
    if source == nil or type(source.value) ~= "function" then
      return
    end

    local cfg = mapStatus.luaSourcesConfig[sourceName]
    if cfg == nil then
      pcall(function() source:value(0) end)
      return
    end

    local telemetryField = cfg[4]
    local scale = cfg[5] or 1
    local decimals = cfg[2] or 0
    local telemetryValue = tonumber(mapStatus.telemetry[telemetryField])
    if telemetryValue == nil then
      pcall(function() source:value(0) end)
      return
    end

    local out = telemetryValue * scale
    if decimals == 0 then
      out = floor(0.5 + out)
    end
    pcall(function() source:value(out) end)
  end
end

local function makeSourceInit(sourceName)
  -- Returns an init callback bound to a single source config entry and applies stable defaults.
  return function(source)
    if source == nil then
      return
    end

    local cfg = mapStatus.luaSourcesConfig[sourceName]
    if cfg == nil then
      if type(source.value) == "function" then
        pcall(function() source:value(0) end)
      end
      return
    end

    if type(source.value) == "function" then
      pcall(function() source:value(cfg[1] or 0) end)
    end
    if type(source.decimals) == "function" then
      pcall(function() source:decimals(cfg[2] or 0) end)
    end
    if type(source.unit) == "function" then
      pcall(function() source:unit(cfg[3]) end)
    end
  end
end

local mspStateNames = { [0]="OFF", "CONNECTING", "GET_VERSION", "GET_WP_INFO", "DOWNLOADING", "DONE", "ERROR" }

local mapLibs = {
  drawLib    = nil,
  resetLib   = nil,
  tileLoader = nil,
  mapLib     = nil,
  compute    = nil,
  utils      = nil,
  msp        = nil,
}

local function markMapDirty()
  mapStatus.mapRedrawPending = true
  if mapLibs and mapLibs.compute then
    mapLibs.compute.setDirty("needsWpProjection")
    mapLibs.compute.setDirty("needsTrailProjection")
    mapLibs.compute.setDirty("needsTileGrid")
  end
end

function loadLib(name)
  -- Loads a library module from disk, injects shared state through init(), and returns the initialized library table.
  local lib = dofile("/scripts/ethosmaps/lib/"..name..".lua")
  if lib.init ~= nil then
    lib.init(mapStatus, mapLibs)
  end
  return lib
end

local function initLibs()
  -- Lazily loads shared libraries once and stores them in mapLibs for later callbacks.
  -- tileLoader must be loaded before mapLib so mapLib can reference libs.tileLoader.
  if mapLibs.utils == nil then mapLibs.utils = loadLib("utils") end
  if mapLibs.drawLib == nil then mapLibs.drawLib = loadLib("drawlib") end
  if mapLibs.resetLib == nil then mapLibs.resetLib = loadLib("resetLib") end
  if mapLibs.tileLoader == nil then mapLibs.tileLoader = loadLib("tileloader") end
  if mapLibs.mapLib == nil then mapLibs.mapLib = loadLib("maplib") end
  if mapLibs.compute == nil then mapLibs.compute = loadLib("compute") end
  if mapLibs.msp == nil then mapLibs.msp = loadLib("msp") end
end

local function checkSize(widget)
  -- Refreshes widget dimensions from the active LCD window and writes the derived scale back into mapStatus.
  local w, h = lcd.getWindowSize()
  mapStatus.widgetWidth = w
  mapStatus.widgetHeight = h
  mapStatus.scaleX = w / 800
  mapStatus.scaleY = h / 480
  mapStatus.verticalMedium = w < (mapStatus.compactWidthThreshold or 450)

  -- Enable panning when widget fills the full LCD width and at least 90% of its height
  -- (the widget title bar can reduce height by a few rows).
  local ev = mapStatus.ethosVersion
  local wasPanEnabled = mapStatus.panDragEnabled
  if ev and ev.lcdWidth and ev.lcdHeight then
    mapStatus.panDragEnabled = (w >= ev.lcdWidth) and (h >= floor(ev.lcdHeight * PAN_HEIGHT_TOLERANCE))
  else
    mapStatus.panDragEnabled = false
  end

  -- When panning becomes unavailable (e.g. layout switched from fullscreen to widget),
  -- re-lock follow mode so the map tracks the UAV again.
  if wasPanEnabled and not mapStatus.panDragEnabled then
    mapStatus.followLock = true
    mapStatus.panState = PAN_IDLE
  end

  return true
end

local function createOnce(widget)
  -- Marks a widget instance as ready for background processing after the first valid lifecycle callback.
  widget.runBgTasks = true

  -- Start MSP here (not in create()) because ETHOS calls create() BEFORE read().
  -- In create(), mapStatus.conf.wpDownload is still at its default (false), so
  -- msp.open() would incorrectly start in armingOnly mode.  By the time wakeup()
  -- fires createOnce(), read() has already loaded the persisted settings.
  if mapLibs and mapLibs.msp then
    local armOnly = not mapStatus.conf.wpDownload
    mapLibs.msp.open({ armingOnly = armOnly })
  end
end

local function reset(widget)
  -- Delegates a user-triggered reset to resetLib so layouts and cached map data are rebuilt.
  if mapLibs and mapLibs.mapLib and mapLibs.mapLib.clearTrail then
    mapLibs.mapLib.clearTrail()
  end
  -- Clear cached missions and re-download from FC
  if mapLibs and mapLibs.msp then
    mapStatus.mspMissions = {}
    mapStatus.mspMissionIdx = 1
    mapStatus.mspDownloadDone = false
    mapStatus.mspArmedHomeSet = false
    mapStatus.mspNavMode = 0
    mapStatus.mspActiveWp = 0
    local armOnly = not mapStatus.conf.wpDownload
    mapLibs.msp.open({ armingOnly = armOnly })
  end
  mapLibs.resetLib.reset(widget)
  markMapDirty()
end

local function loadLayout(widget)
  -- Draws a temporary loading overlay, then loads the layout module for the current screen into mapStatus.layout.
  lcd.pen(SOLID)
  lcd.color(mapStatus.colors.loadingOverlay)
  lcd.drawFilledRectangle(mapStatus.widgetWidth/4, mapStatus.widgetHeight/4, mapStatus.widgetWidth/2, mapStatus.widgetHeight/4)
  lcd.color(mapStatus.colors.white)
  lcd.drawRectangle(mapStatus.widgetWidth/4, mapStatus.widgetHeight/4, mapStatus.widgetWidth/2, mapStatus.widgetHeight/4,3)
  lcd.color(mapStatus.colors.white)
  lcd.font(FONT_XXL)
  lcd.drawText(mapStatus.widgetWidth/2, mapStatus.widgetHeight/2, "loading layout...", CENTERED)

  if mapStatus.layout[widget.screen] == nil then
    mapStatus.layout[widget.screen] = loadLib(mapStatus.layoutFilenames[widget.screen])
  end
  widget.ready = true
end

mapStatus.blinkTimer = getTime()
local bgclock = 0
local cachedGpsSrcLat = nil
local cachedGpsSrcLon = nil

local function bgtasks(widget)
  -- Collects telemetry from Ethos sources, derives navigation values, and writes the updated state back into mapStatus.
  local now = getTime()
  -- Re-emit session header if it was skipped (e.g. after a log rollover or a failed first attempt).
  if not mapStatus.sessionLogged then
    logDebugSessionStart("bgtasks-retry")
  end
  local conf = mapStatus.conf
  local telemetry = mapStatus.telemetry
  local avgSpeed = mapStatus.avgSpeed
  local gpsLat, gpsLon = nil, nil
  local sensorHeadingActive = false
  local sensorSpeedActive = false
  if conf.telemetrySourceMode == 2 then
    -- Sensors mode: read from user-assigned sources.
    local srcLat = conf.sensorGpsLat
    local srcLon = conf.sensorGpsLon
    local srcLatType = type(srcLat)
    local srcLonType = type(srcLon)
    if (srcLatType == "userdata" or srcLatType == "table") and type(srcLat.value) == "function" then
      local ok, v = pcall(srcLat.value, srcLat)
      if ok then gpsLat = v end
    end
    if (srcLonType == "userdata" or srcLonType == "table") and type(srcLon.value) == "function" then
      local ok, v = pcall(srcLon.value, srcLon)
      if ok then gpsLon = v end
    end
    -- Optional heading source → telemetry.yaw (overrides calculated COG).
    local srcHdg = conf.sensorHeading
    local srcHdgType = type(srcHdg)
    if (srcHdgType == "userdata" or srcHdgType == "table") and type(srcHdg.value) == "function" then
      local hdg = srcHdg:value()
      if hdg ~= nil and hdg ~= 0 then
        telemetry.yaw = hdg
        sensorHeadingActive = true
      end
    end
    -- Optional speed source → telemetry.groundSpeed (overrides calculated speed).
    local srcSpd = conf.sensorSpeed
    local srcSpdType = type(srcSpd)
    if (srcSpdType == "userdata" or srcSpdType == "table") and type(srcSpd.value) == "function" then
      local spd = srcSpd:value()
      if spd ~= nil and spd ~= 0 then
        telemetry.groundSpeed = spd
        sensorSpeedActive = true
      end
    end
  else
    -- ETHOS mode: hardcoded GPS source (cached to avoid per-cycle allocations).
    if cachedGpsSrcLat == nil then
      cachedGpsSrcLat = system.getSource({name="GPS", options=OPTION_LATITUDE})
    end
    if cachedGpsSrcLon == nil then
      cachedGpsSrcLon = system.getSource({name="GPS", options=OPTION_LONGITUDE})
    end
    if cachedGpsSrcLat then
      local ok, v = pcall(cachedGpsSrcLat.value, cachedGpsSrcLat)
      if ok then gpsLat = v end
    end
    if cachedGpsSrcLon then
      local ok, v = pcall(cachedGpsSrcLon.value, cachedGpsSrcLon)
      if ok then gpsLon = v end
    end
  end

  -- GPS source diagnostics (throttled to once per 10s)
  if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
    if not mapStatus._gpsDbgTime or (now - mapStatus._gpsDbgTime) > 1000 then
      mapStatus._gpsDbgTime = now
      mapLibs.utils.logDebug("GPS_SRC", fmt("mode=%d gpsLat=%s gpsLon=%s",
          conf.telemetrySourceMode or 0,
          tostring(gpsLat), tostring(gpsLon)), true)
    end
  end

  if gpsLat ~= nil and gpsLon ~= nil then
    telemetry.lat = gpsLat
    telemetry.lon = gpsLon

    -- GPS staleness: track whether coordinates actually changed.
    if gpsLat ~= mapStatus._lastGpsLat or gpsLon ~= mapStatus._lastGpsLon then
      mapStatus._lastGpsLat = gpsLat
      mapStatus._lastGpsLon = gpsLon
      mapStatus._lastGpsChangeTime = now
      mapStatus.telemetryLost = false
    elseif mapStatus._lastGpsChangeTime ~= 0 and (now - mapStatus._lastGpsChangeTime) > GPS_STALE_TIMEOUT then
      mapStatus.telemetryLost = true
    end

    -- Log GPS position at most once every 15 seconds to avoid flooding the debug log.
    if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
      local lat = telemetry.lat or 0
      local lon = telemetry.lon or 0
      local gpsLogInterval = 1500 -- centiseconds (15 seconds)
      if now - (mapStatus.lastGpsLogTime or 0) >= gpsLogInterval then
        mapLibs.utils.logDebug("GPS", fmt("lat=%.6f lon=%.6f", lat, lon))
        mapStatus.lastGpsLogTime = now
        mapStatus.lastLoggedLat = lat
        mapStatus.lastLoggedLon = lon
      end
    end
  end

  if telemetry.lat ~= nil and telemetry.lon ~= nil then
    if avgSpeed.lastLat == nil or avgSpeed.lastLon == nil then
      avgSpeed.lastLat = telemetry.lat
      avgSpeed.lastLon = telemetry.lon
      avgSpeed.lastSampleTime = now
    end

    if now - avgSpeed.lastSampleTime > 100 then
      local travelDist = mapLibs.utils.haversine(telemetry.lat, telemetry.lon, avgSpeed.lastLat, avgSpeed.lastLon)
      local travelTime = now - avgSpeed.lastSampleTime
      -- Only derive speed from GPS deltas when no external speed source provided a value.
      if not sensorSpeedActive and travelDist < 10000 then
        avgSpeed.avgTravelDist = avgSpeed.avgTravelDist * 0.8 + travelDist*0.2
        avgSpeed.avgTravelTime = avgSpeed.avgTravelTime * 0.8 + 0.01 * travelTime * 0.2
        avgSpeed.value = avgSpeed.avgTravelDist/avgSpeed.avgTravelTime
        avgSpeed.travelDist = avgSpeed.travelDist + avgSpeed.avgTravelDist
        telemetry.groundSpeed = avgSpeed.value
      end
      avgSpeed.lastLat = telemetry.lat
      avgSpeed.lastLon = telemetry.lon
      avgSpeed.lastSampleTime = now

      if telemetry.homeLat ~= nil and telemetry.homeLon ~= nil then
        telemetry.homeDist = mapLibs.utils.haversine(telemetry.lat, telemetry.lon, telemetry.homeLat, telemetry.homeLon)
        telemetry.homeAngle = mapLibs.utils.getAngleFromLatLon(telemetry.lat, telemetry.lon, telemetry.homeLat, telemetry.homeLon)
      end
    end
  end

  if bgclock % 4 == 2 then
    if telemetry.lat ~= nil and telemetry.lon ~= nil then
      if conf.gpsFormat == 1 then
        telemetry.strLat = mapLibs.utils.decToDMSFull(telemetry.lat)
        telemetry.strLon = mapLibs.utils.decToDMSFull(telemetry.lon, telemetry.lat)
      else
        telemetry.strLat = fmt("%.06f", telemetry.lat)
        telemetry.strLon = fmt("%.06f", telemetry.lon)
      end
    end
    -- Only derive COG from GPS movement when no external heading source provided a value.
    if not sensorHeadingActive then
      mapLibs.utils.updateCog()
      -- Sync yaw from cog so displays reading (yaw or cog) show the calculated heading.
      if telemetry.cog then
        telemetry.yaw = telemetry.cog
      end
    end
  end

  if now - mapStatus.blinkTimer > 60 then
    mapStatus.blinkon = not mapStatus.blinkon
    mapStatus.blinkTimer = now
  end
  bgclock = (bgclock%4)+1
end

local function gpsDataAvailable(lat,lon)
  -- Validates a GPS fix before map and overlay code consume the coordinates.
  return lat ~= nil and lon ~= nil and lat ~= 0 and lon ~= 0
end

local function paintInner(widget)
  -- Clears the widget area and routes drawing to the active layout using the latest shared state.
  local perfActive = mapStatus.perfActive
  local perfStartMs = nil
  if perfActive then
    perfStartMs = perfNowMs()
    perfInc("paint_calls", 1)
  end
  widget = resolveWidget(widget)
  if not widget then return end -- Safeguard: Ethos can call paint before a widget instance is fully available.
  lcd.color(mapStatus.colors.background)
  lcd.pen(SOLID)
  lcd.drawFilledRectangle(0, 0, mapStatus.widgetWidth, mapStatus.widgetHeight)

  if mapStatus.lastScreen ~= widget.screen then
    mapStatus.lastScreen = widget.screen
  end

  local sizeOk = checkSize(widget)
  if not sizeOk then return end

  if not widget.ready then
    loadLayout(widget)
  else
    if mapStatus.layout[widget.screen] ~= nil then
      local drawStartMs = nil
      if perfActive then
        drawStartMs = perfNowMs()
      end
      mapStatus.layout[widget.screen].draw(widget)
      if perfActive then
        perfAddMs("layout_draw_ms", perfNowMs() - drawStartMs)
      end
    else
      loadLayout(widget)
    end
  end

  if mapStatus.followLock and not gpsDataAvailable(mapStatus.telemetry.lat, mapStatus.telemetry.lon) then
    mapLibs.drawLib.drawNoGPSData(widget)
  end
  if perfActive then
    local paintElapsedMs = perfNowMs() - perfStartMs
    perfAddMs("paint_total_ms", paintElapsedMs)
    if paintElapsedMs >= 100 then
      perfInc("long_frame_count_100ms", 1)
    end
    if paintElapsedMs >= 200 then
      perfInc("long_frame_count_200ms", 1)
    end
  end
end

local function paint(widget)
  local ok, err = pcall(paintInner, widget)
  if not ok then
    -- Release per-instance viewport context if drawMap threw mid-execution.
    if mapLibs and mapLibs.mapLib and mapLibs.mapLib.deactivateVpCtx then
      mapLibs.mapLib.deactivateVpCtx()
    end
    if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
      mapLibs.utils.logDebug("PAINT", "pcall ERROR: " .. tostring(err), true)
    end
  end
end

-- ── File-based runtime state persistence ─────────────────────────────────
-- Runtime state that changes during normal operation (zoom level, observation
-- marker, default position) is stored in a plain-text file on the SD card
-- instead of ETHOS widget storage.  This avoids the limited widget storage
-- buffer (see ETHOS issue #5462) and eliminates the risk of corrupting the
-- configure()-managed settings when out-of-band storage.write() calls shift
-- the positional slot counter.
local STATE_FILE_PATH = "/scripts/ethosmaps/state.dat"

local function writeStateFile()
  -- Persists volatile runtime state to a file so it survives radio restarts.
  -- Merge strategy: read existing file first, then only overwrite keys that
  -- have a non-nil in-memory value.  This prevents write() calls (e.g. from
  -- ETHOS settings dismiss or page-switch) from clobbering state.dat with
  -- nil values when the in-memory state hasn't been fully restored yet.
  local ok, err = pcall(function()
    -- Read existing state first (merge base)
    local existing = {}
    local rf = io.open(STATE_FILE_PATH, "r")
    if rf then
      local line = rf:read("*line")
      while line do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k and v ~= "nil" then
          existing[k] = v
        end
        line = rf:read("*line")
      end
      rf:close()
    end

    -- Merge: in-memory value wins when non-nil, otherwise keep existing
    local function merged(key, memVal)
      if memVal ~= nil then return tostring(memVal) end
      return existing[key]  -- may be nil → written as "nil"
    end

    local f = io.open(STATE_FILE_PATH, "w")
    if not f then
      if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
        mapLibs.utils.logDebug("STATE", "writeStateFile: io.open(w) FAILED for " .. STATE_FILE_PATH, true)
      end
      return
    end
    local function w(key, val)
      if val == nil then
        f:write(key .. "=nil\n")
      else
        f:write(key .. "=" .. tostring(val) .. "\n")
      end
    end
    w("version", WIDGET_VERSION)
    w("mapZoomLevel", mapStatus.mapZoomLevel)
    w("observationLat", merged("observationLat", mapStatus.observationLat))
    w("observationLon", merged("observationLon", mapStatus.observationLon))
    w("defaultLat", merged("defaultLat", mapStatus.conf.defaultLat))
    w("defaultLon", merged("defaultLon", mapStatus.conf.defaultLon))
    f:close()
  end)
  if not ok and err then
    if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
      mapLibs.utils.logDebug("STATE", "writeStateFile pcall ERROR: " .. tostring(err), true)
    end
  end
end

local function readStateFile()
  -- Restores volatile runtime state from the file.  Returns a table of
  -- key→string pairs, or nil if the file does not exist or cannot be read.
  local ok, result = pcall(function()
    local f = io.open(STATE_FILE_PATH, "r")
    if not f then
      if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
        mapLibs.utils.logDebug("STATE", "readStateFile: io.open FAILED (file missing?)", true)
      end
      return nil
    end
    local data = {}
    local line = f:read("*line")
    while line do
      local k, v = line:match("^([^=]+)=(.*)$")
      if k and v ~= "nil" then
        data[k] = v
      end
      line = f:read("*line")
    end
    f:close()
    return data
  end)
  if ok then return result end
  return nil
end

local function event(widget, category, value, x, y)
  -- Handles touch input: zoom buttons and drag-to-pan state machine.
  local perfActive = mapStatus.perfActive
  local perfStartMs = nil
  if perfActive then
    perfStartMs = perfNowMs()
  end
  widget = resolveWidget(widget)

  if category == EVT_TOUCH and x ~= nil and y ~= nil then
    -- Menu guard: while the ETHOS popup menu is open, pass all touch events
    -- through so the pan state machine doesn't consume menu scroll/tap events.
    -- Cleared when a menu callback fires; 3-second safety timeout in case the
    -- user dismisses the menu without selecting an item.
    if mapStatus.menuOpenedAt then
      if (getTime() - mapStatus.menuOpenedAt) > 300 then
        mapStatus.menuOpenedAt = nil  -- safety timeout (3 s)
      else
        return false
      end
    end

    if perfActive then
      perfInc("touch_events", 1)
    end
    local w, h = lcd.getWindowSize()
    if w ~= nil and h ~= nil and w > 0 and h > 0 then
      mapStatus.widgetWidth = w
      mapStatus.widgetHeight = h
      mapStatus.scaleX = w / 800
      mapStatus.scaleY = h / 480
    end

    -- Button geometry (same as layout_default.lua)
    local scaleFactor = 0.15 + 0.8 * mapStatus.scaleX
    local btnSize = floor(52 * scaleFactor)
    local btnX = 12 * mapStatus.scaleX
    local ultraTiny =
      (mapStatus.widgetWidth < (mapStatus.tinyWidthThreshold or 350)) and
      (mapStatus.widgetHeight < (mapStatus.tinyHeightThreshold or 190))

    local btnYPlus, btnYMinus
    if ultraTiny then
      local edgeMargin = btnX
      btnYPlus = edgeMargin
      btnYMinus = mapStatus.widgetHeight - btnSize - edgeMargin
    else
      btnYPlus = 0.27 * mapStatus.widgetHeight
      btnYMinus = mapStatus.widgetHeight - 0.27 * mapStatus.widgetHeight - btnSize
    end

    local touchPadding
    if ultraTiny then
      local maxUltraPadding = floor((mapStatus.widgetHeight - 2 * (btnSize + btnX)) / 2) - 1
      if maxUltraPadding < 0 then maxUltraPadding = 0 end
      touchPadding = min(12, maxUltraPadding)
    else
      touchPadding = 20
    end

    local touchSize = btnSize + 2 * touchPadding
    local plusLeft = btnX - touchPadding
    local plusTop  = btnYPlus - touchPadding
    local minusLeft = btnX - touchPadding
    local minusTop  = btnYMinus - touchPadding

    local hitPlus, hitMinus
    if mapStatus.conf.zoomControl == 0 then
      hitPlus  = mapLibs.drawLib.isInside(x, y, plusLeft, plusTop, plusLeft + touchSize, plusTop + touchSize)
      hitMinus = mapLibs.drawLib.isInside(x, y, minusLeft, minusTop, minusLeft + touchSize, minusTop + touchSize)
    else
      hitPlus  = false
      hitMinus = false
    end

    -- Follow-lock button: right side, vertically centered
    local lockBtnX = mapStatus.widgetWidth - btnX - btnSize
    local lockBtnY = floor((mapStatus.widgetHeight - btnSize) / 2)
    local lockLeft = lockBtnX - touchPadding
    local lockTop  = lockBtnY - touchPadding
    local hitLock  = mapStatus.panDragEnabled
      and mapLibs.drawLib.isInside(x, y, lockLeft, lockTop, lockLeft + touchSize, lockTop + touchSize)

    -- Pin button: right side at zoom+ height (only active when unlocked)
    local pinBtnX = lockBtnX
    local pinBtnY = btnYPlus
    local pinLeft = pinBtnX - touchPadding
    local pinTop  = pinBtnY - touchPadding
    local hitPin  = mapStatus.panDragEnabled and not mapStatus.followLock
      and mapLibs.drawLib.isInside(x, y, pinLeft, pinTop, pinLeft + touchSize, pinTop + touchSize)

    -- Resolve overlap: pin and lock hit areas can overlap vertically.
    -- When both match, prefer pin (it is only visible when unlocked, so
    -- the user's intent is almost certainly the pin button).
    if hitPin and hitLock then
      hitLock = false
    end

    -- Drag zone: full width minus the left button column.
    -- Right edge reserved for future follow button (same width as zoom column).
    -- Top/bottom 10% excluded so menu/swipe gestures are not intercepted.
    local btnColumnW = btnX + btnSize + touchPadding
    local dragMarginY = floor(mapStatus.widgetHeight * 0.15)
    local inDragZone = mapStatus.panDragEnabled
      and x > btnColumnW
      and x < (mapStatus.widgetWidth - btnColumnW)
      and y > dragMarginY
      and y < (mapStatus.widgetHeight - dragMarginY)

    local panState = mapStatus.panState

    -- ═══════════════════════════════════════════════════════════
    -- PAN STATE MACHINE
    -- ═══════════════════════════════════════════════════════════

    -- TOUCH_END (16641)
    if value == 16641 then
      if panState == PAN_PENDING then
        -- END without SLIDE = tap. Let ETHOS handle it (widget menu).
        mapStatus.panState = PAN_IDLE
        if mapStatus.followLock then
          -- Locked mode: full reset
          mapStatus.panOffsetX = 0
          mapStatus.panOffsetY = 0
          mapStatus.panAnchorPixelX = nil
          mapStatus.panAnchorPixelY = nil
          mapStatus.lastPanOffsetX = nil
          mapStatus.lastPanOffsetY = nil
        end
        -- Detached mode: keep panOffset/panAnchor so viewport stays put
        if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
          mapLibs.utils.logDebug("PAN", "TAP_DETECTED -> IDLE", true)
        end
        return false  -- pass to ETHOS

      elseif panState == PAN_DRAGGING then
        -- Finger up during drag -> GRACE
        mapStatus.panState = PAN_GRACE
        mapStatus.panGraceEnd = getTime() + PAN_GRACE_DURATION_CS
        if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
          mapLibs.utils.logDebug("PAN", "TOUCH_END -> GRACE", true)
        end
        system.killEvents(value)
        return true
      end

      -- IDLE/GRACE: consume if it was a zoom/lock/pin release, otherwise pass through
      if mapStatus.consumeZoomRelease or hitPlus or hitMinus or hitLock or hitPin then
        mapStatus.consumeZoomRelease = false
        system.killEvents(value)
        return true
      end
      return false
    end

    -- TOUCH_SLIDE (16642)
    if value == 16642 then
      mapStatus.panLastTouchTime = getTime()

      if panState == PAN_PENDING then
        -- First SLIDE after FIRST → drag confirmed
        mapStatus.panState = PAN_DRAGGING
        local dx = x - mapStatus.panLastX
        local dy = y - mapStatus.panLastY
        mapStatus.panOffsetX = mapStatus.panOffsetX + dx
        mapStatus.panOffsetY = mapStatus.panOffsetY + dy
        mapStatus.panLastX = x
        mapStatus.panLastY = y
        if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
          mapLibs.utils.logDebug("PAN", fmt("DRAG_START dx=%d dy=%d", dx, dy), true)
        end
        system.killEvents(value)
        return true

      elseif panState == PAN_DRAGGING then
        -- Continue drag
        local dx = x - mapStatus.panLastX
        local dy = y - mapStatus.panLastY
        mapStatus.panOffsetX = mapStatus.panOffsetX + dx
        mapStatus.panOffsetY = mapStatus.panOffsetY + dy
        mapStatus.panLastX = x
        mapStatus.panLastY = y
        system.killEvents(value)
        return true

      elseif panState == PAN_GRACE then
        -- SLIDE during grace → resume drag directly
        mapStatus.panState = PAN_DRAGGING
        mapStatus.panLastX = x
        mapStatus.panLastY = y
        if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
          mapLibs.utils.logDebug("PAN", "GRACE_SLIDE -> DRAGGING", true)
        end
        system.killEvents(value)
        return true
      end

      -- IDLE + SLIDE: not our concern
      return false
    end

    -- TOUCH_FIRST (16640)
    if value == 16640 then
      mapStatus.panLastTouchTime = getTime()

      -- Follow-lock toggle button
      if hitLock then
        if mapStatus.followLock then
          -- Unlock: switch to detached mode
          mapStatus.followLock = false
        else
          -- Re-lock: snap back to UAV GPS position
          mapStatus.followLock = true
          mapStatus.panState = PAN_IDLE
          mapStatus.panOffsetX = 0
          mapStatus.panOffsetY = 0
          mapStatus.panAnchorPixelX = nil
          mapStatus.panAnchorPixelY = nil
          mapStatus.lastPanOffsetX = nil
          mapStatus.lastPanOffsetY = nil
          markMapDirty()
        end
        mapStatus.consumeZoomRelease = true
        if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
          mapLibs.utils.logDebug("TOUCH", ">>> FOLLOW LOCK " .. (mapStatus.followLock and "ON" or "OFF") .. " <<<", true)
        end
        system.killEvents(value)
        if perfActive then perfAddMs("event_total_ms", perfNowMs() - perfStartMs) end
        return true
      end

      -- Observation marker pin button (only when unlocked)
      if hitPin then
        if mapStatus.observationLat ~= nil then
          -- Remove existing marker
          mapStatus.observationLat = nil
          mapStatus.observationLon = nil
        else
          -- Place marker at current viewport center
          local anchorX = mapStatus.panAnchorPixelX
          local anchorY = mapStatus.panAnchorPixelY
          if anchorX ~= nil and anchorY ~= nil and mapLibs.mapLib.pixel_to_coord then
            local vcPixelX = anchorX - (mapStatus.panOffsetX or 0)
            local vcPixelY = anchorY - (mapStatus.panOffsetY or 0)
            local lat, lon = mapLibs.mapLib.pixel_to_coord(vcPixelX, vcPixelY, mapStatus.mapZoomLevel)
            mapStatus.observationLat = lat
            mapStatus.observationLon = lon
          else
            if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
              mapLibs.utils.logDebug("TOUCH", fmt("PIN SET FAILED: anchorX=%s anchorY=%s pixel_to_coord=%s",
                tostring(anchorX), tostring(anchorY), tostring(mapLibs.mapLib.pixel_to_coord ~= nil)), true)
            end
          end
        end
        -- Persist immediately
        writeStateFile()
        mapStatus.consumeZoomRelease = true
        markMapDirty()
        if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
          if mapStatus.observationLat then
            mapLibs.utils.logDebug("TOUCH", fmt(">>> OBSERVATION MARKER SET lat=%.6f lon=%.6f <<<", mapStatus.observationLat, mapStatus.observationLon), true)
          else
            mapLibs.utils.logDebug("TOUCH", ">>> OBSERVATION MARKER CLEARED <<<", true)
          end
        end
        system.killEvents(value)
        if perfActive then perfAddMs("event_total_ms", perfNowMs() - perfStartMs) end
        return true
      end

      -- Zoom buttons always take priority
      if hitMinus then
        if (tonumber(mapStatus.mapZoomLevel) or 1) <= (tonumber(mapStatus.conf.mapZoomMin) or 1) then
          -- Already at min zoom — consume event, show message, don't recenter
          mapStatus.zoomLimitMessageEnd = getTime() + 200  -- 2 seconds
          if panState == PAN_GRACE then
            mapStatus.panGraceEnd = getTime() + PAN_GRACE_DURATION_CS
          end
          mapStatus.consumeZoomRelease = true
          system.killEvents(value)
          if perfActive then perfAddMs("event_total_ms", perfNowMs() - perfStartMs) end
          return true
        end
        mapStatus.mapZoomLevel = mapStatus.mapZoomLevel - 1
        mapStatus.consumeZoomRelease = true
        if panState == PAN_GRACE then
          -- Zoom during grace: keep pan position, restart grace timer
          -- Zoom out halves Mercator pixels → scale anchor+offset by 0.5
          mapStatus.panOffsetX = floor(mapStatus.panOffsetX / 2)
          mapStatus.panOffsetY = floor(mapStatus.panOffsetY / 2)
          if mapStatus.panAnchorPixelX then
            mapStatus.panAnchorPixelX = floor(mapStatus.panAnchorPixelX / 2)
            mapStatus.panAnchorPixelY = floor(mapStatus.panAnchorPixelY / 2)
          end
          mapStatus.panGraceEnd = getTime() + PAN_GRACE_DURATION_CS
          mapStatus.lastPanOffsetX = nil
          mapStatus.lastPanOffsetY = nil
        elseif panState == PAN_IDLE and not mapStatus.followLock then
          -- Detached idle: scale anchor+offset for new zoom level
          mapStatus.panOffsetX = floor(mapStatus.panOffsetX / 2)
          mapStatus.panOffsetY = floor(mapStatus.panOffsetY / 2)
          if mapStatus.panAnchorPixelX then
            mapStatus.panAnchorPixelX = floor(mapStatus.panAnchorPixelX / 2)
            mapStatus.panAnchorPixelY = floor(mapStatus.panAnchorPixelY / 2)
          end
          mapStatus.lastPanOffsetX = nil
          mapStatus.lastPanOffsetY = nil
        elseif panState ~= PAN_IDLE then
          mapStatus.panState = PAN_IDLE
          mapStatus.panOffsetX = 0
          mapStatus.panOffsetY = 0
          mapStatus.panAnchorPixelX = nil
          mapStatus.panAnchorPixelY = nil
          mapStatus.lastPanOffsetX = nil
          mapStatus.lastPanOffsetY = nil
        end
        markMapDirty()
        if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
          mapLibs.utils.logDebug("TOUCH", ">>> ZOOM - PRESSED <<<", true)
        end
        system.killEvents(value)
        if perfActive then perfAddMs("event_total_ms", perfNowMs() - perfStartMs) end
        return true

      elseif hitPlus then
        if (tonumber(mapStatus.mapZoomLevel) or 20) >= (tonumber(mapStatus.conf.mapZoomMax) or 20) then
          -- Already at max zoom — consume event, show message, don't recenter
          mapStatus.zoomLimitMessageEnd = getTime() + 200  -- 2 seconds
          if panState == PAN_GRACE then
            mapStatus.panGraceEnd = getTime() + PAN_GRACE_DURATION_CS
          end
          mapStatus.consumeZoomRelease = true
          system.killEvents(value)
          if perfActive then perfAddMs("event_total_ms", perfNowMs() - perfStartMs) end
          return true
        end
        mapStatus.mapZoomLevel = mapStatus.mapZoomLevel + 1
        mapStatus.consumeZoomRelease = true
        if panState == PAN_GRACE then
          -- Zoom during grace: keep pan position, restart grace timer
          -- Zoom in doubles Mercator pixels → scale anchor+offset by 2
          mapStatus.panOffsetX = mapStatus.panOffsetX * 2
          mapStatus.panOffsetY = mapStatus.panOffsetY * 2
          if mapStatus.panAnchorPixelX then
            mapStatus.panAnchorPixelX = mapStatus.panAnchorPixelX * 2
            mapStatus.panAnchorPixelY = mapStatus.panAnchorPixelY * 2
          end
          mapStatus.panGraceEnd = getTime() + PAN_GRACE_DURATION_CS
          mapStatus.lastPanOffsetX = nil
          mapStatus.lastPanOffsetY = nil
        elseif panState == PAN_IDLE and not mapStatus.followLock then
          -- Detached idle: scale anchor+offset for new zoom level
          mapStatus.panOffsetX = mapStatus.panOffsetX * 2
          mapStatus.panOffsetY = mapStatus.panOffsetY * 2
          if mapStatus.panAnchorPixelX then
            mapStatus.panAnchorPixelX = mapStatus.panAnchorPixelX * 2
            mapStatus.panAnchorPixelY = mapStatus.panAnchorPixelY * 2
          end
          mapStatus.lastPanOffsetX = nil
          mapStatus.lastPanOffsetY = nil
        elseif panState ~= PAN_IDLE then
          mapStatus.panState = PAN_IDLE
          mapStatus.panOffsetX = 0
          mapStatus.panOffsetY = 0
          mapStatus.panAnchorPixelX = nil
          mapStatus.panAnchorPixelY = nil
          mapStatus.lastPanOffsetX = nil
          mapStatus.lastPanOffsetY = nil
        end
        markMapDirty()
        if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
          mapLibs.utils.logDebug("TOUCH", ">>> ZOOM + PRESSED <<<", true)
        end
        system.killEvents(value)
        if perfActive then perfAddMs("event_total_ms", perfNowMs() - perfStartMs) end
        return true
      end

      mapStatus.consumeZoomRelease = false

      -- Drag zone: enter PENDING (don't consume — ETHOS needs FIRST for tap)
      if inDragZone then
        if panState == PAN_GRACE then
          -- Re-engage during grace: skip PENDING to avoid 1-frame overlay flash
          mapStatus.panState = PAN_DRAGGING
          mapStatus.panLastX = x
          mapStatus.panLastY = y
          if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
            mapLibs.utils.logDebug("PAN", "GRACE_FIRST -> DRAGGING (consumed)", true)
          end
          system.killEvents(value)
          if perfActive then perfAddMs("event_total_ms", perfNowMs() - perfStartMs) end
          return true

        elseif panState == PAN_IDLE then
          mapStatus.panState = PAN_PENDING
          mapStatus.panLastX = x
          mapStatus.panLastY = y
          if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
            mapLibs.utils.logDebug("PAN", "FIRST -> PENDING (not consumed)", true)
          end
          if perfActive then perfAddMs("event_total_ms", perfNowMs() - perfStartMs) end
          return false  -- LET ETHOS HAVE IT

        elseif panState == PAN_DRAGGING then
          -- New finger sequence while dragging
          mapStatus.panLastX = x
          mapStatus.panLastY = y
          system.killEvents(value)
          if perfActive then perfAddMs("event_total_ms", perfNowMs() - perfStartMs) end
          return true
        end
      end

      -- Outside drag zone and not a button → pass through
      if perfActive then perfAddMs("event_total_ms", perfNowMs() - perfStartMs) end
      return false
    end

    -- Unknown touch values (e.g. 16643): don't consume
    return false
  end

  if perfActive then
    perfAddMs("event_total_ms", perfNowMs() - perfStartMs)
  end
  return false
end

local function setHome(widget)
  -- Copies the current aircraft position from telemetry into the stored home position used by map overlays.
  mapStatus.telemetry.homeLat = mapStatus.telemetry.lat
  mapStatus.telemetry.homeLon = mapStatus.telemetry.lon
  markMapDirty()
end

local function setDefaultPosition(widget)
  -- Saves the current viewport center GPS position as the persistent default position.
  local lat, lon
  if mapStatus.followLock then
    lat = mapStatus.telemetry.lat
    lon = mapStatus.telemetry.lon
  else
    local anchorX = mapStatus.panAnchorPixelX
    local anchorY = mapStatus.panAnchorPixelY
    if anchorX ~= nil and anchorY ~= nil and mapLibs.mapLib.pixel_to_coord then
      local vcPixelX = anchorX - (mapStatus.panOffsetX or 0)
      local vcPixelY = anchorY - (mapStatus.panOffsetY or 0)
      lat, lon = mapLibs.mapLib.pixel_to_coord(vcPixelX, vcPixelY, mapStatus.mapZoomLevel)
    end
  end
  if lat ~= nil and lon ~= nil then
    mapStatus.conf.defaultLat = lat
    mapStatus.conf.defaultLon = lon
    writeStateFile()
    if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
      mapLibs.utils.logDebug("STATE", fmt("setDefaultPosition: lat=%.6f lon=%.6f", lat, lon), true)
    end
  else
    if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
      mapLibs.utils.logDebug("STATE", fmt("setDefaultPosition FAILED: followLock=%s anchorX=%s telLat=%s",
        tostring(mapStatus.followLock), tostring(mapStatus.panAnchorPixelX),
        tostring(mapStatus.telemetry.lat)), true)
    end
  end
end

local function menuDismissed()
  mapStatus.menuOpenedAt = nil
end

local function menu(widget)
  -- Builds the widget context menu from the current telemetry state and dispatches actions back into shared status.
  -- Record open time so event() can pass all touch events through while
  -- the ETHOS popup is active (prevents pan state machine from consuming
  -- menu scroll/tap events, which caused per-frame menu blinking).
  mapStatus.menuOpenedAt = getTime()
  -- Reset PAN_PENDING so stale state from the long-press doesn't linger.
  if mapStatus.panState == PAN_PENDING then
    mapStatus.panState = PAN_IDLE
  end
  if mapStatus.telemetry.lat ~= nil and mapStatus.telemetry.lon ~= nil then
    local items = {
      { "Maps: Reset", function() menuDismissed(); reset(widget) end },
      { "Maps: Set Home", function() menuDismissed(); setHome(widget) end },
      { "Maps: Set Default Position", function() menuDismissed(); setDefaultPosition(widget) end },
    }
    -- Hide manual zoom when proportional channel control overrides it.
    if mapStatus.conf.zoomControl ~= 2 then
      items[#items+1] = { "Maps: Zoom in", function() menuDismissed(); mapStatus.mapZoomLevel = min(tonumber(mapStatus.conf.mapZoomMax) or 20, (tonumber(mapStatus.mapZoomLevel) or 1)+1); markMapDirty() end}
      items[#items+1] = { "Maps: Zoom out", function() menuDismissed(); mapStatus.mapZoomLevel = max(tonumber(mapStatus.conf.mapZoomMin) or 1, (tonumber(mapStatus.mapZoomLevel) or 1)-1); markMapDirty() end}
    end
    return items
  end
  return { { "Maps: Reset", function() menuDismissed(); reset(widget) end } }
end

local function wakeupInner(widget)
  -- Runs recurring background work between paint calls and invalidates the LCD so Ethos schedules a redraw.
  local perfActive = mapStatus.perfActive
  widget = resolveWidget(widget)
  if not widget then return end -- Safeguard: Ethos can schedule wakeup before the widget handle is ready.
  local now = getTime()

  if mapStatus.initPending then
    createOnce(widget)
    mapStatus.initPending = false
  end

  -- Drive MSP state machine FIRST to avoid SmartPort buffer overflow.
  -- Multiple poll() calls per cycle drain queued frames (each processes one chunk).
  if mapLibs and mapLibs.msp then
    local mspStartMs
    if perfActive then
      mspStartMs = perfNowMs()
    end
    for _ = 1, 10 do
      mapLibs.msp.poll()
    end
    if perfActive and mspStartMs then
      perfAddMs("msp_poll_ms", perfNowMs() - mspStartMs)
    end
  end

  -- Pan state machine: timeout-based release and grace expiry
  local panState = mapStatus.panState
  if panState == PAN_DRAGGING then
    if mapStatus.panLastTouchTime > 0 and (now - mapStatus.panLastTouchTime) > PAN_TOUCH_TIMEOUT_CS then
      mapStatus.panState = PAN_GRACE
      mapStatus.panGraceEnd = now + PAN_GRACE_DURATION_CS
      if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
        mapLibs.utils.logDebug("PAN", "TIMEOUT -> GRACE", true)
      end
    end
  elseif panState == PAN_GRACE then
    if now >= mapStatus.panGraceEnd then
      mapStatus.panState = PAN_IDLE
      if mapStatus.followLock then
        -- Locked mode: snap back to GPS position
        mapStatus.panOffsetX = 0
        mapStatus.panOffsetY = 0
        mapStatus.panAnchorPixelX = nil
        mapStatus.panAnchorPixelY = nil
        mapStatus.lastPanOffsetX = nil
        mapStatus.lastPanOffsetY = nil
      else
        -- Detached mode: freeze current viewport position as new anchor
        -- The detached anchor is computed from panAnchor - panOffset in drawMap.
        -- We keep panOffset/panAnchor intact so the next drag starts from here.
      end
      markMapDirty()
      if mapStatus.debugEnabled and mapLibs and mapLibs.utils then
        mapLibs.utils.logDebug("PAN", "GRACE_EXPIRED -> IDLE" .. (mapStatus.followLock and "" or " (DETACHED)"), true)
      end
    end
  end

  -- Zoom control via RC channel
  local zoomCtrl = mapStatus.conf.zoomControl
  local zoomCh = mapStatus.conf.zoomChannel
  if zoomCtrl ~= 0 and (tonumber(zoomCh) or 0) > 0 then
    -- Cache the channel source object; recreate only when channel number changes.
    if mapStatus.cachedZoomChannelSrc == nil or mapStatus.cachedZoomChannelNum ~= zoomCh then
      mapStatus.cachedZoomChannelSrc = system.getSource({category=CATEGORY_CHANNEL, member=zoomCh - 1})
      mapStatus.cachedZoomChannelNum = zoomCh
    end
    local src = mapStatus.cachedZoomChannelSrc
    if src ~= nil and type(src.value) == "function" then
      local chVal = src:value()
      if chVal ~= nil then
        local zMin = tonumber(mapStatus.conf.mapZoomMin) or 1
        local zMax = tonumber(mapStatus.conf.mapZoomMax) or 20

        if zoomCtrl == 1 then
          -- 3-Position mode: edge-triggered zoom steps
          -- chVal is -1024..+1024 in ETHOS (maps to -100%..+100%)
          local dir = 0
          if chVal > 614 then       -- > ~60%
            dir = 1                  -- zoom in
          elseif chVal < -614 then   -- < ~-60%
            dir = -1                 -- zoom out
          end
          if dir ~= 0 and dir ~= mapStatus.zoomControlLastDir then
            local targetLevel = mapStatus.mapZoomLevel + dir
            if mapStatus.zoomControlTarget ~= nil then
              targetLevel = mapStatus.zoomControlTarget + dir
            end
            if targetLevel < zMin then targetLevel = zMin end
            if targetLevel > zMax then targetLevel = zMax end
            if targetLevel ~= mapStatus.mapZoomLevel or targetLevel ~= mapStatus.zoomControlTarget then
              mapStatus.zoomControlTarget = targetLevel
              mapStatus.zoomControlTimer = now
            end
          end
          mapStatus.zoomControlLastDir = dir

        elseif zoomCtrl == 2 then
          -- Proportional mode: map -1024..+1024 → zoomMin..zoomMax
          local normalized = (chVal + 1024) / 2048  -- 0.0 .. 1.0
          local targetLevel = floor(zMin + normalized * (zMax - zMin) + 0.5)
          if targetLevel < zMin then targetLevel = zMin end
          if targetLevel > zMax then targetLevel = zMax end
          if targetLevel ~= mapStatus.zoomControlTarget then
            mapStatus.zoomControlTarget = targetLevel
            mapStatus.zoomControlTimer = now
          end
        end

        -- Apply pending zoom after 2 seconds of no change
        if mapStatus.zoomControlTarget ~= nil and mapStatus.zoomControlTarget ~= mapStatus.mapZoomLevel then
          if (now - mapStatus.zoomControlTimer) >= 200 then  -- 200 centiseconds = 2 seconds
            local oldLevel = mapStatus.mapZoomLevel
            local newLevel = mapStatus.zoomControlTarget
            local delta = newLevel - oldLevel  -- positive = zoom in, negative = zoom out

            -- Scale pan anchor + offset to keep the viewport at the same
            -- geographic position.  Each zoom level doubles Mercator pixels,
            -- so the scale factor is 2^delta.
            local panState = mapStatus.panState
            local isPanOrDetached = (panState == PAN_GRACE or panState == PAN_DRAGGING)
              or (panState == PAN_IDLE and not mapStatus.followLock)
            if isPanOrDetached then
              if delta > 0 then
                -- Zoom in: multiply by 2^delta
                local scale = 2 ^ delta  -- e.g. delta=3 → scale=8
                mapStatus.panOffsetX = floor(mapStatus.panOffsetX * scale)
                mapStatus.panOffsetY = floor(mapStatus.panOffsetY * scale)
                if mapStatus.panAnchorPixelX then
                  mapStatus.panAnchorPixelX = floor(mapStatus.panAnchorPixelX * scale)
                  mapStatus.panAnchorPixelY = floor(mapStatus.panAnchorPixelY * scale)
                end
              elseif delta < 0 then
                -- Zoom out: divide by 2^|delta|
                local scale = 2 ^ (-delta)  -- e.g. delta=-3 → scale=8
                mapStatus.panOffsetX = floor(mapStatus.panOffsetX / scale)
                mapStatus.panOffsetY = floor(mapStatus.panOffsetY / scale)
                if mapStatus.panAnchorPixelX then
                  mapStatus.panAnchorPixelX = floor(mapStatus.panAnchorPixelX / scale)
                  mapStatus.panAnchorPixelY = floor(mapStatus.panAnchorPixelY / scale)
                end
              end
              mapStatus.lastPanOffsetX = nil
              mapStatus.lastPanOffsetY = nil
            end

            mapStatus.mapZoomLevel = newLevel
            mapStatus.zoomControlTarget = nil
            markMapDirty()
          end
        elseif mapStatus.zoomControlTarget == mapStatus.mapZoomLevel then
          mapStatus.zoomControlTarget = nil  -- Already at target, clear pending
        end
      end
    end
  end

  if widget.runBgTasks then
    local bgStartMs = nil
    if perfActive then
      bgStartMs = perfNowMs()
    end
    bgtasks(widget)
    if perfActive then
      perfAddMs("bgtasks_ms", perfNowMs() - bgStartMs)
    end
  end

  -- MSP status logging and mission publish (polling done at top of wakeup)
  if mapLibs and mapLibs.msp then
    local mspState = mapLibs.msp.getState()

    -- MSP status log — only on state change
    if mapStatus.debugEnabled and mapLibs.utils then
      local curMspSig = fmt("%d|%s|%s|%d|%s",
          mspState.state,
          tostring(mspState.fcVariant),
          mspState.fcVersion or "?",
          mspState.wpCount or 0,
          tostring(mspState.isArmed))
      if curMspSig ~= mapStatus._mspLastSig then
        mapStatus._mspLastSig = curMspSig
        local stateNames = mspStateNames
        mapLibs.utils.logDebug("MSP_DBG", fmt("state=%s fc=%s(%s) transport=%s wpCount=%d done=%s active=%s missions=%d published=%s armed=%s",
            stateNames[mspState.state] or tostring(mspState.state),
            tostring(mspState.fcVariant),
            mspState.fcVersion or "?",
            mspState.transport or "?",
            mspState.wpCount or 0,
            tostring(mapLibs.msp.isDone()),
            tostring(mapLibs.msp.isActive()),
            mspState.missions and #mspState.missions or 0,
            tostring(mapStatus.mspDownloadDone),
            tostring(mspState.isArmed)), true)
      end
    end

    -- Publish mission data: progressively during download, final on completion
    -- Gate: only publish WP data when wpDownload is enabled
    local wpEnabled = mapStatus.conf.wpDownload

    if wpEnabled and mapLibs.msp.isDone() then
      -- Final publish with parsed missions (split at multi-mission boundaries)
      if not mapStatus.mspDownloadDone then
        if mapStatus.debugEnabled and mapLibs.utils then
          mapLibs.utils.logDebug("MSP_DBG", fmt(">>> PUBLISH: %d missions, %d total WPs <<<",
              mspState.missions and #mspState.missions or 0,
              mspState.wpCount or 0), true)
        end
        if mspState.missions and #mspState.missions > 0 then
          mapStatus.mspMissions = mspState.missions
          mapStatus.mspMissionIdx = 1
          markMapDirty()
        end
        mapStatus.mspDownloadDone = true
      end
    elseif wpEnabled and mspState.state == mapLibs.msp.STATE_DOWNLOADING and mspState.wpList and #mspState.wpList > 0 then
      -- Progressive publish: show WPs as they arrive (only when count changes)
      local newCount = #mspState.wpList
      if newCount ~= (mapStatus._mspLastWpCount or 0) then
        mapStatus._mspLastWpCount = newCount
        mapStatus.mspMissions = { mspState.wpList }
        mapStatus.mspMissionIdx = 1
        markMapDirty()
      end
    else
      -- MSP not done (retrying / reconnecting) — allow re-publish on next success
      if mapStatus.mspDownloadDone then
        mapStatus.mspDownloadDone = false
        mapStatus._mspLastWpCount = 0
      end
    end

    -- Auto set-home when FC reports armed (once per arming cycle)
    if mspState.isArmed and not mapStatus.mspArmedHomeSet then
      if mapStatus.telemetry.lat ~= nil and mapStatus.telemetry.lon ~= nil then
        setHome(widget)
        mapStatus.mspArmedHomeSet = true
        if mapStatus.debugEnabled and mapLibs.utils then
          mapLibs.utils.logDebug("MSP_DBG", "ARMED detected — home set automatically", true)
        end
      end
    elseif not mspState.isArmed and mapStatus.mspArmedHomeSet then
      mapStatus.mspArmedHomeSet = false
    end

    -- Publish nav status for map rendering (active WP highlight, UAV color)
    mapStatus.mspNavMode  = mspState.navMode or 0
    mapStatus.mspActiveWp = mspState.activeWpNumber or 0
  end

  -- Trail accumulation (moved from paint to keep trig out of the instruction budget)
  if mapLibs and mapLibs.mapLib then
    mapLibs.mapLib.updateTrail()
  end

  -- Run compute scheduler (Phase 1+: staggered task processing)
  if mapLibs and mapLibs.compute then
    -- Phase 4: tile grid must update every cycle (GPS, pan, heading change continuously).
    -- loadAndCenterTiles has its own 25ms throttle to skip redundant rebuilds.
    mapLibs.compute.setDirty("needsTileGrid")
    mapLibs.compute.update(widget)
  end

  -- Snapshot pan state AFTER compute (updateTileGrid) has finished.
  -- paint() reads this snapshot so its flags (skipOverlays, isPanning,
  -- renderOffset clamping) are guaranteed to match the panState that
  -- updateTileGrid used to compute drawOffsetX/Y and myScreenX/Y.
  -- Without this, an event() firing between wakeup and paint would give
  -- paint a different panState, causing 1-frame overlay flashes and
  -- tile position jumps.
  if widget then widget.panStateSnapshot = mapStatus.panState end

  if mapLibs and mapLibs.tileLoader then
    if mapLibs.tileLoader.getQueueLength() > 0 then
      local tilesLoaded = mapLibs.tileLoader.processQueue(3)
      if perfActive and tilesLoaded > 0 then
        perfInc("tiles_loaded", tilesLoaded)
      end
    end
  end

  if mapStatus.debugEnabled
      and mapLibs and mapLibs.utils and mapLibs.utils.flushLogs then
    local flushStartMs = nil
    if perfActive then
      flushStartMs = perfNowMs()
    end
    mapLibs.utils.flushLogs(false)
    if perfActive then
      perfAddMs("log_flush_ms", perfNowMs() - flushStartMs)
    end
  end
end

local function wakeup(widget)
  local perfActive = mapStatus.perfActive
  local perfStartMs = nil
  if perfActive then
    perfStartMs = perfNowMs()
    perfInc("wakeup_calls", 1)
  end

  wakeupInner(widget)

  if perfActive then
    perfAddMs("wakeup_total_ms", perfNowMs() - perfStartMs)
    local perfNowWallMs = perfWindowNowMs()
    local startMs = perfWindowStartMs or tonumber(mapStatus.perfProfile.windowStartMs) or 0
    local windowMs = tonumber(mapStatus.perfProfile.windowMs) or 5000

    if startMs == 0 then
      perfWindowStartMs = perfNowWallMs
      mapStatus.perfProfile.windowStartMs = perfNowWallMs
      startMs = perfNowWallMs
    end

    local elapsedMs = perfNowWallMs - startMs
    if elapsedMs >= windowMs and mapLibs and mapLibs.utils and mapLibs.utils.logDebug then
      local elapsedSec = elapsedMs / 1000
      local wakeupCalls = mapStatus.perfProfile.counters.wakeup_calls or 0
      local paintCalls = mapStatus.perfProfile.counters.paint_calls or 0
      local fps = 0
      if elapsedSec > 0 then
        fps = paintCalls / elapsedSec
      end

      -- Build all perf rows first, then print once to avoid UART buffer overflow.
      local counters = mapStatus.perfProfile.counters
      local metrics  = mapStatus.perfProfile.metrics
      local mspWpReceived = counters.msp_wp_received or 0
      local mspWpPerSec = 0
      if elapsedSec > 0 then
        mspWpPerSec = mspWpReceived / elapsedSec
      end

      local perfBorder = "+----------+------------------+------------------+------------------+"
      local perfRows = {
        "=== PERF WINDOW " .. perfValueText(elapsedSec, 1) .. "s ===",
        perfBorder,
        perfTableRow("rate",
          perfTableCell("fps", perfValueText(fps, 2)),
          perfTableCell("wakeups", wakeupCalls),
          perfTableCell("paints", paintCalls)),
        perfTableRow("paint",
          perfTableCell("totMs", perfValueText(perfMetricAvg("paint_total_ms"), 2)),
          perfTableCell("layoutMs", perfValueText(perfMetricAvg("layout_draw_ms"), 2)),
          perfTableCell("drawTilesMs", perfValueText(perfMetricAvg("draw_tiles_ms"), 2))),
        perfTableRow("compute",
          perfTableCell("totMs", perfValueText(perfMetricAvg("compute_total_ms"), 2)),
          perfTableCell("tileGridMs", perfValueText(perfMetricAvg("compute_tileGrid_ms"), 2)),
          perfTableCell("wpMs", perfValueText(perfMetricAvg("compute_wpProjection_ms"), 2))),
        perfTableRow("",
          perfTableCell("trailMs", perfValueText(perfMetricAvg("compute_trailProjection_ms"), 2)),
          perfTableCell("tasksRun", counters.compute_tasks_run or 0),
          perfTableCell("tasksSkip", counters.compute_tasks_skipped or 0)),
        perfTableRow("wakeup",
          perfTableCell("totMs", perfValueText(perfMetricAvg("wakeup_total_ms"), 2)),
          perfTableCell("bgMs", perfValueText(perfMetricAvg("bgtasks_ms"), 2)),
          perfTableCell("mspPollMs", perfValueText(perfMetricAvg("msp_poll_ms"), 2))),
        perfTableRow("msp",
          perfTableCell("wp/s", perfValueText(mspWpPerSec, 1)),
          perfTableCell("errors", counters.msp_errors or 0),
          perfTableCell("wpTotal", mspWpReceived)),
        perfTableRow("tileIO",
          perfTableCell("loadMs", perfValueText(perfMetricAvg("tile_load_ms"), 2)),
          perfTableCell("min", perfValueText((metrics.tile_load_ms or {}).min or 0, 2)),
          perfTableCell("max", perfValueText((metrics.tile_load_ms or {}).max or 0, 2))),
        perfTableRow("counts",
          perfTableCell("rebuilds", counters.tile_rebuild_count or 0),
          perfTableCell("loaded", counters.tiles_loaded or 0),
          perfTableCell("gcCalls", counters.gc_count or 0)),
        perfTableRow("sched",
          perfTableCell("inval", counters.invalidate_count or 0),
          perfTableCell("touches", counters.touch_events or 0),
          perfTableCell("frame100ms", counters.long_frame_count_100ms or 0)),
        perfBorder,
      }
      for i = 1, #perfRows do
        mapLibs.utils.logDebug("PERF", perfRows[i], true)
      end
      perfResetWindow(perfNowWallMs)
    end
  end

  frameWakeupCount = frameWakeupCount + 1
  scheduledRenderCount = scheduledRenderCount + 1
  mapStatus.mapTickSerial = scheduledRenderCount
  local now = getTime()
  if now - lastBarTickCs >= BAR_TICK_INTERVAL_CS then
    mapStatus.barTickSerial = mapStatus.barTickSerial + 1
    lastBarTickCs = now
  end
  if perfActive then
    perfInc("invalidate_count", 1)
  end
  lcd.invalidate()

  -- Step B: Periodische Garbage Collection (alle 10 Wakeups)
  if frameWakeupCount % 10 == 0 then
    collectgarbage()
    collectgarbage()
    if perfActive then
      perfInc("gc_count", 1)
    end
  end
end

local function create()
  -- Creates a fresh widget instance, initializes shared libraries, and returns the per-instance state table to Ethos.
  if not mapStatus.initPending then
    mapStatus.initPending = true
  end

  initLibs()

  -- Cache ETHOS version and hardware info once per session.
  if mapStatus.ethosVersion == nil then
    local ok, ver = pcall(system.getVersion)
    if ok and type(ver) == "table" then
      mapStatus.ethosVersion = ver
    end
  end

  -- Reset session logging flag so fresh widget initializations emit a new debug marker.
  mapStatus.sessionLogged = false


  -- Emit a visible session marker once so each debug log session has a clear start record.
  logDebugSessionStart("widget create")

  -- NOTE: msp.open() is deferred to createOnce() (first wakeup) because ETHOS
  -- calls create() before read(), so conf.wpDownload is still at its default here.

  return {
    conf = mapStatus.conf,
    ready = false,
    runBgTasks = false,
    drawOffsetX = 0,
    drawOffsetY = 0,
    lastW = 0,
    lastH = 0,
    lastZoom = 0,
    screen = 1,
    centerPanelIndex = 1,
    leftPanelIndex = 1,
    rightPanelIndex = 1,
    layout = nil,
    centerPanel = nil,
    leftPanel = nil,
    rightPanel = nil,
    name = "ETHOS Maps",
  }
end

local function applyDefault(value, defaultValue, lookup)
  -- Resolves a value through a default and optional lookup table before configuration fields consume it.
  -- IMPORTANT: Do NOT use `value ~= nil and value or default` here!
  -- In Lua, `false or default` evaluates to `default`, which silently
  -- replaces a legitimately stored boolean false with the default value.
  local v
  if value ~= nil then
    v = value
  else
    v = defaultValue
  end
  -- Type coercion: ETHOS storage may round-trip booleans as 0/1 or numbers
  -- as booleans.  Ensure the returned value matches the expected type so
  -- downstream relational comparisons (<, >, <=, >=, math.max/min) never
  -- encounter a number-vs-boolean mismatch.
  if v ~= nil and defaultValue ~= nil then
    local dt = type(defaultValue)
    local vt = type(v)
    if dt == "number" and vt ~= "number" then
      v = tonumber(v) or defaultValue
    elseif dt == "boolean" and vt ~= "boolean" then
      if vt == "number" then v = v ~= 0
      else v = (v == true or v == "true" or v == "1") end
    end
  end
  if lookup ~= nil then return lookup[v] end
  return v
end

local function storageToConfig(name, defaultValue, lookup)
  -- Reads a persisted setting from storage and normalizes it into the in-memory config format.
  local storageValue = storage.read(name)
  return applyDefault(storageValue, defaultValue, lookup)
end

local function storageToConfigWithFallback(name, defaultValue, fallbackNames, lookup)
  -- Reads a setting from primary storage key and falls back to legacy keys for backward compatibility.
  local storageValue = storage.read(name)
  if storageValue == nil and fallbackNames ~= nil then
    for i=1,#fallbackNames do
      storageValue = storage.read(fallbackNames[i])
      if storageValue ~= nil then
        break
      end
    end
  end
  return applyDefault(storageValue, defaultValue, lookup)
end

local function configToStorage(value, lookup)
  -- Converts an in-memory config value back into the stored lookup index when persistence needs it.
  if lookup == nil then return value end
  for i=1,#lookup do
    if lookup[i] == value then return i end
  end
  return 1
end

local MAP_PROVIDER_LABELS = {
  [1] = "GMapCatcher (Yaapu)",
  [2] = "Google",
  [3] = "ESRI",
  [4] = "OSM",
}

local MAP_TYPE_LABELS = {
  [1] = "Satellite",
  [2] = "Hybrid",
  [3] = "Map",
  [4] = "Terrain",
  [5] = "Street",
}

-- On-disk folder names for each map provider under /bitmaps/ethosmaps/maps/
local PROVIDER_FOLDER_NAMES = {
  [2] = "GOOGLE",
  [3] = "ESRI",
  [4] = "OSM",
}

local function directoryExists(path)
  -- Checks whether a directory exists by listing the parent and looking for the target entry.
  -- Replaces the old os.rename(path,path) hack that caused f_rename errors on ETHOS.
  if path == nil or path == "" then
    return false
  end
  local parent, target = path:match("^(.+)/([^/]+)$")
  if not parent or not target then
    return false
  end
  if not system or type(system.listFiles) ~= "function" then
    return false
  end
  local ok, entries = pcall(system.listFiles, parent)
  if not ok or type(entries) ~= "table" then
    return false
  end
  for i = 1, #entries do
    local name = entries[i]
    if type(name) == "string" then
      name = name:gsub("/+$", "")
      if name == target then
        return true
      end
    end
  end
  return false
end

local function getProviderRootCandidates(provider)
  local roots = {}
  if provider == 1 then
    tinsert(roots, "/bitmaps/yaapu/maps")
    return roots
  end
  local folderName = PROVIDER_FOLDER_NAMES[provider] or ("PROVIDER" .. tostring(provider or ""))
  tinsert(roots, "/bitmaps/ethosmaps/maps/" .. folderName)
  return roots
end

local function getMapTypeFolder(provider, mapTypeId)
  if provider == 0 or mapTypeId == 0 then
    return nil
  end
  if provider == 1 then
    -- GMapCatcher/Yaapu internal folder names.
    return applyDefault(mapTypeId, 1, {"sat_tiles","tiles","tiles","ter_tiles"})
  end
  if provider == 3 then
    -- ESRI: Satellite, Hybrid, Street.
    if mapTypeId == 1 then return "Satellite" end
    if mapTypeId == 2 then return "Hybrid" end
    if mapTypeId == 5 then return "Street" end
    return nil
  end
  if provider == 4 then
    -- OSM: Street only.
    if mapTypeId == 5 then return "Street" end
    return nil
  end
  -- Google (provider 2): Satellite, Hybrid, Map, Terrain.
  if mapTypeId == 1 then return "Satellite" end
  if mapTypeId == 2 then return "Hybrid" end
  if mapTypeId == 3 then return "Map" end
  if mapTypeId == 4 then return "Terrain" end
  return nil
end

local function getGoogleMapTypeYaapuName(mapTypeId)
  -- Maps Google map type IDs to their Yaapu folder names (for fallback).
  return applyDefault(mapTypeId, 1, {"GoogleSatelliteMap","GoogleHybridMap","GoogleMap","GoogleTerrainMap"})
end

local function mapTypeFolderExists(provider, mapTypeId)
  local folder = getMapTypeFolder(provider, mapTypeId)
  if folder == nil then
    return false
  end
  
  if provider == 2 then
    -- For Google, check BOTH ethosmaps and Yaapu paths for availability.
    local ethosmapsRoot = "/bitmaps/ethosmaps/maps/GOOGLE"
    if directoryExists(ethosmapsRoot .. "/" .. folder) then
      return true
    end
    local yaapuFolder = getGoogleMapTypeYaapuName(mapTypeId)
    if directoryExists("/bitmaps/yaapu/maps/" .. yaapuFolder) then
      return true
    end
    return false
  end
  
  local roots = getProviderRootCandidates(provider)
  for r=1,#roots do
    if directoryExists(roots[r] .. "/" .. folder) then
      return true
    end
  end
  return false
end

local function choiceContainsValue(choices, value)
  for i=1,#choices do
    if choices[i][2] == value then
      return true
    end
  end
  return false
end

local function invalidateAvailabilityCaches(provider)
  -- Kept for compatibility with existing call sites; availability now uses live scanning.
  mapStatus.cachedProviderChoices = nil
  mapStatus.cachedMapTypeChoices = {}
end

local function getAvailableProviderChoices(forceRefresh)
  local choices = {}
  for provider=1,4 do
    local available = false
    for typeId=1,5 do
      if mapTypeFolderExists(provider, typeId) then
        available = true
        break
      end
    end
    if available then
      tinsert(choices, {MAP_PROVIDER_LABELS[provider], provider})
    end
  end

  if #choices == 0 then
    tinsert(choices, {"NONE", 0})
  end
  return choices
end

local function getAvailableMapTypeChoices(provider, forceRefresh)
  if provider == 0 then
    return {{"NONE", 0}}
  end

  local choices = {}
  for typeId=1,5 do
    local folder = getMapTypeFolder(provider, typeId)
    if folder ~= nil and mapTypeFolderExists(provider, typeId) then
      tinsert(choices, {MAP_TYPE_LABELS[typeId], typeId})
    end
  end

  if #choices == 0 then
    tinsert(choices, {"NONE", 0})
  end
  return choices
end

local getSortedDirectories

local function getAvailableZoomBounds(provider, mapTypeId)
  local folder = getMapTypeFolder(provider, mapTypeId)
  if folder == nil then
    return nil, nil
  end

  local searchRoots = {}
  if provider == 2 then
    tinsert(searchRoots, "/bitmaps/ethosmaps/maps/GOOGLE/" .. folder)
    local yaapuFolder = getGoogleMapTypeYaapuName(mapTypeId)
    if yaapuFolder ~= nil then
      tinsert(searchRoots, "/bitmaps/yaapu/maps/" .. yaapuFolder)
    end
  elseif provider == 1 then
    tinsert(searchRoots, "/bitmaps/yaapu/maps/" .. folder)
  else
    local roots = getProviderRootCandidates(provider)
    for i = 1, #roots do
      tinsert(searchRoots, roots[i] .. "/" .. folder)
    end
  end

  local minZoom = nil
  local maxZoom = nil

  for i = 1, #searchRoots do
    local dirs = getSortedDirectories(searchRoots[i])
    if type(dirs) == "table" then
      for j = 1, #dirs do
        local zoom = tonumber(dirs[j])
        if zoom ~= nil and zoom >= 1 and zoom <= 20 and floor(zoom) == zoom then
          if minZoom == nil or zoom < minZoom then
            minZoom = zoom
          end
          if maxZoom == nil or zoom > maxZoom then
            maxZoom = zoom
          end
        end
      end
    end
  end

  return minZoom, maxZoom
end

local function replaceChoices(targetChoices, sourceChoices)
  if targetChoices == nil then
    return
  end
  for i = #targetChoices, 1, -1 do
    targetChoices[i] = nil
  end
  for i = 1, #sourceChoices do
    targetChoices[i] = {sourceChoices[i][1], sourceChoices[i][2]}
  end
end

local function refreshConfigureForm()
  if form == nil then
    return false
  end

  local refreshMethods = { "reinit", "invalidate", "refresh", "reload" }
  for i = 1, #refreshMethods do
    local methodName = refreshMethods[i]
    local method = form[methodName]
    if type(method) == "function" then
      local ok = pcall(method)
      if ok then
        return true
      end
    end
  end
  return false
end

local function syncMapTypeChoicesForProvider(widget, provider, forceRefresh)
  local availableTypes = getAvailableMapTypeChoices(provider, forceRefresh)
  local oldMapTypeId = mapStatus.conf.mapTypeId

  if not choiceContainsValue(availableTypes, mapStatus.conf.mapTypeId) then
    mapStatus.conf.mapTypeId = availableTypes[1][2]
  end

  if widget ~= nil and widget.mapTypeChoices ~= nil then
    replaceChoices(widget.mapTypeChoices, availableTypes)
  end

  if widget ~= nil and widget.mapTypeField ~= nil then
    widget.mapTypeField:enable(provider ~= 0)
  end

  return availableTypes, oldMapTypeId
end

local function logMapSelectionAutofix(message)
  if mapStatus.debugEnabled and mapLibs and mapLibs.utils and mapLibs.utils.logDebug then
    mapLibs.utils.logDebug("SETTINGS", message, true)
  end
end

local function toLogValue(value)
  if value == nil then
    return "nil"
  end
  local valueType = type(value)
  if valueType == "boolean" then
    return value and "true" or "false"
  end
  if valueType == "userdata" or valueType == "function" or valueType == "thread" then
    return "<" .. valueType .. ">"
  end
  return tostring(value)
end

getSortedDirectories = function(path)
  if not system or type(system.listFiles) ~= "function" then
    return nil, "no_directory_api"
  end
  local ok, entries = pcall(system.listFiles, path)
  if not ok or type(entries) ~= "table" then
    return {}, nil
  end
  local result = {}
  local seen = {}
  for i = 1, #entries do
    local rawName = entries[i]
    if type(rawName) == "string" and rawName ~= "." and rawName ~= ".." and rawName ~= "" then
      local name = rawName:gsub("/+$", "")
      if not seen[name] then
        seen[name] = true
        tinsert(result, name)
      end
    end
  end
  table.sort(result)
  return result, nil
end

local function getRootPathCandidates(rootPath)
  local candidates = {}
  local seen = {}

  local function addCandidate(path)
    if path ~= nil and path ~= "" and not seen[path] then
      seen[path] = true
      tinsert(candidates, path)
    end
  end

  addCandidate(rootPath)
  addCandidate(rootPath:gsub("^/", ""))
  if rootPath:sub(1, 1) ~= "/" then
    addCandidate("/" .. rootPath)
  end

  return candidates
end

local function logDirectoryTree(rootPath, title)
  if not (mapLibs and mapLibs.utils and mapLibs.utils.logDebug) then
    return
  end

  mapLibs.utils.logDebug("SETTINGS", "=== " .. title .. " ===", true)
  local activeRootPath = rootPath
  local providerDirs = nil
  local providerErr = nil

  local candidates = getRootPathCandidates(rootPath)
  for i = 1, #candidates do
    local candidate = candidates[i]
    local dirs, err = getSortedDirectories(candidate)
    if err == nil then
      activeRootPath = candidate
      providerDirs = dirs
      providerErr = nil
      if #dirs > 0 then
        break
      end
    else
      providerErr = err
    end
  end

  mapLibs.utils.logDebug("SETTINGS", activeRootPath, true)

  if providerErr ~= nil then
    mapLibs.utils.logDebug("SETTINGS", "(directory listing unavailable: no filesystem directory API)", true)
    mapLibs.utils.logDebug("SETTINGS", "=== END " .. title .. " ===", true)
    return
  end

  providerDirs = providerDirs or {}
  if #providerDirs == 0 then
    mapLibs.utils.logDebug("SETTINGS", "(empty or missing)", true)
    mapLibs.utils.logDebug("SETTINGS", "=== END " .. title .. " ===", true)
    return
  end

  local normalizedRoot = activeRootPath:gsub("^/", ""):lower()
  local yaapuReducedDepth = normalizedRoot == "bitmaps/yaapu/maps"

  for i = 1, #providerDirs do
    local providerName = providerDirs[i]
    local providerPath = activeRootPath .. "/" .. providerName
    local providerPrefix = (i < #providerDirs) and "|-- " or "`-- "
    local mapTypeIndent = (i < #providerDirs) and "|   " or "    "
    mapLibs.utils.logDebug("SETTINGS", providerPrefix .. providerName .. "/", true)

    if not yaapuReducedDepth then
      local mapTypeDirs = getSortedDirectories(providerPath) or {}
      if #mapTypeDirs == 0 then
        mapLibs.utils.logDebug("SETTINGS", mapTypeIndent .. "(no subfolders)", true)
      else
        for j = 1, #mapTypeDirs do
          local mapTypeName = mapTypeDirs[j]
          local mapTypePrefix = (j < #mapTypeDirs) and "|-- " or "`-- "
          mapLibs.utils.logDebug("SETTINGS", mapTypeIndent .. mapTypePrefix .. mapTypeName .. "/", true)
        end
      end
    end
  end

  mapLibs.utils.logDebug("SETTINGS", "=== END " .. title .. " ===", true)
end

local function logSettingsSnapshot()
  if not (mapLibs and mapLibs.utils and mapLibs.utils.logDebug) then
    return
  end

  mapLibs.utils.logDebug("SETTINGS", "=== SETTINGS SNAPSHOT ===", true)

  local keys = {}
  for key in pairs(mapStatus.conf) do
    tinsert(keys, key)
  end
  table.sort(keys)

  for i = 1, #keys do
    local key = keys[i]
    mapLibs.utils.logDebug("SETTINGS", key .. " = " .. toLogValue(mapStatus.conf[key]), true)
  end

  mapLibs.utils.logDebug("SETTINGS", "=== END SETTINGS SNAPSHOT ===", true)
end

logDebugSessionStart = function(reason)
  if not (mapStatus.debugEnabled and mapLibs and mapLibs.utils and mapLibs.utils.logDebug) then
    return
  end
  if mapStatus.sessionLogged then
    return
  end

  -- Mark as logged first so a crash inside snapshot/tree doesn't put us in an infinite retry loop.
  mapStatus.sessionLogged = true

  local marker = "=== DEBUG SESSION STARTED ==="
  if reason and reason ~= "" then
    marker = marker .. " (" .. reason .. ")"
  end

  mapLibs.utils.logDebug("SETTINGS", marker, true)

  if mapStatus.perfActive then
    mapLibs.utils.logDebug("PERF", "=== PERF PROFILE ACTIVE (5s windows) ===", true)
  end

  -- Log ETHOS version and hardware info.
  local ev = mapStatus.ethosVersion
  if ev then
    local verStr = tostring(ev.major or "?") .. "." .. tostring(ev.minor or "?") .. "." .. tostring(ev.revision or "0")
    local board = tostring(ev.board or "unknown")
    local lcdW = tostring(ev.lcdWidth or "?")
    local lcdH = tostring(ev.lcdHeight or "?")
    mapLibs.utils.logDebug("SYSTEM", "ETHOS Version " .. verStr .. " | Radio: " .. board .. " | LCD: " .. lcdW .. "x" .. lcdH, true)
  else
    mapLibs.utils.logDebug("SYSTEM", "system.getVersion() not available", true)
  end

  logSettingsSnapshot()
  logDirectoryTree("/bitmaps/ethosmaps/maps", "FOLDER TREE SNAPSHOT: ethosmaps/maps")
  logDirectoryTree("/bitmaps/yaapu/maps", "FOLDER TREE SNAPSHOT: yaapu/maps")
end

local function providerLabelById(providerId)
  if providerId == 0 then
    return "NONE"
  end
  return MAP_PROVIDER_LABELS[providerId] or tostring(providerId)
end

local function mapTypeLabelById(mapTypeId)
  if mapTypeId == 0 then
    return "NONE"
  end
  return MAP_TYPE_LABELS[mapTypeId] or tostring(mapTypeId)
end

local function normalizeLegacyMapTypeIdForProvider(provider, mapTypeId)
  -- Migrate legacy Street id (3) used in earlier ESRI/OSM builds to dedicated Street id (5).
  if (provider == 3 or provider == 4) and mapTypeId == 3 then
    return 5
  end
  return mapTypeId
end

local function ensureAvailableMapSelections()
  local oldProvider = mapStatus.conf.mapProvider
  local oldMapTypeId = mapStatus.conf.mapTypeId

  mapStatus.conf.mapTypeId = normalizeLegacyMapTypeIdForProvider(mapStatus.conf.mapProvider, mapStatus.conf.mapTypeId)

  local providerChoices = getAvailableProviderChoices()
  if not choiceContainsValue(providerChoices, mapStatus.conf.mapProvider) then
    mapStatus.conf.mapProvider = providerChoices[1][2]
  end

  local mapTypeChoices = getAvailableMapTypeChoices(mapStatus.conf.mapProvider)
  if not choiceContainsValue(mapTypeChoices, mapStatus.conf.mapTypeId) then
    mapStatus.conf.mapTypeId = mapTypeChoices[1][2]
  end

  if oldProvider ~= mapStatus.conf.mapProvider or oldMapTypeId ~= mapStatus.conf.mapTypeId then
    local key = fmt("provider:%s->%s|mapType:%s->%s", tostring(oldProvider), tostring(mapStatus.conf.mapProvider), tostring(oldMapTypeId), tostring(mapStatus.conf.mapTypeId))
    if mapStatus.lastSelectionAutoFixKey ~= key then
      logMapSelectionAutofix("Auto-adjusted map selection because configured provider/map type folders are not available (" .. key .. ")")
      mapStatus.lastSelectionAutoFixKey = key
    end
  end

  return providerChoices, mapTypeChoices
end

local function applyConfig()
  -- Derives labels, unit multipliers, and active zoom limits from persisted settings and writes them into mapStatus.conf.
  ensureAvailableMapSelections()

  mapStatus.conf.horSpeedLabel = applyDefault(mapStatus.conf.horSpeedUnit, 1, {"m/s", "km/h", "mph", "kn"})
  mapStatus.conf.vertSpeedLabel = applyDefault(mapStatus.conf.vertSpeedUnit, 1, {"m/s", "ft/s", "ft/min"})
  mapStatus.conf.distUnitLabel = applyDefault(mapStatus.conf.distUnit, 1, {"m", "ft"})
  mapStatus.conf.distUnitLongLabel = applyDefault(mapStatus.conf.distUnitLong, 1, {"km", "mi"})

  mapStatus.conf.horSpeedMultiplier = applyDefault(mapStatus.conf.horSpeedUnit, 1, {1, 3.6, 2.23694, 1.94384})
  mapStatus.conf.vertSpeedMultiplier = applyDefault(mapStatus.conf.vertSpeedUnit, 1, {1, 3.28084, 196.85})
  mapStatus.conf.distUnitScale = applyDefault(mapStatus.conf.distUnit, 1, {1, 3.28084})
  mapStatus.conf.distUnitLongScale = applyDefault(mapStatus.conf.distUnitLong, 1, {1/1000, 1/1609.34})

  if mapStatus.conf.mapProvider == 0 or mapStatus.conf.mapTypeId == 0 then
    mapStatus.conf.mapType = "NONE"
  else
    mapStatus.conf.mapType = getMapTypeFolder(mapStatus.conf.mapProvider, mapStatus.conf.mapTypeId) or "NONE"
  end

  if mapStatus.conf.mapProvider == 0 then
    mapStatus.mapZoomLevel = max(1, tonumber(mapStatus.conf.mapZoomMin) or 1)
  else
    local zMin = tonumber(mapStatus.conf.mapZoomMin) or 1
    local zMax = tonumber(mapStatus.conf.mapZoomMax) or 20

    local availableMin, availableMax = getAvailableZoomBounds(mapStatus.conf.mapProvider, mapStatus.conf.mapTypeId)
    if availableMin ~= nil and availableMax ~= nil then
      zMin = max(zMin, availableMin)
      zMax = min(zMax, availableMax)
      if zMax < zMin then
        zMin = availableMin
        zMax = availableMax
      end
      mapStatus.conf.mapZoomMin = zMin
      mapStatus.conf.mapZoomMax = zMax
    end

    if zMax < zMin then
      zMax = zMin
      mapStatus.conf.mapZoomMax = zMax
    end

    -- Clamp current zoom into the effective range (never reset to a default).
    local cur = tonumber(mapStatus.mapZoomLevel) or zMin
    if cur < zMin then cur = zMin elseif cur > zMax then cur = zMax end
    mapStatus.mapZoomLevel = cur
  end

  -- Refresh cached guard booleans so hot-path checks are a single boolean test.
  local dbg = mapStatus.flagEnabled and mapStatus.flagEnabled(mapStatus.conf.enableDebugLog) or false
  mapStatus.debugEnabled = dbg
  mapStatus.perfActive   = dbg and (mapStatus.flagEnabled(mapStatus.conf.enablePerfProfile) or false)
end

local function configure(widget)
  -- Builds the Ethos configuration form, reading current values from mapStatus.conf and writing user edits back into it.
  if not widget then return end -- Safeguard: configuration callbacks may arrive before the widget fields exist.
  local providerChoices, mapTypeChoices = ensureAvailableMapSelections()

  -- Provider and map type at the top for quick access during field setup.
  local line = form.addLine("Map provider")
  widget.mapProviderField = form.addChoiceField(line, form.getFieldSlots(line)[0], providerChoices, function() return mapStatus.conf.mapProvider end,
    function(value)
      local oldProvider = mapStatus.conf.mapProvider
      mapStatus.conf.mapProvider = value
      mapStatus.conf.mapTypeId = normalizeLegacyMapTypeIdForProvider(value, mapStatus.conf.mapTypeId)

      if oldProvider ~= value then
        logMapSelectionAutofix("Provider changed: " .. providerLabelById(oldProvider) .. " -> " .. providerLabelById(value))
      end

      -- Force a fresh scan for provider/map type availability when provider changes.
      -- This avoids stale settings choices and prevents temporary "???" labels.
      invalidateAvailabilityCaches()
      local _, oldMapTypeId = syncMapTypeChoicesForProvider(widget, value, true)
      local mapTypeAdjusted = oldMapTypeId ~= mapStatus.conf.mapTypeId
      if oldMapTypeId ~= mapStatus.conf.mapTypeId then
        logMapSelectionAutofix("Map type adjusted after provider change: " .. mapTypeLabelById(oldMapTypeId) .. " -> " .. mapTypeLabelById(mapStatus.conf.mapTypeId))
      end
      applyConfig()

      -- Rebuild the settings form when the provider changed so the map type
      -- dropdown reflects the new provider's available types immediately.
      -- Without this, switching e.g. Google (Hybrid only) → ESRI (Street,
      -- Satellite, Hybrid) would keep showing only Hybrid until settings
      -- are closed and reopened.
      if oldProvider ~= value then
        local rebuilt = false
        if (not configRebuildInProgress) and form ~= nil and type(form.clear) == "function" then
          configRebuildInProgress = true
          local cleared = pcall(form.clear)
          if cleared then
            local configured = pcall(configure, widget)
            rebuilt = configured
          end
          configRebuildInProgress = false
          if rebuilt then
            return
          end
        end

        -- Fallback for Ethos variants without form.clear().
        local refreshed = false
        if not rebuilt then
          refreshed = refreshConfigureForm()
        end
        if not refreshed and mapStatus.debugEnabled then
          logMapSelectionAutofix("Form refresh API unavailable after provider change; choices may update only after reopening settings")
        end
      end

      if widget.mapZoomField ~= nil then
        widget.mapZoomField:enable(value ~= 0)
      end
      if widget.mapZoomMaxField ~= nil then
        widget.mapZoomMaxField:enable(value ~= 0)
      end
      if widget.mapZoomMinField ~= nil then
        widget.mapZoomMinField:enable(value ~= 0)
      end
    end
  )
  widget.mapProviderField:enable(not (#providerChoices == 1 and providerChoices[1][2] == 0))

  line = form.addLine("Map type")
  widget.mapTypeChoices = {}
  replaceChoices(widget.mapTypeChoices, mapTypeChoices)
  widget.mapTypeField = form.addChoiceField(line, form.getFieldSlots(line)[0], widget.mapTypeChoices, function() return mapStatus.conf.mapTypeId end,
    function(value)
      local oldMapTypeId = mapStatus.conf.mapTypeId
      mapStatus.conf.mapTypeId = value
      if oldMapTypeId ~= value then
        logMapSelectionAutofix("Map type changed: " .. mapTypeLabelById(oldMapTypeId) .. " -> " .. mapTypeLabelById(value))
        applyConfig()
      end
    end
  )
  widget.mapTypeField:enable(mapStatus.conf.mapProvider ~= 0)
  syncMapTypeChoicesForProvider(widget, mapStatus.conf.mapProvider, false)

  line = form.addLine("Map zoom max")
  widget.mapZoomMaxField = form.addNumberField(line, nil, 1, 20,
    function()
      widget.mapZoomMaxField:enable(mapStatus.conf.mapProvider ~= 0)
      return mapStatus.conf.mapZoomMax
    end,
    function(value)
      -- Keep unified zoom range valid and clamp current zoom into that range.
      local min = tonumber(mapStatus.conf.mapZoomMin) or 1
      if value < min then
        value = min
      end
      mapStatus.conf.mapZoomMax = value
      if (tonumber(mapStatus.mapZoomLevel) or 1) > value then
        mapStatus.mapZoomLevel = value
      end
    end
  )

  line = form.addLine("Map zoom min")
  widget.mapZoomMinField = form.addNumberField(line, nil, 1, 20,
    function()
      widget.mapZoomMinField:enable(mapStatus.conf.mapProvider ~= 0)
      return mapStatus.conf.mapZoomMin
    end,
    function(value)
      -- Keep unified zoom range valid and clamp current zoom into that range.
      local max = tonumber(mapStatus.conf.mapZoomMax) or 20
      if value > max then
        value = max
      end
      mapStatus.conf.mapZoomMin = value
      if (tonumber(mapStatus.mapZoomLevel) or 1) < value then
        mapStatus.mapZoomLevel = value
      end
    end
  )

  line = form.addLine("Waypoint download (INAV)")
  form.addBooleanField(line, nil,
    function() return mapStatus.conf.wpDownload == true end,
    function(value)
      local newVal = value == true
      if newVal == mapStatus.conf.wpDownload then return end
      mapStatus.conf.wpDownload = newVal
      -- Restart MSP with the new mode and clear/allow WP data accordingly
      if mapLibs and mapLibs.msp then
        mapLibs.msp.close()
        mapLibs.msp.open({ armingOnly = not newVal })
      end
      if not newVal then
        -- Clear all waypoint data from the map immediately
        mapStatus.mspMissions = {}
        mapStatus.mspMissionIdx = 1
        mapStatus.mspDownloadDone = false
        mapStatus._mspLastWpCount = 0
        markMapDirty()
      end
    end
  )

  line = form.addLine("Zoom control")
  form.addChoiceField(line, form.getFieldSlots(line)[0],
    {{"Off", 0}, {"3-Position", 1}, {"Proportional", 2}},
    function() return mapStatus.conf.zoomControl end,
    function(value)
      mapStatus.conf.zoomControl = value
      mapStatus.zoomControlTarget = nil
      mapStatus.zoomControlLastDir = 0
      mapStatus.cachedZoomChannelSrc = nil
    end
  )

  line = form.addLine("Zoom channel")
  widget.zoomChannelField = form.addNumberField(line, nil, 0, 64,
    function()
      widget.zoomChannelField:enable(mapStatus.conf.zoomControl ~= 0)
      return mapStatus.conf.zoomChannel
    end,
    function(value)
      mapStatus.conf.zoomChannel = value
      mapStatus.cachedZoomChannelSrc = nil
      mapStatus.cachedZoomChannelNum = 0
    end
  )

  line = form.addLine("Link quality source")
  form.addSourceField(line, nil, function() return mapStatus.conf.linkQualitySource end, function(value) mapStatus.conf.linkQualitySource = value end)

  line = form.addLine("User sensor 1")
  form.addSourceField(line, nil, function() return mapStatus.conf.userSensor1 end, function(value) mapStatus.conf.userSensor1 = value end)

  line = form.addLine("User sensor 2")
  form.addSourceField(line, nil, function() return mapStatus.conf.userSensor2 end, function(value) mapStatus.conf.userSensor2 = value end)

  line = form.addLine("User sensor 3")
  form.addSourceField(line, nil, function() return mapStatus.conf.userSensor3 end, function(value) mapStatus.conf.userSensor3 = value end)

  line = form.addLine("Airspeed/Groundspeed unit")
  form.addChoiceField(line, form.getFieldSlots(line)[0], {{"m/s",1},{"km/h",2},{"mph",3},{"kn",4}}, function() return mapStatus.conf.horSpeedUnit end, function(value) mapStatus.conf.horSpeedUnit = value end)

  line = form.addLine("Vertical speed unit")
  form.addChoiceField(line, form.getFieldSlots(line)[0], {{"m/s",1},{"ft/s",2},{"ft/min",3}}, function() return mapStatus.conf.vertSpeedUnit end, function(value) mapStatus.conf.vertSpeedUnit = value end)

  line = form.addLine("Altitude/Distance unit")
  form.addChoiceField(line, form.getFieldSlots(line)[0], {{"m",1},{"ft",2}}, function() return mapStatus.conf.distUnit end, function(value) mapStatus.conf.distUnit = value end)

  line = form.addLine("Long distance unit")
  form.addChoiceField(line, form.getFieldSlots(line)[0], {{"km",1},{"mi",2}}, function() return mapStatus.conf.distUnitLong end, function(value) mapStatus.conf.distUnitLong = value end)

  line = form.addLine("GPS coordinates format")
  form.addChoiceField(line, form.getFieldSlots(line)[0], {{"DMS",1},{"Decimal",2}}, function() return mapStatus.conf.gpsFormat end, function(value) mapStatus.conf.gpsFormat = value end)

  line = form.addLine("Vehicle symbol")
  form.addChoiceField(line, form.getFieldSlots(line)[0],
    {{"Arrow", 1}, {"Airplane", 2}, {"Multirotor", 3}},
    function() return mapStatus.conf.uavSymbol end,
    function(value) mapStatus.conf.uavSymbol = value end
  )

  line = form.addLine("Trail resolution")
  form.addChoiceField(line, form.getFieldSlots(line)[0],
    {{"Off", 0}, {"20 m", 20}, {"50 m", 50}, {"100 m", 100}, {"500 m", 500}, {"1 km", 1000}},
    function() return mapStatus.conf.mapTrailResolution end,
    function(value)
      mapStatus.conf.mapTrailResolution = value
      if widget.trailBendField ~= nil then
        widget.trailBendField:enable(value ~= 0)
      end
    end
  )

  line = form.addLine("Trail bend threshold")
  widget.trailBendField = form.addNumberField(line, nil, 3, 15,
    function() return mapStatus.conf.mapTrailHeadingThreshold end,
    function(value) mapStatus.conf.mapTrailHeadingThreshold = value end
  )
  widget.trailBendField:enable(mapStatus.conf.mapTrailResolution ~= 0)
  form.addStaticText(line, nil, "deg")

  -- Telemetry source mode: allows switching between ETHOS and direct sensor input.
  line = form.addLine("Telemetry source")
  widget.telemetrySourceModeField = form.addChoiceField(line, form.getFieldSlots(line)[0],
    {{"ETHOS", 1}, {"Sensors", 2}},
    function() return mapStatus.conf.telemetrySourceMode or 1 end,
    function(value)
      mapStatus.conf.telemetrySourceMode = value
      -- Toggle sensor source field visibility.
      local sensorsActive = (value == 2)
      if widget.sensorGpsLatField ~= nil then widget.sensorGpsLatField:enable(sensorsActive) end
      if widget.sensorGpsLonField ~= nil then widget.sensorGpsLonField:enable(sensorsActive) end
      if widget.sensorHeadingField ~= nil then widget.sensorHeadingField:enable(sensorsActive) end
      if widget.sensorSpeedField ~= nil then widget.sensorSpeedField:enable(sensorsActive) end
    end
  )

  line = form.addLine("GPS Lat source")
  widget.sensorGpsLatField = form.addSourceField(line, nil,
    function() return mapStatus.conf.sensorGpsLat end,
    function(value) mapStatus.conf.sensorGpsLat = value end
  )
  widget.sensorGpsLatField:enable(mapStatus.conf.telemetrySourceMode == 2)

  line = form.addLine("GPS Lon source")
  widget.sensorGpsLonField = form.addSourceField(line, nil,
    function() return mapStatus.conf.sensorGpsLon end,
    function(value) mapStatus.conf.sensorGpsLon = value end
  )
  widget.sensorGpsLonField:enable(mapStatus.conf.telemetrySourceMode == 2)

  line = form.addLine("Heading source (optional)")
  widget.sensorHeadingField = form.addSourceField(line, nil,
    function() return mapStatus.conf.sensorHeading end,
    function(value) mapStatus.conf.sensorHeading = value end
  )
  widget.sensorHeadingField:enable(mapStatus.conf.telemetrySourceMode == 2)

  line = form.addLine("Speed source (optional)")
  widget.sensorSpeedField = form.addSourceField(line, nil,
    function() return mapStatus.conf.sensorSpeed end,
    function(value) mapStatus.conf.sensorSpeed = value end
  )
  widget.sensorSpeedField:enable(mapStatus.conf.telemetrySourceMode == 2)

  -- ── Debug & Developer Tools ─────────────────────────────────────────────

  -- Debug logging is opt-in because writes go to the SD card during runtime.
  line = form.addLine("Enable debug log")
  widget.enableDebugLogField = form.addBooleanField(line, nil, 
    function() return mapStatus.flagEnabled(mapStatus.conf.enableDebugLog) end, 
    function(value) 
      local previous = mapStatus.flagEnabled(mapStatus.conf.enableDebugLog)

      if value and not previous then
        mapStatus.conf.enableDebugLog = true
        -- Refresh cache BEFORE logDebugSessionStart so the session header is emitted.
        mapStatus.debugEnabled = true
        mapStatus.perfActive   = mapStatus.flagEnabled(mapStatus.conf.enablePerfProfile)
        mapStatus.sessionLogged = false
        logDebugSessionStart("debug enabled")
      elseif (not value) and previous then
        if mapLibs and mapLibs.utils and mapLibs.utils.logDebug then
          mapLibs.utils.logDebug("SETTINGS", "=== DEBUG LOG DISABLED ===", true)
        end
        mapStatus.conf.enableDebugLog = false
        mapStatus.debugEnabled = false
        mapStatus.perfActive   = false
        mapStatus.sessionLogged = false
      else
        mapStatus.conf.enableDebugLog = value
        mapStatus.debugEnabled = mapStatus.flagEnabled(value)
        mapStatus.perfActive   = mapStatus.debugEnabled and mapStatus.flagEnabled(mapStatus.conf.enablePerfProfile)
      end

      -- Toggle perf profile field visibility based on debug log state
      if widget.enablePerfProfileField ~= nil then
        widget.enablePerfProfileField:enable(mapStatus.flagEnabled(value))
      end
    end
  )

  line = form.addLine("Enable perf profile (5s)")
  widget.enablePerfProfileField = form.addBooleanField(line, nil,
    function() return mapStatus.flagEnabled(mapStatus.conf.enablePerfProfile) end,
    function(value)
      local previous = mapStatus.flagEnabled(mapStatus.conf.enablePerfProfile)
      local enabled = mapStatus.flagEnabled(value)
      mapStatus.conf.enablePerfProfile = value

      if enabled and not previous then
        perfWindowStartMs = nil
        mapStatus.perfProfile.windowStartMs = 0
        if mapLibs and mapLibs.utils and mapLibs.utils.logDebug then
          mapLibs.utils.logDebug("PERF", "=== PERF PROFILE ENABLED (5s windows) ===", true)
        end
      elseif (not enabled) and previous then
        if mapLibs and mapLibs.utils and mapLibs.utils.logDebug then
          mapLibs.utils.logDebug("PERF", "=== PERF PROFILE DISABLED ===", true)
        end
      end
      -- Refresh cached perf boolean after toggle.
      mapStatus.perfActive = mapStatus.debugEnabled and mapStatus.flagEnabled(mapStatus.conf.enablePerfProfile)
    end
  )
  -- Only show perf profile option when debug logging is enabled.
  widget.enablePerfProfileField:enable(mapStatus.flagEnabled(mapStatus.conf.enableDebugLog))

  line = form.addLine("Widget version")
  form.addStaticText(line, nil, WIDGET_VERSION)

end

local function read(widget)
  if not widget then return end

  -- Slot 0: hidden schema marker.
  -- v1.0 had no marker, so slot 0 holds horSpeedUnit (a small integer 1-4).
  -- v2.0 stored a version string like "2.0-dev3"; v2.1+ stores STORAGE_SCHEMA (integer).
  -- Extract the leading integer to unify both formats: "2.0-dev3"→2, 2→2, nil→nil.
  local slot0 = storage.read("_settingsVersion")
  local schema = tonumber(tostring(slot0 or ""):match("^(%d+)"))

  if schema ~= STORAGE_SCHEMA then
    -- Version mismatch or v1.0 data → drain ALL remaining old slots so
    -- ETHOS’ positional counter is fully consumed, then apply defaults.
    -- On the next write() the current version and clean defaults are saved.
    applyConfig()
    -- Try to restore runtime state (observation marker, default position, zoom)
    -- from the file even across version bumps so the user doesn't lose them.
    local state = readStateFile()
    if state then
      mapStatus.observationLat = tonumber(state.observationLat)
      mapStatus.observationLon = tonumber(state.observationLon)
      mapStatus.conf.defaultLat = tonumber(state.defaultLat)
      mapStatus.conf.defaultLon = tonumber(state.defaultLon)
      local savedZoom = tonumber(state.mapZoomLevel)
      mapStatus.mapZoomLevel = savedZoom or mapStatus.conf.mapZoomDefault or 18
    end
    return
  end

  -- Current version → normal positional read.
  mapStatus.conf.horSpeedUnit = storageToConfig("horSpeedUnit", 1)
  mapStatus.conf.vertSpeedUnit = storageToConfig("vertSpeedUnit",1)
  mapStatus.conf.distUnit = storageToConfig("distUnit", 1)
  mapStatus.conf.distUnitLong = storageToConfig("distUnitLong", 1)
  mapStatus.conf.gpsFormat = storageToConfig("gpsFormat", 2)
  mapStatus.conf.mapProvider = storageToConfig("mapProvider", 2)
  mapStatus.conf.mapTypeId = storageToConfig("mapTypeId", 1)
  mapStatus.conf.mapZoomDefault = storageToConfigWithFallback("mapZoomDefault", 18, {"googleZoomDefault", "gmapZoomDefault"})
  mapStatus.conf.mapZoomMin = storageToConfigWithFallback("mapZoomMin", 1, {"googleZoomMin", "gmapZoomMin"})
  mapStatus.conf.mapZoomMax = storageToConfigWithFallback("mapZoomMax", 20, {"googleZoomMax", "gmapZoomMax"})
  mapStatus.conf.enableDebugLog = storageToConfig("enableDebugLog", false)
  mapStatus.conf.enablePerfProfile = storageToConfig("enablePerfProfile", false)
  mapStatus.conf.uavSymbol = storageToConfig("uavSymbol", 1)
  mapStatus.conf.zoomControl = storageToConfig("zoomControl", 0)
  mapStatus.conf.zoomChannel = storageToConfig("zoomChannel", 0)
  mapStatus.conf.mapTrailResolution = storageToConfig("mapTrailResolution", 50)
  mapStatus.conf.mapTrailHeadingThreshold = storageToConfig("mapTrailHeadingThreshold", 5)
  mapStatus.conf.linkQualitySource = storageToConfig("linkQualitySource", nil)
  mapStatus.conf.userSensor1 = storageToConfig("userSensor1", nil)
  mapStatus.conf.userSensor2 = storageToConfig("userSensor2", nil)
  mapStatus.conf.userSensor3 = storageToConfig("userSensor3", nil)
  mapStatus.conf.telemetrySourceMode = storageToConfig("telemetrySourceMode", 1)
  mapStatus.conf.sensorGpsLat = storageToConfig("sensorGpsLat", nil)
  mapStatus.conf.sensorGpsLon = storageToConfig("sensorGpsLon", nil)
  mapStatus.conf.sensorHeading = storageToConfig("sensorHeading", nil)
  mapStatus.conf.sensorSpeed = storageToConfig("sensorSpeed", nil)
  mapStatus.conf.wpDownload = storageToConfig("wpDownload", true)

  -- Restore runtime state from file (observation marker, default position, zoom level).
  local state = readStateFile()
  if state then
    mapStatus.observationLat = tonumber(state.observationLat)
    mapStatus.observationLon = tonumber(state.observationLon)
    mapStatus.conf.defaultLat = tonumber(state.defaultLat)
    mapStatus.conf.defaultLon = tonumber(state.defaultLon)
    local savedZoom = tonumber(state.mapZoomLevel)
    mapStatus.mapZoomLevel = savedZoom or mapStatus.conf.mapZoomDefault or 18
  else
    mapStatus.mapZoomLevel = mapStatus.conf.mapZoomDefault or 18
  end

  applyConfig()
end

local function write(widget)
  if not widget then return end

  -- Slot 0: schema marker (always first).
  storage.write("_settingsVersion", STORAGE_SCHEMA)

  storage.write("horSpeedUnit", mapStatus.conf.horSpeedUnit)
  storage.write("vertSpeedUnit", mapStatus.conf.vertSpeedUnit)
  storage.write("distUnit", mapStatus.conf.distUnit)
  storage.write("distUnitLong", mapStatus.conf.distUnitLong)
  storage.write("gpsFormat", mapStatus.conf.gpsFormat)
  storage.write("mapProvider", mapStatus.conf.mapProvider)
  storage.write("mapTypeId", mapStatus.conf.mapTypeId)
  storage.write("mapZoomDefault", mapStatus.conf.mapZoomDefault)
  storage.write("mapZoomMin", mapStatus.conf.mapZoomMin)
  storage.write("mapZoomMax", mapStatus.conf.mapZoomMax)
  storage.write("enableDebugLog", mapStatus.conf.enableDebugLog == true)
  storage.write("enablePerfProfile", mapStatus.conf.enablePerfProfile == true)
  storage.write("uavSymbol", mapStatus.conf.uavSymbol)
  storage.write("zoomControl", mapStatus.conf.zoomControl)
  storage.write("zoomChannel", mapStatus.conf.zoomChannel)
  storage.write("mapTrailResolution", mapStatus.conf.mapTrailResolution)
  storage.write("mapTrailHeadingThreshold", mapStatus.conf.mapTrailHeadingThreshold)
  storage.write("linkQualitySource", mapStatus.conf.linkQualitySource)
  storage.write("userSensor1", mapStatus.conf.userSensor1)
  storage.write("userSensor2", mapStatus.conf.userSensor2)
  storage.write("userSensor3", mapStatus.conf.userSensor3)
  storage.write("telemetrySourceMode", mapStatus.conf.telemetrySourceMode)
  storage.write("sensorGpsLat", mapStatus.conf.sensorGpsLat)
  storage.write("sensorGpsLon", mapStatus.conf.sensorGpsLon)
  storage.write("sensorHeading", mapStatus.conf.sensorHeading)
  storage.write("sensorSpeed", mapStatus.conf.sensorSpeed)
  storage.write("wpDownload", mapStatus.conf.wpDownload == true)

  -- Persist runtime state (observation, default position, zoom) to file
  writeStateFile()

  applyConfig()
  mapLibs.resetLib.resetLayout(widget)
end

local function registerSources()
  -- Registers exported telemetry sources so other Ethos widgets can read values computed by this widget.
  system.registerSource({
    key="YM_HOME",
    name="HomeDistance",
    init=makeSourceInit("HomeDistance"),
    wakeup=makeSourceWakeup("HomeDistance")
  })
  system.registerSource({
    key="YM_GSPD",
    name="GroundSpeed",
    init=makeSourceInit("GroundSpeed"),
    wakeup=makeSourceWakeup("GroundSpeed")
  })
  system.registerSource({
    key="YM_COG",
    name="CourseOverGround",
    init=makeSourceInit("CourseOverGround"),
    wakeup=makeSourceWakeup("CourseOverGround")
  })
end

local function init()
  -- Registers the widget lifecycle callbacks and exported sources with Ethos during radio startup.
  local function close(widget)
    if mapLibs and mapLibs.msp then
      mapLibs.msp.close()
    end
  end

  system.registerWidget({key="ethosmw", name="ETHOS Mapping Widget", paint=paint, event=event, wakeup=wakeup, create=create, close=close, configure=configure, menu=menu, read=read, write=write })
  registerSources()
end

return {init=init}