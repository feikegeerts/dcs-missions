# build/pack-miz.ps1 — pack missions\<name>\ into out\<name>.miz
# Shipping only. During dev, the .miz is a dumb loader that reads from disk
# — no repack needed.
#
# Usage:   pwsh -File build\pack-miz.ps1 -MissionName <name>
#          pwsh -File build\pack-miz.ps1 -MissionName <name> -Use7Zip
#
# Requirements:
#   - missions\<name>\  exists and is an unpacked .miz tree (mission, options,
#     warehouses, l10n\DEFAULT\dictionary, plus embedded scripts if shipping static)
#   - 7-Zip on PATH (optional but recommended; 7z.exe). Falls back to .NET ZipFile.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$MissionName,

    [switch]$Use7Zip,

    [string]$MissionsDir = (Join-Path $PSScriptRoot "..\missions"),
    [string]$OutDir      = (Join-Path $PSScriptRoot "..\out")
)

$ErrorActionPreference = "Stop"

$src = Join-Path $MissionsDir $MissionName
if (-not (Test-Path -LiteralPath $src)) {
    throw "Mission tree not found: $src"
}

$required = @("mission", "options", "warehouses", "l10n\DEFAULT\dictionary")
foreach ($r in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $src $r))) {
        throw "Missing required .miz entry: $r  (in $src)"
    }
}

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$out = Join-Path $OutDir "$MissionName.miz"
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }

Push-Location $src
try {
    if ($Use7Zip -or (Get-Command 7z.exe -ErrorAction SilentlyContinue)) {
        $sevenZip = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source
        if (-not $sevenZip) { $sevenZip = "C:\Program Files\7-Zip\7z.exe" }
        if (-not (Test-Path -LiteralPath $sevenZip)) {
            throw "7z.exe not found. Pass -Use7Zip only if installed, or remove it to use .NET."
        }
        & $sevenZip a -tzip -mx=5 -- $out "./\*" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "7z exited with $LASTEXITCODE" }
    } else {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            (Get-Location).Path,
            $out,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $false  # includeBaseDirectory = false: entries are mission, options, ...
        ) | Out-Null
    }
}
finally {
    Pop-Location
}

Write-Host "Packed: $out" -ForegroundColor Green
Write-Host "Size:   $((Get-Item $out).Length) bytes"
