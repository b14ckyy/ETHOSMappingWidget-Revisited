<#
.SYNOPSIS
    LEGACY (obsolete since bsongis.ethos 0.6, 2026-09): use Ethos DevTools "Play Telemetry CSV" instead.
    Kept only as reference for the INAV SmartPort AppID mapping below; scheduled for removal.

    Replays an EdgeTX telemetry log CSV into RADIO/sensors.json for live ETHOS simulator injection.

.DESCRIPTION
    Reads a CSV flight log row by row and writes sensors.json at the inter-row timestamp
    interval so the ETHOS simulator receives live-updating sensor data.

    Sensors injected follow the INAV SmartPort telemetry protocol (smartport.c):

    Standard extension sensors (human-readable values, extension handles wire encoding):
        RSSI          — 1RSS(dB) absolute value
        GPS           — lat/lon/alt/speed(knots)/course(°)/sats
        RxBatt        — RxBt(V)
        FAS           — Curr(A), RxBt(V)
        VariADV       — Alt(m), VSpd(m/s)
        ASS-70        — GPS speed as airspeed proxy (knots)
        VFR           — RSSI link quality % (RQly)      [NOTE: extension multiplier=-1,+100]
        Rx VFR        — TX link quality % (TQly)        [NOTE: extension multiplier=-1,+100]

    Custom INAV SmartPort AppIDs (wire values written directly, multiplier=1):
        0x0430 = 1072   Pitch    — Ptch(rad) converted to tenths-of-degrees
        0x0440 = 1088   Roll     — Roll(rad) converted to tenths-of-degrees
        0x0450 = 1104   COG/FPV  — GPS course (°/10) for heading-over-ground
        0x0600 = 1536   Fuel %   — Bat%(%)  battery remaining percentage
        0x0470 = 1136   MODES    — INAV 7-digit flight mode number (estimated from data)
        0x0480 = 1152   GNSS     — GPS lock/accuracy/sat count (encoded)

.PARAMETER LogPath
  Path to the telemetry CSV log file.
  Default: DemoTelemetry.csv in the same folder as this script.

.PARAMETER SensorsPath
  Destination sensors.json path.
  Default targets the repository file: RADIO/sensors.json.
  Relative custom paths are resolved against the repository root (not current shell folder).

.PARAMETER Speed
    Replay speed multiplier. 1 = real-time, 2 = double speed, etc.

.PARAMETER Loop
    If set, replay restarts from the beginning when the end is reached.

.PARAMETER Format
    'auto' (default) = detect from CSV headers.
    'edgetx' = EdgeTX log (Date, Time, 1RSS(dB), GPS, Ptch(rad), Roll(rad), etc.)
    'generic' = simple CSV with columns: timestamp_ms, lat, lon, alt_m, ...

.PARAMETER IncludeEsc
    Include ESC sensor (RPM/voltage/current derived). Only makes sense for multirotors.

.EXAMPLE
  .\Docs\development\tools\ETHOS VSCode Sim Telemetry Injection\replay-telemetry-log.ps1 -Speed 1 -Loop

.EXAMPLE
  .\Docs\development\tools\ETHOS VSCode Sim Telemetry Injection\replay-telemetry-log.ps1 -LogPath ".\.vscode\MeinFlug.csv" -Speed 5
#>

param(
  [string]$LogPath = (Join-Path $PSScriptRoot 'DemoTelemetry.csv'),

  [string]$SensorsPath = "RADIO/sensors.json",

  [double]$Speed = 1.0,

  [switch]$Loop,

  [ValidateSet('auto', 'edgetx', 'generic')]
  [string]$Format = 'auto',

  [switch]$IncludeEsc
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ProjectRoot {
  param([string]$StartDir)

  $resolvedStart = (Resolve-Path $StartDir).Path
  $dir = New-Object System.IO.DirectoryInfo($resolvedStart)
  while ($null -ne $dir) {
    $radioDir = Join-Path $dir.FullName 'RADIO'
    $docsDir  = Join-Path $dir.FullName 'Docs'
    if ((Test-Path $radioDir) -and (Test-Path $docsDir)) {
      return $dir.FullName
    }
    $dir = $dir.Parent
  }

  # Fallback: use current directory if project root cannot be detected.
  return (Get-Location).Path
}

if (-not (Test-Path $LogPath)) {
  throw "Log file not found: $LogPath"
}
if ($Speed -le 0) {
  throw "-Speed must be > 0"
}

$projectRoot = Get-ProjectRoot -StartDir $PSScriptRoot
$sensorsDefaultPath = Join-Path $projectRoot 'RADIO\sensors.json'

$sensorsFullPath = if ([System.IO.Path]::IsPathRooted($SensorsPath)) {
  $SensorsPath
} else {
  if ($SensorsPath -eq 'RADIO/sensors.json') {
    $sensorsDefaultPath
  } else {
    [System.IO.Path]::GetFullPath((Join-Path $projectRoot $SensorsPath))
  }
}
$sensorsDir = Split-Path -Parent $sensorsFullPath
if (-not (Test-Path $sensorsDir)) {
  New-Item -ItemType Directory -Path $sensorsDir -Force | Out-Null
}

# ---------------------------------------------------------------------------
# CSV loading — deduplicates column names that appear more than once
# (EdgeTX logs have duplicate "Hdg(°)" and "GSpd" columns).
# ---------------------------------------------------------------------------
function Load-CsvUniqueHeaders {
  param([string]$Path)

  $lines = Get-Content -Path $Path
  if (-not $lines -or $lines.Count -lt 2) {
    throw "CSV must contain at least a header and one data row: $Path"
  }

  $rawHeaders = $lines[0].Split(',')
  $seen = @{}
  $headers = New-Object System.Collections.Generic.List[string]
  foreach ($h in $rawHeaders) {
    $base = $h.Trim()
    if ($seen.ContainsKey($base)) {
      $seen[$base] = [int]$seen[$base] + 1
      $headers.Add("${base}_$($seen[$base])")
    } else {
      $seen[$base] = 1
      $headers.Add($base)
    }
  }

  $data = $lines | Select-Object -Skip 1 | ConvertFrom-Csv -Header $headers
  return $data
}

# ---------------------------------------------------------------------------
# Safe numeric parsing with fallback default.
# ---------------------------------------------------------------------------
function Try-ParseDouble {
  param(
    [object]$Value,
    [double]$Default = 0.0
  )
  if ($null -eq $Value) { return $Default }
  $text = "$Value".Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $Default }
  $n = 0.0
  if ([double]::TryParse($text,
      [System.Globalization.NumberStyles]::Float,
      [System.Globalization.CultureInfo]::InvariantCulture,
      [ref]$n)) {
    return $n
  }
  if ([double]::TryParse($text, [ref]$n)) { return $n }
  return $Default
}

# Returns the value of the first matching candidate column, or $Default.
function Get-Field {
  param(
    [object]$Row,
    [string[]]$Candidates,
    [double]$Default = 0.0
  )
  foreach ($name in $Candidates) {
    if ($Row.PSObject.Properties.Name -contains $name) {
      $v = $Row.PSObject.Properties[$name].Value
      return Try-ParseDouble -Value $v -Default $Default
    }
  }
  return $Default
}

# ---------------------------------------------------------------------------
# Parse the combined "lat lon" string from the GPS column.
# Returns a two-element array [lat, lon].
# ---------------------------------------------------------------------------
function Get-GpsLatLon {
  param([object]$Row)
  foreach ($col in @('GPS', 'GPS_2')) {
    if ($Row.PSObject.Properties.Name -contains $col) {
      $text = "$($Row.PSObject.Properties[$col].Value)".Trim()
      if (-not [string]::IsNullOrWhiteSpace($text)) {
        $parts = $text -split '\s+'
        if ($parts.Count -ge 2) {
          $la = Try-ParseDouble -Value $parts[0] -Default 0.0
          $lo = Try-ParseDouble -Value $parts[1] -Default 0.0
          if ($la -ne 0.0 -or $lo -ne 0.0) {
            return @($la, $lo)
          }
        }
      }
    }
  }
  return @(0.0, 0.0)
}

function Try-ParseLogTimestampMs {
  param([object]$Row)

  if ($Row.PSObject.Properties.Name -contains 'timestamp_ms') {
    $ts = Try-ParseDouble -Value $Row.PSObject.Properties['timestamp_ms'].Value -Default -1
    if ($ts -ge 0) {
      return [double]$ts
    }
    return $null
  }

  if (($Row.PSObject.Properties.Name -contains 'Date') -and
      ($Row.PSObject.Properties.Name -contains 'Time')) {
    $dateText = "$($Row.PSObject.Properties['Date'].Value)".Trim()
    $timeText = "$($Row.PSObject.Properties['Time'].Value)".Trim()
    if (-not [string]::IsNullOrWhiteSpace($dateText) -and -not [string]::IsNullOrWhiteSpace($timeText)) {
      $combined = "$dateText`T$timeText"
      foreach ($format in @(
        'yyyy-MM-ddTHH:mm:ss.fff',
        'yyyy-MM-ddTHH:mm:ss.ff',
        'yyyy-MM-ddTHH:mm:ss.f',
        'yyyy-MM-ddTHH:mm:ss'
      )) {
        try {
          $dt = [datetime]::ParseExact(
            $combined,
            $format,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None)
          return [double]([datetimeoffset]$dt).ToUnixTimeMilliseconds()
        } catch {
        }
      }
    }
  }

  return $null
}

# ---------------------------------------------------------------------------
# Converts a row's timestamp to epoch milliseconds.
# Supports "Date+Time" (EdgeTX) or "timestamp_ms" (generic).
# ---------------------------------------------------------------------------
function Get-RowTimeMs {
  param(
    [object]$Row,
    [double]$Previous
  )
  $timestamp = Try-ParseLogTimestampMs -Row $Row
  if ($null -ne $timestamp) {
    return $timestamp
  }

  return $Previous + 100.0
}

# ---------------------------------------------------------------------------
# Encodes an INAV flight mode number (0x0470 MODES) from observable telemetry.
#
# INAV encoding (from smartport.c frskyGetFlightMode):
#   G (ones):     1 = ok-to-arm, 2 = arm-prevented, 4 = armed
#   F (tens):     1 = angle,     2 = horizon,        4 = manual/passthrough
#   E (hundreds): 1 = heading-hold, 2 = alt-hold, 4 = pos-hold
#   D (thousands): 1 = RTH, 2 = WP, 4 = headfree, 8 = course-hold
#
# We estimate armed state from current draw or ground speed.
# Flight mode defaults to Angle because that is the most common fixed-wing stable mode.
# ---------------------------------------------------------------------------
function Get-ModesValue {
  param(
    [double]$CurrentA,
    [double]$SpeedKmh,
    [double]$AltM
  )
  # Armed = significant current draw or motion
  $armed = ($CurrentA -gt 3.0) -or ($SpeedKmh -gt 5.0)
  $gBit = if ($armed) { 4 } else { 1 }  # 4=armed / 1=ok-to-arm
  $fBit = 10                             # tens column = 1 (angle mode)
  return $gBit + $fBit
}

# ---------------------------------------------------------------------------
# Encodes INAV GPS state (0x0480 GNSS) from satellite count.
#
# INAV encoding (from smartport.c frskyGetGPSState):
#   ones+tens: # satellites (0-99)
#   hundreds:  HDOP accuracy 0 (worst) – 9 (best, HDOP ≤ 1.0)
#   thousands: 1 = GPS fix, 2 = home fixed, 4 = home reset active
# ---------------------------------------------------------------------------
function Get-GnssValue {
  param([int]$Sats)
  $sats = [math]::Min(99, [math]::Max(0, $Sats))
  $hdop = if ($sats -ge 12) { 9 } elseif ($sats -ge 9) { 7 } elseif ($sats -ge 6) { 5 } else { 2 }
  $fix  = if ($sats -ge 4) { 3 } else { 0 }  # 1=GPS fix + 2=home fix
  return [int]($fix * 1000 + $hdop * 100 + $sats)
}

# ---------------------------------------------------------------------------
# Writes the sensors.json payload.
#
# IMPORTANT – Custom sensor wire values:
#   The ETHOS extension sensor classes for standard sensors (GPS, FAS, VariADV, etc.)
#   store human-readable values in sensors.json and apply a multiplier internally before
#   injection.  Custom sensors have multiplier = 1, offset = 0, so the value in sensors.json
#   IS the raw INAV SmartPort wire value.  Unit conversions must therefore be done here
#   before writing.
#
#   VFR / Rx VFR: extension frame has multiplier=-1, offset=100 so:
#       wireValue = value × (-1) + 100 = 100 – value
#   → pass link-quality % (RQly/TQly) as value, extension renders it as error-rate.
# ---------------------------------------------------------------------------
function Write-SensorsJson {
  param(
    [double]$Lat,
    [double]$Lon,
    [double]$AltM,
    [double]$GpsSpeedKmh,     # km/h  → converted to knots internally
    [double]$HeadingDeg,       # GPS course over ground, degrees 0–360
    [int]   $Sats,
    [double]$RssiDb,           # absolute dB (RSSI)
    [double]$RxBattV,          # receiver battery / pack voltage
    [double]$CurrentA,         # current draw
    [double]$CapaMah,          # capacity drawn (mAh)
    [double]$VSpeedMps,        # vertical speed m/s
    [double]$Rqly,             # RX link quality %  (0–100)
    [double]$Tqly,             # TX link quality %  (0–100)
    [double]$BatPct,           # battery remaining %
    [double]$PitchRad,         # pitch in radians
    [double]$RollRad,          # roll  in radians
    [double]$ModesValue,       # pre-computed INAV MODES number
    [int]   $GnssValue,        # pre-computed INAV GNSS state number
    [bool]  $IncludeEscSensor
  )

  # -- helper clamps --
  $gpsKnots = [math]::Max(0, $GpsSpeedKmh / 1.852)
  $heading   = (($HeadingDeg % 360) + 360) % 360
  $rssi      = [math]::Abs($RssiDb)
  $rxBatt    = [math]::Max(0, $RxBattV)
  $current   = [math]::Max(0, $CurrentA)
  $capa      = [math]::Max(0, $CapaMah)
  $vspeed    = $VSpeedMps
  $rqly      = [math]::Min(100, [math]::Max(0, $Rqly))
  $tqly      = [math]::Min(100, [math]::Max(0, $Tqly))
  $batPct    = [math]::Min(100, [math]::Max(0, $BatPct))
  $satsInt   = [math]::Max(0, $Sats)

  # Custom INAV wire values (Custom sensor multiplier=1, no further scaling)
  # Pitch and Roll: INAV sends attitude.values.pitch/roll which are in tenths-of-degrees
  $pitchWire = [int][math]::Round($PitchRad * (180.0 / [math]::PI) * 10.0)
  $rollWire  = [int][math]::Round($RollRad  * (180.0 / [math]::PI) * 10.0)
  # COG/FPV (0x0450): GPS course in tenths-of-degrees (INAV gpsSol.groundCourse)
  $cogWire   = [int][math]::Round($heading * 10.0)
  $fuelWire  = [int][math]::Round($batPct)
  $modesWire = [int][math]::Round($ModesValue)
  $gnssWire  = $GnssValue

  $payload = New-Object System.Collections.Generic.List[object]

  # ── Standard sensors ─────────────────────────────────────────────────────

  # RSSI — appId 0xF101 (61697)
  $payload.Add(@{
      name = 'RSSI'; module = 0; band = 0; rx = 0
      frames = @(@{ name = 'RSSI'; value = [math]::Round($rssi, 2); interval = 200 })
    })

  # GPS — lat/lon (0x0800), alt (0x0820), speed (0x0830), course (0x0840), sats (0x0860)
  # Values in human-readable units; extension multiplies by 600000, 100, 1000, 100 internally.
  $payload.Add(@{
      name = 'GPS'; module = 0; band = 0; rx = 0; appId = 0; interval = 1000
      frames = @(
        @{ name = 'Latitude';  value = [math]::Round($Lat, 7) },
        @{ name = 'Longitude'; value = [math]::Round($Lon, 7) },
        @{ name = 'Altitude';  value = [math]::Round($AltM, 2) },
        @{ name = 'Speed';     value = [math]::Round($gpsKnots, 3) },
        @{ name = 'Course';    value = [math]::Round($heading, 2) },
        @{ name = 'Sats';      value = $satsInt }
      )
    })

  # RxBatt — appId 0xF104 (61700); value in Volts
  $payload.Add(@{
      name = 'RxBatt'; module = 0; band = 0; rx = 0
      frames = @(@{ name = 'RxBatt'; value = [math]::Round($rxBatt, 2); interval = 200 })
    })

  # FAS — Current (0x0200) in A, Voltage (0x0210) in V
  $payload.Add(@{
      name = 'FAS'; module = 0; band = 0; rx = 0; appId = 0
      frames = @(
        @{ name = 'Current'; value = [math]::Round($current, 2); interval = 200 },
        @{ name = 'Voltage'; value = [math]::Round($rxBatt, 2);  interval = 200 }
      )
    })

  # VariADV — Baro Altitude (0x0100) in m, VSpeed (0x0110) in m/s
  $payload.Add(@{
      name = 'VariADV'; module = 0; band = 0; rx = 0; appId = 0
      frames = @(
        @{ name = 'Altitude'; value = [math]::Round($AltM, 2);   interval = 200 },
        @{ name = 'VSpeed';   value = [math]::Round($vspeed, 2);  interval = 200 }
      )
    })

  # ASS-70 — Airspeed (0x0A00) in knots; use GPS speed as proxy (no pitot in log)
  $payload.Add(@{
      name = 'ASS-70'; module = 0; band = 0; rx = 0; appId = 0
      frames = @(@{ name = 'Air speed'; value = [math]::Round($gpsKnots, 2); interval = 200 })
    })

  # VFR / Rx VFR — IMPORTANT: extension frame has multiplier=-1, offset=100.
  # wireValue = value*(-1)+100 → pass link-quality% directly; extension inverts to error-rate.
  $payload.Add(@{
      name = 'VFR'; module = 0; band = 0; rx = 0
      frames = @(@{ name = 'VFR'; value = [math]::Round($rqly, 1); interval = 200 })
    })
  $payload.Add(@{
      name = 'Rx VFR'; module = 0; band = 0; rx = 0
      frames = @(@{ name = 'Rx VFR'; value = [math]::Round($tqly, 1); interval = 200 })
    })

  # ── Custom INAV SmartPort sensors ─────────────────────────────────────────
  # These use the generic "Custom" sensor slot.  The extension's Custom sensor has:
  #   multiplier = 1, offset = 0  → frame.value IS the raw SPort wire value.
  # Injection: physId=152, primId=16, appId = (sensor.appId | frame.appId) = sensor.appId | 0.
  # Frame name must be "" so Sensor.deserialize() finds and updates the template frame.

  # Pitch — 0x0430 (1072); wire value = attitude.values.pitch in 10*deg (tenths of degrees)
  $payload.Add(@{
      name = 'Custom'; appId = 1072; module = 0; band = 0; rx = 0
      frames = @(@{ name = ''; value = $pitchWire; interval = 100 })
    })

  # Roll — 0x0440 (1088); wire value = attitude.values.roll in 10*deg
  $payload.Add(@{
      name = 'Custom'; appId = 1088; module = 0; band = 0; rx = 0
      frames = @(@{ name = ''; value = $rollWire; interval = 100 })
    })

  # COG/FPV — 0x0450 (1104); INAV: gpsSol.groundCourse in 10*deg
  # Provides GPS course-over-ground as a separate source from attitude heading.
  $payload.Add(@{
      name = 'Custom'; appId = 1104; module = 0; band = 0; rx = 0
      frames = @(@{ name = ''; value = $cogWire; interval = 200 })
    })

  # Fuel % — 0x0600 (1536); INAV: calculateBatteryPercentage(), integer 0–100
  $payload.Add(@{
      name = 'Custom'; appId = 1536; module = 0; band = 0; rx = 0
      frames = @(@{ name = ''; value = $fuelWire; interval = 500 })
    })

  # MODES — 0x0470 (1136); INAV 7-digit flight mode number (estimated)
  $payload.Add(@{
      name = 'Custom'; appId = 1136; module = 0; band = 0; rx = 0
      frames = @(@{ name = ''; value = $modesWire; interval = 500 })
    })

  # GNSS Status — 0x0480 (1152); satellites + HDOP + fix status (encoded)
  $payload.Add(@{
      name = 'Custom'; appId = 1152; module = 0; band = 0; rx = 0
      frames = @(@{ name = ''; value = $gnssWire; interval = 500 })
    })

  # ── Optional ESC sensor ───────────────────────────────────────────────────
  if ($IncludeEscSensor) {
    $payload.Add(@{
        name = 'ESC'; module = 0; band = 0; rx = 0; appId = 0
        frames = @(
          @{ name = 'Voltage';     value = [math]::Round($rxBatt, 2);  interval = 200 },
          @{ name = 'Current';     value = [math]::Round($current, 2); interval = 200 },
          @{ name = 'RPM';         value = [int][math]::Round($gpsKnots * 80, 0); interval = 200 },
          @{ name = 'Consumption'; value = [math]::Round($capa, 0);    interval = 200 },
          @{ name = 'Temperature'; value = 38;                          interval = 500 }
        )
      })
  }

  $json = $payload | ConvertTo-Json -Depth 8
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

  # Atomic write: write to a unique temp file first, then replace destination.
  # File.Replace handles existing destinations correctly on Windows.
  $sensorsParentDir = Split-Path -Parent $sensorsFullPath
  $sensorsFileName = Split-Path -Leaf $sensorsFullPath
  $tmpPath = Join-Path $sensorsParentDir ("{0}.{1}.tmp" -f $sensorsFileName, [guid]::NewGuid().ToString('N'))
  $backupPath = Join-Path $sensorsParentDir ("{0}.{1}.bak" -f $sensorsFileName, [guid]::NewGuid().ToString('N'))

  for ($attempt = 1; $attempt -le 8; $attempt++) {
    try {
      [System.IO.File]::WriteAllText($tmpPath, $json, $utf8NoBom)
      if (Test-Path -LiteralPath $sensorsFullPath) {
        [System.IO.File]::Replace($tmpPath, $sensorsFullPath, $backupPath, $true)
        if (Test-Path -LiteralPath $backupPath) {
          Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
      } else {
        [System.IO.File]::Move($tmpPath, $sensorsFullPath)
      }
      return
    } catch {
      if (Test-Path -LiteralPath $tmpPath) {
        Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
      }
      if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
      }
      if ($attempt -eq 8) {
        throw
      }
      Start-Sleep -Milliseconds (25 * $attempt)
    }
  }
}

function Get-SampleRateInfo {
  param([object[]]$InputRows)

  $deltas = New-Object System.Collections.Generic.List[double]
  $previous = $null

  foreach ($row in $InputRows) {
    $ts = Try-ParseLogTimestampMs -Row $row
    if ($null -eq $ts) { continue }

    if ($null -ne $previous) {
      $delta = [double]$ts - [double]$previous
      if ($delta -gt 0 -and $delta -le 10000) { $deltas.Add($delta) }
    }
    $previous = $ts
  }

  if ($deltas.Count -eq 0) {
    return $null
  }

  $sorted = $deltas | Sort-Object
  $mid = [int][math]::Floor($sorted.Count / 2)
  $medianMs = if (($sorted.Count % 2) -eq 0) {
    ($sorted[$mid - 1] + $sorted[$mid]) / 2.0
  } else {
    $sorted[$mid]
  }

  $hz = if ($medianMs -gt 0) { 1000.0 / $medianMs } else { 0.0 }
  return [pscustomobject]@{
    MedianMs = [math]::Round($medianMs, 1)
    Hertz    = [math]::Round($hz, 2)
  }
}

# ---------------------------------------------------------------------------
# Load CSV and auto-detect format
# ---------------------------------------------------------------------------
$rows = Load-CsvUniqueHeaders -Path $LogPath
if (-not $rows -or $rows.Count -eq 0) {
  throw "No data rows found in: $LogPath"
}

$detectedFormat = $Format
if ($Format -eq 'auto') {
  $first = $rows[0]
  $cols  = $first.PSObject.Properties.Name
  if (($cols -contains 'Date') -and ($cols -contains 'Time') -and ($cols -contains 'GPS')) {
    $detectedFormat = 'edgetx'
  } else {
    $detectedFormat = 'generic'
  }
}

Write-Host "Replay source : $LogPath"
Write-Host "Streaming to  : $sensorsFullPath"
Write-Host "Rows          : $($rows.Count)"
Write-Host "Speed         : ${Speed}x"
Write-Host "Format        : $detectedFormat"
Write-Host "ESC sensor    : $($IncludeEsc.IsPresent)"
$rateInfo = Get-SampleRateInfo -InputRows $rows
if ($null -ne $rateInfo) {
  Write-Host "Log rate      : ~$($rateInfo.Hertz) Hz (median dt $($rateInfo.MedianMs) ms)"
}
Write-Host ""

# ---------------------------------------------------------------------------
# Main replay loop
# ---------------------------------------------------------------------------
function Run-Replay {
  $previousTimestamp = [double]0

  for ($i = 0; $i -lt $rows.Count; $i++) {
    $row = $rows[$i]

    # -- Timestamp --
    $timestamp = Get-RowTimeMs -Row $row -Previous $previousTimestamp
    if ($i -eq 0) { $previousTimestamp = $timestamp }

    # -- Extract sensor values -------------------------------------------
    $lat = 0.0; $lon = 0.0; $altM = 0.0; $gpsSpeedKmh = 0.0
    $headingDeg = 0.0; $sats = 0; $rssiDb = 95.0; $rxBattV = 10.0
    $currentA = 0.0; $capaMah = 0.0; $vSpeedMps = 0.0; $rqly = 100.0
    $tqly = 100.0; $batPct = 0.0; $pitchRad = 0.0; $rollRad = 0.0

    if ($detectedFormat -eq 'edgetx') {
      # GPS position — combined "lat lon" string field
      $gpsLL      = Get-GpsLatLon -Row $row
      $lat        = $gpsLL[0]
      $lon        = $gpsLL[1]

      # GPS-derived values
      $altM       = Get-Field $row @('Alt(m)')       0.0
      $gpsSpeedKmh = Get-Field $row @('GSpd(kmh)')   0.0
      $headingDeg = Get-Field $row @('Hdg(°)')        0.0   # GPS course over ground
      $sats       = [int](Get-Field $row @('Sats')   0.0)
      $vSpeedMps  = Get-Field $row @('VSpd(m/s)')    0.0

      # Link statistics
      $rssiDb     = Get-Field $row @('1RSS(dB)', 'TRSS(dB)')  -95.0
      $rqly       = Get-Field $row @('RQly(%)')  100.0
      $tqly       = Get-Field $row @('TQly(%)')  100.0

      # Battery / power
      $rxBattV    = Get-Field $row @('RxBt(V)')   10.0
      $currentA   = Get-Field $row @('Curr(A)')    0.0
      $capaMah    = Get-Field $row @('Capa(mAh)') 0.0
      $batPct     = Get-Field $row @('Bat%(%)')   0.0

      # Attitude (radians in EdgeTX log)
      $pitchRad   = Get-Field $row @('Ptch(rad)') 0.0
      $rollRad    = Get-Field $row @('Roll(rad)')  0.0
      # Note: Yaw(rad) from attitude estimator -- we skip separate yaw injection
      # to avoid conflicting with GPS.Course on appId 0x0840.

    } else {
      # Generic CSV format
      $lat         = Get-Field $row @('lat', 'latitude')   0.0
      $lon         = Get-Field $row @('lon', 'longitude')  0.0
      $altM        = Get-Field $row @('alt_m', 'altitude_m') 0.0
      $gpsSpeedKmh = (Get-Field $row @('speed_mps', 'gspd_mps') 0.0) * 3.6
      $headingDeg  = Get-Field $row @('course_deg', 'heading_deg') 0.0
      $sats        = [int](Get-Field $row @('sats') 0.0)
      $rssiDb      = Get-Field $row @('rssi', 'rssi_db') 95.0
      $rxBattV     = Get-Field $row @('rxbatt_v', 'voltage_v') 10.0
      $currentA    = Get-Field $row @('current_a') 0.0
      $capaMah     = Get-Field $row @('capacity_mah') 0.0
      $vSpeedMps   = Get-Field $row @('vspd_mps') 0.0
      $rqly        = Get-Field $row @('rqly') 100.0
      $tqly        = Get-Field $row @('tqly') 100.0
      $batPct      = Get-Field $row @('bat_pct', 'fuel_pct') 0.0
      $pitchRad    = (Get-Field $row @('pitch_deg') 0.0) * ([math]::PI / 180.0)
      $rollRad     = (Get-Field $row @('roll_deg')  0.0) * ([math]::PI / 180.0)
    }

    # -- Derived / encoded values ----------------------------------------
    $modesValue  = Get-ModesValue -CurrentA $currentA -SpeedKmh $gpsSpeedKmh -AltM $altM
    $gnssValue   = Get-GnssValue  -Sats $sats

    # -- Write sensors.json ---------------------------------------------
    Write-SensorsJson `
      -Lat $lat -Lon $lon -AltM $altM -GpsSpeedKmh $gpsSpeedKmh `
      -HeadingDeg $headingDeg -Sats $sats `
      -RssiDb $rssiDb -RxBattV $rxBattV -CurrentA $currentA `
      -CapaMah $capaMah -VSpeedMps $vSpeedMps `
      -Rqly $rqly -Tqly $tqly -BatPct $batPct `
      -PitchRad $pitchRad -RollRad $rollRad `
      -ModesValue $modesValue -GnssValue $gnssValue `
      -IncludeEscSensor:$IncludeEsc

    # -- Terminal progress --------------------------------------------
    $currentRow = $i + 1
    $pct = [int][math]::Floor((100.0 * $currentRow) / $rows.Count)
    $status = "`rRow {0}/{1} ({2}%)  lat={3:F5} lon={4:F5} alt={5:F1}m hdg={6:F1}° sats={7}" -f `
      $currentRow, $rows.Count, $pct, $lat, $lon, $altM, $headingDeg, $sats
    Write-Host $status -NoNewline

    # -- Wait until next row (time-accurate) --------------------------
    if ($i -lt $rows.Count - 1) {
      $delta = $timestamp - $previousTimestamp
      if ($delta -lt 0)   { $delta = 0 }
      if ($delta -lt 10 -and $delta -gt 0) { $delta = $delta * 1000 }   # ms heuristic for epoch-s logs

      $sleepMs = [int][math]::Round($delta / $Speed)
      if ($sleepMs -gt 5000) { $sleepMs = 5000 }
      if ($sleepMs -gt 0)   { Start-Sleep -Milliseconds $sleepMs }
    }

    $previousTimestamp = $timestamp
  }
  Write-Host ""
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
if ($Loop.IsPresent) {
  $pass = 1
  while ($true) {
    Write-Host "--- Loop pass $pass ---"
    Run-Replay
    $pass++
  }
} else {
  Run-Replay
}

Write-Host "Replay finished."
