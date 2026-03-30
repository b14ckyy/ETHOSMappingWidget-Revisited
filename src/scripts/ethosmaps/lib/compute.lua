-- ──────────────────────────────────────────────────────────────
-- compute.lua — Scheduled computation engine for wakeup()
-- ──────────────────────────────────────────────────────────────
-- Runs exclusively in wakeup(). Owns all heavy math that was
-- previously executed inside paint().  paint() reads results
-- via compute.getResults() (read-only contract).
--
-- Design priorities (see ComputeSeparationPlan.md):
--   P1  Staggered scheduler — max 1-2 tasks per wakeup cycle
--   P2  Input fingerprinting — skip when nothing changed
--   P3  Table reuse — overwrite, never re-allocate
-- ──────────────────────────────────────────────────────────────

local compute = {}

-- ── shared refs (set in init) ──────────────────────────────
local status   -- mapStatus
local libs     -- mapLibs

-- ── priority constants ─────────────────────────────────────
local PRI_HIGH   = 1   -- tile grid, vehicle/home position
local PRI_MEDIUM = 2   -- waypoint layout, trail segments
local PRI_LOW    = 3   -- sensor cache, scale bar, prefetch

compute.PRI_HIGH   = PRI_HIGH
compute.PRI_MEDIUM = PRI_MEDIUM
compute.PRI_LOW    = PRI_LOW

-- ── scheduler state ────────────────────────────────────────
local tasks = {}        -- { [i] = { name, pri, fn, dirtyKey } }
local taskCount = 0
local dirty = {}        -- { [dirtyKey] = true/false }
local skipCount = {}    -- starvation counters per task name
local STARVE_LIMIT = 5  -- promote LOW task after N skipped cycles

-- ── input fingerprint ──────────────────────────────────────
local fingerprint = {
  zoom      = 0,
  centerTX  = 0,      -- center tile X
  centerTY  = 0,      -- center tile Y
  offsetPX  = 0,      -- pixel offset X
  offsetPY  = 0,      -- pixel offset Y
  wpRev     = 0,      -- WP data revision
  trailIdx  = 0,      -- trail write index
  panState  = 0,
}

-- ── results table (read-only for paint) ────────────────────
local results = {
  -- Phase 2+: populated by task functions
  -- waypoints = { segments = {}, markers = {}, jumps = {}, rthLine = {} },
  -- trail     = { segments = {} },
  -- tileGrid  = { paths = {}, screenPositions = {} },
  -- positions = { vehicleX, vehicleY, homeX, homeY },
  -- scale     = { pixels, label },
  -- bar       = { groundSpeed, heading, travelDist, homeDist },
  -- sensors   = {},
}

-- ──────────────────────────────────────────────────────────────
-- Task registry
-- ──────────────────────────────────────────────────────────────

--- Register a named compute task.
-- @param name     string   unique task identifier
-- @param priority number   PRI_HIGH / PRI_MEDIUM / PRI_LOW
-- @param fn       function task body: fn(status, libs, results)
-- @param dirtyKey string   key into dirty[] that triggers this task
function compute.registerTask(name, priority, fn, dirtyKey)
  taskCount = taskCount + 1
  tasks[taskCount] = { name = name, pri = priority, fn = fn, key = dirtyKey }
  dirty[dirtyKey] = false
  skipCount[name] = 0
end

--- Mark a dirty flag so the scheduler picks up the associated task.
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
-- Fingerprint-based change detection
-- ──────────────────────────────────────────────────────────────

--- Update fingerprint from current mapStatus. Returns true if
--- any input changed (→ something is potentially dirty).
local function updateFingerprint()
  local changed = false
  local s = status

  local zoom = s.mapZoomLevel or 0
  if zoom ~= fingerprint.zoom then
    fingerprint.zoom = zoom
    changed = true
  end

  local ox = s.panOffsetX or 0
  local oy = s.panOffsetY or 0
  if ox ~= fingerprint.offsetPX or oy ~= fingerprint.offsetPY then
    fingerprint.offsetPX = ox
    fingerprint.offsetPY = oy
    changed = true
  end

  local ps = s.panState or 0
  if ps ~= fingerprint.panState then
    fingerprint.panState = ps
    changed = true
  end

  -- mapRedrawPending is set by markMapDirty() in main.lua
  if s.mapRedrawPending then
    changed = true
  end

  return changed
end

-- ──────────────────────────────────────────────────────────────
-- Scheduler core
-- ──────────────────────────────────────────────────────────────

--- Pick the best task to run this cycle.
-- Returns task table or nil.
local function pickTask()
  local best = nil
  local bestPri = PRI_LOW + 1   -- sentinel

  for i = 1, taskCount do
    local t = tasks[i]
    if dirty[t.key] then
      local effectivePri = t.pri
      -- Starvation promotion: LOW tasks that have been skipped too many cycles
      if effectivePri == PRI_LOW and skipCount[t.name] >= STARVE_LIMIT then
        effectivePri = PRI_MEDIUM
      end
      if effectivePri < bestPri then
        bestPri = effectivePri
        best = t
      end
    end
  end

  return best
end

--- Main scheduler entry point. Called once per wakeup().
function compute.update(widget)
  if taskCount == 0 then return end

  -- Step 1: fingerprint check — if nothing changed AND no flags
  -- are dirty, skip entirely.
  local inputChanged = updateFingerprint()

  local anyDirty = false
  if inputChanged then
    -- When fingerprint changed, mark all as potentially dirty.
    -- (In later phases, individual tasks will refine this.)
    anyDirty = true
  else
    for i = 1, taskCount do
      if dirty[tasks[i].key] then
        anyDirty = true
        break
      end
    end
  end

  if not anyDirty then return end

  -- Step 2: pick highest-priority dirty task
  local t = pickTask()
  if not t then return end

  -- Execute the task
  t.fn(status, libs, results)
  dirty[t.key] = false
  skipCount[t.name] = 0

  -- Increment skip counters for tasks NOT chosen
  for i = 1, taskCount do
    local other = tasks[i]
    if other ~= t and dirty[other.key] then
      skipCount[other.name] = (skipCount[other.name] or 0) + 1
    end
  end

  -- Step 3: if budget remains, try one LOW/MEDIUM bonus task
  local bonus = pickTask()
  if bonus and bonus.pri >= PRI_LOW then
    bonus.fn(status, libs, results)
    dirty[bonus.key] = false
    skipCount[bonus.name] = 0
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
  -- Clear all dirty flags and skip counters (e.g. on full map reset)
  for i = 1, taskCount do
    dirty[tasks[i].key] = false
    skipCount[tasks[i].name] = 0
  end
end

function compute.init(param_status, param_libs)
  status = param_status
  libs = param_libs

  -- Phase 2+: register concrete tasks here, e.g.:
  -- compute.registerTask("wpLayout",  PRI_MEDIUM, computeWpLayout,  "needsWpLayout")
  -- compute.registerTask("trail",     PRI_MEDIUM, computeTrail,     "needsTrailClip")
  -- compute.registerTask("tileGrid",  PRI_HIGH,   computeTileGrid,  "needsTileGrid")
  -- compute.registerTask("positions", PRI_HIGH,   computePositions, "needsPositions")
  -- compute.registerTask("scale",     PRI_LOW,    computeScale,     "needsScale")
  -- compute.registerTask("bar",       PRI_LOW,    computeBar,       "needsBarSnapshot")
  -- compute.registerTask("sensors",   PRI_LOW,    computeSensors,   "needsSensors")
end

return compute
