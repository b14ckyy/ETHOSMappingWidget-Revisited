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

local status = nil
local libs = nil

local alwaysOn = system.getSource({category=CATEGORY_ALWAYS_ON, member=1, options=0})
local alwaysOff = system.getSource({category=0, member=1, options=0})
local sources = {}
-- NEW: Globaler Zähler für die Log-Datei (Performance)
utils.debugLineCount = 0
-- END NEW

-- NEW: getTime() for the logger (was missing before)
local function getTime()
  return os.clock()*100
end
-- END NEW

-- NEW: Debug Logger (Schritt 2)
local debugFile = nil
local debugLogPath = "/scripts/ethosmaps/debug.log"
local maxLogLines = 1000
local lastLogWrite = 0

-- NEW: Debug Line Count nur initialisieren, wenn Logging aktiviert ist
local function initDebugLineCount()
  if not status.conf.enableDebugLog then 
    utils.debugLineCount = 0
    return 
  end

  local count = 0
  local f = io.open(debugLogPath, "r")
  if f then
    for _ in f:lines() do count = count + 1 end
    f:close()
  end
  utils.debugLineCount = count
end
-- END NEW

function utils.logDebug(category, message)
  -- NEW: Rollender Log mit 5000 Zeilen – löscht älteste 2000 (deine Idee)
  -- Defensive guard: allow logger to be called before utils.init() without crashing
  if not status or not status.conf or not status.conf.enableDebugLog then return end

  local now = getTime()
  if now - lastLogWrite < 10 then return end
  lastLogWrite = now

  local timestamp = string.format("%02d:%02d:%02d.%02d",
    math.floor(now/360000)%24,
    math.floor(now/6000)%60,
    math.floor(now/100)%60,
    math.floor(now % 100))

  local cat = string.format("%-8s", category)
  local line = timestamp .. " | " .. cat .. " | " .. tostring(message) .. "\n"

  local f = io.open(debugLogPath, "a")
  if f then
    f:write(line)
    f:close()
  end

  -- Zeilen zählen
  utils.debugLineCount = (utils.debugLineCount or 0) + 1

    -- NEW: Streaming Rollover with temp file (Copilot suggestion – no full table in RAM)
  if utils.debugLineCount >= 5000 then
    local tmpPath = debugLogPath .. ".tmp"
    
    local f  = io.open(debugLogPath, "r")
    local f2 = io.open(tmpPath, "w")
    
    if f and f2 then
      local lineIndex = 0
      for line in f:lines() do
        lineIndex = lineIndex + 1
        if lineIndex > 2000 then                -- skip oldest 2000 lines
          f2:write(line .. "\n")
        end
      end
      
      -- Add rollover marker
      f2:write("00:00:00.00 | SETTINGS | === DEBUG LOG ROLLED (oldest 2000 lines removed) ===\n")
      
      f:close()
      f2:close()
      
      -- Replace original file
      os.remove(debugLogPath)
      os.rename(tmpPath, debugLogPath)
    end
    
    utils.debugLineCount = 3000   -- now we have ~3000 lines left
  end
  -- END NEW

function utils.getSourceValue(name)
  -- Returns value of a telemetry source by name (caches source handle for performance)
  local src = sources[name]
  if src == nil then
    src = system.getSource(name)
    sources[name] = src
  end
  return src == nil and 0 or src:value()
end

function utils.getRSSI()
  -- Returns current RSSI value from the radio
  return utils.getSourceValue("RSSI")
end

function utils.getBitmask(low, high)
  -- Returns bitmask for extracting a range of bits (cached for performance)
  local key = tostring(low)..tostring(high)
  local res = bitmaskCache[key]
  if res == nil then
    res = 2^(1 + high-low)-1 << low
    bitmaskCache[key] = res
  end
  return res
end

function utils.bitExtract(value, start, len)
  -- Extracts a range of bits from a value using bitmask
  return (value & utils.getBitmask(start,start+len-1)) >> start
end

function utils.processTelemetry(primID, data, now)
  -- Placeholder for processing raw telemetry packets (not used in current version)
end

function utils.playTime(seconds)
  -- Plays elapsed time as voice announcement (hours/minutes/seconds)
  if seconds > 3600 then
    system.playNumber(seconds / 3600, UNIT_HOUR)
    system.playNumber((seconds % 3600) / 60, UNIT_MINUTE)
    system.playNumber((seconds % 3600) % 60, UNIT_SECOND)
  else
    system.playNumber(seconds / 60, UNIT_MINUTE)
    system.playNumber(seconds % 60, UNIT_SECOND)
  end
end

function utils.haversine(lat1, lon1, lat2, lon2)
  -- Calculates great-circle distance between two GPS coordinates in meters
  local lat1 = lat1 * math.pi / 180
  local lon1 = lon1 * math.pi / 180
  local lat2 = lat2 * math.pi / 180
  local lon2 = lon2 * math.pi / 180

  local lat_dist = lat2 - lat1
  local lon_dist = lon2 - lon1
  local lat_hsin  = math.sin(lat_dist/2)^2
  local lon_hsin  = math.sin(lon_dist/2)^2

  local a = lat_hsin + math.cos(lat1) * math.cos(lat2) * lon_hsin
  return 2 * 6372.8 * math.asin(math.sqrt(a)) * 1000
end

function utils.getAngleFromLatLon(lat1, lon1, lat2, lon2)
  -- Calculates bearing angle (0-360°) from point 1 to point 2
  local la1 = math.rad(lat1)
  local lo1 = math.rad(lon1)
  local la2 = math.rad(lat2)
  local lo2 = math.rad(lon2)

  local y = math.sin(lo2-lo1) * math.cos(la2);
  local x = math.cos(la1)*math.sin(la2) - math.sin(la1)*math.cos(la2)*math.cos(lo2-lo1);
  local a = math.atan(y, x);

  return (a*180/math.pi + 360) % 360 -- in degrees
end

function utils.getMaxValue(value,idx)
  -- Returns max value seen so far (used for min/max display)
  status.minmaxValues[idx] = math.max(value,status.minmaxValues[idx])
  return status.showMinMaxValues == true and status.minmaxValues[idx] or value
end

function utils.updateCog()
  -- Updates Course Over Ground (COG) when GPS position changes
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
    -- update last GPS coords
    status.lastLat = status.telemetry.lat
    status.lastLon = status.telemetry.lon
  end
end

function utils.calcMinValue(value,min)
  -- Returns the smaller of two values (used for minimum tracking)
  return min == 0 and value or math.min(value,min)
end

-- returns the actual minimun only if both are > 0
function utils.getNonZeroMin(v1,v2)
  -- Returns the smaller non-zero value of two numbers
  return v1 == 0 and v2 or ( v2 == 0 and v1 or math.min(v1,v2))
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
  if status.telemetry.lat == nil or status.telemetry.lon == nil then
    return nil,nil
  end
  local lat1 = math.rad(status.telemetry.lat)
  local lon1 = math.rad(status.telemetry.lon)
  local Ad = distance/(6371000) --meters
  local lat2 = math.asin( math.sin(lat1) * math.cos(Ad) + math.cos(lat1) * math.sin(Ad) * math.cos( math.rad(angle)) )
  local lon2 = lon1 + math.atan( math.sin( math.rad(angle) ) * math.sin(Ad) * math.cos(lat1) , math.cos(Ad) - math.sin(lat1) * math.sin(lat2))
  return math.deg(lat2), math.deg(lon2)
end

function utils.decToDMS(dec,lat)
  -- Converts decimal degrees to DMS format (short version)
  local D = math.floor(math.abs(dec))
  local M = (math.abs(dec) - D)*60
  local S = (math.abs((math.abs(dec) - D)*60) - M)*60
	return D .. string.format("°%04.2f", M) .. (lat and (dec >= 0 and "E" or "W") or (dec >= 0 and "N" or "S"))
end

function utils.decToDMSFull(dec,lat)
  -- Converts decimal degrees to full DMS format with minutes and seconds
  local D = math.floor(math.abs(dec))
  local M = math.floor((math.abs(dec) - D)*60)
  local S = (math.abs((math.abs(dec) - D)*60) - M)*60
	return D .. string.format("°%d'%04.1f", M, S) .. (lat and (dec >= 0 and "E" or "W") or (dec >= 0 and "N" or "S"))
end

function utils.resetTimer()
  -- Resets the Yaapu flight timer
  local timer = model.getTimer("Yaapu")
  timer:activeCondition( alwaysOff )
  timer:resetCondition( alwaysOn )
end

function utils.startTimer()
  -- Starts the Yaapu flight timer
  status.lastTimerStart = getTime()/100
  local timer = model.getTimer("Yaapu")
  timer:activeCondition( alwaysOn )
  timer:resetCondition( alwaysOff )
end

function utils.stopTimer()
  -- Stops the Yaapu flight timer
  status.lastTimerStart = 0
  local timer = model.getTimer("Yaapu")
  timer:activeCondition( alwaysOff )
  timer:resetCondition( alwaysOff )
end

function utils.telemetryEnabled(widget)
  -- Returns true if telemetry data is currently being received
  if utils.getRSSI() == 0 then
    status.noTelemetryData = 1
  end
  return status.noTelemetryData == 0
end

function utils.playSound(soundFile, skipHaptic)
  -- Plays a sound file and optional haptic feedback
  if status.conf.enableHaptic and skipHaptic == nil then
    system.playHaptic(15,0)
  end
  if status.conf.disableAllSounds then
    return
  end
  libs.drawLib.resetBacklightTimeout()
  system.playFile("/audio/ethosmaps/"..status.conf.language.."/".. soundFile..".wav")
end

function utils.init(param_status, param_libs)
  status = param_status
  libs = param_libs
  -- NEW: Nur zählen, wenn Debugging wirklich eingeschaltet ist
  initDebugLineCount()
  -- END NEW
  return utils
end

return utils