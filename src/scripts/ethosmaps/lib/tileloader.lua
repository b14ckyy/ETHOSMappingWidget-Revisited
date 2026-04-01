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

-- tileloader.lua
-- Responsible for all tile I/O: disk probing, lcd.loadBitmap(), bitmap cache, and
-- a two-priority load queue that is drained by wakeup() one tile at a time so the
-- paint() callback never blocks on SD-card reads.

local tileLoader = {}

-- Cached stdlib references for embedded Lua performance (avoid _ENV hash lookups).
local type = type
local tostring = tostring
local tonumber = tonumber
local pairs = pairs
local floor, max, min = math.floor, math.max, math.min
local fmt = string.format
local io_open = io.open

local os_clock = os.clock

local status = nil
local libs   = nil

-- Spatial ring radius for cache eviction (tiles beyond this radius around the visible
-- window are discarded when trimCache() is called from maplib).
local TILE_CACHE_REFERENCE_MARGIN_TILES = 0
local TILE_CACHE_RING_TILES = 0
local TILE_CACHE_DIRECTIONAL_GUARD_TILES = 1

-- Bitmap cache: tilePath → bitmap (or nomap sentinel).
local mapBitmapByPath = {}

-- Confirmed-missing sentinel – loaded once and reused for every absent tile.
local noMapBitmap = nil

-- Loading sentinel – used while a tile is still queued/not-yet-loaded.
local loadingBitmap = nil

-- Two-bucket priority queue.  "High" tiles (near map center) are loaded first so the
-- aircraft position appears sharp before the buffer fringe fills in.
local highQueue    = {}   -- array of tile paths, consumed from highHead
local highQueueSet = {}   -- set for O(1) dedup
local highHead     = 1

local lowQueue    = {}
local lowQueueSet = {}
local lowHead     = 1

-- Running count of cache entries; avoids O(n) iteration on every trim check.
local cacheCount = 0

-- GC synchronisation flag.  Set by trimCache() after evicting bitmap entries so
-- processQueue() can run collectgarbage() *before* allocating new bitmaps.
-- Without this, old and new bitmap userdata coexist until the next periodic GC
-- cycle (every 10 wakeups), causing a transient RAM peak that can exceed the
-- ETHOS per-widget memory budget and trigger an immediate kill – even when the
-- steady-state cache size is well within limits.  See Docs/development/
-- ETHOS-BITMAP-GC-TIMING.md for a detailed write-up.
local pendingGCBeforeLoad = false

-- One-time log keys so we don't flood the debug log with repeated messages.
local lastTileFormatLogByKey = {}
local lastNoTilesLogKey      = nil

-- ── File I/O helpers ─────────────────────────────────────────────────────────

local function fileExists(path)
  local f = io_open(path, "r")
  if f ~= nil then
    io.close(f)
    return true
  end
  return false
end

local function getGoogleFallbackBasePath(mapType, tilePath)
  -- Builds the extension-free Yaapu legacy path for a Google tile so we can fall back
  -- to an existing Yaapu cache when no ethosmaps tile is present.
  local yaapuMapTypeMap = {
    ["Satellite"] = "GoogleSatelliteMap",
    ["Hybrid"]    = "GoogleHybridMap",
    ["Map"]       = "GoogleMap",
    ["Terrain"]   = "GoogleTerrainMap",
  }
  local yaapuMapType    = yaapuMapTypeMap[mapType] or mapType
  local fallbackTilePath = tilePath
  local z, x, y = tilePath:match("^/(%d+)/(%d+)/(%d+)$")
  if z ~= nil and x ~= nil and y ~= nil then
    fallbackTilePath = fmt("/%s/%s/s_%s", z, y, x)
  end
  return "/bitmaps/yaapu/maps/" .. yaapuMapType .. fallbackTilePath
end

local function loadFirstExisting(tilePath, ...)
  -- Probes candidate full file paths and loads the first one that exists on disk.
  local paths = { ... }
  for i = 1, #paths do
    if fileExists(paths[i]) then
      local bmp = lcd.loadBitmap(paths[i])
      mapBitmapByPath[tilePath] = bmp
      return bmp, paths[i]
    end
  end
  return nil, nil
end

local function ensureNoMapBitmap()
  -- Loads the shared "NO MAP DATA" bitmap once so draw code can always paint a
  -- deterministic missing-data placeholder without SD-card I/O during paint().
  if noMapBitmap ~= nil then
    return noMapBitmap
  end

  if fileExists("/bitmaps/ethosmaps/bitmaps/nomap.png") then
    noMapBitmap = lcd.loadBitmap("/bitmaps/ethosmaps/bitmaps/nomap.png")
  elseif fileExists("/bitmaps/ethosmaps/maps/notiles.png") then
    noMapBitmap = lcd.loadBitmap("/bitmaps/ethosmaps/maps/notiles.png")
  else
    noMapBitmap = lcd.loadBitmap("/bitmaps/ethosmaps/bitmaps/nomap.png")
  end

  return noMapBitmap
end

local function ensureLoadingBitmap()
  -- Loads the shared "LOADING..." bitmap once for queued/not-yet-loaded tiles.
  if loadingBitmap ~= nil then
    return loadingBitmap
  end

  if fileExists("/bitmaps/ethosmaps/bitmaps/loading.png") then
    loadingBitmap = lcd.loadBitmap("/bitmaps/ethosmaps/bitmaps/loading.png")
  else
    loadingBitmap = ensureNoMapBitmap()
  end

  return loadingBitmap
end

local function loadTileFromDisk(tilePath)
  -- Resolves SD-card paths for the current provider/mapType, loads the first match,
  -- and populates mapBitmapByPath.  Returns the cached bitmap on success, or the
  -- nomap sentinel when no file is found anywhere.
  local provider = (status and status.conf and status.conf.mapProvider) or 2
  local mapType  = (status and status.conf and status.conf.mapType)     or ""

  local bmp, loadedPath, attemptedPaths

  if provider == 1 then
    -- GMapCatcher / Yaapu: path already has extension baked in.
    local onlyPath    = "/bitmaps/yaapu/maps/" .. mapType .. tilePath
    attemptedPaths    = { onlyPath }
    bmp, loadedPath   = loadFirstExisting(tilePath, onlyPath)
  else
    local PROVIDER_FOLDERS = { [2] = "GOOGLE", [3] = "ESRI", [4] = "OSM" }
    local folder = PROVIDER_FOLDERS[provider] or ("PROVIDER" .. tostring(provider))
    local base   = "/bitmaps/ethosmaps/maps/" .. folder .. "/" .. mapType .. tilePath
    if provider == 2 then
      local yaapuBase  = getGoogleFallbackBasePath(mapType, tilePath)
      attemptedPaths   = { base .. ".jpg", base .. ".bmp", base .. ".png",
                           yaapuBase .. ".png" }
      bmp, loadedPath  = loadFirstExisting(tilePath, base .. ".jpg", base .. ".bmp", base .. ".png",
                                           yaapuBase .. ".png")
    else
      attemptedPaths   = { base .. ".jpg", base .. ".bmp", base .. ".png" }
      bmp, loadedPath  = loadFirstExisting(tilePath, base .. ".jpg", base .. ".bmp", base .. ".png")
    end
  end

  if bmp ~= nil then
    -- Log the tile format the first time it is seen for this provider+mapType combination.
    if status.debugEnabled and libs and libs.utils and libs.utils.logDebug then
      local logKey = fmt("provider:%s|mapType:%s", tostring(provider), tostring(mapType))
      if lastTileFormatLogByKey[logKey] == nil then
        local ext    = (type(loadedPath) == "string" and (loadedPath:match("%.([%a%d]+)$") or "unknown"):lower()) or "unknown"
        local source = "ethosmaps"
        if type(loadedPath) == "string" and loadedPath:find("/bitmaps/yaapu/maps/", 1, true) == 1 then
          source = "yaapu-fallback"
        elseif provider == 1 then
          source = "yaapu"
        end
        libs.utils.logDebug("TILE", "Tile format detected for " .. logKey .. ": ." .. ext .. " (source: " .. source .. ")", true)
        lastTileFormatLogByKey[logKey] = ext .. "|" .. source
      end
    end
    return bmp
  end

  -- No file found – log once per provider+mapType, then return the shared nomap sentinel.
  if status.debugEnabled and libs and libs.utils and libs.utils.logDebug then
    local logKey = fmt("provider:%s|mapType:%s", tostring(provider), tostring(mapType))
    if lastNoTilesLogKey ~= logKey then
      libs.utils.logDebug("TILE", "No tile files found for " .. logKey .. "; using fallback bitmap", true)
      if type(tilePath) == "string" then
        libs.utils.logDebug("TILE", "First missing tile key: " .. tilePath, true)
      end
      if type(attemptedPaths) == "table" then
        for i = 1, #attemptedPaths do
          libs.utils.logDebug("TILE", "Attempted path " .. tostring(i) .. ": " .. tostring(attemptedPaths[i]), true)
        end
      end
      lastNoTilesLogKey = logKey
    end
  end

  mapBitmapByPath[tilePath] = ensureNoMapBitmap()
  return mapBitmapByPath[tilePath]
end

-- ── Public API ────────────────────────────────────────────────────────────────

function tileLoader.getBitmap(tilePath)
  -- Cache-only read; returns nil when the tile has not been loaded yet.
  -- drawTiles() calls this so the paint path never touches the SD card.
  return mapBitmapByPath[tilePath]
end

function tileLoader.getNoMapBitmap()
  -- Returns the shared "NO MAP DATA" bitmap preloaded outside the paint path.
  return noMapBitmap
end

function tileLoader.getLoadingBitmap()
  -- Returns the shared "LOADING..." bitmap preloaded outside the paint path.
  return loadingBitmap
end

function tileLoader.enqueue(tilePath, isHighPriority)
  -- Adds tilePath to the appropriate load queue bucket if it is not already cached
  -- or queued.  High-priority tiles (near the map center) are placed in the front
  -- bucket and loaded before the low-priority fringe.
  if mapBitmapByPath[tilePath] ~= nil then return end

  if isHighPriority then
    if not highQueueSet[tilePath] then
      highQueueSet[tilePath]       = true
      highQueue[#highQueue + 1]    = tilePath
    end
  else
    if not lowQueueSet[tilePath] and not highQueueSet[tilePath] then
      lowQueueSet[tilePath]     = true
      lowQueue[#lowQueue + 1]   = tilePath
    end
  end
end

function tileLoader.processQueue(maxCount)
  -- Loads up to maxCount tiles from the queue.
  -- Called once per wakeup() tick so SD I/O is spread across frames instead
  -- of blocking a single paint() call.  High-priority tiles are always
  -- drained before low-priority ones.
  local highLen = #highQueue
  local lowLen  = #lowQueue
  if highHead > highLen and lowHead > lowLen then
    return 0  -- Both queues empty; nothing to do.
  end

  local loaded = 0
  local limit  = maxCount or 3

  -- Flush dead bitmap userdata before allocating new ones.  trimCache() sets
  -- the flag whenever it evicts entries; a single full GC cycle here ensures
  -- the freed memory is actually reclaimed before lcd.loadBitmap() allocates.
  if pendingGCBeforeLoad then
    collectgarbage()
    collectgarbage()  -- two passes: first marks, second finalises/frees
    pendingGCBeforeLoad = false
  end

  local perfActive = status and status.perfActive
  local perfAddMs = perfActive and status.perfProfileAddMs or nil

  while highHead <= highLen and loaded < limit do
    local path        = highQueue[highHead]
    highHead          = highHead + 1
    if path ~= nil then
      highQueueSet[path] = nil
      if mapBitmapByPath[path] == nil then
        local t0 = os_clock() * 1000
        loadTileFromDisk(path)
        local elapsed = os_clock() * 1000 - t0
        if perfAddMs then
          perfAddMs("tile_load_ms", elapsed)
        end
        cacheCount = cacheCount + 1
        loaded     = loaded + 1
      end
    end
  end

  while lowHead <= lowLen and loaded < limit do
    local path        = lowQueue[lowHead]
    lowHead           = lowHead + 1
    if path ~= nil then
      lowQueueSet[path] = nil
      if mapBitmapByPath[path] == nil then
        local t0 = os_clock() * 1000
        loadTileFromDisk(path)
        local elapsed = os_clock() * 1000 - t0
        if perfAddMs then
          perfAddMs("tile_load_ms", elapsed)
        end
        cacheCount = cacheCount + 1
        loaded     = loaded + 1
      end
    end
  end

  -- Compact arrays once fully drained to prevent unbounded index growth.
  if highHead > highLen then
    highQueue = {}
    highHead  = 1
  end
  if lowHead > lowLen then
    lowQueue = {}
    lowHead  = 1
  end

  return loaded
end

function tileLoader.clearCache()
  -- Discards all cached bitmaps and pending queue entries.
  -- Called by maplib.setupMaps() on zoom level, provider, or map-type change.
  --
  -- Nil each entry individually before reassigning the table.  Lua's GC is
  -- incremental: simply replacing the table reference (mapBitmapByPath = {})
  -- keeps all old bitmap userdata alive until the next GC sweep, which can
  -- happen AFTER new bitmaps are already loading – transiently doubling RAM
  -- and triggering an ETHOS kill.  Explicit per-key nils let the GC account
  -- for the dropped references before new loads begin.
  for k, _ in pairs(mapBitmapByPath) do
    mapBitmapByPath[k] = nil
  end
  mapBitmapByPath = {}
  highQueue       = {}
  highQueueSet    = {}
  highHead        = 1
  lowQueue        = {}
  lowQueueSet     = {}
  lowHead         = 1
  cacheCount      = 0
  lastTileFormatLogByKey = {}
  lastNoTilesLogKey      = nil
end

function tileLoader.trimCache(centerTileX, centerTileY, level, tilesX, tilesY, leadX, leadY, cacheRing)
  -- Evicts bitmap cache entries that fall outside the spatial ring around the current
  -- visible tile window, then purges the same paths from both load queues so we never
  -- waste a budget slot on a tile that is already out of view.
  if libs == nil or libs.mapLib == nil or libs.mapLib.tiles_to_path == nil then
    return 0
  end

  local ringTiles = (cacheRing ~= nil) and cacheRing or TILE_CACHE_RING_TILES
  local leadTileX = max(-1, min(1, tonumber(leadX) or 0))
  local leadTileY = max(-1, min(1, tonumber(leadY) or 0))
  local keepTilesX = max(1, tonumber(tilesX) or 0) + TILE_CACHE_REFERENCE_MARGIN_TILES
  local keepTilesY = max(1, tonumber(tilesY) or 0) + TILE_CACHE_REFERENCE_MARGIN_TILES

  local keepMinX = 1 - ringTiles
  local keepMaxX = keepTilesX + ringTiles
  local keepMinY = 1 - ringTiles
  local keepMaxY = keepTilesY + ringTiles

  if leadTileX ~= 0 then
    keepMinX = keepMinX - TILE_CACHE_DIRECTIONAL_GUARD_TILES
    keepMaxX = keepMaxX + TILE_CACHE_DIRECTIONAL_GUARD_TILES
  end

  if leadTileY ~= 0 then
    keepMinY = keepMinY - TILE_CACHE_DIRECTIONAL_GUARD_TILES
    keepMaxY = keepMaxY + TILE_CACHE_DIRECTIONAL_GUARD_TILES
  end

  -- Nothing cached – nothing to evict.
  if cacheCount == 0 then
    return 0
  end

  local keep  = {}
  local halfX = floor(keepTilesX / 2 + 0.5)
  local halfY = floor(keepTilesY / 2 + 0.5)

  for x = keepMinX, keepMaxX do
    for y = keepMinY, keepMaxY do
      local kp = libs.mapLib.tiles_to_path(centerTileX + x - halfX, centerTileY + y - halfY, level)
      keep[kp] = true
    end
  end

  -- Protect tiles belonging to OTHER widget instances' viewports so
  -- multi-instance configurations don't evict each other's visible tiles.
  local getProtected = libs.mapLib.getProtectedTilePaths
  if getProtected then
    local protected = getProtected()
    for path in pairs(protected) do
      keep[path] = true
    end
  end

  local removed = 0
  for path in pairs(mapBitmapByPath) do
    if not keep[path] then
      mapBitmapByPath[path] = nil
      removed = removed + 1
    end
  end

  if removed > 0 then
    cacheCount = cacheCount - removed
    pendingGCBeforeLoad = true

    -- Purge evicted paths from the high queue.
    local newHigh    = {}
    local newHighSet = {}
    for i = highHead, #highQueue do
      local p = highQueue[i]
      if p ~= nil and keep[p] then
        newHigh[#newHigh + 1] = p
        newHighSet[p]         = true
      end
    end
    highQueue    = newHigh
    highQueueSet = newHighSet
    highHead     = 1

    -- Purge evicted paths from the low queue.
    local newLow    = {}
    local newLowSet = {}
    for i = lowHead, #lowQueue do
      local p = lowQueue[i]
      if p ~= nil and keep[p] then
        newLow[#newLow + 1] = p
        newLowSet[p]        = true
      end
    end
    lowQueue    = newLow
    lowQueueSet = newLowSet
    lowHead     = 1
  end

  return removed
end

function tileLoader.getCacheCount()
  -- Returns the current number of entries in the bitmap cache (O(1) via tracked counter).
  return cacheCount
end

function tileLoader.getQueueLength()
  -- Returns total pending load-queue entries across both priority buckets.
  return (#highQueue - highHead + 1) + (#lowQueue - lowHead + 1)
end

function tileLoader.init(param_status, param_libs)
  status = param_status
  libs   = param_libs
  ensureNoMapBitmap()
  ensureLoadingBitmap()
  return tileLoader
end

return tileLoader
