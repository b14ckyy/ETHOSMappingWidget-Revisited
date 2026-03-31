--
-- msp.lua — MSP transport and waypoint download library
--
-- Communicates with an INAV flight controller over SmartPort or CRSF
-- telemetry passthrough to download stored waypoint missions.
--
-- Protocol layers:
--   SmartPort: [ETHOS Lua] → sport sensor → [SmartPort MSP Transport]
--              → [FrSky Rx] → [FC UART] → [INAV MSP Handler]
--   CRSF:      [ETHOS Lua] → crsf sensor → [CRSF MSP Passthrough]
--              → [ELRS/TBS Rx] → [FC UART] → [INAV MSP Handler]
--
-- MSP version selection:
--   Commands ≤ 254 → MSPv1 chunks (version bits 01, works on all INAV versions)
--   Commands > 254 → native MSPv2 chunks (version bits 10, requires INAV ≥ 9.0)
--
-- CRC handling:
--   V1 over SmartPort: XOR checksum appended to final chunk
--   V1 over CRSF:      no MSP CRC (CRSF frame CRC provides integrity)
--   V2 over any:        no chunk CRC (DVB-S2 CRC is embedded in V2 payload)
--
-- Transport auto-detection: tries SmartPort first, then CRSF.
-- Falls back to next transport after FC_DETECT_TIMEOUT on each.
--
-- ETHOS Lua API references:
--   SmartPort: pushFrame({table}) / popFrame() → SPortFrame object  (Since 1.1.0)
--   CRSF:      pushFrame(command, data) / popFrame() → command, data (Since 1.4.0/1.6.0)
--
-- Usage from widget:
--   libs.msp.open()      — acquire sensor + auto-detect transport
--   libs.msp.poll()      — drive state machine (call in wakeup)
--   libs.msp.close()     — release sensor (call in close)
--   libs.msp.getState()  — read current state + wp data
--

local msp = {}

-- ============================================================================
-- Injected shared state (set by init)
-- ============================================================================
local status = nil
local libs   = nil

-- ============================================================================
-- Bitwise helpers  (ETHOS Lua 5.4 — native operators, no bit32)
-- ============================================================================
local function band(a, b)   return a & b end
local function bor(a, b)    return a | b end
local function bxor(a, b)   return a ~ b end
local function lshift(a, n) return (a << n) & 0xFFFFFFFF end
local function rshift(a, n) return (a & 0xFFFFFFFF) >> n end
local function btest(a, b)  return (a & b) ~= 0 end
local fmt   = string.format
local char  = string.char
local clock = os.clock

-- ============================================================================
-- CRC8 DVB-S2  (for MSPv2 payload integrity)
-- ============================================================================
local function crc8_dvb_s2(crc, byte)
    crc = bxor(crc, byte)
    for _ = 1, 8 do
        if btest(crc, 0x80) then
            crc = bxor(lshift(band(crc, 0xFF), 1), 0xD5)
        else
            crc = lshift(band(crc, 0xFF), 1)
        end
        crc = band(crc, 0xFF)
    end
    return crc
end

-- ============================================================================
-- MSP command IDs
-- ============================================================================
local MSP_FC_VARIANT  = 2       -- 4-char FC identifier ("INAV")
local MSP_FC_VERSION  = 3       -- uint8 major + uint8 minor + uint8 patch
local MSP_STATUS      = 101     -- cycleTime + i2cErr + sensors + flightModeFlags + profile
local MSP_WP_GETINFO  = 20      -- reserved(1)+maxWP(1)+valid(1)+count(1)
local MSP_WP          = 118     -- get single WP by index
local MSP_NAV_STATUS  = 121     -- navMode(1)+navState(1)+activeWpAction(1)+activeWpNumber(1)+navError(1)+targetHeading(2)

-- Waypoint action names (INAV)
local WP_ACTION_NAMES = {
    [1] = "WAYPOINT",
    [2] = "POSHOLD_UNLIM",
    [3] = "POSHOLD_TIME",
    [4] = "RTH",
    [5] = "SET_POI",
    [6] = "JUMP",
    [7] = "SET_HEAD",
    [8] = "LAND",
}

-- ============================================================================
-- SmartPort transport constants
-- ============================================================================
local LOCAL_SENSOR_ID  = 0x0D
local REQUEST_FRAME_ID = 0x30
local REPLY_FRAME_ID   = 0x32
local SP_REMOTE_ID     = 0x1B
local FP_REMOTE_ID     = 0x00

-- ============================================================================
-- CRSF transport constants
-- ============================================================================
local CRSF_FRAMETYPE_MSP_REQ  = 0x7A  -- MSP request  (Radio → FC via Rx)
local CRSF_FRAMETYPE_MSP_RESP = 0x7B  -- MSP response (FC → Radio via Rx)
local CRSF_ADDRESS_FC         = 0xC8  -- Flight Controller
local CRSF_ADDRESS_RADIO      = 0xEA  -- Radio Transmitter

-- ============================================================================
-- Transport abstraction
-- ============================================================================
local TRANSPORT_NONE  = 0
local TRANSPORT_SPORT = 1
local TRANSPORT_CRSF  = 2

-- Max bytes per transport chunk (status byte + MSP body):
--   SmartPort: 6 (2 dataId + 4 value, all repurposed as MSP chunk)
--   CRSF:     58 (64 max frame - sync - framelen - type - dest - orig - CRC)
local SPORT_FRAME_PAYLOAD = 6
local CRSF_FRAME_PAYLOAD  = 58

-- MSP chunk status byte fields
local MSP_VERSION_V1  = 0x20     -- bits 5-6 = 01  (MSPv1)
local MSP_VERSION_V2  = 0x40     -- bits 5-6 = 10  (MSPv2)
local MSP_STARTFLAG   = 0x10     -- bit 4 = start of message

-- ============================================================================
-- Timing
-- ============================================================================
local POST_REPLY_DELAY = 0.02     -- seconds after reply before next request
local REQUEST_TIMEOUT  = 1.00     -- seconds before retry
local CONNECT_TIMEOUT  = 3.00     -- seconds without reply → disconnected
local MAX_RETRIES      = 10
local FC_DETECT_TIMEOUT = 5.0     -- seconds to wait for FC on one transport before trying next
local RETRY_DELAY      = 5.0     -- seconds to wait before auto-retry after ERROR
local ARM_POLL_INTERVAL = 5.0    -- seconds between arming state queries
local NAV_STATUS_POLL_INTERVAL = 2.0  -- seconds between MSP_NAV_STATUS queries

-- ============================================================================
-- State machine constants
-- ============================================================================
local STATE_OFF         = 0  -- MSP disabled / not started
local STATE_CONNECTING  = 1  -- Identifying FC (MSP_FC_VARIANT)
local STATE_GET_VERSION = 2  -- Querying FC firmware version (MSP_FC_VERSION)
local STATE_GET_WP_INFO = 3  -- Requesting waypoint count
local STATE_DOWNLOADING = 4  -- Downloading individual waypoints
local STATE_DONE        = 5  -- Download complete
local STATE_ERROR       = 6  -- Unrecoverable error

-- Expose state constants for external code
msp.STATE_OFF         = STATE_OFF
msp.STATE_CONNECTING  = STATE_CONNECTING
msp.STATE_GET_VERSION = STATE_GET_VERSION
msp.STATE_GET_WP_INFO = STATE_GET_WP_INFO
msp.STATE_DOWNLOADING = STATE_DOWNLOADING
msp.STATE_DONE        = STATE_DONE
msp.STATE_ERROR       = STATE_ERROR

msp.TRANSPORT_NONE  = TRANSPORT_NONE
msp.TRANSPORT_SPORT = TRANSPORT_SPORT
msp.TRANSPORT_CRSF  = TRANSPORT_CRSF

-- ============================================================================
-- Module-level state
-- ============================================================================

-- ETHOS sensor handle
local sensor = nil

-- Transport state (set during open(), preserved across resetState())
local transportType    = TRANSPORT_NONE
local maxFramePayload  = SPORT_FRAME_PAYLOAD
local rawSend          = nil   -- function(chunk) -> bool
local rawPoll          = nil   -- function() -> chunk_table or nil

-- Transport fallback: list of candidate transports built during open()
-- Each entry: { type=TRANSPORT_*, payload=int, send=fn, poll=fn, name=string }
local transportCandidates = {}
local transportIdx        = 0   -- index into transportCandidates (current)

-- MSP transport state
local mspSeq       = 0
local mspRemoteSeq = 0
local mspTxBuf     = {}
local mspTxIdx     = 1
local mspTxCRC     = 0
local mspTxVersion = 1    -- MSP version of current outgoing message (1 or 2)
local mspRxBuf     = {}
local mspRxError   = false
local mspRxSize    = 0
local mspRxCRC     = 0
local mspRxReq     = 0
local mspRxVersion = 1    -- MSP version of current incoming message
local mspStarted   = false
local mspLastReq   = 0

-- Duplicate-frame filter (SmartPort only)
local prevSensorId, prevFrameId, prevDataId, prevValue

-- Application state
local state        = STATE_OFF
local fcVariant    = nil
local fcVersionMajor = 0
local fcVersionMinor = 0
local fcVersionPatch = 0
local connected    = false
local currentCmd   = nil
local lastReqTime  = 0
local lastRspTime  = 0
local retries      = 0

-- Waypoint data
local wpMaxCount   = 0       -- max WPs the FC supports
local wpCount      = 0       -- WPs in current mission
local wpValid      = false   -- mission validity flag
local wpNextIdx    = 1       -- next WP index to request
local wpList       = {}      -- downloaded waypoints { idx, action, actionName, lat, lon, alt, p1, p2, p3, flags }
local missions     = {}      -- parsed missions (list of wpList sub-tables, split at flag=0xA5)
local startTime    = 0       -- os.clock() when open() was called
local errorTime    = 0       -- os.clock() when ERROR state was entered

-- Arming state
local isArmed        = false   -- true once FC reports armed
local lastArmPollTime = 0      -- os.clock() of last MSP_STATUS request
local armingOnly     = false   -- true = skip WP download, only poll arming state

-- Nav status (MSP_NAV_STATUS, polled after armed)
local navMode          = 0     -- navSystemStatus_Mode_e: 0=NONE 1=HOLD 2=RTH 3=NAV 15=EMERG
local navState         = 0     -- navSystemStatus_State_e
local activeWpNumber   = 0     -- FC's current WP index (1-based)
local navError         = 0     -- navSystemStatus_Error_e
local lastNavPollTime  = 0     -- os.clock() of last MSP_NAV_STATUS request

-- ============================================================================
-- Debug logging helper (uses widget debug log if available)
-- ============================================================================
local function log(tag, msg)
    if status and status.debugEnabled and libs and libs.utils then
        libs.utils.logDebug(tag, msg, true)
    end
end

-- ============================================================================
-- SmartPort send / receive
-- ============================================================================

local function sportSend(payload)
    if not sensor then return false end
    local dataId = payload[1] + lshift(payload[2], 8)
    local value  = 0
    for i = 3, #payload do
        value = value + lshift(payload[i], (i - 3) * 8)
    end
    return sensor:pushFrame({
        physId = LOCAL_SENSOR_ID,
        primId = REQUEST_FRAME_ID,
        appId  = dataId,
        value  = value,
    })
end

local function sportPoll()
    if not sensor then return nil end
    while true do
        local frame = sensor:popFrame()
        if not frame then return nil end
        local sId = frame:physId()
        local fId = frame:primId()
        local dId = frame:appId()
        local val = frame:value()
        -- Duplicate-frame filter
        if sId == prevSensorId and fId == prevFrameId
           and dId == prevDataId and val == prevValue then
            -- skip duplicate
        else
            prevSensorId = sId
            prevFrameId  = fId
            prevDataId   = dId
            prevValue    = val
            if (sId == SP_REMOTE_ID or sId == FP_REMOTE_ID)
               and fId == REPLY_FRAME_ID then
                return {
                    band(dId, 0xFF),
                    band(rshift(dId, 8), 0xFF),
                    band(val, 0xFF),
                    band(rshift(val, 8), 0xFF),
                    band(rshift(val, 16), 0xFF),
                    band(rshift(val, 24), 0xFF),
                }
            end
        end
    end
end

-- ============================================================================
-- CRSF send / receive
-- ETHOS API: pushFrame(command, data) since 1.4.0
--            popFrame([filterMin, filterMax]) → command, data since 1.6.0
-- ============================================================================

--- Send an MSP chunk as a CRSF frame (type 0x7A).
--- Wraps the chunk with destination/origin address bytes.
local function crsfSend(chunk)
    if not sensor then return false end
    local payload = { CRSF_ADDRESS_FC, CRSF_ADDRESS_RADIO }
    for i = 1, #chunk do
        payload[i + 2] = chunk[i]
    end
    return sensor:pushFrame(CRSF_FRAMETYPE_MSP_REQ, payload)
end

--- Poll for a CRSF MSP response frame (type 0x7B).
--- Strips destination/origin address bytes and returns the MSP chunk.
local function crsfPoll()
    if not sensor then return nil end
    while true do
        local fType, data = sensor:popFrame(CRSF_FRAMETYPE_MSP_RESP, CRSF_FRAMETYPE_MSP_RESP)
        if not fType then return nil end
        if data and #data >= 3 then
            -- Strip dest(1) + orig(1), return MSP chunk from status byte onward
            local chunk = {}
            for i = 3, #data do
                chunk[#chunk + 1] = data[i]
            end
            return chunk
        end
    end
end

-- ============================================================================
-- MSP chunk TX  (shared chunking for SmartPort and CRSF, version-aware)
-- ============================================================================

--- Continue transmitting the current mspTxBuf as transport-sized chunks.
--- Version bits in the status byte are set according to mspTxVersion.
--- XOR CRC is appended only for V1 over SmartPort.
local function mspProcessTxQ()
    if #mspTxBuf == 0 then return false end
    local versionBits = mspTxVersion == 2 and MSP_VERSION_V2 or MSP_VERSION_V1
    local frame = {}
    frame[1] = mspSeq + versionBits
    mspSeq = band(mspSeq + 1, 0x0F)
    if mspTxIdx == 1 then
        frame[1] = frame[1] + MSP_STARTFLAG
    end
    local i = 2
    while i <= maxFramePayload and mspTxIdx <= #mspTxBuf do
        frame[i] = mspTxBuf[mspTxIdx]
        mspTxIdx = mspTxIdx + 1
        -- Accumulate XOR CRC for V1 SmartPort only
        if mspTxVersion == 1 then
            mspTxCRC = bxor(mspTxCRC, frame[i])
        end
        i = i + 1
    end
    if i <= maxFramePayload then
        -- Final chunk
        -- V1 SmartPort: append XOR CRC byte
        if mspTxVersion == 1 and transportType == TRANSPORT_SPORT then
            frame[i] = mspTxCRC
            i = i + 1
        end
        -- SmartPort: zero-pad to fixed 6-byte frame
        if transportType == TRANSPORT_SPORT then
            while i <= maxFramePayload do frame[i] = 0; i = i + 1 end
        end
        rawSend(frame)
        mspTxBuf = {}
        mspTxIdx = 1
        mspTxCRC = 0
        return false
    end
    rawSend(frame)
    return true
end

-- ============================================================================
-- MSP request building  (V1 and native V2, auto-selected by command ID)
-- ============================================================================

--- Queue an MSP request. Auto-selects V1 (cmd ≤ 254) or native V2 (cmd > 254).
---
--- V1 TX buffer layout: [size(1), cmd(1), payload...]
--- V2 TX buffer layout: [flag(1), cmd_lo(1), cmd_hi(1), size_lo(1), size_hi(1), payload..., crc8(1)]
local function mspSendRequest(cmd, payload)
    if #mspTxBuf ~= 0 then return nil end
    payload = payload or {}

    if cmd > 254 then
        -- ── Native MSPv2 (requires INAV ≥ 9.0 for telemetry transport) ──
        mspTxVersion = 2
        local flag   = 0
        local cmdLo  = band(cmd, 0xFF)
        local cmdHi  = band(rshift(cmd, 8), 0xFF)
        local sizeLo = band(#payload, 0xFF)
        local sizeHi = band(rshift(#payload, 8), 0xFF)

        -- DVB-S2 CRC over flag + cmd + size + payload
        local crc = 0
        crc = crc8_dvb_s2(crc, flag)
        crc = crc8_dvb_s2(crc, cmdLo)
        crc = crc8_dvb_s2(crc, cmdHi)
        crc = crc8_dvb_s2(crc, sizeLo)
        crc = crc8_dvb_s2(crc, sizeHi)
        for i = 1, #payload do
            crc = crc8_dvb_s2(crc, band(payload[i], 0xFF))
        end

        local idx = 1
        mspTxBuf[idx] = flag;   idx = idx + 1
        mspTxBuf[idx] = cmdLo;  idx = idx + 1
        mspTxBuf[idx] = cmdHi;  idx = idx + 1
        mspTxBuf[idx] = sizeLo; idx = idx + 1
        mspTxBuf[idx] = sizeHi; idx = idx + 1
        for i = 1, #payload do
            mspTxBuf[idx] = band(payload[i], 0xFF)
            idx = idx + 1
        end
        mspTxBuf[idx] = crc
    else
        -- ── MSPv1 (works on all INAV versions) ──
        mspTxVersion = 1
        mspTxBuf[1] = #payload
        mspTxBuf[2] = band(cmd, 0xFF)
        for i = 1, #payload do
            mspTxBuf[i + 2] = band(payload[i], 0xFF)
        end
    end

    mspLastReq = cmd
    return mspProcessTxQ()
end

-- ============================================================================
-- MSP chunk RX  (version-aware reassembly)
-- ============================================================================

--- Process a single received transport chunk as MSP reply fragment.
--- Handles V0 (legacy), V1, and V2 header formats.
---
--- V1 start: [status | size(1) | cmd(1) | payload...]
--- V2 start: [status | flag(1) | cmd_lo(1) | cmd_hi(1) | size_lo(1) | size_hi(1) | payload...]
local function mspReceivedReply(frame)
    local idx    = 1
    local st     = frame[idx]
    local ver    = rshift(band(st, 0x60), 5)   -- 0=V0, 1=V1, 2=V2
    local start  = btest(st, 0x10)
    local seq    = band(st, 0x0F)
    idx = idx + 1

    if start then
        mspRxBuf     = {}
        mspRxError   = btest(st, 0x80)
        mspRxVersion = ver

        if ver == 2 then
            -- V2 header: flag(1) + cmd(2) + size(2) = 5 bytes
            local flag   = frame[idx]; idx = idx + 1
            local cmdLo  = frame[idx]; idx = idx + 1
            local cmdHi  = frame[idx]; idx = idx + 1
            local sizeLo = frame[idx]; idx = idx + 1
            local sizeHi = frame[idx]; idx = idx + 1
            mspRxReq  = cmdLo + lshift(cmdHi, 8)
            mspRxSize = sizeLo + lshift(sizeHi, 8)
        else
            -- V1/V0 header: size(1) [+ cmd(1) for V1]
            mspRxSize = frame[idx]; idx = idx + 1
            if ver == 1 then
                mspRxReq = frame[idx]; idx = idx + 1
            else
                mspRxReq = mspLastReq   -- V0: cmd not in response
            end
        end

        -- V1 XOR CRC seed (for SmartPort verification)
        mspRxCRC = 0
        if ver == 1 then
            mspRxCRC = bxor(mspRxSize, mspRxReq)
        end

        if mspRxReq == mspLastReq then
            mspStarted = true
        else
            mspStarted = false
            return nil
        end
    elseif not mspStarted then
        return nil
    elseif band(mspRemoteSeq + 1, 0x0F) ~= seq then
        mspStarted = false
        return nil
    end

    -- Collect payload bytes
    local frameLen = #frame
    while idx <= frameLen and #mspRxBuf < mspRxSize do
        mspRxBuf[#mspRxBuf + 1] = frame[idx]
        if mspRxVersion == 1 then
            mspRxCRC = bxor(mspRxCRC, frame[idx])
        end
        idx = idx + 1
    end

    -- Check completeness
    if #mspRxBuf >= mspRxSize then
        -- V2 or CRSF: no chunk-level MSP CRC — done immediately
        if mspRxVersion == 2 or transportType == TRANSPORT_CRSF then
            mspStarted = false
            return true
        end
        -- V0/V1 over SmartPort: expect XOR CRC byte following payload
        if idx > frameLen then
            mspRemoteSeq = seq
            return false   -- CRC byte will arrive in next chunk
        end
        mspStarted = false
        -- V0: validate XOR CRC  (V1: CRC present but not validated, matching reference impls)
        if ver == 0 and mspRxCRC ~= frame[idx] then
            return nil
        end
        return true
    end

    mspRemoteSeq = seq
    return false
end

--- Poll for a complete MSP reply.
--- Drains all available transport frames so multi-frame responses
--- are assembled in a single wakeup cycle.
local function mspPollReply()
    if not rawPoll then return nil end
    while true do
        local frame = rawPoll()
        if not frame then return nil end
        local result = mspReceivedReply(frame)
        if result then
            mspLastReq = 0
            return mspRxReq, mspRxBuf, mspRxError
        end
    end
end

-- ============================================================================
-- Byte-level helpers
-- ============================================================================

local function readInt16(buf, off)
    if not buf[off] or not buf[off + 1] then return 0 end
    local v = buf[off] + lshift(buf[off + 1], 8)
    if v >= 32768 then v = v - 65536 end
    return v
end

local function readInt32(buf, off)
    if not buf[off] or not buf[off + 3] then return 0 end
    local v = buf[off] + lshift(buf[off + 1], 8)
              + lshift(buf[off + 2], 16) + lshift(buf[off + 3], 24)
    if v >= 2147483648 then v = v - 4294967296 end
    return v
end

-- ============================================================================
-- MSP response handlers
-- ============================================================================

--- Split the flat wpList into per-mission sub-tables at flag=0xA5 boundaries.
local function parseMissions()
    missions = {}
    local current = {}
    for _, wp in ipairs(wpList) do
        current[#current + 1] = wp
        if wp.flags == 0xA5 then
            missions[#missions + 1] = current
            current = {}
        end
    end
    if #current > 0 then
        missions[#missions + 1] = current
    end
    log("MSP", fmt("Parsed %d mission(s) from %d waypoints", #missions, #wpList))
end

local function handleStatus(buf)
    -- MSP_STATUS response: uint16 cycleTime, uint16 i2cErr, uint16 sensors,
    --                      uint32 flightModeFlags, uint8 profile  (11 bytes)
    -- In INAV, ARM is always box index 0 → bit 0 of flightModeFlags.
    if #buf >= 10 then
        local flightModeFlags = buf[7] + lshift(buf[8], 8)
                              + lshift(buf[9], 16) + lshift(buf[10], 24)
        local armed = btest(flightModeFlags, 1)
        if armed and not isArmed then
            isArmed = true
            log("MSP", "FC ARMED detected")
        elseif not armed and isArmed then
            isArmed = false
            navMode = 0
            activeWpNumber = 0
            navError = 0
            log("MSP", "FC DISARMED detected")
        end
    end
end

local function handleNavStatus(buf)
    -- MSP_NAV_STATUS response: uint8 navMode, uint8 navState, uint8 activeWpAction,
    --                          uint8 activeWpNumber, uint8 navError, int16 targetHeading (7 bytes)
    if #buf >= 5 then
        navMode        = buf[1]
        navState       = buf[2]
        activeWpNumber = buf[4]
        navError       = buf[5]
        log("MSP", fmt("NAV_STATUS: mode=%d state=%d activeWP=%d err=%d",
                        navMode, navState, activeWpNumber, navError))
    end
end

local function handleFcVariant(buf)
    if #buf >= 4 then
        fcVariant = char(buf[1], buf[2], buf[3], buf[4])
        log("MSP", fmt("FC variant: %s", fcVariant))
        if fcVariant == "INAV" then
            state = STATE_GET_VERSION
        else
            log("MSP", fmt("Unsupported FC: %s (need INAV)", fcVariant))
            state = STATE_ERROR
            errorTime = clock()
        end
    end
end

local function handleFcVersion(buf)
    if #buf >= 3 then
        fcVersionMajor = buf[1]
        fcVersionMinor = buf[2]
        fcVersionPatch = buf[3]
        log("MSP", fmt("FC version: %d.%d.%d", fcVersionMajor, fcVersionMinor, fcVersionPatch))
        if armingOnly then
            state = STATE_DONE
            log("MSP", "Arming-only mode — skipping WP download")
        else
            state = STATE_GET_WP_INFO
        end
    end
end

local function handleWpGetInfo(buf)
    if #buf >= 4 then
        wpMaxCount = buf[2]
        wpValid    = buf[3] ~= 0
        wpCount    = buf[4]
        log("MSP", fmt("Mission: %d WPs, valid=%s, max=%d",
                        wpCount, wpValid and "yes" or "no", wpMaxCount))
        if wpCount > 0 then
            state     = STATE_DOWNLOADING
            wpNextIdx = 1
            retries   = 0
            log("MSP", fmt("Downloading %d waypoints...", wpCount))
        else
            state = STATE_DONE
            log("MSP", "No waypoints in mission")
        end
    else
        state = STATE_ERROR
    end
end

local function handleWp(buf)
    if #buf < 21 then return end

    local wp = {
        idx        = buf[1],
        action     = buf[2],
        actionName = WP_ACTION_NAMES[buf[2]] or fmt("UNK(%d)", buf[2]),
        lat        = readInt32(buf, 3) / 10000000.0,
        lon        = readInt32(buf, 7) / 10000000.0,
        alt        = readInt32(buf, 11) / 100.0,   -- meters
        p1         = readInt16(buf, 15),
        p2         = readInt16(buf, 17),
        p3         = readInt16(buf, 19),
        flags      = buf[21],
    }

    -- Sanity check: discard waypoints with obviously corrupt coordinates.
    -- Valid lat range: -90..90, valid lon range: -180..180.
    if wp.lat < -90 or wp.lat > 90 or wp.lon < -180 or wp.lon > 180 then
      log("MSP", fmt("WP#%d CORRUPT lat=%.7f lon=%.7f — skipped",
                      wp.idx, wp.lat, wp.lon))
      -- Keep index in sync but replace with zeroed-out placeholder
      wp.lat = 0
      wp.lon = 0
      wp.action = 0  -- mark as non-navigable so drawWaypoints skips it
    end

    wpList[#wpList + 1] = wp

    -- Perf counter: WP successfully received
    if status and status.perfProfileInc then
        status.perfProfileInc("msp_wp_received")
    end

    log("MSP", fmt("WP#%d %s lat=%.7f lon=%.7f alt=%.1fm",
                    wp.idx, wp.actionName, wp.lat, wp.lon, wp.alt))

    wpNextIdx = wpNextIdx + 1
    retries   = 0
    if wpNextIdx > wpCount or wp.flags == 0xA5 then
        state = STATE_DONE
        parseMissions()
        log("MSP", fmt("Download complete: %d waypoints", #wpList))
    end
end

-- ============================================================================
-- Internal state reset
-- ============================================================================
local function resetState()
    mspSeq       = 0
    mspRemoteSeq = 0
    mspTxBuf     = {}
    mspTxIdx     = 1
    mspTxCRC     = 0
    mspTxVersion = 1
    mspRxBuf     = {}
    mspRxError   = false
    mspRxSize    = 0
    mspRxCRC     = 0
    mspRxReq     = 0
    mspRxVersion = 1
    mspStarted   = false
    mspLastReq   = 0

    prevSensorId = nil
    prevFrameId  = nil
    prevDataId   = nil
    prevValue    = nil

    fcVariant      = nil
    fcVersionMajor = 0
    fcVersionMinor = 0
    fcVersionPatch = 0
    connected    = false
    currentCmd   = nil
    lastReqTime  = 0
    lastRspTime  = 0
    retries      = 0

    wpMaxCount   = 0
    wpCount      = 0
    wpValid      = false
    wpNextIdx    = 1
    wpList       = {}
    missions     = {}
    startTime    = 0
    errorTime    = 0
    isArmed        = false
    lastArmPollTime = 0
    armingOnly     = false
    navMode          = 0
    navState         = 0
    activeWpNumber   = 0
    navError         = 0
    lastNavPollTime  = 0
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Activate the transport candidate at transportCandidates[transportIdx].
--- Sets sensor, transportType, maxFramePayload, rawSend, rawPoll.
local function activateTransport()
    local t = transportCandidates[transportIdx]
    if not t then return false end
    sensor          = t.sensor
    transportType   = t.type
    maxFramePayload = t.payload
    rawSend         = t.send
    rawPoll         = t.poll
    log("MSP", fmt("%s transport acquired", t.name))
    return true
end

--- Try the next transport candidate. Returns true if activated, false if exhausted.
local function tryNextTransport()
    transportIdx = transportIdx + 1
    if transportIdx > #transportCandidates then
        return false
    end
    -- Reset MSP protocol state for the new transport attempt
    mspSeq       = 0
    mspRemoteSeq = 0
    mspTxBuf     = {}
    mspTxIdx     = 1
    mspTxCRC     = 0
    mspTxVersion = 1
    mspRxBuf     = {}
    mspRxError   = false
    mspRxSize    = 0
    mspRxVersion = 1
    mspStarted   = false
    currentCmd   = nil
    lastReqTime  = 0
    lastRspTime  = 0
    retries      = 0
    connected    = false
    return activateTransport()
end

--- Acquire sensor, auto-detect transport (SmartPort → CRSF), start state machine.
--- Builds a list of available transports and tries each in order.
--- On FC detection timeout, falls back to next transport before entering ERROR.
--- @param opts table|nil  Optional { armingOnly = bool } to skip WP download
function msp.open(opts)
    resetState()
    if opts and opts.armingOnly then
        armingOnly = true
    end

    -- Build list of available transport candidates
    transportCandidates = {}
    transportIdx        = 0

    -- Probe SmartPort (FrSky ACCESS / ACCST / TD)
    local sportRssi =
        system.getSource("RSSI") or
        system.getSource("RSSI 2.4G") or
        system.getSource("RSSI 900M") or
        system.getSource("Rx RSSI1") or
        system.getSource("Rx RSSI2")

    if sportRssi then
        local sportSensor = sport.getSensor({primId = 0x32})
        if sportSensor then
            sportSensor:module(sportRssi:module())
            transportCandidates[#transportCandidates + 1] = {
                type    = TRANSPORT_SPORT,
                payload = SPORT_FRAME_PAYLOAD,
                send    = sportSend,
                poll    = sportPoll,
                sensor  = sportSensor,
                name    = "SmartPort",
            }
        end
    end

    -- Probe CRSF (Crossfire / ELRS)
    -- Don't gate on specific RSSI source names — ELRS sources vary by setup.
    -- Just check if the crsf global exists and has a getSensor function.
    local crsfAvail = false
    if crsf then
        local gt = type(crsf)
        crsfAvail = (gt == "table" or gt == "userdata") and type(crsf.getSensor) == "function"
        if not crsfAvail then
            log("MSP", fmt("CRSF probe: crsf exists (type=%s) but no getSensor", gt))
        end
    else
        log("MSP", "CRSF probe: crsf global not found")
    end
    if crsfAvail then
        local ok, crsfSensor = pcall(crsf.getSensor, {})
        if ok and crsfSensor then
            -- Try to bind to the correct RF module (best-effort, not required)
            local crsfRssi =
                system.getSource("1RSS") or
                system.getSource("2RSS") or
                system.getSource("RQly") or
                system.getSource("RSNR") or
                system.getSource("Rx RSSI1") or
                system.getSource("Rx RSSI2") or
                system.getSource("RSSI")
            if crsfRssi then
                pcall(function() crsfSensor:module(crsfRssi:module()) end)
            end
            transportCandidates[#transportCandidates + 1] = {
                type    = TRANSPORT_CRSF,
                payload = CRSF_FRAME_PAYLOAD,
                send    = crsfSend,
                poll    = crsfPoll,
                sensor  = crsfSensor,
                name    = "CRSF",
            }
        else
            log("MSP", fmt("CRSF probe: getSensor failed: ok=%s sensor=%s",
                tostring(ok), tostring(crsfSensor)))
        end
    end

    -- Activate first candidate
    if #transportCandidates == 0 then
        log("MSP", "No transport available (tried SmartPort and CRSF)")
        state     = STATE_ERROR
        errorTime = clock()
        return
    end

    transportIdx = 1
    activateTransport()
    state     = STATE_CONNECTING
    startTime = clock()
    log("MSP", fmt("Trying transport %d/%d: %s",
        transportIdx, #transportCandidates, transportCandidates[transportIdx].name))
end

--- Release sensor and reset transport state.
function msp.close()
    sensor              = nil
    transportType       = TRANSPORT_NONE
    maxFramePayload     = SPORT_FRAME_PAYLOAD
    rawSend             = nil
    rawPoll             = nil
    transportCandidates = {}
    transportIdx        = 0
    state               = STATE_OFF
    log("MSP", "Sensor released")
end

--- Drive the MSP state machine. Call once per wakeup cycle.
function msp.poll()
    if state == STATE_OFF then
        return
    end

    -- STATE_DONE: poll arming + nav status
    if state == STATE_DONE then
        local now = clock()
        if #mspTxBuf > 0 then mspProcessTxQ() end
        local cmd, buf, err = mspPollReply()
        if cmd then
            lastRspTime = now
            if cmd == MSP_STATUS and not err then
                handleStatus(buf)
            elseif cmd == MSP_NAV_STATUS and not err then
                handleNavStatus(buf)
            end
            currentCmd = nil
        end
        local readyToSend = currentCmd == nil
            and (now - lastRspTime) >= POST_REPLY_DELAY
            and (now - lastReqTime) >= POST_REPLY_DELAY
        if readyToSend then
            if isArmed and (now - lastNavPollTime) >= NAV_STATUS_POLL_INTERVAL then
                mspSendRequest(MSP_NAV_STATUS, {})
                currentCmd      = MSP_NAV_STATUS
                lastReqTime     = now
                lastNavPollTime = now
            elseif (now - lastArmPollTime) >= ARM_POLL_INTERVAL then
                mspSendRequest(MSP_STATUS, {})
                currentCmd      = MSP_STATUS
                lastReqTime     = now
                lastArmPollTime = now
            end
        end
        if currentCmd and (now - lastReqTime) > REQUEST_TIMEOUT then
            currentCmd = nil
        end
        return
    end

    -- Auto-retry after ERROR: wait RETRY_DELAY then restart from first transport
    if state == STATE_ERROR then
        local now = clock()
        if #transportCandidates > 0 and (now - errorTime) >= RETRY_DELAY then
            log("MSP", "Auto-retry after error...")
            local savedArmingOnly = armingOnly
            local savedCandidates = transportCandidates
            resetState()
            armingOnly          = savedArmingOnly
            transportCandidates = savedCandidates
            transportIdx        = 1
            activateTransport()
            state     = STATE_CONNECTING
            startTime = now
            log("MSP", fmt("Trying transport %d/%d: %s",
                transportIdx, #transportCandidates, transportCandidates[transportIdx].name))
        end
        return
    end

    local now = clock()

    -- FC detection timeout: try next transport, then ERROR if exhausted
    if state == STATE_CONNECTING and (now - startTime) > FC_DETECT_TIMEOUT then
        if tryNextTransport() then
            log("MSP", fmt("No FC on %s after %.0fs, trying transport %d/%d: %s",
                transportCandidates[transportIdx - 1].name, FC_DETECT_TIMEOUT,
                transportIdx, #transportCandidates, transportCandidates[transportIdx].name))
            startTime = now
            currentCmd = nil
        else
            log("MSP", fmt("No FC detected on any transport after %.0fs each", FC_DETECT_TIMEOUT))
            state = STATE_ERROR
            errorTime = clock()
            currentCmd = nil
        end
        return
    end

    -- Continue transmitting multi-frame requests
    if #mspTxBuf > 0 then
        mspProcessTxQ()
    end

    -- Poll for MSP replies
    local cmd, buf, err = mspPollReply()
    if cmd then
        lastRspTime = now
        connected = true

        if err then
            log("MSP", fmt("Error response for cmd %d", cmd))
            if status and status.perfProfileInc then
                status.perfProfileInc("msp_errors")
            end
        else
            if cmd == MSP_FC_VARIANT then
                handleFcVariant(buf)
            elseif cmd == MSP_FC_VERSION then
                handleFcVersion(buf)
            elseif cmd == MSP_WP_GETINFO then
                handleWpGetInfo(buf)
            elseif cmd == MSP_WP then
                handleWp(buf)
            end
        end
        currentCmd = nil
    end

    -- Decide what to request next
    local readyToSend = currentCmd == nil
                        and (now - lastRspTime) >= POST_REPLY_DELAY
                        and (now - lastReqTime) >= POST_REPLY_DELAY

    if readyToSend then
        if state == STATE_CONNECTING then
            mspSendRequest(MSP_FC_VARIANT, {})
            currentCmd  = MSP_FC_VARIANT
            lastReqTime = now
        elseif state == STATE_GET_VERSION then
            mspSendRequest(MSP_FC_VERSION, {})
            currentCmd  = MSP_FC_VERSION
            lastReqTime = now
        elseif state == STATE_GET_WP_INFO then
            mspSendRequest(MSP_WP_GETINFO, {})
            currentCmd  = MSP_WP_GETINFO
            lastReqTime = now
        elseif state == STATE_DOWNLOADING then
            mspSendRequest(MSP_WP, { wpNextIdx })
            currentCmd  = MSP_WP
            lastReqTime = now
        end
    end

    -- Timeout handling with progressive backoff
    local retryTimeout = REQUEST_TIMEOUT + retries * 0.5
    if currentCmd and (now - lastReqTime) > retryTimeout then
        retries = retries + 1
        if status and status.perfProfileInc then
            status.perfProfileInc("msp_errors")
        end
        if retries > MAX_RETRIES then
            log("MSP", fmt("Timeout after %d retries (cmd=%d)", MAX_RETRIES, currentCmd))
            state = STATE_ERROR
            errorTime = clock()
            currentCmd = nil
        else
            log("MSP", fmt("Timeout, retry %d (cmd=%d)", retries, currentCmd))
            currentCmd = nil  -- will re-send next cycle
        end
        connected = (now - lastRspTime) < CONNECT_TIMEOUT
    end
end

--- Return current state snapshot for external consumers.
local TRANSPORT_NAMES = { [0]="NONE", "SPORT", "CRSF" }
function msp.getState()
    return {
        state      = state,
        fcVariant  = fcVariant,
        fcVersion  = fcVersionMajor > 0
                       and fmt("%d.%d.%d", fcVersionMajor, fcVersionMinor, fcVersionPatch)
                       or nil,
        connected  = connected,
        wpCount    = wpCount,
        wpValid    = wpValid,
        wpList     = wpList,
        wpNextIdx  = wpNextIdx,
        wpMaxCount = wpMaxCount,
        missions   = missions,
        isArmed    = isArmed,
        transport  = TRANSPORT_NAMES[transportType] or "UNKNOWN",
        navMode        = navMode,
        activeWpNumber = activeWpNumber,
    }
end

--- Check if the state machine has completed successfully.
function msp.isDone()
    return state == STATE_DONE
end

--- Check if the state machine hit an error.
function msp.isError()
    return state == STATE_ERROR
end

--- Check if MSP is currently active (open and not finished).
function msp.isActive()
    return state ~= STATE_OFF and state ~= STATE_DONE and state ~= STATE_ERROR
end

-- ============================================================================
-- Module init (called by loadLib)
-- ============================================================================
function msp.init(param_status, param_libs)
    status = param_status
    libs   = param_libs
    return msp
end

return msp
