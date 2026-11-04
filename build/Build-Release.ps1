# Build-Release.ps1
# Builds a release package for the ETHOS Mapping Widget.
#
# 1. Copies all source files from src/ into build/release/ with ETHOS SD-card layout.
# 2. Creates a ZIP archive ready to extract onto the radio SD card.
# 3. Deploys the release into the active VS Code simulator folder
#    (simulators/<board>_<protocol>@<release>/, resolved from .vscode/settings.json).
#
# Usage:  .\build\Build-Release.ps1
#         .\build\Build-Release.ps1 -SimDir simulators\X20RS_FCC@nightly26
#         .\build\Build-Release.ps1 -NoDeploy

param(
    [string]$SimDir,
    [switch]$NoDeploy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Paths ---

$repoRoot   = Split-Path -Parent $PSScriptRoot
$srcDir     = Join-Path $repoRoot 'src'
$buildDir   = Join-Path $repoRoot 'build'
$releaseDir = Join-Path $buildDir 'release'

# --- Simulator target (bsongis.ethos >= 0.6 layout) ---

function Resolve-SimDir {
    $settingsPath = Join-Path (Join-Path $repoRoot '.vscode') 'settings.json'
    if (-not (Test-Path $settingsPath)) { return $null }
    # Strip // line comments so ConvertFrom-Json (PS 5.1) accepts the file.
    $raw = (Get-Content $settingsPath -Raw) -replace '(?m)^\s*//.*$', ''
    try { $json = $raw | ConvertFrom-Json } catch { return $null }
    $board    = $json.'ethos.board'
    $protocol = $json.'ethos.protocol'
    $release  = $json.'ethos.release'
    $folder   = $json.'ethos.simulatorsFolder'
    if (-not $release) { $release = 'nightly26' }
    if (-not $folder)  { $folder  = 'simulators' }
    if (-not $board -or -not $protocol) { return $null }
    return Join-Path (Join-Path $repoRoot $folder) ("{0}_{1}@{2}" -f $board, $protocol, $release)
}

if (-not $NoDeploy) {
    if ($SimDir) {
        if (-not [System.IO.Path]::IsPathRooted($SimDir)) { $SimDir = Join-Path $repoRoot $SimDir }
    } else {
        $SimDir = Resolve-SimDir
    }
}

# --- Version ---

$mainLua = Join-Path (Join-Path (Join-Path $srcDir 'scripts') 'ethosmaps') 'main.lua'
$widgetVersion = 'unknown'
foreach ($line in (Get-Content $mainLua)) {
    if ($line -match 'local\s+WIDGET_VERSION\s*=\s*"([^"]+)"') {
        $widgetVersion = $Matches[1]
        break
    }
}

$commitId = git -C $repoRoot rev-parse --short HEAD 2>$null
if (-not $commitId) { $commitId = 'nogit' }
$commitId = $commitId.Trim()

$zipName = 'ETHOSMappingWidget-' + $widgetVersion + '-' + $commitId + '.zip'
$zipPath = Join-Path $buildDir $zipName

# --- Clean ---

Write-Host '=== ETHOS Mapping Widget Build ===' -ForegroundColor Cyan
Write-Host "Version : $widgetVersion ($commitId)"
Write-Host "Source  : $srcDir"
Write-Host "Release : $releaseDir"
if ($NoDeploy)      { Write-Host 'Deploy  : skipped (-NoDeploy)' }
elseif ($SimDir)    { Write-Host "Deploy  : $SimDir" }
else                { Write-Host 'Deploy  : skipped (no simulator configured in .vscode/settings.json)' -ForegroundColor Yellow }
Write-Host ''

if (Test-Path $releaseDir) {
    Write-Host 'Cleaning previous release...' -ForegroundColor Yellow
    Remove-Item -Recurse -Force $releaseDir
}
if (Test-Path $zipPath) {
    Remove-Item -Force $zipPath
}

# --- Stage ---

Write-Host 'Staging source files...' -ForegroundColor Green

$bmpSrc = Join-Path (Join-Path (Join-Path $srcDir 'bitmaps') 'ethosmaps') 'bitmaps'
$bmpDst = Join-Path (Join-Path (Join-Path $releaseDir 'bitmaps') 'ethosmaps') 'bitmaps'
New-Item -ItemType Directory -Path $bmpDst -Force | Out-Null
Copy-Item -Path (Join-Path $bmpSrc '*') -Destination $bmpDst -Recurse

$scriptSrc = Join-Path (Join-Path $srcDir 'scripts') 'ethosmaps'
$scriptDst = Join-Path (Join-Path $releaseDir 'scripts') 'ethosmaps'
New-Item -ItemType Directory -Path $scriptDst -Force | Out-Null
Copy-Item -Path (Join-Path $scriptSrc 'main.lua') -Destination $scriptDst

$libDst = Join-Path $scriptDst 'lib'
New-Item -ItemType Directory -Path $libDst -Force | Out-Null
Copy-Item -Path (Join-Path (Join-Path $scriptSrc 'lib') '*') -Destination $libDst -Recurse

$audioDst = Join-Path $scriptDst 'audio'
New-Item -ItemType Directory -Path $audioDst -Force | Out-Null
Copy-Item -Path (Join-Path (Join-Path $scriptSrc 'audio') '*') -Destination $audioDst -Recurse

$fileCount = (Get-ChildItem -Path $releaseDir -Recurse -File).Count
Write-Host "Staged $fileCount files." -ForegroundColor Green

# --- ZIP ---

Write-Host "Creating ZIP: $zipName" -ForegroundColor Green
Compress-Archive -Path (Join-Path $releaseDir '*') -DestinationPath $zipPath -Force

$zipSizeKB = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)
Write-Host "ZIP created ($zipSizeKB KB)" -ForegroundColor Green

# --- Deploy to simulator ---

if (-not $NoDeploy -and $SimDir) {
    Write-Host 'Deploying to simulator...' -ForegroundColor Green

    $simBmpDst = Join-Path (Join-Path (Join-Path $SimDir 'bitmaps') 'ethosmaps') 'bitmaps'
    New-Item -ItemType Directory -Path $simBmpDst -Force | Out-Null
    Copy-Item -Path (Join-Path $bmpDst '*') -Destination $simBmpDst -Force -Recurse

    $simScriptDst = Join-Path (Join-Path $SimDir 'scripts') 'ethosmaps'
    New-Item -ItemType Directory -Path $simScriptDst -Force | Out-Null
    Copy-Item -Path (Join-Path $scriptDst 'main.lua') -Destination $simScriptDst -Force

    $simLibDst = Join-Path $simScriptDst 'lib'
    New-Item -ItemType Directory -Path $simLibDst -Force | Out-Null
    Copy-Item -Path (Join-Path $libDst '*') -Destination $simLibDst -Force -Recurse

    $simAudioDst = Join-Path $simScriptDst 'audio'
    New-Item -ItemType Directory -Path $simAudioDst -Force | Out-Null
    Copy-Item -Path (Join-Path $audioDst '*') -Destination $simAudioDst -Force -Recurse

    # Mirror: drop lib files that no longer exist in src/ and stale bytecode caches,
    # otherwise ETHOS keeps loading deleted modules / outdated .luac files.
    $stale = @()
    $stale += Get-ChildItem -Path $simLibDst -File | Where-Object {
        -not (Test-Path (Join-Path $libDst $_.Name)) -or $_.Extension -eq '.luac'
    }
    $stale += Get-ChildItem -Path $simScriptDst -File -Filter '*.luac'
    foreach ($f in $stale) {
        Write-Host "  removing stale $($f.FullName.Substring($SimDir.Length + 1))" -ForegroundColor Yellow
        Remove-Item -Force $f.FullName
    }
}

Write-Host ''
Write-Host '=== Build complete ===' -ForegroundColor Cyan
Write-Host "  Release : $releaseDir"
Write-Host "  ZIP     : $zipPath"
if (-not $NoDeploy -and $SimDir) { Write-Host "  SIM     : $SimDir" }
