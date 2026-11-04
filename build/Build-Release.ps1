# Build-Release.ps1
# Builds the release packages for the ETHOS Mapping Widget.
#
# 1. Stages src/scripts/ethosmaps/ into build/release/scripts/ethosmaps/ and generates
#    ethos_lua_manifest.json (FrSky Lua package spec V1, Docs/development/tools/ethos_good_lua.md).
# 2. Creates two ZIPs from the same staged tree:
#      ETHOSMappingWidget-<ver>-<hash>-suite.zip   manifest + script files at ZIP root (Ethos Suite install)
#      ETHOSMappingWidget-<ver>-<hash>-sdcard.zip  scripts/ethosmaps/... (extract to SD card root)
#    and validates the Suite ZIP against the spec.
# 3. Deploys the staged script folder into the active VS Code simulator folder
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

# --- Package identity (never change key or folder after the first Suite release) ---

$packageName   = 'ETHOS Mapping Widget'
$packageKey    = 'com.github.b14ckyy.ethosmaps'
$packageFolder = 'ethosmaps'
$packageFiles  = @('main.lua', 'lib/*', 'audio/*', 'bitmaps/*')
$manifestName  = 'ethos_lua_manifest.json'

# --- Paths ---

$repoRoot   = Split-Path -Parent $PSScriptRoot
$srcDir     = Join-Path $repoRoot 'src'
$buildDir   = Join-Path $repoRoot 'build'
$releaseDir = Join-Path $buildDir 'release'
$scriptSrc  = Join-Path (Join-Path $srcDir 'scripts') $packageFolder
$scriptDst  = Join-Path (Join-Path $releaseDir 'scripts') $packageFolder
$changelog  = Join-Path (Join-Path (Join-Path $repoRoot 'Docs') 'development') 'CHANGELOG.md'

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

# --- Version and release notes ---

$widgetVersion = $null
foreach ($line in (Get-Content (Join-Path $scriptSrc 'main.lua'))) {
    if ($line -match 'local\s+WIDGET_VERSION\s*=\s*"([^"]+)"') {
        $widgetVersion = $Matches[1]
        break
    }
}
if (-not $widgetVersion) { throw 'WIDGET_VERSION not found in main.lua' }
if ($widgetVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "WIDGET_VERSION '$widgetVersion' is not a 3-part numeric version (x.y.z) as required by the Suite manifest"
}

function Get-ReleaseNotes([string]$version) {
    $lines = Get-Content $changelog -Encoding UTF8
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match ('^##\s+' + [regex]::Escape($version) + '(\s|$)')) { $start = $i; break }
    }
    if ($start -lt 0) { throw "CHANGELOG.md has no '## $version' section (needed for the manifest release notes)" }
    $body = New-Object System.Collections.Generic.List[string]
    $body.Add($lines[$start])
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^##\s' -or $lines[$i] -match '^---\s*$') { break }
        $body.Add($lines[$i])
    }
    $text = ($body -join "`n").Trim()
    if ($text.Length -gt 32000) { throw "Release notes for $version exceed 32000 chars ($($text.Length))" }
    return $text
}

$releaseNotes = Get-ReleaseNotes $widgetVersion

$commitId = git -C $repoRoot rev-parse --short HEAD 2>$null
if (-not $commitId) { $commitId = 'nogit' }
$commitId = $commitId.Trim()

$zipBase     = 'ETHOSMappingWidget-' + $widgetVersion + '-' + $commitId
$suiteZip    = Join-Path $buildDir ($zipBase + '-suite.zip')
$sdcardZip   = Join-Path $buildDir ($zipBase + '-sdcard.zip')

Write-Host '=== ETHOS Mapping Widget Build ===' -ForegroundColor Cyan
Write-Host "Version : $widgetVersion ($commitId)"
Write-Host "Package : $packageKey -> SCRIPTS:/$packageFolder/"
Write-Host "Release : $releaseDir"
if ($NoDeploy)      { Write-Host 'Deploy  : skipped (-NoDeploy)' }
elseif ($SimDir)    { Write-Host "Deploy  : $SimDir" }
else                { Write-Host 'Deploy  : skipped (no simulator configured in .vscode/settings.json)' -ForegroundColor Yellow }
Write-Host ''

# --- Clean ---

if (Test-Path $releaseDir) {
    Write-Host 'Cleaning previous release...' -ForegroundColor Yellow
    Remove-Item -Recurse -Force $releaseDir
}
foreach ($z in @($suiteZip, $sdcardZip)) { if (Test-Path $z) { Remove-Item -Force $z } }

# --- Stage ---

Write-Host 'Staging source files...' -ForegroundColor Green

New-Item -ItemType Directory -Path $scriptDst -Force | Out-Null
Copy-Item -Path (Join-Path $scriptSrc 'main.lua') -Destination $scriptDst
foreach ($dir in @('lib', 'audio', 'bitmaps')) {
    $dst = Join-Path $scriptDst $dir
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    Copy-Item -Path (Join-Path (Join-Path $scriptSrc $dir) '*') -Destination $dst
}

$manifest = [ordered]@{
    manifestVersion = 1
    name            = $packageName
    key             = $packageKey
    version         = $widgetVersion
    releaseNotes    = [ordered]@{ format = 'markdown'; content = $releaseNotes }
    folder          = $packageFolder
    files           = $packageFiles
}
$manifestJson = $manifest | ConvertTo-Json -Depth 4
$manifestPath = Join-Path $scriptDst $manifestName
[System.IO.File]::WriteAllText($manifestPath, $manifestJson, (New-Object System.Text.UTF8Encoding $false))

$fileCount = (Get-ChildItem -Path $scriptDst -Recurse -File).Count
Write-Host "Staged $fileCount files (incl. $manifestName)." -ForegroundColor Green

# --- ZIPs (forward-slash entry names; Compress-Archive on PS 5.1 writes backslashes) ---

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-ZipFromDir([string]$sourceDir, [string]$zipPath, [string]$entryPrefix) {
    $root = (Resolve-Path $sourceDir).Path.TrimEnd('\') + '\'
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in (Get-ChildItem -Path $sourceDir -Recurse -File | Sort-Object FullName)) {
            $rel = $f.FullName.Substring($root.Length).Replace('\', '/')
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $f.FullName, ($entryPrefix + $rel), [System.IO.Compression.CompressionLevel]::Optimal)
        }
    } finally {
        $zip.Dispose()
    }
}

Write-Host "Creating ZIPs..." -ForegroundColor Green
New-ZipFromDir $scriptDst $suiteZip ''
New-ZipFromDir $releaseDir $sdcardZip ''

# --- Validate Suite ZIP against the spec ---

function Test-SuiteZip([string]$zipPath) {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entries = @($zip.Entries | ForEach-Object { $_.FullName })
    } finally {
        $zip.Dispose()
    }
    $errors = @()
    if ($entries -notcontains $manifestName) { $errors += "no $manifestName at ZIP root" }
    if ($entries -notcontains 'main.lua')    { $errors += 'no main.lua at ZIP root' }
    foreach ($e in $entries) {
        if ($e.Contains('\'))                       { $errors += "backslash in entry '$e'" }
        if ($e.StartsWith('/') -or $e -match '(^|/)\.\.(/|$)') { $errors += "unsafe path '$e'" }
        if ($e -eq $manifestName) { continue }
        $covered = $false
        foreach ($p in $packageFiles) {
            if ($p.EndsWith('/**')) {
                if ($e.StartsWith($p.Substring(0, $p.Length - 2))) { $covered = $true }
            } elseif ($p.EndsWith('/*')) {
                $dir = $p.Substring(0, $p.Length - 1)
                if ($e.StartsWith($dir) -and -not $e.Substring($dir.Length).Contains('/')) { $covered = $true }
            } elseif ($e -eq $p) {
                $covered = $true
            }
        }
        if (-not $covered) { $errors += "entry '$e' is not covered by manifest files (would not be installed)" }
    }
    $parsed = (Get-Content (Join-Path $scriptDst $manifestName) -Raw -Encoding UTF8) | ConvertFrom-Json
    if ($parsed.manifestVersion -ne 1)                         { $errors += 'manifestVersion must be 1' }
    if ($parsed.key -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') { $errors += "invalid key '$($parsed.key)'" }
    if ($parsed.folder -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { $errors += "invalid folder '$($parsed.folder)'" }
    if ($parsed.name.Length -lt 1 -or $parsed.name.Length -gt 128) { $errors += 'name must be 1-128 chars' }
    if ($errors.Count -gt 0) { throw ("Suite ZIP validation failed:`n  " + ($errors -join "`n  ")) }
    return $entries.Count
}

$suiteEntries = Test-SuiteZip $suiteZip
Write-Host ("Suite ZIP  : {0} entries, {1} KB, manifest valid" -f $suiteEntries, [math]::Round((Get-Item $suiteZip).Length / 1KB, 1)) -ForegroundColor Green
Write-Host ("SD-card ZIP: {0} KB" -f [math]::Round((Get-Item $sdcardZip).Length / 1KB, 1)) -ForegroundColor Green

# --- Deploy to simulator ---

if (-not $NoDeploy -and $SimDir) {
    Write-Host 'Deploying to simulator...' -ForegroundColor Green

    $simScriptDst = Join-Path (Join-Path $SimDir 'scripts') $packageFolder
    New-Item -ItemType Directory -Path $simScriptDst -Force | Out-Null
    Copy-Item -Path (Join-Path $scriptDst 'main.lua') -Destination $simScriptDst -Force
    Copy-Item -Path $manifestPath -Destination $simScriptDst -Force
    foreach ($dir in @('lib', 'audio', 'bitmaps')) {
        $dst = Join-Path $simScriptDst $dir
        New-Item -ItemType Directory -Path $dst -Force | Out-Null
        Copy-Item -Path (Join-Path (Join-Path $scriptDst $dir) '*') -Destination $dst -Force

        # Mirror: drop files that no longer exist in src/ and stale bytecode caches,
        # otherwise ETHOS keeps loading deleted modules / outdated .luac files.
        $srcSub = Join-Path $scriptDst $dir
        foreach ($f in @(Get-ChildItem -Path $dst -File | Where-Object {
                -not (Test-Path (Join-Path $srcSub $_.Name)) -or $_.Extension -eq '.luac' })) {
            Write-Host "  removing stale $($f.FullName.Substring($SimDir.Length + 1))" -ForegroundColor Yellow
            Remove-Item -Force $f.FullName
        }
    }
    foreach ($f in @(Get-ChildItem -Path $simScriptDst -File -Filter '*.luac')) {
        Write-Host "  removing stale $($f.FullName.Substring($SimDir.Length + 1))" -ForegroundColor Yellow
        Remove-Item -Force $f.FullName
    }
}

Write-Host ''
Write-Host '=== Build complete ===' -ForegroundColor Cyan
Write-Host "  Release    : $releaseDir"
Write-Host "  Suite ZIP  : $suiteZip"
Write-Host "  SD-card ZIP: $sdcardZip"
if (-not $NoDeploy -and $SimDir) { Write-Host "  SIM        : $SimDir" }
