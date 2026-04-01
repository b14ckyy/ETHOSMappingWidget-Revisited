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
local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local fmt = string.format

local panel = {}

local status = nil
local libs = nil

-- Cached stdlib references for edge arrow angle computation.
local _atan2 = math.atan2 or math.atan
local _deg = math.deg
local MAP_TILE_SIZE = 100
local MAP_TILE_BUFFER_X = 1
local MAP_TILE_BUFFER_Y = 1
local MAP_MIN_TILES_X = 3
local MAP_MIN_TILES_Y = 3

-- Bar string cache (Optimization D): only re-format when the computed value changes.
local _lastGSpdVal, _cachedGSpdStr = nil, ""
local _lastHdgVal, _cachedHdgStr = nil, ""
local _lastTravVal, _cachedTravStr = nil, ""
local _lastHDistVal, _cachedHDistStr = nil, ""

-- Bar height cache: avoids 8 lcd.font/lcd.getTextSize calls per frame for static values.
local _barHeightCacheKey = nil
local _cachedTopH = 0
local _cachedBottomH = 0

local function getBarSnapshot()
  local barTickSerial = status.barTickSerial or 0

  if status.barSnapshot == nil then
    status.barSnapshot = {
      lastTickSerial = -1,
      groundSpeed = 0,
      heading = 0,
      travelDist = 0,
      homeDist = 0,
    }
  end

  if status.barSnapshot.lastTickSerial ~= barTickSerial then
    status.barSnapshot.groundSpeed = (status.telemetry and status.telemetry.groundSpeed) or 0
    status.barSnapshot.heading = (status.telemetry and (status.telemetry.yaw or status.telemetry.cog)) or 0
    status.barSnapshot.travelDist = (status.avgSpeed and status.avgSpeed.travelDist) or 0
    status.barSnapshot.homeDist = (status.telemetry and status.telemetry.homeDist) or 0
    status.barSnapshot.lastTickSerial = barTickSerial
  end

  return status.barSnapshot
end

local function drawBarSensor(x, barTop, barHeight, label, value, unit, font, label_font, unit_font, color, label_color, blink, flags)
  -- Draws one labeled sensor readout for the layout bars and returns the width consumed by the rendered block.
  lcd.font(label_font)
  local lw, lh = lcd.getTextSize(label)
  local sw, sh = lcd.getTextSize(" ")
  lcd.font(unit_font)
  local uw, uh = lcd.getTextSize(unit)
  lcd.font(font)
  local vw, vh = lcd.getTextSize(value)

  local valueY = barTop + floor((barHeight - vh) / 2)
  local valueBottomY = valueY + vh
  local labelY = valueBottomY - lh
  local unitY = valueBottomY - uh

  if flags == RIGHT then
    libs.drawLib.drawText(x, unitY, unit, unit_font, color, RIGHT, blink)
    libs.drawLib.drawText(x-uw, valueY, value, font, color, RIGHT, blink)
    libs.drawLib.drawText(x-(uw+sw+vw), labelY, label, label_font, label_color, RIGHT, blink)
  else
    libs.drawLib.drawText(x, labelY, label, label_font, label_color, LEFT, blink)
    libs.drawLib.drawText(x+lw+sw, valueY, value, font, color, LEFT, blink)
    libs.drawLib.drawText(x+lw+sw+vw, unitY, unit, unit_font, color, LEFT, blink)
  end
  return lw + vw + uw + 3*sw
end

function panel.draw(widget)
  -- Renders the default layout by combining the map, status bars, warnings, and navigation overlays from shared widget state.
  local w = status.widgetWidth
  local h = status.widgetHeight
  local sx = status.scaleX
  local sy = status.scaleY
  local conf = status.conf
  local colors = status.colors
  local telemetry = status.telemetry

  -- Guard: widget area too small to render meaningfully.
  if w < 200 or h < 100 then
    lcd.color(colors.warningYellow)
    lcd.drawFilledRectangle(0, 0, w, h)
    lcd.color(colors.black)
    lcd.font(FONT_STD)
    local line1 = "TOO SMALL!"
    local line2 = w .. " x " .. h .. " px"
    local line3 = "Min. 200x100"
    local tw1, th1 = lcd.getTextSize(line1)
    local tw2, th2 = lcd.getTextSize(line2)
    lcd.font(FONT_XS)
    local tw3, th3 = lcd.getTextSize(line3)
    local totalH = th1 + 4 + th2 + 2 + th3
    local startY = floor((h - totalH) / 2)
    lcd.font(FONT_STD)
    lcd.drawText(floor((w - tw1) / 2), startY, line1)
    lcd.drawText(floor((w - tw2) / 2), startY + th1 + 4, line2)
    lcd.font(FONT_XS)
    lcd.drawText(floor((w - tw3) / 2), startY + th1 + 4 + th2 + 2, line3)
    return
  end

  -- Detect compact screen classes so overlays can scale down without overlapping the map.
  local verticalTiny = (w < (status.tinyWidthThreshold or 350))
  local horizontalTiny = (h < (status.tinyHeightThreshold or 190))
  local verticalMedium = status.verticalMedium == true or (w < (status.compactWidthThreshold or 450))
  local ultraTiny = verticalTiny and horizontalTiny

  -- Pan mode: suppress map overlays and freeze bar updates during active drag/grace.
  -- PENDING is excluded — overlays stay visible until drag actually starts.
  -- Detached-idle (followLock=false, panState=0) keeps overlays visible.
  local panState = status.panState or 0
  local panActive = panState == 1 or panState == 2  -- DRAGGING or GRACE only

  -- Derive the map viewport after reserving space for the top and bottom bars.
  -- Bars stay visible during pan (frozen content) — map only renders in its normal area.
  local topH, bottomH
  if horizontalTiny then
    topH = 0
    bottomH = 0
  else
    -- Cache bar heights: only recompute when verticalMedium or scaleY changes.
    local barKey = (verticalMedium and 1 or 0) * 10000 + floor(sy * 1000)
    if _barHeightCacheKey == barKey then
      topH = _cachedTopH
      bottomH = _cachedBottomH
    else
      local topValueFont = verticalMedium and FONT_S or FONT_L
      local topLabelFont = FONT_XS
      lcd.font(topValueFont)
      local _, topValueH = lcd.getTextSize("TX 99.9V")
      lcd.font(topLabelFont)
      local _, topLabelH = lcd.getTextSize("SRC")
      local topContentH = max(topValueH, topLabelH)
      topH = max(floor(26 * sy), topContentH + floor(8 * sy))

      local bottomValueFont = verticalMedium and FONT_S or FONT_L
      local bottomMetaFont = FONT_XS
      lcd.font(bottomValueFont)
      local _, bottomValueH = lcd.getTextSize("999.9")
      lcd.font(bottomMetaFont)
      local _, bottomMetaH = lcd.getTextSize("km/h")
      local bottomContentH = max(bottomValueH, bottomMetaH)
      bottomH = max(floor(46 * sy), bottomContentH + floor(12 * sy))

      _cachedTopH = topH
      _cachedBottomH = bottomH
      _barHeightCacheKey = barKey
    end
  end
  local mapY    = topH
  local mapH    = h - topH - bottomH
  local mapTilesX = max(MAP_MIN_TILES_X, ceil(w / MAP_TILE_SIZE) + MAP_TILE_BUFFER_X)
  local mapTilesY = max(MAP_MIN_TILES_Y, ceil(h / MAP_TILE_SIZE) + MAP_TILE_BUFFER_Y)

  local mapTickSerial = status.mapTickSerial or 0
  local zoomChanged = status.mapZoomLevel ~= (status.mapLastZoom or 0)
  local mapNeedsUpdate = status.mapRedrawPending == true or zoomChanged or mapTickSerial ~= (status.mapLastTickSerial or -1)

  if zoomChanged then
    libs.mapLib.setNeedsHeavyUpdate()
  end

  if mapNeedsUpdate then
    status.mapRedrawPending = false
    status.mapLastTickSerial = mapTickSerial
  end

  status.mapLastZoom = status.mapZoomLevel

  -- Draw the map viewport for the current layout.
  libs.mapLib.drawMap(widget, 0, mapY, w, mapH, status.mapZoomLevel, mapTilesX, mapTilesY, telemetry.yaw or telemetry.cog, mapNeedsUpdate)

  -- Draw the dedicated left-side zoom buttons.
  local scaleFactor = 0.15 + 0.8 * status.scaleX
  local btnSize     = floor(52 * scaleFactor)
  local btnX        = 12 * status.scaleX

  -- In ultra-tiny mode, anchor buttons to top and bottom edges with symmetric margins.
  local btnYPlus, btnYMinus
  if ultraTiny then
    local edgeMargin = btnX
    btnYPlus  = edgeMargin
    btnYMinus = status.widgetHeight - btnSize - edgeMargin
  else
    btnYPlus  = 0.27 * status.widgetHeight
    btnYMinus = status.widgetHeight - 0.27 * status.widgetHeight - btnSize
  end

  -- Draw the actual zoom buttons (hidden when zoom is controlled via RC channel).
  if (status.conf.zoomControl or 0) == 0 then
    libs.drawLib.drawBitmap(btnX, btnYPlus, "zoom_plus", btnSize, btnSize)
    libs.drawLib.drawBitmap(btnX, btnYMinus, "zoom_minus", btnSize, btnSize)
  end

  -- Follow-lock button: right side, vertically centered (only when pan/drag is enabled).
  if status.panDragEnabled then
    local lockBtnX = w - btnX - btnSize
    local lockBtnY = floor((h - btnSize) / 2)
    local lockIcon = status.followLock and "flockon" or "flockoff"
    libs.drawLib.drawBitmap(lockBtnX, lockBtnY, lockIcon, btnSize, btnSize)

    -- Pin button: right side at zoom+ height, only when unlocked
    if not status.followLock then
      libs.drawLib.drawBitmap(lockBtnX, btnYPlus, "pinbutton", btnSize, btnSize)
    end
  end

  -- Crosshair: red "+" at viewport center when follow-unlocked
  if status.panDragEnabled and not status.followLock then
    local chX = floor(w / 2)
    local chY = mapY + floor(mapH / 2)
    local chHalf = floor(10 * min(sx, sy))
    lcd.color(colors.red)
    lcd.pen(SOLID)
    lcd.drawLine(chX - chHalf, chY, chX + chHalf, chY)
    lcd.drawLine(chX, chY - chHalf, chX, chY + chHalf)
  end

  -- Show zoom limit message
  if (status.zoomLimitMessageEnd or 0) > status.getTime() then
    local limitText = "ZOOM LIMIT"
    local limitFont = verticalMedium and FONT_S or FONT_L
    lcd.font(limitFont)
    local ltw, lth = lcd.getTextSize(limitText)
    local lbx = floor((w - ltw) / 2) - 8
    local lby = floor(h / 2) - floor(lth / 2) - 4
    lcd.color(colors.semiBlack60)
    lcd.drawFilledRectangle(lbx, lby, ltw + 16, lth + 8)
    lcd.color(colors.yellow)
    lcd.drawText(lbx + 8, lby + 4, limitText)
  end

  -- Draw the top bar and text overlays only when the layout has enough vertical space.
  if not horizontalTiny then
    -- Bar backgrounds always drawn (even during pan) for consistent UI.
    lcd.color(colors.black)
    lcd.pen(SOLID)
    lcd.drawFilledRectangle(0, 0, w, topH)
    lcd.drawFilledRectangle(0, h - bottomH, w, bottomH)

    -- Bar content and map overlays frozen during active pan to save cycles.
    if not panActive then
    libs.drawLib.drawTopBar(widget, 0, topH)

    lcd.font(verticalTiny and FONT_XS or verticalMedium and FONT_STD or FONT_L)

    local overlayPadX = max(6, floor(8 * sx))
    local overlayPadY = max(3, floor(4 * sy))
    local overlayMargin = max(6, floor(8 * sx))

    local gpsText = telemetry.strLat .. " " .. telemetry.strLon
    local gpsTw, gpsTh = lcd.getTextSize(gpsText)
    local gpsBoxW = gpsTw + 2 * overlayPadX
    local gpsBoxH = gpsTh + 2 * overlayPadY
    local gpsBoxX = max(overlayMargin, w - gpsBoxW - overlayMargin)
    local gpsBoxY = mapY + overlayMargin

    lcd.color(colors.semiBlack45)
    lcd.drawFilledRectangle(gpsBoxX, gpsBoxY, gpsBoxW, gpsBoxH)
    lcd.color(status.telemetryLost and colors.red or colors.white)
    lcd.drawText(gpsBoxX + floor((gpsBoxW - gpsTw) / 2), gpsBoxY + floor((gpsBoxH - gpsTh) / 2), gpsText)

    local zoomText = "zoom " .. tostring(status.mapZoomLevel)
    local zoomTw, zoomTh = lcd.getTextSize(zoomText)
    local zoomBoxW = zoomTw + 2 * overlayPadX
    local zoomBoxH = zoomTh + 2 * overlayPadY
    local zoomBoxX = overlayMargin
    local zoomBoxY = mapY + overlayMargin

    lcd.color(colors.semiBlack45)
    lcd.drawFilledRectangle(zoomBoxX, zoomBoxY, zoomBoxW, zoomBoxH)
    lcd.color(colors.white)
    lcd.drawText(zoomBoxX + floor((zoomBoxW - zoomTw) / 2), zoomBoxY + floor((zoomBoxH - zoomTh) / 2), zoomText)
    end -- not panActive (top bar content + overlays)
  end -- not horizontalTiny

  -- Draw the bottom flight-data bar except on the narrowest horizontal layouts.
  if not panActive and not horizontalTiny then
    local barSnapshot = getBarSnapshot()

    lcd.color(colors.black)
    lcd.pen(SOLID)
    lcd.drawFilledRectangle(0, h - bottomH, w, bottomH)

    local labelColor = colors.labelGray
    local barTop = h - bottomH
    local barFont = verticalMedium and FONT_S or FONT_L
    local barMetaFont = FONT_XS
    local spacing = verticalMedium and 8*sx or 22*sx
    local hideHomeDistAndHeading = w < (status.tinyWidthThreshold or 350)

    local gspdLabel   = verticalMedium and "GS" or "GSpd"
    local homeLabel   = verticalMedium and "HD" or "HomeDist"

    -- Delta-check bar strings (Optimization D): only re-format when the computed value changes.
    local gspdVal = barSnapshot.groundSpeed * conf.horSpeedMultiplier
    if gspdVal ~= _lastGSpdVal then
      _lastGSpdVal = gspdVal
      _cachedGSpdStr = fmt("%.01f", gspdVal)
    end

    local travVal = barSnapshot.travelDist * conf.distUnitLongScale
    if travVal ~= _lastTravVal then
      _lastTravVal = travVal
      _cachedTravStr = fmt("%.01f", travVal)
    end

    local hdgVal = barSnapshot.heading or 0
    if hdgVal ~= _lastHdgVal then
      _lastHdgVal = hdgVal
      _cachedHdgStr = fmt("%.0f", hdgVal)
    end

    local hDistVal = barSnapshot.homeDist * conf.distUnitScale
    if hDistVal ~= _lastHDistVal then
      _lastHDistVal = hDistVal
      _cachedHDistStr = fmt("%.01f", hDistVal)
    end

    if hideHomeDistAndHeading then
      drawBarSensor(12*sx, barTop, bottomH, gspdLabel,
        _cachedGSpdStr,
        conf.horSpeedLabel, barFont, barMetaFont, barFont, colors.white, labelColor, false)

      drawBarSensor(w - 12*sx, barTop, bottomH, "TR",
        _cachedTravStr,
        conf.distUnitLongLabel, barFont, barMetaFont, barFont, colors.white, labelColor, false, RIGHT)
    else
      local offset = drawBarSensor(12*sx, barTop, bottomH, gspdLabel,
        _cachedGSpdStr,
        conf.horSpeedLabel, barFont, barMetaFont, barFont, colors.white, labelColor, false)

      offset = offset + drawBarSensor(12*sx + offset + spacing, barTop, bottomH, "HDG",
        _cachedHdgStr, "°",
        barFont, barMetaFont, barFont, colors.white, labelColor, false)

      local travelOffset = drawBarSensor(w, barTop, bottomH, "TR",
        _cachedTravStr,
        conf.distUnitLongLabel, barFont, barMetaFont, barFont, colors.white, labelColor, false, RIGHT)

      drawBarSensor(w - travelOffset - spacing - 15*sx, barTop, bottomH, homeLabel,
        _cachedHDistStr,
        conf.distUnitLabel, barFont, barMetaFont, barFont, colors.white, labelColor, false, RIGHT)
    end
  end
  if not panActive and telemetry.lat ~= nil and (telemetry.homeLat == nil or telemetry.homeLon == nil) then
    local warningText = "WARNING: HOME NOT SET!"
    local font = verticalMedium and FONT_S or FONT_L
    lcd.font(font)
    local tw, th = lcd.getTextSize(warningText)

    local padX = max(8, floor(14 * sx))
    local padY = max(4, floor(8 * sy))
    local boxW = tw + 2 * padX
    local boxH = th + 2 * padY
    local boxX = floor((w - boxW) / 2)

    local boxY = floor((h - boxH) / 2)

    lcd.color(colors.semiBlack45)
    lcd.drawFilledRectangle(boxX, boxY, boxW, boxH)

    lcd.color(WHITE)
    lcd.drawRectangle(boxX, boxY, boxW, boxH, 2)

    lcd.color(colors.yellow)
    libs.drawLib.drawText(boxX + boxW/2, boxY + (boxH - th) / 2, warningText, font, colors.yellow, CENTERED, true)
  end

    -- Draw the map scale bar when the viewport is large enough to keep it readable.
  if not panActive and not ultraTiny then
    local scaleLen, scaleLabel = libs.mapLib.calculateScale(status.mapZoomLevel)
    if scaleLen ~= 0 then
      local scaleFont = verticalMedium and FONT_S or FONT_STD
      lcd.font(scaleFont)
      local labelW, labelH = lcd.getTextSize(scaleLabel)

      local scaleY_line  = mapY + mapH - 18*sy
      local scaleY_label = scaleY_line - labelH - 4*sy

      lcd.color(colors.semiBlack45)
      lcd.drawFilledRectangle(8*sx, scaleY_label - 5*sy, scaleLen + 20*sx, labelH + 22*sy)

      lcd.color(WHITE)
      lcd.drawLine(12*sx, scaleY_line, 12*sx + scaleLen, scaleY_line)
      lcd.drawText(12*sx, scaleY_label, scaleLabel)
    end
  end

  -- Edge arrows: drawn after all overlays so they are always on top.
  -- Black outline is drawn first (larger), colored fill second (smaller, on top)
  -- so that both colors are always clearly visible.
  local edgeDamp = 0.5 + min(sx, sy) * 0.5
  local edgeMargin = floor(33 * edgeDamp)
  local edgeArrowR = floor(30 * edgeDamp)
  local vcx = floor(w / 2)
  local vcy = mapY + floor(mapH / 2)

  -- UAV out-of-view edge arrow (black outline + red fill)
  if status.uavEdgeDrawX ~= nil then
    local eX = max(edgeMargin, min(status.uavEdgeDrawX, w - edgeMargin))
    local eY = max(mapY + edgeMargin, min(status.uavEdgeDrawY, mapY + mapH - edgeMargin))
    local angle = _deg(_atan2(status.uavEdgeDrawX - vcx, -(status.uavEdgeDrawY - vcy)))
    libs.drawLib.drawRArrow(eX, eY, edgeArrowR, angle, colors.black)
    libs.drawLib.drawRArrow(eX, eY, edgeArrowR - floor(5 * edgeDamp), angle, colors.red)
  end

  -- Home out-of-view edge arrow (black outline + yellow fill)
  if status.homeEdgeDrawX ~= nil then
    local eX = max(edgeMargin, min(status.homeEdgeDrawX, w - edgeMargin))
    local eY = max(mapY + edgeMargin, min(status.homeEdgeDrawY, mapY + mapH - edgeMargin))
    local angle = _deg(_atan2(status.homeEdgeDrawX - vcx, -(status.homeEdgeDrawY - vcy)))
    libs.drawLib.drawRArrow(eX, eY, edgeArrowR, angle, colors.black)
    libs.drawLib.drawRArrow(eX, eY, edgeArrowR - floor(5 * edgeDamp), angle, colors.yellow)
  end

end

function panel.background(widget)
  -- Placeholder background callback required by Ethos when the widget is off-screen.
end

function panel.init(param_status, param_libs)
  -- Stores shared state references so the layout can read telemetry/config data and call drawing/map helpers.
  status = param_status
  libs = param_libs
  return panel
end

return panel