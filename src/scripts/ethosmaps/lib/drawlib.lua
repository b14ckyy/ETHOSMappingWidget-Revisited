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
local tostring = tostring
local floor, max, min = math.floor, math.max, math.min
local sin, cos, rad = math.sin, math.cos, math.rad
local sub = string.sub
local tinsert = table.insert
local pairs = pairs

local status = nil

local drawLib = {}
local bitmaps = {}
local topBarUnifiedFont = nil
local topBarValueCache = {}
local topBarValueCacheCount = 0
local TOP_BAR_CACHE_MAX = 20

-- Pre-allocated tables reused each frame inside drawTopBar to avoid per-frame allocations.
local _sensorEntries = {}
local _sensorNames = {}
local _candidateFonts_medium = nil  -- lazily filled on first use (FONT constants must be available)
local _candidateFonts_full   = nil

-- Cached system sources for drawTopBar (system.getSource is expensive; these never change).
local _cachedTxVoltSrc = nil

-- Font selection cache: skip expensive font-fitting loop when inputs haven't changed.
local _topBarFontCacheKey = nil

-- Pre-computed angle offsets for drawRArrow (constants, never change).
local ARROW_ANG_150  = rad(150)
local ARROW_ANG_N150 = rad(-150)
local ARROW_ANG_180  = rad(180)

-- Pre-computed angle offsets for drawRMultirotor.
local ROTOR_ARM_45  = rad(45)
local ROTOR_ARM_135 = rad(135)
local ROTOR_ARM_225 = rad(225)
local ROTOR_ARM_315 = rad(315)
local HALF_PI = math.pi / 2
local _multirotorShadowColor = nil  -- cached lcd.RGB(0,0,0,0.4) for rotor disc shadow

-- Per-tick cache for safeSensorName to avoid redundant pcall overhead.
local _sensorNameCache = {}
local _sensorNameCacheTick = -1

local function safeSensorName(sensor)
  if sensor == nil then
    return nil
  end
  -- Guard against corrupted config values (boolean/number instead of source object).
  local st = type(sensor)
  if st ~= "userdata" and st ~= "table" then
    return nil
  end
  local barTickSerial = (status and status.barTickSerial) or 0
  if barTickSerial ~= _sensorNameCacheTick then
    for k in pairs(_sensorNameCache) do _sensorNameCache[k] = nil end
    _sensorNameCacheTick = barTickSerial
  end
  local key = tostring(sensor)
  local cached = _sensorNameCache[key]
  if cached ~= nil then
    return cached ~= false and cached or nil
  end
  local ok, value = pcall(function() return sensor:name() end)
  if not ok or value == nil then
    _sensorNameCache[key] = false
    return nil
  end
  value = tostring(value)
  if value == "" or value == "---" then
    _sensorNameCache[key] = false
    return nil
  end
  _sensorNameCache[key] = value
  return value
end

local function safeSensorValueText(sensor)
  if sensor == nil then
    return "--"
  end

  local barTickSerial = (status and status.barTickSerial) or 0
  local cacheKey = tostring(sensor)
  local sensorName = safeSensorName(sensor)
  if sensorName ~= nil then
    cacheKey = sensorName .. "|" .. cacheKey
  end

  local cached = topBarValueCache[cacheKey]
  if cached ~= nil and cached.tickSerial == barTickSerial then
    return cached.text
  end

  local valueText = "--"

  local okStr, text = pcall(function() return sensor:stringValue() end)
  if okStr and text ~= nil then
    valueText = tostring(text)
  else
    local okVal, value = pcall(function() return sensor:value() end)
    if okVal and value ~= nil then
      valueText = tostring(value)
    end
  end

  if topBarValueCacheCount >= TOP_BAR_CACHE_MAX then
    -- Evict stale entries instead of nuking the entire cache to avoid flicker.
    local freshCount = 0
    for k, v in pairs(topBarValueCache) do
      if v.tickSerial ~= barTickSerial then
        topBarValueCache[k] = nil
      else
        freshCount = freshCount + 1
      end
    end
    topBarValueCacheCount = freshCount
  end
  local cached = topBarValueCache[cacheKey]
  if cached then
    cached.tickSerial = barTickSerial
    cached.text = valueText
  else
    topBarValueCache[cacheKey] = { tickSerial = barTickSerial, text = valueText }
    topBarValueCacheCount = topBarValueCacheCount + 1
  end

  return valueText
end

local function getFontRank(font)
  if font == FONT_XS then
    return 1
  elseif font == FONT_S then
    return 2
  elseif font == FONT_L then
    return 3
  end
  return 0
end

local function getTopBarSensorName(sensor, label, compactNames)
  local sensorName = safeSensorName(sensor)
  local name = label or sensorName or "SRC"
  if compactNames then
    name = sub(name, 1, 4)
  end
  return name
end

local function getTopBarSensorBlockWidth(name, valueText, barFont, labelFont)
  lcd.font(barFont)
  local valW = lcd.getTextSize(tostring(valueText or "--"))
  lcd.font(labelFont)
  local lblW = lcd.getTextSize(tostring(name or "SRC"))
  return valW + lblW + 10, valW
end

-- Label font for the top bar is always FONT_XS regardless of the value font.
local TOP_BAR_LABEL_FONT = FONT_XS

function drawLib.drawText(x, y, txt, font, color, flags, blink)
  -- Draws text with the requested font and color, using the shared blink state to optionally suppress output.
  lcd.font(font)
  lcd.color(color)
  if status.blinkon == true or blink == nil or blink == false then
    lcd.drawText(x, y, txt, flags)
  end
end

function drawLib.drawNumber(x, y, num, precision, font, color, flags, blink)
  -- Draws a formatted number with optional blink gating and sends it directly to the LCD.
  lcd.font(font)
  lcd.color(color)
  if status.blinkon == true or blink == nil or blink == false then
    lcd.drawNumber(x, y, num, nil, precision, flags)
  end
end

function drawLib.drawNoGPSData(widget)
  -- Draws the no-GPS overlay when the layout detects that no valid position is available.
  local w = status.widgetWidth
  local h = status.widgetHeight
  local sx = status.scaleX
  local sy = status.scaleY
  local verticalMedium = status.verticalMedium == true or (w < (status.compactWidthThreshold or 450))

  local fontBig = verticalMedium and FONT_L or FONT_XXL

  lcd.font(fontBig)
  local textW, textH = lcd.getTextSize("...waiting for GPS")

  local boxW = min(floor(textW + 80*sx), floor(w * 0.88))
  local boxH = floor(textH + 55*sy)
  local boxX = floor((w - boxW) / 2)
  local boxY = floor((h / 2) - boxH / 2) - 15*sy

  lcd.color(RED)
  lcd.drawFilledRectangle(boxX, boxY, boxW, boxH)

  lcd.color(WHITE)
  lcd.drawRectangle(boxX, boxY, boxW, boxH, 3)

  lcd.font(fontBig)
  lcd.drawText(w / 2, boxY + 25*sy, "...waiting for GPS", CENTERED)
end

function drawLib.drawTopBar(widget, barTop, barHeight)
  -- Draws the top status bar by combining model info, system voltage, and user-selected telemetry sources.
  local w = status.widgetWidth
  local sx = status.scaleX
  local sy = status.scaleY
  local conf = status.conf
  local colors = status.colors
  local top = barTop or 0
  local barH = barHeight or floor(26 * sy)
  local verticalMedium = status.verticalMedium == true or (w < (status.compactWidthThreshold or 450))
  local verticalTiny = w < (status.tinyWidthThreshold or 350)
  local showModelName = w >= 600
  local compactNames = verticalMedium
  local labelFont = TOP_BAR_LABEL_FONT

  local sensorEntries = _sensorEntries
  local sensorCount = 0

  -- Slot 1: TX voltage (always present; source cached to avoid per-frame getSource overhead).
  if _cachedTxVoltSrc == nil then
    _cachedTxVoltSrc = system.getSource({category=CATEGORY_SYSTEM, member=MAIN_VOLTAGE, options=0})
  end
  sensorCount = sensorCount + 1
  local e1 = sensorEntries[sensorCount]
  if e1 then e1.sensor = _cachedTxVoltSrc; e1.label = "TX"
  else sensorEntries[sensorCount] = { sensor = _cachedTxVoltSrc, label = "TX" } end

  -- Slot 2: link quality (always present).
  sensorCount = sensorCount + 1
  local e2 = sensorEntries[sensorCount]
  if e2 then e2.sensor = conf.linkQualitySource; e2.label = nil
  else sensorEntries[sensorCount] = { sensor = conf.linkQualitySource, label = nil } end

  if not verticalTiny and safeSensorName(conf.userSensor1) ~= nil then
    sensorCount = sensorCount + 1
    local ei = sensorEntries[sensorCount]
    if ei then ei.sensor = conf.userSensor1; ei.label = nil
    else sensorEntries[sensorCount] = { sensor = conf.userSensor1, label = nil } end
  end
  if not verticalTiny and safeSensorName(conf.userSensor2) ~= nil then
    sensorCount = sensorCount + 1
    local ei = sensorEntries[sensorCount]
    if ei then ei.sensor = conf.userSensor2; ei.label = nil
    else sensorEntries[sensorCount] = { sensor = conf.userSensor2, label = nil } end
  end
  if not verticalTiny and safeSensorName(conf.userSensor3) ~= nil then
    sensorCount = sensorCount + 1
    local ei = sensorEntries[sensorCount]
    if ei then ei.sensor = conf.userSensor3; ei.label = nil
    else sensorEntries[sensorCount] = { sensor = conf.userSensor3, label = nil } end
  end
  -- Clear any leftover slots from a previous frame with more sensors.
  for i = sensorCount + 1, #sensorEntries do sensorEntries[i] = nil end

  -- Pre-cache sensor names to avoid redundant pcall lookups in the font-selection loop.
  local sensorNames = _sensorNames
  for e = 1, sensorCount do
    sensorNames[e] = safeSensorName(sensorEntries[e].sensor)
  end
  for i = sensorCount + 1, #sensorNames do sensorNames[i] = nil end

  -- Lazily initialise the constant candidate-font tables (ETHOS font globals must be set first).
  if _candidateFonts_medium == nil then
    _candidateFonts_medium = {FONT_S, FONT_XS}
    _candidateFonts_full   = {FONT_L, FONT_S, FONT_XS}
  end
  local candidateFonts = verticalMedium and _candidateFonts_medium or _candidateFonts_full
  local modelText = status.modelString or model.name()
  local selectedFont = candidateFonts[#candidateFonts]
  local selectedUsedWidth = 0
  local selectedAvailableWidth = 0

  -- Cache key: skip the expensive font-fitting loop when layout inputs haven't changed.
  local fontCacheKey = w * 100 + sensorCount * 10 + (verticalMedium and 1 or 0)
  if _topBarFontCacheKey == fontCacheKey and topBarUnifiedFont ~= nil then
    selectedFont = topBarUnifiedFont
  else
    for i = 1, #candidateFonts do
    local candidateFont = candidateFonts[i]

    local minTelemetryX = 6 * sx
    if showModelName then
      lcd.font(candidateFont)
      local modelW = lcd.getTextSize(modelText)
      minTelemetryX = 8 * sx + modelW + 12 * sx
    end

    local usedWidth = 0
    for e = 1, sensorCount do
      if sensorNames[e] ~= nil then
        local entry = sensorEntries[e]
        local name = getTopBarSensorName(entry.sensor, entry.label, compactNames)
        local valueText = safeSensorValueText(entry.sensor)
        local blockW = getTopBarSensorBlockWidth(name, valueText, candidateFont, labelFont)
        usedWidth = usedWidth + blockW
      end
    end

    local availableWidth = max(20, (w - 12 * sx) - minTelemetryX)
    selectedFont = candidateFont
    selectedUsedWidth = usedWidth
    selectedAvailableWidth = availableWidth
    if usedWidth <= availableWidth then
      break
    end
  end

  local cachedFont = topBarUnifiedFont
  if cachedFont ~= nil and getFontRank(selectedFont) > getFontRank(cachedFont) then
    if (selectedAvailableWidth - selectedUsedWidth) < 12 then
      selectedFont = cachedFont
    end
  end
  topBarUnifiedFont = selectedFont
  _topBarFontCacheKey = fontCacheKey
  end -- font cache miss

  local minTelemetryX = 6 * sx

  lcd.color(colors.barBackground)
  lcd.pen(SOLID)
  lcd.drawFilledRectangle(0, top, w, barH)

  if showModelName then
    local modelY = top + floor(2 * sy)
    drawLib.drawText(8*sx, modelY, modelText, selectedFont, colors.barText, LEFT)
    lcd.font(selectedFont)
    local modelW = lcd.getTextSize(modelText)
    minTelemetryX = 8 * sx + modelW + 12 * sx
  end

  local offset = 12*sx
  for e = 1, sensorCount do
    local entry = sensorEntries[e]
    offset = offset + drawLib.drawTopBarSensor(widget, w - offset, entry.sensor, entry.label, minTelemetryX, selectedFont, labelFont, compactNames, top, barH)
  end
end

function drawLib.drawTopBarSensor(widget, x, sensor, label, minX, barFont, labelFont, compactNames, barTop, barHeight)
  -- Draws one top-bar sensor block by reading its current string value and writing the label/value pair to the LCD.
  if safeSensorName(sensor) == nil then
    return 80 -- Safeguard: skip invalid sensor handles and reserve a stable fallback width.
  end

  local name = getTopBarSensorName(sensor, label, compactNames)
  local valueText = safeSensorValueText(sensor)
  local blockW, valW = getTopBarSensorBlockWidth(name, valueText, barFont, labelFont)

  lcd.font(barFont)
  local _, valueH = lcd.getTextSize(valueText)
  local valueY = (barTop or 0) + floor(((barHeight or 0) - valueH) / 2)
  local labelY = valueY

  drawLib.drawText(x - valW - 2, labelY, name, labelFont, status.colors.barText, RIGHT)
  drawLib.drawText(x - valW, valueY, valueText, barFont, status.colors.barText, LEFT)

  return blockW
end

function drawLib.drawRArrow(x,y,r,angle,color)
  -- Draws a rotated arrow primitive used by the map for aircraft heading and home direction overlays.
  local baseRad = rad(angle - 90)
  local cosB, sinB = cos(baseRad), sin(baseRad)
  local x1 = x + r * cosB
  local y1 = y + r * sinB

  local cos2, sin2 = cos(baseRad + ARROW_ANG_150), sin(baseRad + ARROW_ANG_150)
  local x2 = x + r * cos2
  local y2 = y + r * sin2

  local cos3, sin3 = cos(baseRad + ARROW_ANG_N150), sin(baseRad + ARROW_ANG_N150)
  local x3 = x + r * cos3
  local y3 = y + r * sin3

  local r2 = r * 0.5
  local cos4, sin4 = cos(baseRad + ARROW_ANG_180), sin(baseRad + ARROW_ANG_180)
  local x4 = x + r2 * cos4
  local y4 = y + r2 * sin4

  lcd.pen(SOLID)
  lcd.color(color)
  lcd.drawLine(x1,y1,x2,y2)
  lcd.drawLine(x1,y1,x3,y3)
  lcd.drawLine(x2,y2,x4,y4)
  lcd.drawLine(x3,y3,x4,y4)
end

function drawLib.drawRAirplane(x, y, r, angle, color, cb, sb)
  -- Draws a rotated flying-wing silhouette with rear propeller stub.
  -- Accepts optional pre-computed cos/sin of (angle-90) to avoid redundant trig.
  if cb == nil then
    local baseRad = rad(angle - 90)
    cb, sb = cos(baseRad), sin(baseRad)
  end

  -- Nose tip (shorter fuselage — wingspan wider than length)
  local nx = x + r * 0.70 * cb
  local ny = y + r * 0.70 * sb

  -- Wing leading edge tips (wide out, barely swept back)
  local wlfx = x + r * (-0.05*cb + 0.95*sb)                 -- left front (-0.05, -0.95)
  local wlfy = y + r * (-0.05*sb - 0.95*cb)
  local wrfx = x + r * (-0.05*cb - 0.95*sb)                 -- right front (-0.05, +0.95)
  local wrfy = y + r * (-0.05*sb + 0.95*cb)

  -- Wing trailing edge tips (clipped: behind leading tips, slightly inward)
  local wlbx = x + r * (-0.25*cb + 0.85*sb)                 -- left back (-0.25, -0.85)
  local wlby = y + r * (-0.25*sb - 0.85*cb)
  local wrbx = x + r * (-0.25*cb - 0.85*sb)                 -- right back (-0.25, +0.85)
  local wrby = y + r * (-0.25*sb + 0.85*cb)

  -- Trailing edge inner (forward of tips — V notch)
  local tlx = x + r * ( 0.05*cb + 0.15*sb)                  -- left inner (0.05, -0.15)
  local tly = y + r * ( 0.05*sb - 0.15*cb)
  local trx = x + r * ( 0.05*cb - 0.15*sb)                  -- right inner (0.05, +0.15)
  local try_ = y + r * ( 0.05*sb + 0.15*cb)

  -- Propeller stub (small line just behind body center)
  local plx = x + r * (-0.10*cb + 0.10*sb)                  -- prop left (-0.10, -0.10)
  local ply = y + r * (-0.10*sb - 0.10*cb)
  local prx = x + r * (-0.10*cb - 0.10*sb)                  -- prop right (-0.10, +0.10)
  local pry = y + r * (-0.10*sb + 0.10*cb)

  lcd.pen(SOLID)
  lcd.color(color)
  -- Leading edges (nose to wing front tips)
  lcd.drawLine(nx, ny, wlfx, wlfy)
  lcd.drawLine(nx, ny, wrfx, wrfy)
  -- Clipped wing tips
  lcd.drawLine(wlfx, wlfy, wlbx, wlby)
  lcd.drawLine(wrfx, wrfy, wrbx, wrby)
  -- Trailing edges (wing back tips to inner body)
  lcd.drawLine(wlbx, wlby, tlx, tly)
  lcd.drawLine(wrbx, wrby, trx, try_)
  -- Rear closing (inner trailing edges)
  lcd.drawLine(tlx, tly, trx, try_)
  -- Propeller stub
  lcd.drawLine(plx, ply, prx, pry)
end

function drawLib.drawRMultirotor(x,y,r,angle,fillColor)
  -- Draws a rotated multirotor symbol with self-contained coloring:
  -- Black 2px X-frame arms, concentric black/fillColor rotor circles,
  -- heading triangle (black outline, fillColor fill) with black neck.
  fillColor = fillColor or WHITE
  local baseRad = rad(angle - 90)
  local armR = r * 0.75
  local rotorR = r * 0.28

  -- Arm endpoints (4 diagonal arms in X configuration)
  local c1, s1 = cos(baseRad + ROTOR_ARM_45), sin(baseRad + ROTOR_ARM_45)
  local c2, s2 = cos(baseRad + ROTOR_ARM_135), sin(baseRad + ROTOR_ARM_135)
  local c3, s3 = cos(baseRad + ROTOR_ARM_225), sin(baseRad + ROTOR_ARM_225)
  local c4, s4 = cos(baseRad + ROTOR_ARM_315), sin(baseRad + ROTOR_ARM_315)

  local ax1 = x + armR * c1
  local ay1 = y + armR * s1
  local ax2 = x + armR * c2
  local ay2 = y + armR * s2
  local ax3 = x + armR * c3
  local ay3 = y + armR * s3
  local ax4 = x + armR * c4
  local ay4 = y + armR * s4

  -- Perpendicular offsets for 2px arm thickness
  local p1x, p1y = cos(baseRad + ROTOR_ARM_135), sin(baseRad + ROTOR_ARM_135)
  local p2x, p2y = cos(baseRad + ROTOR_ARM_225), sin(baseRad + ROTOR_ARM_225)

  lcd.pen(SOLID)

  -- X-frame arms: 2px thick, black only
  lcd.color(BLACK)
  lcd.drawLine(ax1, ay1, ax3, ay3)
  lcd.drawLine(ax1 + p1x, ay1 + p1y, ax3 + p1x, ay3 + p1y)
  lcd.drawLine(ax2, ay2, ax4, ay4)
  lcd.drawLine(ax2 + p2x, ay2 + p2y, ax4 + p2x, ay4 + p2y)

  -- Rotor circles: black shadow fill (alpha 0.4) + fillColor ring on top
  if not _multirotorShadowColor then
    _multirotorShadowColor = lcd.RGB(0, 0, 0, 0.4)
  end
  lcd.color(_multirotorShadowColor)
  lcd.drawFilledCircle(ax1, ay1, rotorR - 1)
  lcd.drawFilledCircle(ax2, ay2, rotorR - 1)
  lcd.drawFilledCircle(ax3, ay3, rotorR - 1)
  lcd.drawFilledCircle(ax4, ay4, rotorR - 1)
  lcd.color(fillColor)
  lcd.drawCircle(ax1, ay1, rotorR - 1)
  lcd.drawCircle(ax2, ay2, rotorR - 1)
  lcd.drawCircle(ax3, ay3, rotorR - 1)
  lcd.drawCircle(ax4, ay4, rotorR - 1)

  -- Heading triangle tip
  local noseR = r * 0.55
  local cb, sb = cos(baseRad), sin(baseRad)
  local tipX = x + noseR * cb
  local tipY = y + noseR * sb

  -- Triangle base center + perpendicular for base width
  local triBaseR = r * 0.30
  local triHalfW = r * 0.15
  local bcx = x + triBaseR * cb
  local bcy = y + triBaseR * sb
  local cp, sp = cos(baseRad + HALF_PI), sin(baseRad + HALF_PI)
  local b1x = bcx + triHalfW * cp
  local b1y = bcy + triHalfW * sp
  local b2x = bcx - triHalfW * cp
  local b2y = bcy - triHalfW * sp

  -- Neck: black line from center to triangle base
  lcd.color(BLACK)
  lcd.drawLine(x, y, bcx, bcy)

  -- Triangle outline (black)
  lcd.drawLine(tipX, tipY, b1x, b1y)
  lcd.drawLine(tipX, tipY, b2x, b2y)
  lcd.drawLine(b1x, b1y, b2x, b2y)

  -- Triangle inner fill (fillColor, inset toward centroid)
  local cx3 = (tipX + b1x + b2x) / 3
  local cy3 = (tipY + b1y + b2y) / 3
  local s = 0.70
  local itx  = cx3 + (tipX - cx3) * s
  local ity  = cy3 + (tipY - cy3) * s
  local ib1x = cx3 + (b1x - cx3) * s
  local ib1y = cy3 + (b1y - cy3) * s
  local ib2x = cx3 + (b2x - cx3) * s
  local ib2y = cy3 + (b2y - cy3) * s

  lcd.color(fillColor)
  lcd.drawLine(itx, ity, ib1x, ib1y)
  lcd.drawLine(itx, ity, ib2x, ib2y)
  lcd.drawLine(ib1x, ib1y, ib2x, ib2y)
end

function drawLib.drawVehicle(x, y, r, heading, symbolType, fillColor)
  -- Dispatches to the correct vehicle symbol drawer based on user config.
  -- Arrow and Airplane use a semi-transparent filled shadow backdrop instead of
  -- a hard black outline.  Multirotor already has its own shadow circles.
  fillColor = fillColor or WHITE
  if not _uavShadowColor then _uavShadowColor = lcd.RGB(0, 0, 0, 0.4) end
  if symbolType == 2 then
    -- Airplane: 3-triangle shadow (blunt wing tips) + fillColor wireframe on top.
    local baseRad = rad(heading - 90)
    local cb, sb = cos(baseRad), sin(baseRad)
    -- Shadow vertices at full radius r (wireframe at r-2 → 2px margin).
    local sNx   = x + r * ( 0.70 * cb)
    local sNy   = y + r * ( 0.70 * sb)
    local sWFLx = x + r * (-0.05 * cb + 0.95 * sb)
    local sWFLy = y + r * (-0.05 * sb - 0.95 * cb)
    local sWFRx = x + r * (-0.05 * cb - 0.95 * sb)
    local sWFRy = y + r * (-0.05 * sb + 0.95 * cb)
    local sWBLx = x + r * (-0.25 * cb + 0.85 * sb)
    local sWBLy = y + r * (-0.25 * sb - 0.85 * cb)
    local sWBRx = x + r * (-0.25 * cb - 0.85 * sb)
    local sWBRy = y + r * (-0.25 * sb + 0.85 * cb)
    lcd.color(_uavShadowColor)
    lcd.drawFilledTriangle(sNx, sNy, sWBLx, sWBLy, sWBRx, sWBRy)   -- central (flat rear)
    lcd.drawFilledTriangle(sNx, sNy, sWFLx, sWFLy, sWBLx, sWBLy)   -- left wing cap
    lcd.drawFilledTriangle(sNx, sNy, sWFRx, sWFRy, sWBRx, sWBRy)   -- right wing cap
    drawLib.drawRAirplane(x, y, r - 2, heading, fillColor, cb, sb)
  elseif symbolType == 3 then
    drawLib.drawRMultirotor(x, y, r, heading, fillColor)
  else
    -- Arrow: shadow filled chevron (2 triangles, 2px bigger) + fillColor wireframe.
    local baseRad = rad(heading - 90)
    local cb, sb = cos(baseRad), sin(baseRad)
    local c150, s150 = cos(baseRad + ARROW_ANG_150), sin(baseRad + ARROW_ANG_150)
    local cn150, sn150 = cos(baseRad + ARROW_ANG_N150), sin(baseRad + ARROW_ANG_N150)
    local c180, s180 = cos(baseRad + ARROW_ANG_180), sin(baseRad + ARROW_ANG_180)
    -- Shadow at r-3 (2px bigger than fill at r-5)
    local sr = r - 3
    local sx1, sy1 = x + sr * cb, y + sr * sb
    local sx2, sy2 = x + sr * c150, y + sr * s150
    local sx3, sy3 = x + sr * cn150, y + sr * sn150
    local sr2 = sr * 0.5
    local sx4, sy4 = x + sr2 * c180, y + sr2 * s180
    lcd.color(_uavShadowColor)
    lcd.drawFilledTriangle(sx1, sy1, sx2, sy2, sx4, sy4)
    lcd.drawFilledTriangle(sx1, sy1, sx3, sy3, sx4, sy4)
    -- Fill wireframe at r-5
    local fr = r - 5
    local fx1, fy1 = x + fr * cb, y + fr * sb
    local fx2, fy2 = x + fr * c150, y + fr * s150
    local fx3, fy3 = x + fr * cn150, y + fr * sn150
    local fr2 = fr * 0.5
    local fx4, fy4 = x + fr2 * c180, y + fr2 * s180
    lcd.pen(SOLID)
    lcd.color(fillColor)
    lcd.drawLine(fx1, fy1, fx2, fy2)
    lcd.drawLine(fx1, fy1, fx3, fy3)
    lcd.drawLine(fx2, fy2, fx4, fy4)
    lcd.drawLine(fx3, fy3, fx4, fy4)
  end
end

function drawLib.drawBitmap(x, y, bitmap, w, h)
  -- Draws a named bitmap by resolving it through the local bitmap cache first.
  local bmp = drawLib.getBitmap(bitmap)
  if bmp ~= nil then
    lcd.drawBitmap(x, y, bmp, w, h)
  end
end

function drawLib.getBitmap(name)
  -- Lazily loads a bitmap from the SD card and keeps it cached for repeated draw calls.
  if bitmaps[name] == nil then
    bitmaps[name] = lcd.loadBitmap("/bitmaps/ethosmaps/bitmaps/"..name..".png")
  end
  return bitmaps[name]
end

function drawLib.computeOutCode(x,y,xmin,ymin,xmax,ymax)
  -- Computes a Cohen-Sutherland outcode so callers can test whether a point lies outside a viewport.
  local code = 0
  if x < xmin then code = code | 1 end
  if x > xmax then code = code | 2 end
  if y < ymin then code = code | 8 end
  if y > ymax then code = code | 4 end
  return code
end

function drawLib.isInside(x,y,xmin,ymin,xmax,ymax)
  -- Returns whether a point falls inside the requested rectangle by reusing computeOutCode().
  return drawLib.computeOutCode(x,y,xmin,ymin,xmax,ymax) == 0
end

-- Cohen-Sutherland line clipping against a rectangular viewport.
-- Returns clipped x1,y1,x2,y2 or nil if the segment is entirely outside.
-- NOTE: outCode is inlined (not a local closure) to save ~1,500+ VM
-- opcodes per paint frame — critical for the ETHOS 40K instruction limit.
function drawLib.clipLine(x1, y1, x2, y2, xmin, ymin, xmax, ymax)
  local code1 = 0
  if x1 < xmin then code1 = 1 elseif x1 > xmax then code1 = 2 end
  if y1 < ymin then code1 = code1 | 8 elseif y1 > ymax then code1 = code1 | 4 end
  local code2 = 0
  if x2 < xmin then code2 = 1 elseif x2 > xmax then code2 = 2 end
  if y2 < ymin then code2 = code2 | 8 elseif y2 > ymax then code2 = code2 | 4 end
  for _ = 1, 20 do
    if (code1 | code2) == 0 then return x1, y1, x2, y2 end
    if (code1 & code2) ~= 0 then return nil end
    local codeOut = code1 ~= 0 and code1 or code2
    local x, y
    if (codeOut & 8) ~= 0 then
      x = x1 + (x2 - x1) * (ymin - y1) / (y2 - y1); y = ymin
    elseif (codeOut & 4) ~= 0 then
      x = x1 + (x2 - x1) * (ymax - y1) / (y2 - y1); y = ymax
    elseif (codeOut & 2) ~= 0 then
      y = y1 + (y2 - y1) * (xmax - x1) / (x2 - x1); x = xmax
    else
      y = y1 + (y2 - y1) * (xmin - x1) / (x2 - x1); x = xmin
    end
    if codeOut == code1 then
      x1 = x; y1 = y
      code1 = 0
      if x1 < xmin then code1 = 1 elseif x1 > xmax then code1 = 2 end
      if y1 < ymin then code1 = code1 | 8 elseif y1 > ymax then code1 = code1 | 4 end
    else
      x2 = x; y2 = y
      code2 = 0
      if x2 < xmin then code2 = 1 elseif x2 > xmax then code2 = 2 end
      if y2 < ymin then code2 = code2 | 8 elseif y2 > ymax then code2 = code2 | 4 end
    end
  end
  return nil
end

function drawLib.init(param_status, param_libs)
  -- Stores shared state references so drawing helpers can read status values and call sibling libraries.
  status = param_status
  topBarValueCache = {}
  topBarValueCacheCount = 0
  return drawLib
end

return drawLib