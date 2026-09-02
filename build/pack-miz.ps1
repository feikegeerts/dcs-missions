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

    [string]$MissionsDir = "",
    [string]$OutDir      = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

if (-not $MissionsDir) { $MissionsDir = (Join-Path $PSScriptRoot "..\missions") }
if (-not $OutDir) { $OutDir = (Join-Path $PSScriptRoot "..\out") }

function New-PortableZipFromDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $sourcePath = [System.IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\', '/')
    $outputStream = $null
    $archive = $null
    try {
        $outputStream = [System.IO.File]::Open($DestinationPath, [System.IO.FileMode]::CreateNew)
        $archive = New-Object System.IO.Compression.ZipArchive(
            $outputStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false
        )

        $files = [System.IO.Directory]::GetFiles(
            $sourcePath,
            '*',
            [System.IO.SearchOption]::AllDirectories
        ) | Sort-Object
        foreach ($filePath in $files) {
            $entryName = $filePath.Substring($sourcePath.Length + 1).Replace('\', '/')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive,
                $filePath,
                $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        if ($null -ne $outputStream) { $outputStream.Dispose() }
    }
}

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
        New-PortableZipFromDirectory -SourceDirectory (Get-Location).Path -DestinationPath $out
    }
}
finally {
    Pop-Location
}

$archive = [System.IO.Compression.ZipFile]::OpenRead($out)
try {
    $invalidEntries = @($archive.Entries | Where-Object { $_.FullName.Contains('\') })
    if ($invalidEntries.Count -gt 0) {
        throw "Archive contains Windows-style entry names: $($invalidEntries.FullName -join ', ')"
    }
} finally {
    $archive.Dispose()
}

Write-Host "Packed: $out" -ForegroundColor Green
Write-Host "Size:   $((Get-Item $out).Length) bytes"
