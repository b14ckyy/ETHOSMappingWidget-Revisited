-- ftrace.lua  –  Function Trace Logger for instruction-spike diagnosis
--
-- Records enter/leave events with os.clock() timestamps for every
-- instrumented function during paint() and wakeup().
--
-- On a successful paint frame the current trace is kept in a small ring
-- buffer (last N frames).  When pcall catches an instruction-limit error
-- the crash frame plus the preceding normal frames and two post-crash
-- frames are dumped to the debug log for offline analysis.
--
-- Trace line format:
--   >NNN T.TTTTTT   (enter function NNN at time T)
--   <NNN T.TTTTTT   (leave function NNN at time T)
--
-- The LAST ">NNN" without a matching "<NNN" in a crash frame identifies
-- the function that was executing when the instruction limit was hit.

local ftrace = {}

local os_clock = os.clock
local fmt      = string.format

-- ── state ──────────────────────────────────────────────────────
-- Single pre-allocated buffer, reused every frame.  On crash the contents
-- are copied into crashSnapshot before being overwritten.
local buf   = {}   -- current frame: flat {id,flag,clock, id,flag,clock, …}
local bN    = 0    -- write index into buf

-- Instead of a ring of table objects we keep ONE previous-frame snapshot.
-- This avoids per-frame table allocations entirely.
local prevBuf  = {}   -- snapshot of the last successful frame
local prevN    = 0    -- valid length of prevBuf

local crashSnapshot = nil  -- shallow copy of buf at crash time
local crashN        = 0
local crashErr      = nil  -- error message string

local dumpCount = 0   -- number of dumps written this session
local logFn     = nil -- reference to utils.logDebug

-- ── API ────────────────────────────────────────────────────────

--- Called by loadLib(). Extracts the log function from shared libs.
function ftrace.init(status, libs)
  if libs and libs.utils and libs.utils.logDebug then
    logFn = libs.utils.logDebug
  end
  dumpCount     = 0
  crashSnapshot = nil
  crashN        = 0
  crashErr      = nil
  prevN         = 0
  bN            = 0
end

--- Call at the very beginning of the function / block.
function ftrace.enter(id)
  bN = bN + 1;  buf[bN] = id
  bN = bN + 1;  buf[bN] = 1         -- 1 = enter
  bN = bN + 1;  buf[bN] = os_clock()
end

--- Call just before the function / block returns.
function ftrace.leave(id)
  bN = bN + 1;  buf[bN] = id
  bN = bN + 1;  buf[bN] = 0         -- 0 = leave
  bN = bN + 1;  buf[bN] = os_clock()
end

-- ── helpers (zero-alloc snapshot) ──────────────────────────────

--- Copy buf[1..bN] → dest[1..bN], nil-pad any stale tail in dest.
local function snapBuf(src, srcN, dest)
  for i = 1, srcN do dest[i] = src[i] end
  -- clear stale tail from a previous longer frame
  local j = srcN + 1
  while dest[j] ~= nil do dest[j] = nil; j = j + 1 end
  return srcN
end

--- Reset the current-frame buffer (call once at frame start).
--- Reuses the same table — just resets the write cursor.
function ftrace.frameStart()
  bN = 0
end

--- Finalize the current frame.
--- @param crashed  boolean   true when pcall caught an error
--- @param errMsg   string?   the error message (only on crash)
function ftrace.frameEnd(crashed, errMsg)
  if crashed then
    -- Snapshot the live buf into crashSnapshot (one-time copy, no alloc after init).
    if not crashSnapshot then crashSnapshot = {} end
    crashN   = snapBuf(buf, bN, crashSnapshot)
    crashErr = errMsg
    ftrace.dump()
    -- Reset state so the next crash can be captured in the same session.
    crashSnapshot = nil
    crashN        = 0
    crashErr      = nil
    prevN         = 0
  else
    -- Normal: rotate current frame into prevBuf (single table, reused).
    prevN = snapBuf(buf, bN, prevBuf)
  end
end

--- Write all collected traces to a dedicated trace file on the SD card.
function ftrace.dump()
  dumpCount = dumpCount + 1

  local lines = {}
  local n = 0

  local function add(s)
    n = n + 1
    lines[n] = s
  end

  local function dumpBuf(label, b, bLen)
    local evts = bLen / 3
    add(fmt("--- %s (%d events) ---", label, evts))
    for i = 1, bLen, 3 do
      add(fmt("%s%03d %.6f",
          b[i + 1] == 1 and ">" or "<",
          b[i], b[i + 2]))
    end
  end

  add(fmt("========== FUNCTION TRACE DUMP #%d ==========", dumpCount))

  if prevN > 0 then
    dumpBuf("PRE-CRASH (last good frame)", prevBuf, prevN)
  end

  if crashSnapshot then
    add(fmt("!!! CRASH: %s !!!", crashErr or "unknown"))
    dumpBuf("CRASH FRAME", crashSnapshot, crashN)
  end

  add("========== END TRACE DUMP ==========")

  -- Numbered files: ftrace_dump_1.txt, ftrace_dump_2.txt, ...
  local filename = fmt("/scripts/ethosmaps/ftrace_dump_%d.txt", dumpCount)
  local f = io.open(filename, "w")
  if f then
    for i = 1, n do
      f:write(lines[i])
      f:write("\n")
    end
    f:close()
  end

  if logFn then
    logFn("FTRACE", fmt("Trace dumped to %s (%d lines)", filename, n), true)
  end
end

function ftrace.hasCrashed()
  return dumpCount > 0
end

function ftrace.getDumpCount()
  return dumpCount
end

return ftrace
