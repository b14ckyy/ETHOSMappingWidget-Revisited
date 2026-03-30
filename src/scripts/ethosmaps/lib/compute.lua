-- ──────────────────────────────────────────────────────────────
-- compute.lua — Computation engine for wakeup()
-- ──────────────────────────────────────────────────────────────
-- Runs exclusively in wakeup(). Owns all heavy math that was
-- previously executed inside paint().  paint() reads results
-- via compute.getResults() (read-only contract).
--
-- Design (see ComputeSeparationPlan.md):
--   - ALL dirty tasks run every cycle (no staggering — wakeup
--     has no instruction limit and runs at only 2-3 Hz)
--   - Each task has an individual dirty flag; tasks whose inputs
--     haven't changed are skipped cheaply
--   - Table reuse: overwrite result fields, never re-allocate
--   - Optimize later: use perf logging to identify costly tasks
-- ──────────────────────────────────────────────────────────────

local compute = {}

-- ── shared refs (set in init) ──────────────────────────────
local status   -- mapStatus
local libs     -- mapLibs

-- ── task registry ──────────────────────────────────────────
local tasks = {}        -- { [i] = { name, fn, dirtyKey } }
local taskCount = 0
local dirty = {}        -- { [dirtyKey] = true/false }

-- ── results table (read-only for paint) ────────────────────
local results = {
  waypoints = {
    tpx     = {},     -- tile-pixel X per WP index
    tpy     = {},     -- tile-pixel Y per WP index
    homeTpx = nil,    -- home tile-pixel X (for RTH line)
    homeTpy = nil,    -- home tile-pixel Y (for RTH line)
    mLen    = 0,      -- mission length at last projection
    mIdx    = 0,      -- mission index at last projection
    level   = 0,      -- zoom level at last projection
    valid   = false,  -- true when projection covers all WPs
  },
  trail = {
    tpx     = {},     -- tile-pixel X per trail slot
    tpy     = {},     -- tile-pixel Y per trail slot
    level   = 0,      -- zoom level at last projection
    wpCount = 0,      -- trail point count at last projection
    valid   = false,  -- true when all trail points are projected
  },
}

-- ── WP action constants (mirrored from maplib.lua) ─────────
local WP_ACT_WAYPOINT      = 1
local WP_ACT_POSHOLD_TIME  = 3
local WP_ACT_SET_POI       = 5
local WP_ACT_LAND          = 8
local TILES_SIZE            = 100

local function wpHasPosition(action)
  return action == WP_ACT_WAYPOINT
      or action == WP_ACT_POSHOLD_TIME
      or action == WP_ACT_LAND
      or action == WP_ACT_SET_POI
end

-- ──────────────────────────────────────────────────────────────
-- Task: Waypoint tile-pixel projection
-- ──────────────────────────────────────────────────────────────
-- Replaces the batched reprojection that was previously in
-- drawWaypoints() inside paint(). Since wakeup() has no
-- instruction limit, all WPs are projected in a single pass.
-- ──────────────────────────────────────────────────────────────

local function computeWpProjection(st, lb, res)
  local wp = res.waypoints
  local missionList = st.mspMissions
  if not missionList or #missionList == 0 then
    wp.valid = false
    wp.mLen = 0
    return
  end

  local mIdx = st.mspMissionIdx or 1
  local mission = missionList[mIdx]
  if not mission or #mission == 0 then
    wp.valid = false
    wp.mLen = 0
    return
  end

  local level = st.mapZoomLevel or 0
  local mLen = #mission
  local coordToTiles = lb.mapLib and lb.mapLib.coord_to_tiles

  if not coordToTiles then
    wp.valid = false
    return
  end

  local tpx = wp.tpx
  local tpy = wp.tpy

  -- Check if full reprojection is needed
  local needsFull = (wp.level ~= level) or (wp.mIdx ~= mIdx)
  local needsIncremental = (mLen > wp.mLen) and (wp.level == level) and (wp.mIdx == mIdx)

  if needsFull then
    -- Full reprojection — all WPs in one pass (no batching needed in wakeup)
    for i = 1, mLen do
      local w = mission[i]
      if wpHasPosition(w.action) then
        local tx, ty, ox, oy = coordToTiles(w.lat, w.lon, level)
        tpx[i] = tx * TILES_SIZE + ox
        tpy[i] = ty * TILES_SIZE + oy
      else
        tpx[i] = nil
        tpy[i] = nil
      end
    end
    -- Clear stale entries beyond mission length
    for i = mLen + 1, #tpx do tpx[i] = nil end
    for i = mLen + 1, #tpy do tpy[i] = nil end

  elseif needsIncremental then
    -- Incremental: only project newly-added WPs (download in progress)
    for i = wp.mLen + 1, mLen do
      local w = mission[i]
      if w and wpHasPosition(w.action) then
        local tx, ty, ox, oy = coordToTiles(w.lat, w.lon, level)
        tpx[i] = tx * TILES_SIZE + ox
        tpy[i] = ty * TILES_SIZE + oy
      else
        tpx[i] = nil
        tpy[i] = nil
      end
    end

  else
    -- Nothing changed — keep existing projection
    return
  end

  -- Pre-compute home tile-pixel position for RTH lines
  local tel = st.telemetry
  if tel and tel.homeLat and tel.homeLon then
    local htx, hty, hox, hoy = coordToTiles(tel.homeLat, tel.homeLon, level)
    wp.homeTpx = htx * TILES_SIZE + hox
    wp.homeTpy = hty * TILES_SIZE + hoy
  else
    wp.homeTpx = nil
    wp.homeTpy = nil
  end

  wp.mLen = mLen
  wp.mIdx = mIdx
  wp.level = level
  wp.valid = true
end

-- ──────────────────────────────────────────────────────────────
-- Task: Trail tile-pixel projection
-- ──────────────────────────────────────────────────────────────
-- Replaces the batched trail reprojection that was previously in
-- drawMap() inside paint(). Since wakeup() has no instruction
-- limit, all trail points are projected in a single pass.
-- Trail data (ring-buffer) still lives in maplib.lua; we access
-- it via mapLib.getTrailState().
-- ──────────────────────────────────────────────────────────────

local function computeTrailProjection(st, lb, res)
  local tr = res.trail
  local mapLib = lb and lb.mapLib
  if not mapLib or not mapLib.getTrailState then
    tr.valid = false
    return
  end

  local trailState = mapLib.getTrailState()
  local wpCount = trailState.wpCount
  if wpCount == 0 then
    tr.valid = false
    tr.wpCount = 0
    return
  end

  local level = st.mapZoomLevel or 0
  local coordToTiles = mapLib.coord_to_tiles
  if not coordToTiles then
    tr.valid = false
    return
  end

  local waypoints = trailState.waypoints
  local head = trailState.head
  local maxWp = trailState.maxWaypoints
  local tpx = tr.tpx
  local tpy = tr.tpy

  -- Check if full reprojection is needed
  local needsFull = (tr.level ~= level)
  local needsIncremental = (wpCount > tr.wpCount) and (tr.level == level)

  if needsFull then
    -- Full reprojection — all trail points in one pass
    for k = 1, wpCount do
      local slot
      if wpCount < maxWp then
        slot = k
      else
        slot = ((head + k - 1) % maxWp) + 1
      end
      local wp = waypoints[slot]
      if wp then
        local tx, ty, ox, oy = coordToTiles(wp[1], wp[2], level)
        tpx[slot] = tx * TILES_SIZE + ox
        tpy[slot] = ty * TILES_SIZE + oy
      end
    end
    -- Clear stale entries beyond trail size
    for i = wpCount + 1, #tpx do tpx[i] = nil end
    for i = wpCount + 1, #tpy do tpy[i] = nil end

  elseif needsIncremental then
    -- Incremental: only project newly-added trail points
    -- New points have indices from (old wpCount+1) to wpCount in iteration order.
    -- We need to project the new slot(s) that were added.
    for k = tr.wpCount + 1, wpCount do
      local slot
      if wpCount < maxWp then
        slot = k
      else
        slot = ((head + k - 1) % maxWp) + 1
      end
      local wp = waypoints[slot]
      if wp then
        local tx, ty, ox, oy = coordToTiles(wp[1], wp[2], level)
        tpx[slot] = tx * TILES_SIZE + ox
        tpy[slot] = ty * TILES_SIZE + oy
      end
    end

  else
    -- Nothing changed — keep existing projection
    return
  end

  tr.wpCount = wpCount
  tr.level = level
  tr.valid = true
end

-- ──────────────────────────────────────────────────────────────
-- Task registry
-- ──────────────────────────────────────────────────────────────

--- Register a named compute task.
-- @param name     string   unique task identifier (for perf logging)
-- @param fn       function task body: fn(status, libs, results)
-- @param dirtyKey string   key into dirty[] that triggers this task
function compute.registerTask(name, fn, dirtyKey)
  taskCount = taskCount + 1
  tasks[taskCount] = { name = name, fn = fn, key = dirtyKey }
  dirty[dirtyKey] = false
end

--- Mark a dirty flag so the next update() runs the associated task.
function compute.setDirty(key)
  dirty[key] = true
end

--- Mark ALL dirty flags (e.g. after zoom change or full reset).
function compute.setAllDirty()
  for i = 1, taskCount do
    dirty[tasks[i].key] = true
  end
end

--- Query whether a specific key is dirty.
function compute.isDirty(key)
  return dirty[key] == true
end

-- ──────────────────────────────────────────────────────────────
-- Update — runs ALL dirty tasks every cycle
-- ──────────────────────────────────────────────────────────────

--- Main entry point. Called once per wakeup().
--- Runs every task whose dirty flag is set, then clears it.
function compute.update(widget)
  if taskCount == 0 then return end

  for i = 1, taskCount do
    local t = tasks[i]
    if dirty[t.key] then
      t.fn(status, libs, results)
      dirty[t.key] = false
    end
  end
end

-- ──────────────────────────────────────────────────────────────
-- Accessors
-- ──────────────────────────────────────────────────────────────

function compute.getResults()
  return results
end

function compute.getTaskCount()
  return taskCount
end

function compute.getDirtyFlags()
  return dirty
end

-- ──────────────────────────────────────────────────────────────
-- Init / reset
-- ──────────────────────────────────────────────────────────────

function compute.reset()
  for i = 1, taskCount do
    dirty[tasks[i].key] = false
  end
end

function compute.init(param_status, param_libs)
  status = param_status
  libs = param_libs

  -- Phase 2: WP tile-pixel projection (Mercator coordToTiles math)
  compute.registerTask("wpProjection", computeWpProjection, "needsWpProjection")

  -- Phase 3: Trail tile-pixel projection
  compute.registerTask("trailProjection", computeTrailProjection, "needsTrailProjection")

  -- Run all tasks on the first wakeup cycle — data may already be
  -- published (e.g. MSP missions loaded before compute.init).
  compute.setAllDirty()
end

return compute
