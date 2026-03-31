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


local mapLib = {}

-- Cached stdlib references for embedded Lua performance (avoid _ENV hash lookups).
local tonumber = tonumber
local tostring = tostring
local floor, abs, max, min = math.floor, math.abs, math.max, math.min
local sqrt = math.sqrt
local sin, cos, log, exp, atan, deg, rad = math.sin, math.cos, math.log, math.exp, math.atan, math.deg, math.rad
local pi = math.pi
local fmt = string.format
local os_clock = os.clock

local status = nil
local libs = nil

-- Global map geometry constants and runtime state shared across draw calls.
local MAP_X = 0
local MAP_Y = 0

-- Cached map support state for tiles, screen coordinates, trail history, and redraw throttling.
local myScreenX, myScreenY
local tile_x, tile_y, offset_x, offset_y
local tiles = {}
local tiles_path_to_idx = {} -- Maps tile file paths back to their active slot in the visible tile grid.
local _lastCenterTileX, _lastCenterTileY, _lastCenterLevel  -- cache to skip rebuild when unchanged
local world_tiles
local tiles_per_radian
local tile_dim

-- GPS-based trail: ring-buffer of up to TRAIL_MAX_WAYPOINTS lat/lon anchors.
-- A new waypoint is committed only when BOTH the configured minimum distance has
-- been travelled AND the angle between the last committed segment and the pending
-- segment (last WP → UAV) exceeds the configured threshold.  This measures the
-- actual visual bend in the trail rather than relying on heading/COG which can
-- fluctuate with wind and gusts.
local TRAIL_MAX_WAYPOINTS = 51
local trailWaypoints = {}
local trailWpCount = 0
local trailHead = 0       -- ring-buffer write index (1-based, wraps at TRAIL_MAX_WAYPOINTS)
local trailAccumDist = 0
local trailLastLat = nil
local trailLastLon = nil

-- Trail tile-pixel cache now lives in compute.lua (Phase 3).
-- drawMap reads results via libs.compute.getResults().trail.

-- Waypoint tile-pixel cache now lives in compute.lua (Phase 2).
-- drawWaypoints reads results via libs.compute.getResults().waypoints.

-- Reusable flat arrays for waypoint screen positions (avoids per-frame table-of-tables).
local wpScrX = {}
local wpScrY = {}
local wpOutCode = {}  -- viewport outcode per WP for fast trivial-reject in Pass 1
local lastZoomLevel = -99
local lastMapProvider = -99
local lastMapType = nil
local coord_to_tiles = nil
local tiles_to_path = nil
local MinLatitude = -85.05112878
local MaxLatitude = 85.05112878
local MinLongitude = -180
local MaxLongitude = 180

local TILES_X = 8
local TILES_Y = 3
local TILES_SIZE = 100
local TILES_DIM = 76.5
local TILES_IDX_BMP = 1
local TILES_IDX_PATH = 2

local lastHeavyUpdate = 0    -- Initialised to 0; first loadAndCenterTiles always runs.
local HEAVY_UPDATE_INTERVAL = 25
local mapNeedsHeavyUpdate = true
local RASTER_REBUILD_OFFSET_THRESHOLD = 40

local DIRECTIONAL_LEAD_TILES = 1
local DIRECTIONAL_LEAD_MIN_SPEED = 1.5
local DIRECTIONAL_LEAD_OFFSET_THRESHOLD = 90
local PREFETCH_LEAD_OFFSET_THRESHOLD = 60
local PREFETCH_STRIP_DEPTH = 1

-- Pre-built octant lookup: heading octant → {leadX, leadY}.  Module-level
-- constant so the table is not recreated on every call.
local OCTANT_LEAD = {
  [0] = { 0, -1 }, -- N
  [1] = { 1, -1 }, -- NE
  [2] = { 1,  0 }, -- E
  [3] = { 1,  1 }, -- SE
  [4] = { 0,  1 }, -- S
  [5] = {-1,  1 }, -- SW
  [6] = {-1,  0 }, -- W
  [7] = {-1, -1 }, -- NW
}
local OCTANT_LEAD_ZERO = { 0, 0 }

local function getDirectionalLeadFromHeading(heading)
  if DIRECTIONAL_LEAD_TILES <= 0 then
    return 0, 0
  end

  local speed = (status and status.telemetry and status.telemetry.groundSpeed) or 0
  if heading == nil or speed < DIRECTIONAL_LEAD_MIN_SPEED then
    return 0, 0
  end

  local normalizedHeading = heading % 360
  local octant = floor((normalizedHeading + 22.5) / 45) % 8
  local lead = OCTANT_LEAD[octant] or OCTANT_LEAD_ZERO
  return lead[1] * DIRECTIONAL_LEAD_TILES, lead[2] * DIRECTIONAL_LEAD_TILES
end

local function gateLeadByTileOffsetThreshold(leadX, leadY, offsetX, offsetY, threshold)
  local gatedLeadX = leadX or 0
  local gatedLeadY = leadY or 0
  local gateThreshold = threshold or DIRECTIONAL_LEAD_OFFSET_THRESHOLD

  if gatedLeadX > 0 then
    if (offsetX or 0) < gateThreshold then
      gatedLeadX = 0
    end
  elseif gatedLeadX < 0 then
    if (offsetX or 0) > (100 - gateThreshold) then
      gatedLeadX = 0
    end
  end

  if gatedLeadY > 0 then
    if (offsetY or 0) < gateThreshold then
      gatedLeadY = 0
    end
  elseif gatedLeadY < 0 then
    if (offsetY or 0) > (100 - gateThreshold) then
      gatedLeadY = 0
    end
  end

  return gatedLeadX, gatedLeadY
end

local function gateLeadByTileOffset(leadX, leadY, offsetX, offsetY)
  return gateLeadByTileOffsetThreshold(leadX, leadY, offsetX, offsetY, DIRECTIONAL_LEAD_OFFSET_THRESHOLD)
end

local function gatePrefetchByTileOffset(leadX, leadY, offsetX, offsetY)
  return gateLeadByTileOffsetThreshold(leadX, leadY, offsetX, offsetY, PREFETCH_LEAD_OFFSET_THRESHOLD)
end

local function enqueueDirectionalPrefetch(centerTileX, centerTileY, level, prefetchLeadX, prefetchLeadY, isHighPriority)
  if libs == nil or libs.tileLoader == nil then
    return
  end

  local leadX = max(-1, min(1, tonumber(prefetchLeadX) or 0))
  local leadY = max(-1, min(1, tonumber(prefetchLeadY) or 0))
  if leadX == 0 and leadY == 0 then
    return
  end

  local highPrio = isHighPriority == true
  local halfX = floor(TILES_X / 2 + 0.5)
  local halfY = floor(TILES_Y / 2 + 0.5)

  if leadX ~= 0 then
    for depth = 1, PREFETCH_STRIP_DEPTH do
      local gridX = leadX > 0 and (TILES_X + depth) or (1 - depth)
      for gridY = 1 - PREFETCH_STRIP_DEPTH, TILES_Y + PREFETCH_STRIP_DEPTH do
        local tilePath = mapLib.tiles_to_path(centerTileX + gridX - halfX, centerTileY + gridY - halfY, level)
        libs.tileLoader.enqueue(tilePath, highPrio)
      end
    end
  end

  if leadY ~= 0 then
    for depth = 1, PREFETCH_STRIP_DEPTH do
      local gridY = leadY > 0 and (TILES_Y + depth) or (1 - depth)
      for gridX = 1 - PREFETCH_STRIP_DEPTH, TILES_X + PREFETCH_STRIP_DEPTH do
        local tilePath = mapLib.tiles_to_path(centerTileX + gridX - halfX, centerTileY + gridY - halfY, level)
        libs.tileLoader.enqueue(tilePath, highPrio)
      end
    end
  end
end

function mapLib.clip(n, lo, hi)
  -- Constrains a numeric value to a valid range before projection and tile math use it.
  return min(max(n, lo), hi)
end

function mapLib.tiles_on_level(level)
  -- Converts a user-facing zoom level (1..20) into the number of tiles on one map axis.
  -- Both providers now receive user-facing levels; GMapCatcher internal offset is applied only where tiles are addressed.
  if status.conf.mapProvider == 1 then
    return 2^(level-1)  -- same as legacy form 2^(17-(18-level)); simplified algebraically
  else
    return 2^level
  end
end

--[[
  total tiles on the web mercator projection = 2^zoom*2^zoom
--]]
function mapLib.get_tile_matrix_size_pixel(level)
  -- Converts a zoom level into the full Web Mercator pixel dimensions for projection math.
  local size = 2^level * TILES_SIZE
  return size, size
end

--[[
  https://developers.google.com/maps/documentation/javascript/coordinates
  https://github.com/judero01col/GMap.NET
--]]
function mapLib.google_coord_to_tiles(lat, lng, level)
  -- Projects GPS coordinates into Google tile indexes and pixel offsets for the current zoom level.
  lat = mapLib.clip(lat, MinLatitude, MaxLatitude)
  lng = mapLib.clip(lng, MinLongitude, MaxLongitude)

  local x = (lng + 180) / 360
  local sinLatitude = sin(lat * pi / 180)
  local y = 0.5 - log((1 + sinLatitude) / (1 - sinLatitude)) / (4 * pi)

  local mapSizeX, mapSizeY = mapLib.get_tile_matrix_size_pixel(level)

    -- Convert the normalized Mercator position into absolute pixel coordinates for this zoom level.
  local rx = mapLib.clip(x * mapSizeX + 0.5, 0, mapSizeX - 1)
  local ry = mapLib.clip(y * mapSizeY + 0.5, 0, mapSizeY - 1)
    -- Return tile indexes plus the pixel offset inside the resolved tile.
  return floor(rx/TILES_SIZE), floor(ry/TILES_SIZE), floor(rx%TILES_SIZE), floor(ry%TILES_SIZE)
end

function mapLib.gmapcatcher_coord_to_tiles(lat, lon, level)
  -- Projects GPS coordinates into GMapCatcher tile indexes and pixel offsets for the current zoom level.
  local x = world_tiles / 360 * (lon + 180)
  local e = sin(lat * (1/180 * pi))
  local y = world_tiles / 2 + 0.5 * log((1+e)/(1-e)) * -1 * tiles_per_radian
  return floor(x % world_tiles), floor(y % world_tiles), floor((x - floor(x)) * TILES_SIZE), floor((y - floor(y)) * TILES_SIZE)
end

function mapLib.pixel_to_coord(pixelX, pixelY, level)
  -- Inverse Web Mercator projection: absolute Mercator pixel → GPS lat/lon.
  -- Works for all providers (Google, OSM, ESRI, GMapCatcher) because the
  -- normalized Mercator math is identical; only the total pixel count differs.
  local provider = (status and status.conf and status.conf.mapProvider) or 2
  local mapSize
  if provider == 1 then
    mapSize = mapLib.tiles_on_level(level) * TILES_SIZE
  else
    mapSize = mapLib.get_tile_matrix_size_pixel(level)
  end
  local lng = (pixelX / mapSize) * 360 - 180
  local n = pi * (1 - 2 * pixelY / mapSize)
  local expN = exp(n)
  local lat = deg(atan((expN - 1 / expN) / 2))  -- atan(sinh(n))
  return lat, lng
end

function mapLib.google_tiles_to_path(tile_x, tile_y, level)
  -- Builds the extension-free SD-card path for native Google/OSM tiles in /z/x/y format.
  return fmt("/%d/%.0f/%.0f", level, tile_x, tile_y)
end

function mapLib.esri_tiles_to_path(tile_x, tile_y, level)
  -- Builds the extension-free SD-card path for ESRI tiles in /z/y/x format.
  return fmt("/%d/%.0f/%.0f", level, tile_y, tile_x)
end

function mapLib.gmapcatcher_tiles_to_path(tile_x, tile_y, level)
  -- Builds the relative SD-card path for a GMapCatcher tile from tile coordinates and zoom.
  -- Translate user-facing level (1..20) to the GMapCatcher internal level (-2..17) for the on-disk path.
  local internalLevel = 18 - level
  return fmt("/%d/%.0f/%.0f/%.0f/s_%.0f.png", internalLevel, tile_x/1024, tile_x%1024, tile_y/1024, tile_y%1024)
end

function mapLib.loadAndCenterTiles(tile_x, tile_y, offset_x, offset_y, width, level, leadX, leadY, prefetchLeadX, prefetchLeadY, cacheRing, isPanning)
  -- Rebuilds the visible tile window around the current center tile and updates tile caches when the map moves or zooms.
  local perfActive = status.perfActive
  local perfStartMs = nil
  if perfActive then
    perfStartMs = os_clock() * 1000
    status.perfProfileInc("tile_update_calls", 1)
  end
  local now = status.getTime()

  if now - lastHeavyUpdate < HEAVY_UPDATE_INTERVAL and not mapNeedsHeavyUpdate then
    return
  end
  
  lastHeavyUpdate = now
  mapNeedsHeavyUpdate = false

  local windowLeadX = max(-1, min(1, tonumber(leadX) or 0))
  local windowLeadY = max(-1, min(1, tonumber(leadY) or 0))
  local centerTileX = tile_x + windowLeadX
  local centerTileY = tile_y + windowLeadY

  local tilesChanged = false
  local removedCacheEntries = 0

  local halfX = floor(TILES_X / 2 + 0.5)
  local halfY = floor(TILES_Y / 2 + 0.5)

  -- Only rebuild tiles_path_to_idx when the center tile or zoom level changed.
  local centerMoved = (centerTileX ~= _lastCenterTileX or centerTileY ~= _lastCenterTileY or level ~= _lastCenterLevel)
  if centerMoved then
    _lastCenterTileX = centerTileX
    _lastCenterTileY = centerTileY
    _lastCenterLevel = level
    libs.resetLib.clearTable(tiles_path_to_idx)
    for x=1,TILES_X do
      for y=1,TILES_Y do
        local tile_path = mapLib.tiles_to_path(centerTileX + x - halfX, centerTileY + y - halfY, level)
        local idx = width*(y-1)+x
        -- Pack idx/x/y into one number: avoids 24 table allocations per rebuild.
        tiles_path_to_idx[tile_path] = idx * 10000 + x * 100 + y
        if tiles[idx] ~= tile_path then
          tiles[idx] = tile_path
          tilesChanged = true
        end
      end
    end
  end

  -- Only run eviction and enqueue work when the visible window actually shifted.
  if tilesChanged then
    removedCacheEntries = libs.tileLoader.trimCache(centerTileX, centerTileY, level, TILES_X, TILES_Y, windowLeadX, windowLeadY, cacheRing)
    if removedCacheEntries > 0 then
    end

    -- Pan mode: enqueue prefetch FIRST as HIGH priority so tiles ahead of
    -- the drag direction are loaded before anything else.
    if isPanning then
      enqueueDirectionalPrefetch(centerTileX, centerTileY, level, prefetchLeadX, prefetchLeadY, true)
    end

    -- Enqueue viewport tiles in spiral order (center outward).
    -- Normal mode: ring 0-1 = HIGH, ring 2+ = LOW.
    -- Pan mode: all viewport tiles = LOW (prefetch already has HIGH).
    local halfX = floor(TILES_X / 2 + 0.5)
    local halfY = floor(TILES_Y / 2 + 0.5)
    local maxRing = max(halfX - 1, TILES_X - halfX, halfY - 1, TILES_Y - halfY)
    local enq = libs.tileLoader.enqueue
    for ring = 0, maxRing do
      local isHighPrio = (not isPanning) and (ring <= 1)
      local xLo = max(1, halfX - ring)
      local xHi = min(TILES_X, halfX + ring)
      local yLo = max(1, halfY - ring)
      local yHi = min(TILES_Y, halfY + ring)
      for x = xLo, xHi do
        for y = yLo, yHi do
          if abs(x - halfX) == ring or abs(y - halfY) == ring then
            local tp = tiles[width * (y - 1) + x]
            if tp ~= nil then
              enq(tp, isHighPrio)
            end
          end
        end
      end
    end
  end

  if tilesChanged then
    if perfActive then
      status.perfProfileInc("tile_rebuild_count", 1)
    end
    if perfActive and removedCacheEntries > 0 then
      status.perfProfileInc("gc_count", 1)
    end
    if status.debugEnabled and libs and libs.utils then
      libs.utils.logDebug("TILE", fmt("loadAndCenterTiles: window rebuilt (queue=%d)", libs.tileLoader.getQueueLength()))
    end
  end

  -- Normal mode: enqueue prefetch as LOW priority (pan mode already enqueued as HIGH above).
  if not isPanning then
    enqueueDirectionalPrefetch(centerTileX, centerTileY, level, prefetchLeadX, prefetchLeadY, false)
  end

  if perfActive then
    status.perfProfileAddMs("tile_update_ms", os_clock() * 1000 - perfStartMs)
  end
end


function mapLib.drawTiles(width, xmin, ymin)
  -- Draws the active tile cache into the map viewport.
  local perfActive = status.perfActive
  local perfStartMs = nil
  if perfActive then
    perfStartMs = os_clock() * 1000
  end

  -- Cache sentinel bitmaps and getBitmap reference outside the loop so each
  -- tile iteration pays only one table lookup instead of up to four function calls.
  local tileGet    = libs.tileLoader.getBitmap
  local loadingBmp = libs.tileLoader.getLoadingBitmap()
  local noMapBmp   = libs.tileLoader.getNoMapBitmap()

  for x=1,TILES_X do
    for y=1,TILES_Y do
      local idx = width*(y-1)+x
      if tiles[idx] ~= nil then
        local bmp = tileGet(tiles[idx]) or loadingBmp or noMapBmp
        if bmp ~= nil then
          lcd.drawBitmap(xmin+(x-1)*TILES_SIZE, ymin+(y-1)*TILES_SIZE, bmp)
        end
      end
    end
  end

  if status.debugEnabled then
    local gridXMax = xmin + TILES_X * TILES_SIZE
    local gridYMax = ymin + TILES_Y * TILES_SIZE
    lcd.pen(DOTTED)
    lcd.color(status.colors.yellow)
    for x=1,TILES_X-1 do
      local lineX = xmin + x*TILES_SIZE
      lcd.drawLine(lineX, ymin, lineX, gridYMax)
    end
    for y=1,TILES_Y-1 do
      local lineY = ymin + y*TILES_SIZE
      lcd.drawLine(xmin, lineY, gridXMax, lineY)
    end
  end

  if perfActive and perfStartMs then
    status.perfProfileAddMs("draw_tiles_ms", os_clock() * 1000 - perfStartMs)
  end
end


function mapLib.getScreenCoordinates(minX, minY, tile_x, tile_y, offset_x, offset_y, level)
  -- Resolves tile-local coordinates back into screen coordinates using the current visible tile cache.
  local tile_path = mapLib.tiles_to_path(tile_x, tile_y, level)
  local packed = tiles_path_to_idx[tile_path]
  if packed ~= nil then
    local idx = floor(packed * 0.0001)
    if tiles[idx] ~= nil then
      local cx = floor((packed % 10000) * 0.01)
      local cy = packed % 100
      return minX + (cx-1)*TILES_SIZE + offset_x, minY + (cy-1)*TILES_SIZE + offset_y
    end
  end
  return status.widgetWidth / 2, -10
end

-- ============================================================================
-- Waypoint mission rendering
-- ============================================================================

-- WP action constants (must match msp.lua WP_ACTION_NAMES)
local WP_ACT_WAYPOINT      = 1
local WP_ACT_POSHOLD_TIME  = 3
local WP_ACT_RTH           = 4
local WP_ACT_SET_POI       = 5
local WP_ACT_JUMP          = 6
local WP_ACT_SET_HEAD      = 7
local WP_ACT_LAND          = 8

-- Cached colors created once to avoid repeated lcd.RGB() calls per frame.
local wpColorPath    = nil  -- neon green path lines
local wpColorLabel   = nil  -- neon green text/symbols
local wpColorRingOut = nil  -- black outer ring
local wpColorRingIn  = nil  -- white inner ring
local wpColorPoi     = nil  -- red for SET_POI bullseye
local wpColorJump    = nil  -- light yellow for JUMP dashed lines
local wpColorRth     = nil  -- green dashed line for RTH
local wpColorActive  = nil  -- green ring for active WP
local wpColorUavRth  = nil  -- orange for UAV in RTH mode
local wpColorShadow  = nil  -- translucent black for marker shadow fill
local wpColorsReady  = false
local obsMarkerFill  = nil  -- cached lcd.RGB(0, 200, 0, 0.6) for observation marker
local WP_DENSE_THRESHOLD = 15 -- auto-dense mode when mission has more WPs than this

local function ensureWpColors()
  if wpColorsReady then return end
  wpColorPath    = lcd.RGB(0, 255, 43)    -- neon green #00FF2B
  wpColorLabel   = lcd.RGB(0, 255, 43)    -- neon green #00FF2B
  wpColorRingOut = BLACK
  wpColorRingIn  = WHITE
  wpColorPoi     = RED
  wpColorJump    = lcd.RGB(255, 220, 50)  -- light yellow-orange
  wpColorRth     = lcd.RGB(0, 255, 43)    -- neon green (same as path)
  wpColorActive  = lcd.RGB(0, 255, 43)    -- neon green for active WP ring
  wpColorUavRth  = lcd.RGB(255, 165, 0)   -- orange for UAV in RTH mode
  wpColorShadow  = lcd.RGB(0, 0, 0, 0.4)  -- translucent black shadow fill
  wpColorsReady  = true
  obsMarkerFill  = lcd.RGB(0, 200, 0, 0.6)  -- cached observation marker fill
end

--- Shorten a line segment by radius r at both ends (so lines stop at circle edges).
--- Returns adjusted x1,y1,x2,y2 or nil if segment is too short.
local function shortenLine(x1, y1, x2, y2, r)
  local dx = x2 - x1
  local dy = y2 - y1
  local len = sqrt(dx * dx + dy * dy)
  if len < 2 * r + 1 then return nil end
  local nx, ny = dx / len, dy / len
  return x1 + nx * r, y1 + ny * r, x2 - nx * r, y2 - ny * r
end

--- Draw a chevron ("Dach") arrow tip pointing in direction (nx, ny) at (tipX, tipY).
--- size controls the chevron arm length.
local function drawChevron(tipX, tipY, nx, ny, size)
  local px, py = -ny, nx  -- perpendicular
  local backX = tipX - nx * size
  local backY = tipY - ny * size
  lcd.drawLine(backX + px * size * 0.5, backY + py * size * 0.5, tipX, tipY)
  lcd.drawLine(backX - px * size * 0.5, backY - py * size * 0.5, tipX, tipY)
end

--- Returns true if this WP action has a meaningful lat/lon position on the map.
local function wpHasPosition(action)
  return action == WP_ACT_WAYPOINT
      or action == WP_ACT_POSHOLD_TIME
      or action == WP_ACT_LAND
      or action == WP_ACT_SET_POI
end

--- Returns true if this WP action is part of the flight path (connects with lines).
local function wpIsNavigable(action)
  return action == WP_ACT_WAYPOINT
      or action == WP_ACT_POSHOLD_TIME
      or action == WP_ACT_LAND
end

--- Draw a single waypoint marker at screen (sx, sy) based on its action type.
--- @param wp      table  waypoint data {action, p1, p2, ...}
--- @param sx      number screen X
--- @param sy      number screen Y
--- @param wpNum   number sequential navigable waypoint number for label
--- @param r       number base circle radius
--- @param dense   boolean true = dense mode (dot only, no text)
local function drawWpMarker(wp, sx, sy, wpNum, r, dense, isActive)
  local action = wp.action

  if action == WP_ACT_SET_POI then
    -- Red bullseye: outer ring, inner ring, center dot
    lcd.color(wpColorPoi)
    lcd.drawCircle(sx, sy, r)
    lcd.drawCircle(sx, sy, max(floor(r * 0.55), 2))
    lcd.drawFilledRectangle(sx - 1, sy - 1, 3, 3)
    return
  end

  if dense then
    -- Dense mode: small filled dot only
    lcd.color(wpColorPath)
    lcd.drawFilledRectangle(sx - 2, sy - 2, 5, 5)
    return
  end

  -- Shadow fill (alpha 0.4) first, then contrast ring on top
  lcd.color(wpColorShadow)
  lcd.drawFilledCircle(sx, sy, r - 2)
  lcd.color(isActive and wpColorActive or wpColorRingIn)
  lcd.drawCircle(sx, sy, r - 2)
  lcd.drawCircle(sx, sy, r - 3)

  -- WP type-specific decoration (lcd.font set once before Pass 2 loop)
  lcd.color(wpColorLabel)
  if action == WP_ACT_POSHOLD_TIME then
    -- Seconds from p1 above the circle
    local secText = tostring(wp.p1) .. "s"
    local tw, th = lcd.getTextSize(secText)
    lcd.drawText(sx - floor(tw / 2), sy - r - th - 2, secText)
    -- WP number centered in circle
    local numText = tostring(wpNum)
    tw, th = lcd.getTextSize(numText)
    lcd.drawText(sx - floor(tw / 2), sy - floor(th / 2), numText)
  elseif action == WP_ACT_LAND then
    -- "L" centered in the circle
    local tw, th = lcd.getTextSize("L")
    lcd.drawText(sx - floor(tw / 2), sy - floor(th / 2), "L")
  else
    -- WAYPOINT: number centered in circle
    local numText = tostring(wpNum)
    local tw, th = lcd.getTextSize(numText)
    lcd.drawText(sx - floor(tw / 2), sy - floor(th / 2), numText)
  end
end

local wpDbgLastLog = 0  -- throttle for drawWaypoints debug logging

--- Draw all waypoints from the currently selected mission onto the map.
--- Called from drawMap() after trail, before observation marker.
local function drawWaypoints(x, y, w, h, level, uav_tile_x, uav_tile_y, uav_offset_x, uav_offset_y, renderOffsetX, renderOffsetY, isPanning)
  local dbg = status.debugEnabled and libs and libs.utils
  local dbgThrottle = false
  if dbg then
    local now = status.getTime()
    if (now - wpDbgLastLog) > 200 then  -- max once per 2s
      wpDbgLastLog = now
      dbgThrottle = true
    end
  end

  local missionList = status.mspMissions
  if not missionList or #missionList == 0 then
    if dbgThrottle then
      libs.utils.logDebug("WP_DRAW", "SKIP: no missions (mspMissions empty)", true)
    end
    return
  end
  local mIdx = status.mspMissionIdx or 1
  local mission = missionList[mIdx]
  if not mission or #mission == 0 then
    if dbgThrottle then
      libs.utils.logDebug("WP_DRAW", fmt("SKIP: mission[%d] empty or nil", mIdx), true)
    end
    return
  end
  if myScreenX == nil or uav_tile_x == nil then
    if dbgThrottle then
      libs.utils.logDebug("WP_DRAW", fmt("SKIP: myScreenX=%s uav_tile_x=%s", tostring(myScreenX), tostring(uav_tile_x)), true)
    end
    return
  end

  if dbgThrottle then
    libs.utils.logDebug("WP_DRAW", fmt("DRAW M%d: %d WPs, wpR=%d, screenX=%.0f", mIdx, #mission, max(floor(20 * min(status.scaleX or 1, status.scaleY or 1)), 10), myScreenX), true)
  end

  ensureWpColors()

  local scaleX = status.scaleX or 1
  local scaleY = status.scaleY or 1
  local wpR = max(floor(20 * min(scaleX, scaleY)), 10)  -- 40px diameter

  local clipLine = libs.drawLib.clipLine
  local computeOutCode = libs.drawLib.computeOutCode
  local margin = wpR + 20  -- viewport margin for clipping

  -- Read pre-computed tile-pixel positions from compute.lua (wakeup).
  -- Projection was moved out of paint() to avoid instruction-limit pressure.
  local wpRes = libs.compute.getResults().waypoints
  if not wpRes or not wpRes.valid then return end
  local wpTpx = wpRes.tpx
  local wpTpy = wpRes.tpy
  local mLen = #mission

  -- ── Quick dense detection ──
  -- Lightweight loop: tile-pixel distances equal screen-pixel distances
  -- (pure translation offset), so proximity threshold 2500 (=50²) is valid.
  local baseX = myScreenX - uav_tile_x * TILES_SIZE - uav_offset_x + renderOffsetX
  local baseY = myScreenY - uav_tile_y * TILES_SIZE - uav_offset_y + renderOffsetY
  local scrX = wpScrX
  local scrY = wpScrY
  local wpOC = wpOutCode
  local xMax = x + w
  local yMax = y + h
  local dense = false
  local visibleNavCount = 0
  do
    local prevTpxD, prevTpyD = nil, nil
    local vpMinTpx = x - baseX
    local vpMaxTpx = xMax - baseX
    local vpMinTpy = y - baseY
    local vpMaxTpy = yMax - baseY
    for i = 1, mLen do
      local tpxi = wpTpx[i]
      if tpxi then
        local act = mission[i].action
        if act == 1 or act == 3 or act == 8 then  -- inlined wpIsNavigable
          local inVP = tpxi >= vpMinTpx and tpxi <= vpMaxTpx
                   and wpTpy[i] >= vpMinTpy and wpTpy[i] <= vpMaxTpy
          if inVP then
            visibleNavCount = visibleNavCount + 1
            if not dense and prevTpxD then
              local dx = tpxi - prevTpxD
              local dy = wpTpy[i] - prevTpyD
              if (dx * dx + dy * dy) < 2500 then
                dense = true
              end
            end
            prevTpxD = tpxi
            prevTpyD = wpTpy[i]
          end
        end
      end
    end
  end
  if not dense and visibleNavCount > WP_DENSE_THRESHOLD then
    dense = true
  end

  if dense then
    -- ── Dense mode: single-pass (screen positions + lines + dots) ──
    -- Merges the original three passes into one loop to cut ~40% of
    -- per-frame Lua instructions.  Z-order is acceptable because dense
    -- markers are 5×5 dots sharing the same color as path lines.
    local prevNav = nil
    lcd.color(wpColorPath)
    lcd.pen(SOLID)
    local colorDirty = false
    for i = 1, mLen do
      local tpxi = wpTpx[i]
      if tpxi then
        local sx = baseX + tpxi
        local sy = baseY + wpTpy[i]
        scrX[i] = sx
        scrY[i] = sy
        local c = 0
        if sx < x then c = 1 elseif sx > xMax then c = 2 end
        if sy < y then c = c | 8 elseif sy > yMax then c = c | 4 end
        wpOC[i] = c
      else
        scrX[i] = nil
        scrY[i] = nil
        wpOC[i] = 15
      end

      local act = mission[i].action
      if act == 1 or act == 3 or act == 8 then  -- navigable WP
        -- Path line from previous navigable WP
        if scrX[i] and prevNav then
          local prevC = wpOC[prevNav]
          if (prevC & wpOC[i]) == 0 then
            if colorDirty then
              lcd.color(wpColorPath)
              lcd.pen(SOLID)
              colorDirty = false
            end
            -- Skip expensive clipLine when both endpoints are inside viewport
            if (prevC | wpOC[i]) == 0 then
              lcd.drawLine(scrX[prevNav], scrY[prevNav], scrX[i], scrY[i])
            else
              local cx1, cy1, cx2, cy2 = clipLine(scrX[prevNav], scrY[prevNav], scrX[i], scrY[i], x, y, xMax, yMax)
              if cx1 then lcd.drawLine(cx1, cy1, cx2, cy2) end
            end
          end
        end
        -- Dense dot (skip during panning)
        if not isPanning and scrX[i] and wpOC[i] == 0 then
          if colorDirty then lcd.color(wpColorPath); colorDirty = false end
          lcd.drawFilledRectangle(scrX[i] - 2, scrY[i] - 2, 5, 5)
        end
        if scrX[i] then prevNav = i end

      elseif act == 6 then  -- JUMP
        if prevNav and scrX[prevNav] then
          local targetIdx = mission[i].p1
          if targetIdx >= 1 and targetIdx <= mLen and scrX[targetIdx] then
            if (wpOC[prevNav] & wpOC[targetIdx]) == 0 then
              lcd.color(wpColorJump)
              lcd.pen(DOTTED)
              local cx1, cy1, cx2, cy2 = clipLine(scrX[prevNav], scrY[prevNav], scrX[targetIdx], scrY[targetIdx], x, y, xMax, yMax)
              if cx1 then lcd.drawLine(cx1, cy1, cx2, cy2) end
              lcd.pen(SOLID)
              local lx1, ly1 = scrX[prevNav], scrY[prevNav]
              local lx2, ly2 = scrX[targetIdx], scrY[targetIdx]
              local mx = (lx1 + lx2) * 0.5
              local my = (ly1 + ly2) * 0.5
              local ddx = lx2 - lx1
              local ddy = ly2 - ly1
              local dlen = sqrt(ddx * ddx + ddy * ddy)
              if dlen > 1 then
                lcd.color(wpColorJump)
                drawChevron(mx + ddx / dlen * 12, my + ddy / dlen * 12, ddx / dlen, ddy / dlen, 20)
              end
              colorDirty = true
            end
          end
        end

      elseif act == 5 then  -- SET_POI
        if not isPanning and scrX[i] and wpOC[i] == 0 then
          lcd.color(wpColorPoi)
          lcd.drawCircle(scrX[i], scrY[i], wpR)
          lcd.drawCircle(scrX[i], scrY[i], max(floor(wpR * 0.55), 2))
          lcd.drawFilledRectangle(scrX[i] - 1, scrY[i] - 1, 3, 3)
          colorDirty = true
        end

      elseif act == 4 then  -- RTH
        if not isPanning and prevNav and scrX[prevNav] and wpRes.homeTpx then
          local homeSx = baseX + wpRes.homeTpx
          local homeSy = baseY + wpRes.homeTpy
          local lx1, ly1, lx2, ly2 = shortenLine(scrX[prevNav], scrY[prevNav], homeSx, homeSy, wpR)
          if lx1 then
            lcd.color(wpColorRth)
            lcd.pen(DOTTED)
            local cx1, cy1, cx2, cy2 = clipLine(lx1, ly1, lx2, ly2, x, y, xMax, yMax)
            if cx1 then lcd.drawLine(cx1, cy1, cx2, cy2) end
            lcd.pen(SOLID)
            colorDirty = true
          end
        end
      end
      -- SET_HEAD (act 7) has no visual representation in dense mode
    end

  else
    -- ── Normal mode (few visible WPs): merged position-calc + line pass ──
    local prevNav = nil
    lcd.color(wpColorPath)
    lcd.pen(SOLID)
    for i = 1, mLen do
      local tpxi = wpTpx[i]
      if tpxi then
        local sx = baseX + tpxi
        local sy = baseY + wpTpy[i]
        scrX[i] = sx
        scrY[i] = sy
        local c = 0
        if sx < x then c = 1 elseif sx > xMax then c = 2 end
        if sy < y then c = c | 8 elseif sy > yMax then c = c | 4 end
        wpOC[i] = c
      else
        scrX[i] = nil
        scrY[i] = nil
        wpOC[i] = 15
      end

      local act = mission[i].action
      local isNav = act == 1 or act == 3 or act == 8

      -- Path lines between consecutive navigable WPs
      if isNav and scrX[i] then
        if prevNav and scrX[prevNav] then
          if (wpOC[prevNav] & wpOC[i]) == 0 then
            local lx1, ly1, lx2, ly2 = shortenLine(
              scrX[prevNav], scrY[prevNav],
              scrX[i], scrY[i], wpR)
            if lx1 then
              lcd.color(wpColorPath)
              lcd.pen(SOLID)
              -- Skip clipLine when both endpoints are inside viewport
              if (wpOC[prevNav] | wpOC[i]) == 0 then
                lcd.drawLine(lx1, ly1, lx2, ly2)
              else
                local cx1, cy1, cx2, cy2 = clipLine(lx1, ly1, lx2, ly2, x, y, xMax, yMax)
                if cx1 then lcd.drawLine(cx1, cy1, cx2, cy2) end
              end
            end
          end
        end
        prevNav = i
      end

      -- JUMP connections
      if act == 6 and prevNav then
        local targetIdx = mission[i].p1
        if targetIdx >= 1 and targetIdx <= mLen and scrX[targetIdx] and scrX[prevNav] then
          if (wpOC[prevNav] & wpOC[targetIdx]) == 0 then
            local lx1, ly1, lx2, ly2 = shortenLine(
              scrX[prevNav], scrY[prevNav],
              scrX[targetIdx], scrY[targetIdx], wpR)
            if lx1 then
              lcd.color(wpColorJump)
              lcd.pen(DOTTED)
              local cx1, cy1, cx2, cy2 = clipLine(lx1, ly1, lx2, ly2, x, y, xMax, yMax)
              if cx1 then lcd.drawLine(cx1, cy1, cx2, cy2) end
              lcd.pen(SOLID)
              local mx = (lx1 + lx2) * 0.5
              local my = (ly1 + ly2) * 0.5
              local dx = lx2 - lx1
              local dy = ly2 - ly1
              local dlen = sqrt(dx * dx + dy * dy)
              if dlen > 1 then
                lcd.color(wpColorJump)
                drawChevron(mx + dx / dlen * 12, my + dy / dlen * 12, dx / dlen, dy / dlen, 20)
              end
            end
          end
        end
      end
    end

    -- When actively dragging, skip heavy marker pass
    if isPanning then
      for i = mLen + 1, #scrX do scrX[i] = nil end
      for i = mLen + 1, #scrY do scrY[i] = nil end
      for i = mLen + 1, #wpOC do wpOC[i] = nil end
      return
    end

    -- Marker pass: circles, numbers, annotations (normal mode only)
    lcd.font(FONT_STD)
    local navNum = 0
    local curActiveWp = status.mspActiveWp or 0
    local lastNavIdx = nil
    for i = 1, mLen do
      local wp = mission[i]
      local act = wp.action
      local isNav = act == 1 or act == 3 or act == 8
      if isNav then
        navNum = navNum + 1
      end

      if wpHasPosition(act) and scrX[i] then
        local sx, sy = scrX[i], scrY[i]
        local code = computeOutCode(sx, sy, x - margin, y - margin, xMax + margin, yMax + margin)
        if code == 0 then
          local isActive = curActiveWp > 0 and wp.idx == curActiveWp
          drawWpMarker(wp, sx, sy, isNav and navNum or 0, wpR, false, isActive)
        end
      end

      if act == 7 and wp.p1 >= 0 and lastNavIdx and scrX[lastNavIdx] then
        local nsx, nsy = scrX[lastNavIdx], scrY[lastNavIdx]
        local code = computeOutCode(nsx, nsy, x - margin, y - margin, xMax + margin, yMax + margin)
        if code == 0 then
          local headRad = rad(wp.p1)
          local hx = sin(headRad)
          local hy = -cos(headRad)
          lcd.color(wpColorLabel)
          drawChevron(nsx + hx * (wpR + 16), nsy + hy * (wpR + 16), hx, hy, 15)
        end
      end

      if act == 6 and lastNavIdx and scrX[lastNavIdx] then
        local ssx, ssy = scrX[lastNavIdx], scrY[lastNavIdx]
        local iterCode = computeOutCode(ssx, ssy, x - margin, y - margin, xMax + margin, yMax + margin)
        if iterCode == 0 then
          local iterText
          if wp.p2 == -1 then
            iterText = "\xE2\x88\x9E"  -- UTF-8 infinity symbol ∞
          else
            iterText = "x" .. tostring(wp.p2)
          end
          lcd.font(FONT_STD)
          lcd.color(wpColorLabel)
          local tw, th = lcd.getTextSize(iterText)
          lcd.drawText(ssx + wpR + 3, ssy - floor(th / 2), iterText)
        end
      end

      if act == 4 and lastNavIdx and scrX[lastNavIdx] and wpRes.homeTpx then
        local rsx, rsy = scrX[lastNavIdx], scrY[lastNavIdx]
        local homeSx = baseX + wpRes.homeTpx
        local homeSy = baseY + wpRes.homeTpy
        local lx1, ly1, lx2, ly2 = shortenLine(rsx, rsy, homeSx, homeSy, wpR)
        if lx1 then
          lcd.color(wpColorRth)
          lcd.pen(DOTTED)
          local cx1, cy1, cx2, cy2 = clipLine(lx1, ly1, lx2, ly2, x, y, xMax, yMax)
          if cx1 then lcd.drawLine(cx1, cy1, cx2, cy2) end
          lcd.pen(SOLID)
        end
      end

      if isNav then
        lastNavIdx = i
      end
    end
  end

  -- Clear stale entries beyond current mission length.
  for i = mLen + 1, #scrX do scrX[i] = nil end
  for i = mLen + 1, #scrY do scrY[i] = nil end
  for i = mLen + 1, #wpOC do wpOC[i] = nil end

end

-- ──────────────────────────────────────────────────────────────
-- Phase 4: Tile grid computation (called from compute.lua/wakeup)
-- ──────────────────────────────────────────────────────────────
-- Moves the tile grid rebuild cycle out of drawMap()/paint():
--   coord_to_tiles → lead → loadAndCenterTiles → getScreenCoordinates → drawOffset
-- Reads viewport params published by drawMap() on the previous frame.
-- On the very first frame (no viewport yet), returns early — drawMap
-- bootstraps the grid inline for that single frame.
-- ──────────────────────────────────────────────────────────────

function mapLib.updateTileGrid(widget)
  -- Read viewport params published by the previous paint frame.
  local x = status.mapViewX
  local y = status.mapViewY
  local w = status.mapViewW
  local h = status.mapViewH
  -- Use live zoom level so zoom changes take effect immediately in wakeup
  -- instead of waiting one frame for paint to publish the new level.
  local level = status.mapZoomLevel or status.mapViewLevel
  local tiles_x = status.mapViewTilesX
  local tiles_y = status.mapViewTilesY
  -- Use live telemetry heading for directional lead (more current than previous frame's snapshot).
  local telemetry = status.telemetry
  local heading = telemetry and (telemetry.yaw or telemetry.cog) or status.mapViewHeading

  -- Guard: viewport not yet published (first frame hasn't run).
  if x == nil or w == nil or level == nil or tiles_x == nil then return end
  if not telemetry then return end

  -- Ensure projection helpers and grid constants are configured.
  setupMaps(x, y, w, h, level, tiles_x, tiles_y)

  -- Effective rendering position: fall back to saved default position when GPS is unavailable.
  local renderLat = telemetry.lat
  local renderLon = telemetry.lon
  if (renderLat == nil or renderLat == 0) and (renderLon == nil or renderLon == 0) then
    local conf = status.conf
    if conf and conf.defaultLat ~= nil and conf.defaultLon ~= nil then
      renderLat = conf.defaultLat
      renderLon = conf.defaultLon
    end
  end

  -- First-frame bootstrap: if tile grid is empty, populate it right away.
  if #tiles == 0 or tiles[1] == nil then
    if renderLat ~= nil and renderLon ~= nil then
      tile_x, tile_y, offset_x, offset_y = mapLib.coord_to_tiles(renderLat, renderLon, level)
    else
      tile_x, tile_y, offset_x, offset_y = 0, 0, 0, 0
    end
    mapLib.loadAndCenterTiles(tile_x, tile_y, offset_x, offset_y, TILES_X, level, 0, 0, 0, 0)
  end

  if widget.drawOffsetX == nil then widget.drawOffsetX = 0 end
  if widget.drawOffsetY == nil then widget.drawOffsetY = 0 end

  local viewportChanged = (widget.lastW ~= w or widget.lastH ~= h)
  local zoomChanged = (widget.lastZoom ~= level)
  if viewportChanged or zoomChanged then
    widget.drawOffsetX = 0
    widget.drawOffsetY = 0
    widget.lastW = w
    widget.lastH = h
    widget.lastZoom = level
    mapLib.loadAndCenterTiles(tile_x or 0, tile_y or 0, offset_x or 0, offset_y or 0, TILES_X, level, 0, 0, 0, 0)

    if viewportChanged and status.debugEnabled and libs and libs.utils and libs.utils.logDebug and libs.tileLoader then
      local gridTiles = TILES_X * TILES_Y
      local cacheTiles = libs.tileLoader.getCacheCount and libs.tileLoader.getCacheCount() or 0
      local queueTiles = libs.tileLoader.getQueueLength and libs.tileLoader.getQueueLength() or 0
      local totalTiles = cacheTiles + queueTiles
      libs.utils.logDebug("TILE", fmt("VIEWPORT_CHANGE | viewport=%dx%d | raster=%dx%d | rasterTiles=%d | cache=%d | queue=%d | total=%d", w, h, TILES_X, TILES_Y, gridTiles, cacheTiles, queueTiles, totalTiles), true)
    end
  end

  -- Pan state: read once for this cycle
  local panOffX = status.panOffsetX or 0
  local panOffY = status.panOffsetY or 0
  local panState = status.panState or 0
  local isActivePan = panState == 1 or panState == 2  -- DRAGGING or GRACE
  local isDetached = not status.followLock and (panState == 0 or panState == 3)
  local isPanning = isActivePan or isDetached

  if renderLat ~= nil and renderLon ~= nil then
    tile_x, tile_y, offset_x, offset_y = mapLib.coord_to_tiles(renderLat, renderLon, level)

    if isPanning then
      if status.panAnchorPixelX == nil then
        status.panAnchorPixelX = tile_x * TILES_SIZE + offset_x
        status.panAnchorPixelY = tile_y * TILES_SIZE + offset_y
      end
      local vcPixelX = status.panAnchorPixelX - panOffX
      local vcPixelY = status.panAnchorPixelY - panOffY
      local vcTileX = floor(vcPixelX / TILES_SIZE)
      local vcTileY = floor(vcPixelY / TILES_SIZE)
      local vcOffsetX = vcPixelX % TILES_SIZE
      local vcOffsetY = vcPixelY % TILES_SIZE

      if isActivePan then
        local prevPanX = status.lastPanOffsetX or panOffX
        local prevPanY = status.lastPanOffsetY or panOffY
        local dX = panOffX - prevPanX
        local dY = panOffY - prevPanY
        local rawPanLeadX = (dX > 0 and -1) or (dX < 0 and 1) or 0
        local rawPanLeadY = (dY > 0 and -1) or (dY < 0 and 1) or 0
        local panLeadX, panLeadY = gateLeadByTileOffset(rawPanLeadX, rawPanLeadY, vcOffsetX, vcOffsetY)
        local panPrefetchX, panPrefetchY = gatePrefetchByTileOffset(rawPanLeadX, rawPanLeadY, vcOffsetX, vcOffsetY)
        status.lastPanOffsetX = panOffX
        status.lastPanOffsetY = panOffY
        mapNeedsHeavyUpdate = true
        mapLib.loadAndCenterTiles(vcTileX, vcTileY, vcOffsetX, vcOffsetY, TILES_X, level, panLeadX, panLeadY, panPrefetchX, panPrefetchY, 2, true)
      else
        mapLib.loadAndCenterTiles(vcTileX, vcTileY, vcOffsetX, vcOffsetY, TILES_X, level, 0, 0, 0, 0, 0, false)
      end

      local vcScreenX, vcScreenY = mapLib.getScreenCoordinates(MAP_X, MAP_Y, vcTileX, vcTileY, vcOffsetX, vcOffsetY, level)
      local centerX = x + (w / 2)
      local centerY = y + (h / 2)
      widget.drawOffsetX = centerX - vcScreenX
      widget.drawOffsetY = centerY - vcScreenY
      myScreenX = vcScreenX + (tile_x - vcTileX) * TILES_SIZE + (offset_x - vcOffsetX)
      myScreenY = vcScreenY + (tile_y - vcTileY) * TILES_SIZE + (offset_y - vcOffsetY)
    else
      -- Normal mode: center on UAV
      local rawLeadX, rawLeadY = getDirectionalLeadFromHeading(heading)
      local leadX, leadY = gateLeadByTileOffset(rawLeadX, rawLeadY, offset_x, offset_y)
      local prefetchLeadX, prefetchLeadY = gatePrefetchByTileOffset(rawLeadX, rawLeadY, offset_x, offset_y)
      myScreenX, myScreenY = mapLib.getScreenCoordinates(MAP_X, MAP_Y, tile_x, tile_y, offset_x, offset_y, level)

      local centerX = x + (w / 2)
      local centerY = y + (h / 2)
      if myScreenX == nil or myScreenY == nil or
         abs(centerX - myScreenX) > RASTER_REBUILD_OFFSET_THRESHOLD or
         abs(centerY - myScreenY) > RASTER_REBUILD_OFFSET_THRESHOLD then
        mapNeedsHeavyUpdate = true
      end

      mapLib.loadAndCenterTiles(tile_x, tile_y, offset_x, offset_y, TILES_X, level, leadX, leadY, prefetchLeadX, prefetchLeadY)
      myScreenX, myScreenY = mapLib.getScreenCoordinates(MAP_X, MAP_Y, tile_x, tile_y, offset_x, offset_y, level)

      widget.drawOffsetX = centerX - myScreenX
      widget.drawOffsetY = centerY - myScreenY
    end
  end
end

function mapLib.drawMap(widget, x, y, w, h, level, tiles_x, tiles_y, heading, allowStateUpdate)
  -- Draws the full map view by combining tile rendering, aircraft/home overlays, trail history, and zoom controls.
  local perfActive = status.perfActive
  local perfStartMs = nil
  if perfActive then
    perfStartMs = os_clock() * 1000
  end
  lcd.setClipping(x, y, w, h)
  setupMaps(x, y, w, h, level, tiles_x, tiles_y)

  -- Publish viewport params so compute.lua/wakeup can call updateTileGrid().
  status.mapViewX = x
  status.mapViewY = y
  status.mapViewW = w
  status.mapViewH = h
  status.mapViewLevel = level
  status.mapViewTilesX = tiles_x
  status.mapViewTilesY = tiles_y
  status.mapViewHeading = heading

  local telemetry = status.telemetry
  local scaleX = status.scaleX
  local scaleY = status.scaleY
  local debugEnabled = status.debugEnabled
  local colors = status.colors

  local vehicleR = floor(34 * min(scaleX, scaleY))

  -- Pan state: read once for this frame (needed for render offset clamping and draw flags).
  local panOffX = status.panOffsetX or 0
  local panOffY = status.panOffsetY or 0
  local panState = status.panState or 0
  local isActivePan = panState == 1 or panState == 2  -- DRAGGING or GRACE
  local isDetached = not status.followLock and (panState == 0 or panState == 3)
  local isPanning = isActivePan or isDetached

  local doStateUpdate = allowStateUpdate ~= false

  -- Tile grid, vehicle position, and drawOffset are now pre-computed
  -- by updateTileGrid() in compute.lua/wakeup().  Module-level tile_x,
  -- tile_y, offset_x, offset_y, myScreenX, myScreenY and widget.drawOffsetX/Y
  -- are already set.  When the grid is empty (e.g. after a zoom-triggered
  -- setupMaps reset that happens between wakeup and paint), skip drawing
  -- for this frame and let the next wakeup rebuild the grid.  This avoids
  -- running the heavy updateTileGrid + loadAndCenterTiles bootstrap inside
  -- paint's 40K instruction budget.
  if #tiles == 0 or tiles[1] == nil then
    if perfActive and perfStartMs then
      status.perfProfileAddMs("paint_total_ms", os_clock() * 1000 - perfStartMs)
    end
    lcd.setClipping()
    return
  end

  local minX = max(0, MAP_X)
  local minY = max(0, MAP_Y)
  local maxX = min(minX + w, minX + TILES_X * TILES_SIZE)
  local maxY = min(minY + h, minY + TILES_Y * TILES_SIZE)
  local renderOffsetX = widget.drawOffsetX or 0
  local renderOffsetY = widget.drawOffsetY or 0

  -- Clamp render offset so the drawn tile grid always fully covers the viewport.
  -- Skip clamping when pan offset is active — panning can exceed the tile grid.
  if not isPanning then
    local minRenderOffsetX = w - TILES_X * TILES_SIZE
    local minRenderOffsetY = h - TILES_Y * TILES_SIZE
    if renderOffsetX > 0 then
      renderOffsetX = 0
    elseif renderOffsetX < minRenderOffsetX then
      renderOffsetX = minRenderOffsetX
    end
    if renderOffsetY > 0 then
      renderOffsetY = 0
    elseif renderOffsetY < minRenderOffsetY then
      renderOffsetY = minRenderOffsetY
    end
  end

  -- Save UAV tile coords before drawing (used by trail, WP, observation marker).
  local uav_tile_x, uav_tile_y = tile_x, tile_y
  local uav_offset_x, uav_offset_y = offset_x, offset_y

  -- Home position has been fully moved to compute.lua (tile-pixel precomputed
  -- in computeTileGrid).  Paint only reads results.home.tpx/tpy below.

  -- Trail accumulation has been moved to mapLib.updateTrail() called from wakeup.

  mapLib.drawTiles(TILES_X, minX + renderOffsetX, minY + renderOffsetY)

  local uavEdgeDrawX, uavEdgeDrawY
  if myScreenX ~= nil and myScreenY ~= nil then
    local drawX = myScreenX + renderOffsetX
    local drawY = myScreenY + renderOffsetY
    local uavOutCode = libs.drawLib.computeOutCode(drawX, drawY, x + vehicleR, y + vehicleR, x + w - vehicleR, y + h - vehicleR)
    if uavOutCode == 0 then
      -- UAV is inside the viewport: draw normal vehicle marker
      -- Nav-aware coloring: green for NAV/HOLD, orange for RTH, red for telemetry lost, white default
      local uavFillColor = nil
      if status.telemetryLost then
        uavFillColor = RED
      else
        local nm = status.mspNavMode or 0
        if nm == 3 or nm == 1 then
          ensureWpColors()
          uavFillColor = wpColorActive   -- neon green
        elseif nm == 2 then
          ensureWpColors()
          uavFillColor = wpColorUavRth   -- orange
        end
      end
      if heading ~= nil then
        libs.drawLib.drawVehicle(drawX, drawY, vehicleR, heading, status.conf.uavSymbol, uavFillColor)
      else
        lcd.color(wpColorShadow or lcd.RGB(0, 0, 0, 0.4))
        lcd.drawFilledCircle(drawX, drawY, vehicleR - 3)
        lcd.color(uavFillColor or WHITE)
        lcd.drawCircle(drawX, drawY, vehicleR - 3)
      end
    elseif isPanning then
      -- UAV is outside viewport during pan: store data for deferred edge arrow drawing
      uavEdgeDrawX = drawX
      uavEdgeDrawY = drawY
    end
  end

  local homeDrawX, homeDrawY
  local homeRes = libs.compute and libs.compute.getResults().home
  if homeRes and homeRes.tpx and myScreenX ~= nil and uav_tile_x ~= nil then
    local uavTpx = uav_tile_x * TILES_SIZE + uav_offset_x
    local uavTpy = uav_tile_y * TILES_SIZE + uav_offset_y
    local hx = myScreenX + (homeRes.tpx - uavTpx) + renderOffsetX
    local hy = myScreenY + (homeRes.tpy - uavTpy) + renderOffsetY
    local homeCode = libs.drawLib.computeOutCode(hx, hy, x + 14, y + 12, x + w - 14, y + h - 12)
    if homeCode == 0 then
      libs.drawLib.drawBitmap(hx - 14, hy - 12, "minihomeorange")
    else
      -- Home is outside viewport: pass to layout for edge arrow drawing
      homeDrawX = hx
      homeDrawY = hy
    end
  end

  local trailResolution = tonumber((status and status.conf and status.conf.mapTrailResolution) or 0) or 0
  if trailResolution > 0 and trailWpCount >= 1 and myScreenX ~= nil and uav_tile_x ~= nil then
    -- Read pre-computed tile-pixel positions from compute.lua (wakeup).
    local trailRes = libs.compute.getResults().trail
    if trailRes and trailRes.valid then
      lcd.color(colors.yellow)
      lcd.pen(SOLID)
      local clipLine = libs.drawLib.clipLine
      local baseX = myScreenX - uav_tile_x * TILES_SIZE - uav_offset_x + renderOffsetX
      local baseY = myScreenY - uav_tile_y * TILES_SIZE - uav_offset_y + renderOffsetY
      local trailTpx = trailRes.tpx
      local trailTpy = trailRes.tpy

      -- Use the projected snapshot (wpCount/head) from compute results, NOT the
      -- live trailWpCount/trailHead from maplib.  paint() can add a new trail
      -- point mid-frame; if we iterate with the live head the newest slot still
      -- carries the OLD occupant's tile-pixel projection → visual glitch.
      local projWpCount = trailRes.wpCount
      local projHead    = trailRes.head

      -- Segments shorter than MIN_TRAIL_PX are skipped to reduce draw calls.
      local MIN_TRAIL_PX_SQ = 15 * 15  -- squared to avoid sqrt per segment
      local anchorSX, anchorSY = nil, nil
      for k = 1, projWpCount do
        local idx
        if projWpCount < TRAIL_MAX_WAYPOINTS then
          idx = k
        else
          idx = ((projHead + k - 1) % TRAIL_MAX_WAYPOINTS) + 1
        end
        local tpxVal = trailTpx[idx]
        local tpyVal = trailTpy[idx]
        if tpxVal and tpyVal then
          local sx = baseX + tpxVal
          local sy = baseY + tpyVal
          if anchorSX then
            local dx, dy = sx - anchorSX, sy - anchorSY
            if dx * dx + dy * dy >= MIN_TRAIL_PX_SQ then
              local cx1, cy1, cx2, cy2 = clipLine(anchorSX, anchorSY, sx, sy, x, y, x + w, y + h)
              if cx1 then lcd.drawLine(cx1, cy1, cx2, cy2) end
              anchorSX, anchorSY = sx, sy
            end
          else
            anchorSX, anchorSY = sx, sy
          end
        end
      end
      -- Dynamic segment: newest waypoint to current UAV position.
      if anchorSX then
        local uavX, uavY = myScreenX + renderOffsetX, myScreenY + renderOffsetY
        local cx1, cy1, cx2, cy2 = clipLine(anchorSX, anchorSY, uavX, uavY, x, y, x + w, y + h)
        if cx1 then lcd.drawLine(cx1, cy1, cx2, cy2) end
      end
    end
  end

  -- Waypoint mission overlay (skip heavy rendering only during active finger drag)
  drawWaypoints(x, y, w, h, level, uav_tile_x, uav_tile_y, uav_offset_x, uav_offset_y, renderOffsetX, renderOffsetY, panState == 1)

  -- Observation marker: green line from UAV + marker circle
  if status.observationLat ~= nil and status.observationLon ~= nil and myScreenX ~= nil and uav_tile_x ~= nil then
    local obsRes = libs.compute and libs.compute.getResults().observation
    if obsRes and obsRes.tpx then
      local markerX = myScreenX + obsRes.tpx - uav_tile_x * TILES_SIZE - uav_offset_x + renderOffsetX
      local markerY = myScreenY + obsRes.tpy - uav_tile_y * TILES_SIZE - uav_offset_y + renderOffsetY
      local uavDX = myScreenX + renderOffsetX
      local uavDY = myScreenY + renderOffsetY
      -- Green line from UAV to observation marker (clipped to viewport)
      lcd.color(status.colors.observationGreen)
      lcd.pen(SOLID)
      local cx1, cy1, cx2, cy2 = libs.drawLib.clipLine(uavDX, uavDY, markerX, markerY, x, y, x + w, y + h)
      if cx1 then lcd.drawLine(cx1, cy1, cx2, cy2) end
      -- Marker circle if within viewport
      local markerCode = libs.drawLib.computeOutCode(markerX, markerY, x + 6, y + 6, x + w - 6, y + h - 6)
      if markerCode == 0 then
        local mr = floor(5 * min(scaleX, scaleY))
        lcd.color(obsMarkerFill or lcd.RGB(0, 200, 0, 0.6))
        lcd.drawFilledCircle(markerX, markerY, mr)
        lcd.color(BLACK)
        lcd.drawCircle(markerX, markerY, mr)
      end
    end
  end
  if status.zoomControlTarget ~= nil and status.zoomControlTarget ~= level then
    lcd.font(FONT_XL)
    local zoomTargetText = fmt("ZOOM > %d", status.zoomControlTarget)
    local ztW, ztH = lcd.getTextSize(zoomTargetText)
    local ztPadX, ztPadY = floor(10 * scaleX), floor(6 * scaleY)
    local ztBoxW = ztW + 2 * ztPadX
    local ztBoxH = ztH + 2 * ztPadY
    local ztBoxX = x + floor((w - ztBoxW) / 2)
    local ztBoxY = y + floor(h / 2) - floor(25 * scaleY) - ztPadY
    lcd.color(status.colors.semiBlack45)
    lcd.drawFilledRectangle(ztBoxX, ztBoxY, ztBoxW, ztBoxH)
    lcd.color(WHITE)
    lcd.drawText(x + w/2, ztBoxY + ztPadY, zoomTargetText, CENTERED)
  end

  -- Store edge arrow data in status for layout to draw on top of all overlays
  status.uavEdgeDrawX = uavEdgeDrawX
  status.uavEdgeDrawY = uavEdgeDrawY
  status.homeEdgeDrawX = homeDrawX
  status.homeEdgeDrawY = homeDrawY

  lcd.setClipping()
end

local function configureProjectionHelpers(provider)
  if provider == 1 then
    mapLib.coord_to_tiles = mapLib.gmapcatcher_coord_to_tiles
    mapLib.tiles_to_path = mapLib.gmapcatcher_tiles_to_path
  elseif provider == 3 then
    -- ESRI uses Web Mercator with /z/y/x tile addressing.
    mapLib.coord_to_tiles = mapLib.google_coord_to_tiles
    mapLib.tiles_to_path = mapLib.esri_tiles_to_path
  else
    -- Google (2) and OSM (4): Web Mercator with /z/x/y tile addressing.
    mapLib.coord_to_tiles = mapLib.google_coord_to_tiles
    mapLib.tiles_to_path = mapLib.google_tiles_to_path
  end
end

local function getScaleDistanceForLevel(level)
  local unitFactor = (status.conf.distUnitScale == 1 and 1 or 3)
  return unitFactor * 50 * 2^(20-level)
end

function setupMaps(x, y, w, h, level, tiles_x, tiles_y)
  -- Reconfigures projection helpers, tile caches, and scale metadata whenever map geometry or zoom changes.

  if level == nil or tiles_x == nil or tiles_y == nil or x == nil or y == nil then
    return -- Safeguard: map initialization requires complete viewport and zoom information.
  end

  MAP_X = x
  MAP_Y = y
  TILES_X = tiles_x
  TILES_Y = tiles_y

  local provider = (status and status.conf and status.conf.mapProvider) or 2
  local mapType = (status and status.conf and status.conf.mapType) or ""
  if level ~= lastZoomLevel or provider ~= lastMapProvider or mapType ~= lastMapType or lastZoomLevel == -99 then
    libs.resetLib.clearTable(tiles)
    libs.resetLib.clearTable(tiles_path_to_idx)
    _lastCenterTileX = nil  -- force rebuild on next loadAndCenterTiles
    libs.tileLoader.clearCache()

    world_tiles = mapLib.tiles_on_level(level)
    tiles_per_radian = world_tiles / (2 * pi)
    configureProjectionHelpers(provider)
    tile_dim = (40075017/world_tiles) * status.conf.distUnitScale
    lastZoomLevel = level
    lastMapProvider = provider
    lastMapType = mapType
  end
end

function mapLib.clearTrail()
  -- Resets the GPS trail ring-buffer. Called on disable and user reset.
  libs.resetLib.clearTable(trailWaypoints)
  trailWpCount = 0
  trailHead = 0
  trailAccumDist = 0
  trailLastLat = nil
  trailLastLon = nil
  -- Also invalidate compute projections.
  if libs and libs.compute then
    libs.compute.setDirty("needsWpProjection")
    libs.compute.setDirty("needsTrailProjection")
  end
  libs.resetLib.clearTable(wpScrX)
  libs.resetLib.clearTable(wpScrY)
end

--- Trail accumulation: haversine distance check + bend angle commit.
--- Called from wakeup() to keep trig computation out of paint().
function mapLib.updateTrail()
  local telemetry = status.telemetry
  if not telemetry then return end
  local trailResolution = tonumber((status and status.conf and status.conf.mapTrailResolution) or 0) or 0
  if trailResolution > 0 and telemetry.lat ~= nil and telemetry.lon ~= nil
      and (telemetry.lat ~= 0 or telemetry.lon ~= 0) then
    if trailLastLat ~= nil then
      local delta = libs.utils.haversine(trailLastLat, trailLastLon, telemetry.lat, telemetry.lon)
      trailAccumDist = trailAccumDist + delta
    end
    trailLastLat = telemetry.lat
    trailLastLon = telemetry.lon
    if trailWpCount == 0 then
      trailWpCount = 1
      trailHead = 1
      trailWaypoints[1] = { telemetry.lat, telemetry.lon }
      if libs and libs.compute then libs.compute.setDirty("needsTrailProjection") end
    elseif trailAccumDist >= trailResolution then
      local bendExceeded = true
      if trailWpCount >= 2 then
        local prevIdx
        if trailWpCount < TRAIL_MAX_WAYPOINTS then
          prevIdx = trailHead - 1
        else
          prevIdx = ((trailHead - 2) % TRAIL_MAX_WAYPOINTS) + 1
        end
        local prevWp = trailWaypoints[prevIdx]
        local headWp = trailWaypoints[trailHead]
        local ax, ay = headWp[2] - prevWp[2], headWp[1] - prevWp[1]
        local bx, by = telemetry.lon - headWp[2], telemetry.lat - headWp[1]
        local cross = ax * by - ay * bx
        local dot   = ax * bx + ay * by
        local bendDeg = abs(deg(atan(cross, dot)))
        local threshold = tonumber((status.conf and status.conf.mapTrailHeadingThreshold) or 5) or 5
        bendExceeded = (bendDeg >= threshold)
      end
      if bendExceeded then
        trailAccumDist = 0
        if trailWpCount < TRAIL_MAX_WAYPOINTS then
          trailWpCount = trailWpCount + 1
          trailHead = trailWpCount
          trailWaypoints[trailWpCount] = { telemetry.lat, telemetry.lon }
        else
          trailHead = (trailHead % TRAIL_MAX_WAYPOINTS) + 1
          trailWaypoints[trailHead] = { telemetry.lat, telemetry.lon }
        end
        if libs and libs.compute then libs.compute.setDirty("needsTrailProjection") end
      end
    end
  elseif trailResolution == 0 and trailWpCount > 0 then
    mapLib.clearTrail()
  end
end

--- Returns a reusable snapshot of trail ring-buffer state for compute.lua.
local _trailSnapshot = { waypoints = nil, wpCount = 0, head = 0, maxWaypoints = TRAIL_MAX_WAYPOINTS }
function mapLib.getTrailState()
  _trailSnapshot.waypoints = trailWaypoints
  _trailSnapshot.wpCount   = trailWpCount
  _trailSnapshot.head      = trailHead
  return _trailSnapshot
end

function mapLib.init(param_status, param_libs)
  -- Stores shared state references so map helpers can read telemetry/config data and call sibling libraries.
  status = param_status
  libs = param_libs
  configureProjectionHelpers((status and status.conf and status.conf.mapProvider) or 2)
  return mapLib
end

function mapLib.calculateScale(level)
  -- Converts the current zoom level into a scale-bar length and label for layout overlays.
  local scaleLen, scaleLabel = 0, ""

  if level == nil then
    return scaleLen, scaleLabel
  end

  local world_tiles = mapLib.tiles_on_level(level)
  local tile_dim = (40075017 / world_tiles) * status.conf.distUnitScale
  local scaleDistance = getScaleDistanceForLevel(level)

  scaleLabel = fmt("%.0f%s", scaleDistance, status.conf.distUnitLabel)
  scaleLen = (scaleDistance/tile_dim)*TILES_SIZE

  return scaleLen, scaleLabel
end

function mapLib.setNeedsHeavyUpdate()
  -- Flags the next draw cycle to rebuild the visible tile set instead of relying on throttled reuse.
  mapNeedsHeavyUpdate = true
end

return mapLib
