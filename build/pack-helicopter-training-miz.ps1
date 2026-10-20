# build/pack-helicopter-training-miz.ps1 - build a self-contained shipping .miz
# for the Helicopter Training Grounds range.
#
# The dev .miz is a "dumb loader": a MISSION START trigger does loadfile() on
# src/missions/helicopter-training/main.lua. That only works where the source
# tree exists. This script produces a .miz that carries the whole range inside
# its own mission file, so it runs on any install with no source tree and no
# de-sanitized environment.
#
# What it does:
#   1. Reads the eight range modules from src/missions/helicopter-training/
#   2. Strips the HTG:DEV-ONLY-BEGIN/END blocks (the loadfile fallbacks) so the
#      shipped payload touches no filesystem at all
#   3. Wraps each module as a local, builds the _G.HTG_PRELOADED table, and
#      appends main.lua - one self-contained Lua payload
#   4. Gates the payload against banned patterns, then syntax-checks it
#   5. Extracts the source .miz and rewrites the `mission` file: the MISSION
#      START trigger becomes one a_do_script action carrying that payload
#   6. Re-zips to out/helicopter-training.miz, leaving out/helicopter-training-build/
#      as an inspectable staging directory
#   7. Verifies the result: the rewritten mission file is loaded and the trigger
#      text is decoded back out and compared with the payload byte for byte
#
# The source .miz is never modified.
#
# Usage:
#   pwsh -File build/pack-helicopter-training-miz.ps1
#   pwsh -File build/pack-helicopter-training-miz.ps1 -SourceMiz "C:\path\to\range.miz"
#   pwsh -File build/pack-helicopter-training-miz.ps1 -DropRequiredModules

[CmdletBinding()]
param(
    [string]$SourceMiz = "",
    [string]$SrcRoot = "",
    [string]$OutDir = "",
    [string]$OutName = "helicopter-training.miz",
    [string]$BuildName = "helicopter-training-build",
    # Remove requiredModules from the shipped mission so players without the
    # UH-60L mod can still load it and fly the Chinook slot.
    [switch]$DropRequiredModules,
    # Copy the built .miz into the full-client Missions folder.
    [switch]$Install
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not $SrcRoot) { $SrcRoot = (Join-Path $PSScriptRoot "..\src") }
if (-not $OutDir) { $OutDir = (Join-Path $PSScriptRoot "..\out") }
if (-not $SourceMiz) {
    $SourceMiz = Join-Path $env:USERPROFILE "Saved Games\DCS\Missions\Helicopter Training Grounds.miz"
}
# Normalise every path: the defaults contain "..", and the zip step compares
# directory prefixes against resolved file paths.
$SrcRoot = [System.IO.Path]::GetFullPath($SrcRoot)
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
$SourceMiz = [System.IO.Path]::GetFullPath($SourceMiz)

$MissionFolder = Join-Path $SrcRoot "missions\helicopter-training"
$BuildDir = Join-Path $OutDir $BuildName
# Build artefacts (payload, source mission copy, re-extraction) live beside the
# staging directory so the staging directory mirrors the .miz exactly.
$ArtifactDir = Join-Path $OutDir "$BuildName-artifacts"
$OutMiz = Join-Path $OutDir $OutName

# Module load order for the payload. Names are the filenames the dev loaders use.
$Modules = @(
    "config.lua", "geo.lua", "notify.lua", "range.lua",
    "terrain.lua", "troops.lua", "progress.lua", "exercises.lua"
)

function ConvertTo-LuaStringBody {
    param([Parameter(Mandatory = $true)][string]$Text)
    # Escape for a Lua 5.1 short string. Order matters: backslashes first.
    # Newlines become backslash + LF, which is a Lua line continuation that
    # yields a newline in the value - the same form the mission editor writes.
    $escaped = $Text.Replace('\', '\\')
    $escaped = $escaped.Replace('"', '\"')
    $escaped = $escaped.Replace("`r`n", "\`n")
    $escaped = $escaped.Replace("`n", "\`n")
    return $escaped
}

function Remove-DevOnlyBlocks {
    param([Parameter(Mandatory = $true)][string]$Text)
    $beginMarker = '  -- HTG:DEV-ONLY-BEGIN'
    $endMarker = '  -- HTG:DEV-ONLY-END'
    $result = $Text
    while ($true) {
        $begin = $result.IndexOf($beginMarker)
        if ($begin -lt 0) { break }
        $beginLine = $result.LastIndexOf("`n", $begin) + 1
        $end = $result.IndexOf($endMarker, $begin)
        if ($end -lt 0) { throw "HTG:DEV-ONLY-BEGIN without a matching END" }
        $endLine = $result.IndexOf("`n", $end)
        if ($endLine -lt 0) { $endLine = $result.Length } else { $endLine = $endLine + 1 }
        $result = $result.Remove($beginLine, $endLine - $beginLine)
    }
    return $result
}

# ---------------------------------------------------------------- build payload

Write-Host "Helicopter Training Grounds - shipping build"
Write-Host "  source .miz : $SourceMiz"
Write-Host "  source tree : $MissionFolder"

if (-not (Test-Path $SourceMiz)) { throw "source .miz not found: $SourceMiz" }
if (-not (Test-Path $MissionFolder)) { throw "mission source folder not found: $MissionFolder" }

$payload = New-Object System.Text.StringBuilder
[void]$payload.AppendLine("-- Helicopter Training Grounds - self-contained shipping payload.")
[void]$payload.AppendLine("-- Generated by build/pack-helicopter-training-miz.ps1 from")
[void]$payload.AppendLine("-- src/missions/helicopter-training/. Do not edit: edit the source modules.")
[void]$payload.AppendLine("--")
[void]$payload.AppendLine("-- No filesystem access: the modules are pre-assembled below, and the")
[void]$payload.AppendLine("-- dev-only loadfile fallbacks have been stripped.")
[void]$payload.AppendLine("")

foreach ($module in $Modules) {
    $path = Join-Path $MissionFolder $module
    if (-not (Test-Path $path)) { throw "missing module: $path" }
    $source = [System.IO.File]::ReadAllText($path)
    $source = Remove-DevOnlyBlocks -Text $source
    $source = $source -replace "`r`n", "`n"

    $id = $module -replace '\.lua$', ''
    $id = $id -replace '-', '_'
    [void]$payload.AppendLine("local htg_$id = (function()")
    [void]$payload.AppendLine($source.TrimEnd())
    [void]$payload.AppendLine("end)()")
    [void]$payload.AppendLine("")
}

[void]$payload.AppendLine("_G.HTG_PRELOADED = {")
foreach ($module in $Modules) {
    $id = $module -replace '\.lua$', ''
    $id = $id -replace '-', '_'
    [void]$payload.AppendLine("  [""$module""] = htg_$id,")
}
[void]$payload.AppendLine("}")
[void]$payload.AppendLine("")

$mainSource = [System.IO.File]::ReadAllText((Join-Path $MissionFolder "main.lua"))
$mainSource = Remove-DevOnlyBlocks -Text $mainSource
$mainSource = $mainSource -replace "`r`n", "`n"
[void]$payload.AppendLine("(function()")
[void]$payload.AppendLine($mainSource.TrimEnd())
[void]$payload.AppendLine("end)()")

$payloadText = $payload.ToString() -replace "`r`n", "`n"

# ------------------------------------------------------------------ payload gate

$banned = @(
    'os\.', 'io\.', 'lfs\.', 'require\(', 'dofile\(', 'loadfile\(', 'loadstring\(',
    'MY_SCRIPTS_ROOT', 'HTG:DEV-ONLY'
)
foreach ($pattern in $banned) {
    $hits = [regex]::Matches($payloadText, "^.*$pattern.*$", 'Multiline') |
        Where-Object { $_.Value -notmatch '^\s*--' } |
        ForEach-Object { $_.Value }
    if ($hits) {
        throw "Refusing to ship: '$pattern' found in the payload:`n$($hits -join "`n")"
    }
}
Write-Host "  payload gate: OK ($([math]::Round($payloadText.Length / 1024, 1)) KiB, no filesystem access)"

# ------------------------------------------------------------------ staging dir

if (Test-Path $BuildDir) { Remove-Item $BuildDir -Recurse -Force }
if (Test-Path $ArtifactDir) { Remove-Item $ArtifactDir -Recurse -Force }
New-Item -ItemType Directory -Path $BuildDir | Out-Null
New-Item -ItemType Directory -Path $ArtifactDir | Out-Null
$stagingZip = Join-Path $ArtifactDir "source.zip"
Copy-Item $SourceMiz $stagingZip -Force
[System.IO.Compression.ZipFile]::ExtractToDirectory($stagingZip, $BuildDir)
Remove-Item $stagingZip -Force

$missionFile = Join-Path $BuildDir "mission"
if (-not (Test-Path $missionFile)) { throw "the source .miz has no 'mission' entry" }
$sourceMissionCopy = Join-Path $ArtifactDir "mission.source"
Copy-Item $missionFile $sourceMissionCopy -Force

# --------------------------------------------------------------- rewrite trigger

$missionText = [System.IO.File]::ReadAllText($missionFile)

$trigPattern = '(?s)\["trig"\] = \s*\{.*?\}, -- end of \["trig"\]'
$trigRulesPattern = '(?s)\["trigrules"\] = \s*\{\},'
if ([regex]::Matches($missionText, $trigPattern).Count -ne 1) {
    throw "expected exactly one empty [trig] block in the mission file"
}
if ([regex]::Matches($missionText, $trigRulesPattern).Count -ne 1) {
    throw "expected exactly one empty [trigrules] block in the mission file"
}

$scriptText = $payloadText.TrimEnd("`n")
$escapedOnce = ConvertTo-LuaStringBody -Text $scriptText
$escapedTwice = ConvertTo-LuaStringBody -Text $escapedOnce

$trigBlock = @"
["trig"] = 
	{
		["actions"] = 
		{
			[1] = "a_do_script(\"$escapedTwice\");",
		}, -- end of ["actions"]
		["events"] = {},
		["custom"] = {},
		["func"] = {},
		["flag"] = 
		{
			[1] = true,
		}, -- end of ["flag"]
		["conditions"] = 
		{
			[1] = "return(true)",
		}, -- end of ["conditions"]
		["customStartup"] = {},
		["funcStartup"] = 
		{
			[1] = "if mission.trig.conditions[1]() then mission.trig.actions[1]() end",
		}, -- end of ["funcStartup"]
	}, -- end of ["trig"]
"@

$trigRulesBlock = @"
["trigrules"] = 
	{
		[1] = 
		{
			["rules"] = {},
			["eventlist"] = "",
			["actions"] = 
			{
				[1] = 
				{
					["text"] = "$escapedOnce",
					["predicate"] = "a_do_script",
				}, -- end of [1]
			}, -- end of ["actions"]
			["predicate"] = "triggerStart",
			["comment"] = "Helicopter Training Grounds range",
		}, -- end of [1]
	}, -- end of ["trigrules"]
"@

$missionText = [regex]::Replace($missionText, $trigPattern, { param($m) $trigBlock.TrimEnd("`n") }, 1)
$missionText = [regex]::Replace($missionText, $trigRulesPattern, { param($m) $trigRulesBlock.TrimEnd("`n") }, 1)

if ($DropRequiredModules) {
    $requiredPattern = '(?s)\s*\["requiredModules"\] = \s*\{.*?\}, -- end of \["requiredModules"\]'
    if ([regex]::Matches($missionText, $requiredPattern).Count -eq 1) {
        $missionText = [regex]::Replace($missionText, $requiredPattern, "", 1)
        Write-Host "  requiredModules: dropped (players without the UH-60L mod can load the mission)"
    } else {
        Write-Warning "requiredModules not found; nothing dropped"
    }
}

[System.IO.File]::WriteAllText($missionFile, $missionText, (New-Object System.Text.UTF8Encoding $false))

# -------------------------------------------------------------------- re-zip

$payloadPath = Join-Path $ArtifactDir "helicopter-training-payload.lua"
[System.IO.File]::WriteAllText($payloadPath, $payloadText, (New-Object System.Text.UTF8Encoding $false))

if (Test-Path $OutMiz) { Remove-Item $OutMiz -Force }
$archive = [System.IO.Compression.ZipFile]::Open($OutMiz, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem $BuildDir -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($BuildDir.Length + 1).Replace('\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive, $_.FullName, $relative, [System.IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $archive.Dispose()
}
Write-Host "  wrote $OutMiz ($([math]::Round((Get-Item $OutMiz).Length / 1024, 1)) KiB)"

# ---------------------------------------------------------------- verification

$lua = Get-Command lua5.1 -ErrorAction SilentlyContinue
if (-not $lua) { throw "lua5.1 is required for the payload and mission-file checks" }

$syntax = & lua5.1 -e "local f, e = loadfile([[$payloadPath]]); if f then print('ok') else print('FAIL: ' .. tostring(e)) end"
if ($syntax -notmatch '^ok') { throw "payload syntax check failed: $syntax" }
Write-Host "  payload syntax: OK"

$verifyScript = Join-Path $PSScriptRoot "..\tests\lua\verify-htg-mission-file.lua"
$verifyOutput = & lua5.1 $verifyScript $missionFile $payloadPath 2>&1
if ($LASTEXITCODE -ne 0) { throw "mission-file verification failed:`n$verifyOutput" }
Write-Host "  mission file: $verifyOutput"

$diffScript = Join-Path $PSScriptRoot "..\tests\test-htg-mission-diff.ps1"
$diffOutput = & pwsh -NoProfile -File $diffScript -SourceMission $sourceMissionCopy -BuiltMission $missionFile 2>&1
if ($LASTEXITCODE -ne 0) { throw "mission diff verification failed:`n$diffOutput" }
Write-Host "  mission diff: $diffOutput"

# Re-extract from the built .miz and verify that copy too, so the check covers
# what a player actually downloads.
$recheckDir = Join-Path $ArtifactDir "recheck"
if (Test-Path $recheckDir) { Remove-Item $recheckDir -Recurse -Force }
New-Item -ItemType Directory -Path $recheckDir | Out-Null
$zip = [System.IO.Compression.ZipFile]::OpenRead($OutMiz)
try {
    $entry = $zip.Entries | Where-Object { $_.FullName -eq 'mission' }
    if (-not $entry) { throw "the built .miz has no 'mission' entry" }
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $recheckDir "mission"), $true)
    $names = ($zip.Entries | ForEach-Object { $_.FullName }) -join ", "
} finally {
    $zip.Dispose()
}
$recheckOutput = & lua5.1 $verifyScript (Join-Path $recheckDir "mission") $payloadPath 2>&1
if ($LASTEXITCODE -ne 0) { throw "built .miz verification failed:`n$recheckOutput" }
Write-Host "  built .miz re-check: $recheckOutput"
Write-Host "  entries: $names"

# Run the payload itself against the DCS mocks: proves the shipped code boots
# the range with no source tree and no filesystem access at all.
$shippedTest = Join-Path $PSScriptRoot "..\tests\lua\run-helicopter-training-shipped.lua"
$shippedOutput = & lua5.1 $shippedTest $payloadPath 2>&1
if ($LASTEXITCODE -ne 0) { throw "shipped payload behaviour check failed:`n$shippedOutput" }
Write-Host "  payload behaviour: $shippedOutput"

if ($Install) {
    $target = Join-Path $env:USERPROFILE "Saved Games\DCS\Missions\$OutName"
    Copy-Item $OutMiz $target -Force
    Write-Host "  installed: $target"
}

Write-Host "Done."
Write-Host "  .miz staging : $BuildDir"
Write-Host "  build output : $ArtifactDir"
