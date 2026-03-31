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


local utils = {}

-- Cached stdlib references for embedded Lua performance (avoid _ENV hash lookups).
local type = type
local tostring = tostring
local floor, abs = math.floor, math.abs
local sin, cos, rad, asin, sqrt, atan, deg = math.sin, math.cos, math.rad, math.asin, math.sqrt, math.atan, math.deg
local pi = math.pi
local fmt = string.format
local io_open = io.open
local os_rename, os_remove = os.rename, os.remove
local tinsert = table.insert

local status = nil
local libs = nil

-- Debug logger state shared by rollover and write helpers.
local debugLogPath = "/scripts/ethosmaps/debug.log"
local maxLogLines = 1000
local maxScanLines = 8000      -- Safety cap for line-by-line scans to avoid ETHOS instruction-limit aborts.
local lastLogWrite = 0
local logFlushInterval = 100   -- Flush buffered log lines every 1 second (centiseconds).
local maxBufferedLines = 40
local lastLogFlush = 0
local logBuffer = {}
utils.debugLineCount = nil   -- Keeps lazy initialization active across restarts and debug toggles.

-- Canonical flag evaluator for all config booleans across the widget.
-- Normalises Ethos config values (bool / number / string) into a plain boolean.
-- Exported as status.flagEnabled in init() — every other module must use that
-- reference instead of defining its own copy.
local function flagEnabled(value)
  if value == true then
    return true
  end
  local valueType = type(value)
  if valueType == "number" then
    return value ~= 0
  end
  if valueType == "string" then
    local normalized = string.lower(value)
    return normalized == "true" or normalized == "1" or normalized == "on"
  end
  return false
end

-- Compacts the debug log file when it reaches its size limit by copying only the newest lines into a fresh file.
-- Ethos file handles use read("*l") reliably here, so rollover avoids iterator helpers and writes the retained log back to disk.
function utils.performRollover()
  local tmpPath  = debugLogPath .. ".tmp"
  local backupPath = debugLogPath .. ".bak"
  
  -- Count the current number of log lines before choosing how much history to keep.
  local totalLines = 0
  local fCount = io_open(debugLogPath, "r")
  if fCount then
    local line = fCount:read("*l")
    while line do
      totalLines = totalLines + 1
      if totalLines >= maxScanLines then
        break
      end
      line = fCount:read("*l")
    end
    fCount:close()
  end

  -- Copy only the newest 70% of the configured log limit into the replacement file.
  local keepCount = floor(maxLogLines * 0.7)  -- Example: keep 3500 lines when the limit is 5000.
  local skipCount = totalLines - keepCount         -- Skip the oldest lines first.

  local f  = io_open(debugLogPath, "r")
  local f2 = io_open(tmpPath, "w")
  
  if f and f2 then
    local lineIndex = 0
    local line = f:read("*l")
    while line do
      lineIndex = lineIndex + 1
      if lineIndex > skipCount then
        f2:write(line .. "\n")
      end
      line = f:read("*l")
    end
    
    f2:write("00:00:00.00 | SETTINGS | === DEBUG LOG ROLLED (kept last " .. keepCount .. " lines) ===\n")
    
    f:close()
    f2:close()
    
    -- Protect file operations with pcall to avoid runtime aborts on rename/remove failures.
    pcall(function()
      os_rename(debugLogPath, backupPath)
      os_rename(tmpPath, debugLogPath)
      os_remove(backupPath)
    end)
    
    utils.debugLineCount = keepCount + 1

    -- After a rollover the session header and settings snapshot are gone; trigger a fresh one.
    if status then
      status.sessionLogged = false
    end
    else
    -- Ensure all opened handles are closed and the temporary file is cleaned up on failure.
    if f then f:close() end
    if f2 then f2:close() end
    os_remove(tmpPath)
  end
end

local function initDebugLineCount()
  -- Counts existing log lines on demand so logDebug can append efficiently without scanning the file every call.
  if not status or not status.conf or not status.flagEnabled(status.conf.enableDebugLog) then 
    utils.debugLineCount = nil
    return 
  end

  local count = 0
  local f = io_open(debugLogPath, "r")
  if f then
    local line = f:read("*l")
    while line do
      count = count + 1
      if count >= maxScanLines then
        -- Treat over-limit files as "full" without scanning to EOF to stay below instruction limits.
        count = maxLogLines
        break
      end
      line = f:read("*l")
    end
    f:close()
  end
  utils.debugLineCount = count

  -- Trigger rollover immediately once the existing file is already at the limit.
  if utils.debugLineCount >= maxLogLines then
    utils.performRollover()
  end
end

function utils.logDebug(category, message, force)
  -- Buffers debug records in RAM and writes them to disk in batches to reduce SD-card I/O.
  if not status or not status.conf or not status.flagEnabled(status.conf.enableDebugLog) then 
    logBuffer = {}
    utils.debugLineCount = nil   -- Safeguard: reset lazy state when logging is unavailable or disabled.
    return 
  end

  -- Lazily count existing lines only on the first write after startup or a debug toggle.
  if utils.debugLineCount == nil then
    initDebugLineCount()
  end

  local now = status.getTime()
  if not force and now - lastLogWrite < 10 then return end
  lastLogWrite = now

  local timestamp = fmt("%02d:%02d:%02d.%02d",
    floor(now/360000)%24,
    floor(now/6000)%60,
    floor(now/100)%60,
    floor(now % 100))

  local cat = fmt("%-8s", category)
  local line = timestamp .. " | " .. cat .. " | " .. tostring(message) .. "\n"

  local function writeLines(lines)
    if #lines == 0 then
      return
    end
    local f = io_open(debugLogPath, "a")
    if f then
      for i = 1, #lines do
        f:write(lines[i])
      end
      f:close()
      utils.debugLineCount = (utils.debugLineCount or 0) + #lines
      if utils.debugLineCount >= maxLogLines then
        utils.performRollover()
      end
    end
  end

  local function flushBuffer(forceFlush)
    if #logBuffer == 0 then
      return
    end
    if not forceFlush and (now - lastLogFlush) < logFlushInterval then
      return
    end
    local pending = logBuffer
    logBuffer = {}
    writeLines(pending)
    lastLogFlush = now
  end

  local immediate = force == true or category == "ERROR" or category == "CRASH" or category == "SETTINGS"
  if immediate then
    flushBuffer(true)
    writeLines({line})
    lastLogFlush = now
  else
    logBuffer[#logBuffer + 1] = line
    if #logBuffer >= maxBufferedLines then
      flushBuffer(true)
    else
      flushBuffer(false)
    end
  end
end

function utils.flushLogs(force)
  -- Flushes buffered log lines when the interval elapsed (or immediately when forced).
  if not status or not status.conf or not status.flagEnabled(status.conf.enableDebugLog) then
    logBuffer = {}
    return
  end

  if #logBuffer == 0 then
    return
  end

  if utils.debugLineCount == nil then
    initDebugLineCount()
  end

  local now = status.getTime()
  if not force and (now - lastLogFlush) < logFlushInterval then
    return
  end

  local f = io_open(debugLogPath, "a")
  if f then
    for i = 1, #logBuffer do
      f:write(logBuffer[i])
    end
    f:close()
    utils.debugLineCount = (utils.debugLineCount or 0) + #logBuffer
    if utils.debugLineCount >= maxLogLines then
      utils.performRollover()
    end
  end

  logBuffer = {}
  lastLogFlush = now
end

function utils.haversine(lat1, lon1, lat2, lon2)
  -- Converts two GPS coordinates into a great-circle distance in meters for speed, trail, and home calculations.
  local lat1 = lat1 * pi / 180
  local lon1 = lon1 * pi / 180
  local lat2 = lat2 * pi / 180
  local lon2 = lon2 * pi / 180

  local lat_dist = lat2 - lat1
  local lon_dist = lon2 - lon1
  local lat_hsin  = sin(lat_dist/2)^2
  local lon_hsin  = sin(lon_dist/2)^2

  local a = lat_hsin + cos(lat1) * cos(lat2) * lon_hsin
  if a < 0 then a = 0 end  -- Guard against FP rounding producing a tiny negative value.
  return 2 * 6372.8 * asin(sqrt(a)) * 1000
end

function utils.getAngleFromLatLon(lat1, lon1, lat2, lon2)
  -- Calculates the bearing from one GPS coordinate to another and returns the heading in degrees.
  local la1 = rad(lat1)
  local lo1 = rad(lon1)
  local la2 = rad(lat2)
  local lo2 = rad(lon2)

  local y = sin(lo2-lo1) * cos(la2);
  local x = cos(la1)*sin(la2) - sin(la1)*cos(la2)*cos(lo2-lo1);
  local a = atan(y, x);

  return (a*180/pi + 360) % 360 -- Returned in degrees.
end

function utils.updateCog()
  -- Derives course over ground from successive GPS samples and writes the result back into status.telemetry.cog.
  if status.lastLat == nil then
    status.lastLat = status.telemetry.lat
  end
  if status.lastLon == nil then
    status.lastLon = status.telemetry.lon
  end
  if status.lastLat ~= nil and status.lastLon ~= nil and status.lastLat ~= status.telemetry.lat and status.lastLon ~= status.telemetry.lon then
    local cog = utils.getAngleFromLatLon(status.lastLat, status.lastLon, status.telemetry.lat, status.telemetry.lon)
    if cog ~= nil and status.telemetry.groundSpeed > 1 then
      status.telemetry.cog = cog
    end
    -- Store the latest coordinates so the next call can derive movement direction from fresh samples.
    status.lastLat = status.telemetry.lat
    status.lastLon = status.telemetry.lon
  end
end

function utils.getLatLonFromAngleAndDistance(angle, distance)
--[[
  la1,lo1 coordinates of first point
  d be distance (m),
  R as radius of Earth (m),
  Ad be the angular distance i.e d/R and
  θ be the bearing in deg

  la2 =  asin(sin la1 * cos Ad  + cos la1 * sin Ad * cos θ), and
  lo2 = lo1 + atan(sin θ * sin Ad * cos la1 , cos Ad – sin la1 * sin la2)
--]]
  -- Projects a point away from the current aircraft position using bearing and distance, then returns the estimated GPS coordinate.
  if status.telemetry.lat == nil or status.telemetry.lon == nil then
    return nil,nil -- Safeguard: projection requires a valid current GPS position.
  end
  local lat1 = rad(status.telemetry.lat)
  local lon1 = rad(status.telemetry.lon)
  local Ad = distance/(6371000) -- Angular distance in radians for Earth-radius based projection.
  local lat2 = asin( sin(lat1) * cos(Ad) + cos(lat1) * sin(Ad) * cos( rad(angle)) )
  local lon2 = lon1 + atan( sin( rad(angle) ) * sin(Ad) * cos(lat1) , cos(Ad) - sin(lat1) * sin(lat2))
  return deg(lat2), deg(lon2)
end

function utils.decToDMS(dec,lat)
  -- Converts decimal degrees into a compact DMS string for overlay text and telemetry labels.
  local D = floor(abs(dec))
  local M = (abs(dec) - D)*60
  local S = (abs((abs(dec) - D)*60) - M)*60
	return D .. fmt("°%04.2f", M) .. (lat and (dec >= 0 and "E" or "W") or (dec >= 0 and "N" or "S"))
end

function utils.decToDMSFull(dec,lat)
  -- Converts decimal degrees into a full DMS string for detailed coordinate displays.
  local D = floor(abs(dec))
  local M = floor((abs(dec) - D)*60)
  local S = (abs((abs(dec) - D)*60) - M)*60
	return D .. fmt("°%d'%04.1f", M, S) .. (lat and (dec >= 0 and "E" or "W") or (dec >= 0 and "N" or "S"))
end

function utils.init(param_status, param_libs)
  -- Stores shared status/library references for utility helpers and primes the debug logger state when enabled.
  status = param_status
  libs = param_libs

  -- Publish shared helpers so every module can access them through the status
  -- table without duplicating the implementation.  See also status.getTime,
  -- which is published by main.lua before any library is loaded.
  status.flagEnabled = flagEnabled

  -- Initialize line counting only when debug logging is currently enabled.
  initDebugLineCount()
  return utils
end

return utils