-- Tile format probing: a missing file returns an empty bitmap handle on ETHOS, not nil, and width()
-- forces the lazy decode (Docs/development/helper/ETHOS-API-QUIRKS.md). Run from the repo root.

local fails = 0
local function check(name, cond)
  print((cond and "ok   " or "FAIL ") .. name)
  if not cond then fails = fails + 1 end
end

local files = {}
local loads = {}
local widthCalls = 0
local function handle(w) return { width = function() widthCalls = widthCalls + 1 return w end, tag = w } end
local NOMAP = handle(64)
lcd = {
  loadBitmap = function(path)
    loads[#loads + 1] = path
    if path:find("nomap.png", 1, true) then return NOMAP end
    if path:find("loading.png", 1, true) then return handle(32) end
    if files[path] then return handle(100) end
    return handle(0)
  end,
}

local realOpen = io.open
io.open = function(path, mode)
  if path:sub(1, 5) == "src/s" then return realOpen(path, mode) end
  if files[path] or path:find("nomap.png", 1, true) or path:find("loading.png", 1, true) then return {} end
  return nil
end
io.close = function() end

local function newLoader()
  local tl = dofile("src/scripts/ethosmaps/lib/tileloader.lua")
  tl.init({ conf = { mapProvider = 2, mapType = "Satellite" } }, {})
  return tl
end

local function load(tl, path)
  tl.enqueue(path, true)
  tl.processQueue(100000)
  return tl.getBitmap(path)
end

local base = "/bitmaps/ethosmaps/maps/GOOGLE/Satellite"

do
  files = { [base .. "/15/1/2.png"] = true, [base .. "/15/1/3.png"] = true }
  local tl = newLoader()
  local bmp = load(tl, "/15/1/2")
  check("png found behind empty .jpg and .bmp handles", bmp ~= nil and bmp.tag == 100)
  loads = {}
  bmp = load(tl, "/15/1/3")
  check("format cached: next tile goes straight to .png", bmp.tag == 100 and #loads == 1 and loads[1] == base .. "/15/1/3.png")
end

do
  files = { [base .. "/15/1/2.jpg"] = true }
  local tl = newLoader()
  loads = {}
  local bmp = load(tl, "/15/1/2")
  check("jpg still first", bmp.tag == 100 and #loads == 1 and loads[1] == base .. "/15/1/2.jpg")
end

do
  files = { ["/bitmaps/yaapu/maps/GoogleSatelliteMap/15/2/s_1.png"] = true }
  local tl = newLoader()
  local bmp = load(tl, "/15/1/2")
  check("yaapu fallback reached", bmp ~= nil and bmp.tag == 100)
end

do
  files = {}
  local tl = newLoader()
  local bmp = load(tl, "/15/1/2")
  check("no file anywhere -> nomap placeholder", bmp == NOMAP)
end

check("width() never called in the load path", widthCalls == 0)

do
  files = { [base .. "/15/1/2.jpg"] = true, [base .. "/15/1/3.jpg"] = true }
  local tl = newLoader()
  load(tl, "/15/1/2")
  check("probed tile needs no verification", tl.getUnverified() == nil)

  local good = load(tl, "/15/1/3")
  load(tl, "/15/1/4")
  check("fast path tiles wait for verification", tl.getUnverified() ~= nil)
  check("no width() before the idle check", widthCalls == 0)

  tl.verifyTile("/15/1/3")
  check("existing tile keeps its bitmap", tl.getBitmap("/15/1/3") == good)
  tl.verifyTile("/15/1/4")
  check("missing tile -> placeholder", tl.getBitmap("/15/1/4") == NOMAP)
  check("nothing left to verify", tl.getUnverified() == nil)

  local before = widthCalls
  tl.verifyTile("/15/1/3")
  check("second check does nothing", widthCalls == before)

  load(tl, "/15/1/5")
  tl.clearCache()
  check("clearCache drops pending checks", tl.getUnverified() == nil)
end

print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
