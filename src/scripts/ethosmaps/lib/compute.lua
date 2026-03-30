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

  -- Phase 2+: register concrete tasks here, e.g.:
  -- compute.registerTask("wpLayout",  computeWpLayout,  "needsWpLayout")
  -- compute.registerTask("trail",     computeTrail,     "needsTrailClip")
  -- compute.registerTask("tileGrid",  computeTileGrid,  "needsTileGrid")
  -- compute.registerTask("positions", computePositions, "needsPositions")
  -- compute.registerTask("scale",     computeScale,     "needsScale")
  -- compute.registerTask("bar",       computeBar,       "needsBarSnapshot")
  -- compute.registerTask("sensors",   computeSensors,   "needsSensors")
end

return compute
