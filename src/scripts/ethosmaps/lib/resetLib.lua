local resetLib = {}
local status = nil

-- Clears all entries from a table so cached layouts, tiles, and other transient state can be released.
-- Sub-tables are collected by Lua GC once no references remain.
function resetLib.clearTable(t)
  if type(t) == "table" then
    for k in pairs(t) do
      t[k] = nil
    end
  end
end

function resetLib.resetLayout(widget)
  -- Clears the loaded layout cache, resets per-screen layout state, and marks the widget for a fresh layout load.
  status.loadCycle = 0
  resetLib.clearTable(status.layout)
  status.layout = {}
  widget.ready = false

  if status.perfActive and status.perfProfileInc then
    status.perfProfileInc("gc_count", 2)
  end
end

function resetLib.reset(widget)
  -- Performs a full widget reset by clearing layout state and forcing Lua garbage collection afterwards.
  resetLib.resetLayout(widget)
  if status.perfActive and status.perfProfileInc then
    status.perfProfileInc("gc_count", 2)
  end
end

function resetLib.init(param_status, param_libs)
  -- Stores shared state references so reset helpers can mutate widget status and cooperate with sibling libraries.
  status = param_status
  return resetLib
end

return resetLib
