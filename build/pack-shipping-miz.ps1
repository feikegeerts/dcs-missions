# build/pack-shipping-miz.ps1 - build a self-contained shipping .miz.
#
# The dev .miz is a "dumb loader" that does loadfile() on
# C:\Projects\dcs-missions\src\bootstrap.lua, which only works on this
# dev box with a de-sanitized MissionScripting.lua. To ship, we have to
# produce a self-contained .miz that runs on a stock DCS install.
#
# What this does:
#   1. Reads the dev .miz (default: server's Missions folder)
#   2. Extracts to a temp working dir
#   3. Rewrites the MISSION START trigger in the `mission` file by
#      finding the unique anchor strings the ME emits, and splicing in
#      the shipping action lists. No regex on Lua string contents (the
#      dev .miz's loadfile string has lots of \" and \<LF> escapes that
#      make regex brittle). Pure substring search/replace.
#   4. Embeds the shipping Lua sources as DCS resources under l10n/DEFAULT:
#        - Moose_.lua   (copied from src/lib/Moose_.lua)
#        - main.lua     (synthesized: inlines score.lua and
#                               patches the dev main.lua for stock
#                               DCS - strips TraceOn, replaces os.time()
#                               with timer.getTime()*1000, removes the
#                               dispatcher-driven dofile(score.lua))
#   5. Re-zips into out/duel-dynamic.miz (the shipping artifact)
#
# The dev .miz is NEVER overwritten. The dev workflow (edit src/, restart
# the mission) is unchanged. Run this script only when shipping a build.
#
# Usage:
#   pwsh -File build\pack-shipping-miz.ps1
#   pwsh -File build\pack-shipping-miz.ps1 -DevMizPath "C:\path\to\duel-dynamic.miz"

[CmdletBinding()]
param(
    [string]$DevMizPath = "$env:USERPROFILE\Saved Games\DCS.dcs_serverrelease\Missions\duel-dynamic.miz",
    [string]$SrcRoot    = "",
    [string]$OutDir     = "",
    [string]$BuildName  = "duel-dynamic-build",
    [string]$OutName    = "duel-dynamic.miz",
    [switch]$Zip        = $false
)

# Default $SrcRoot and $OutDir relative to this script's location. Done in
# the body (not the param block) because PS 5.1 doesn't reliably see
# $PSScriptRoot inside param default expressions.
if (-not $SrcRoot) { $SrcRoot = (Join-Path $PSScriptRoot "..\src") }
if (-not $OutDir)  { $OutDir  = (Join-Path $PSScriptRoot "..\out") }

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-PortableZipFromDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    # Zip entry names always use forward slashes. ZipFile.CreateFromDirectory()
    # preserves Windows backslashes in entry names under Windows PowerShell 5.1;
    # DCS resource lookup expects l10n/DEFAULT/<file>, so those archives silently
    # fail to resolve DO SCRIPT FILE resources.
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

# Resolve inputs.
if (-not (Test-Path -LiteralPath $DevMizPath)) {
    throw "Dev .miz not found: $DevMizPath. Edit -DevMizPath or save the mission first."
}
$DevMizPath = (Resolve-Path -LiteralPath $DevMizPath).Path
foreach ($nameParameter in @(
    @{ Name = 'BuildName'; Value = $BuildName },
    @{ Name = 'OutName'; Value = $OutName }
)) {
    $value = $nameParameter.Value
    if ([string]::IsNullOrWhiteSpace($value) -or
        [System.IO.Path]::IsPathRooted($value) -or
        [System.IO.Path]::GetFileName($value) -cne $value -or
        $value -in @('.', '..')) {
        throw "$($nameParameter.Name) must be a file or directory name, not a path: $value"
    }
}
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
$mooseSrc = Join-Path $SrcRoot "lib\Moose_.lua"
if (-not (Test-Path -LiteralPath $mooseSrc)) {
    throw "Moose_.lua not found: $mooseSrc"
}
$devMain  = Join-Path $SrcRoot "missions\duel-dynamic\main.lua"
$devScore = Join-Path $SrcRoot "missions\duel-dynamic\score.lua"
foreach ($f in @($devMain, $devScore)) {
    if (-not (Test-Path -LiteralPath $f)) {
        throw "Dev source not found: $f"
    }
}

# Build dir lives under out/ so it's easy to inspect and so the user
# can inspect the exact generated payload. Wiped on every run so it always
# reflects the current dev .miz + src/; make changes in src/, not staging.
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$workDir = Join-Path $OutDir $BuildName
if ([System.StringComparer]::OrdinalIgnoreCase.Equals(
    [System.IO.Path]::GetFullPath($workDir),
    [System.IO.Path]::GetFullPath($DevMizPath)
)) {
    throw "Build directory must not overwrite the dev .miz: $DevMizPath"
}
if (Test-Path -LiteralPath $workDir) {
    Write-Host "Cleaning previous build at $workDir ..."
    Remove-Item -LiteralPath $workDir -Recurse -Force
}
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
Write-Host "Build dir: $workDir"

try {
    # --- 1. Extract dev .miz into workDir ---
    Write-Host "Extracting $DevMizPath ..."
    [System.IO.Compression.ZipFile]::ExtractToDirectory($DevMizPath, $workDir)

    $missionPath = Join-Path $workDir "mission"
    if (-not (Test-Path -LiteralPath $missionPath)) {
        throw "Extracted .miz has no `mission` file"
    }
    $mission = [System.IO.File]::ReadAllText($missionPath, [System.Text.Encoding]::UTF8)

    # --- 2. Rewrite the trigrules (modern) block ---
    # The dev trigrules triggerStart entry has a single a_do_script action
    # inside its [1] entry. We replace JUST that one inner entry (not the
    # surrounding actions array, comment, or outer trigrules[1] close)
    # with two a_do_script_file actions. The dev's inner entry looks like:
    #
    #     [1] =
    #     {
    #         ["text"] = "...",
    #         ["predicate"] = "a_do_script",
    #     }, -- end of [1]
    #
    # Use a regex (with `(?s)` so . matches newlines across the inner
    # script string) anchored on the unique `["predicate"] = "a_do_script"`
    # marker. The Lua-string pattern `"(?:[^"\\]|\\.)*"` handles the
    # escaped-quote/backslash sequences in the dev's loadfile string.
    $trigrulesPattern = '(?s)\[1\]\s*=\s*\{\s*\["text"\]\s*=\s*"(?:[^"\\]|\\.)*"\s*,\s*\["predicate"\]\s*=\s*"a_do_script",?\s*\}\s*,\s*-- end of \[1\]'
    $m = [regex]::Match($mission, $trigrulesPattern)
    if (-not $m.Success) {
        throw "trigrules (modern): pattern not found. Dev .miz structure may have changed."
    }

    # The replacement is two a_do_script_file actions. The match consumed
    # the original [1] entry through `}, -- end of [1]`. Indent matches
    # the dev .miz: 4 tabs before [1] = and {, 5 tabs before the inner
    # fields, 4 tabs before }, -- end of [1]. The replacement includes
    # the trailing \n so the next line (}, -- end of ["actions"]) starts
    # on its own line.
    # Indent: original 4 tabs before [1] = are preserved from the file
    # (they're before the match). Replacement starts with [1] = (no tabs).
    $mooseResourceKey = "ResKey_Action_duel_dynamic_moose"
    $mainResourceKey = "ResKey_Action_duel_dynamic_main"
    $newInnerActions = "[1] =`n`t`t`t`t{`n`t`t`t`t`t[`"file`"] = `"$mooseResourceKey`",`n`t`t`t`t`t[`"predicate`"] = `"a_do_script_file`",`n`t`t`t`t}, -- end of [1]`n`t`t`t`t[2] =`n`t`t`t`t{`n`t`t`t`t`t[`"file`"] = `"$mainResourceKey`",`n`t`t`t`t`t[`"predicate`"] = `"a_do_script_file`",`n`t`t`t`t}, -- end of [2]"
    $mission = $mission.Substring(0, $m.Index) + $newInnerActions + $mission.Substring($m.Index + $m.Length)
    Write-Host "Patched trigrules block (modern)"

    # --- 3. Rewrite the trig (legacy) block ---
    # The dev trig legacy block's actions[1] is a Lua string literal:
    #     [1] = "a_do_script(\"...end\");",
    # followed by the actions array close:
    #     }, -- end of ["actions"]
    #
    # The end-anchor "end\");"" uniquely identifies the close of the
    # dev's loadfile call (the inner content always ends with
    # `tostring(err)) end");`).
    $trigStartAnchor = '[1] = "a_do_script('
    # The dev's loadfile script string always ends with: end\");
    # That's 5 chars in the file: e n d \ " ) ; — wait actually 6:
    #   e n d \ " ) ;
    # In PowerShell, single-quoted strings are literal, so we write the
    # backslash and quote directly.
    $trigEndAnchor   = 'end\");",'

    $tStart = $mission.IndexOf($trigStartAnchor)
    if ($tStart -lt 0) {
        throw "trig (legacy): start anchor not found."
    }
    $tEnd = $mission.IndexOf($trigEndAnchor, $tStart)
    if ($tEnd -lt 0) {
        throw "trig (legacy): end anchor not found. The dev source may have changed."
    }
    $tEnd = $tEnd + $trigEndAnchor.Length  # include the trailing ","

    # The legacy trig block's actions[1] is itself a Lua string literal
    # in the mission file. Inside it, the inner quotes around the path
    # must be escaped with backslash (the ME's own format uses this).
    # Path uses forward slashes so it doesn't need further escaping.
$newTrigAction = @"
[1] = "a_do_script_file(getValueResourceByKey(\"$mooseResourceKey\"));",
			[2] = "a_do_script_file(getValueResourceByKey(\"$mainResourceKey\"));",
"@
    $mission = $mission.Substring(0, $tStart) + $newTrigAction + $mission.Substring($tEnd)
    Write-Host "Patched trig block (legacy) actions"

    # --- 4. Update the trig.flag block to have two enabled actions ---
    # The dev .miz's flag block is at 2-tab indent:
    #     ["flag"] =
    #     {
    #         [1] = true,
    #     }, -- end of ["flag"]
    # Pattern includes the 3 tabs before [1] so the replacement doesn't
    # double up on indent. The dev .miz's flag block is at 2-tab indent:
    #     ["flag"] =
    #     {
    #         [1] = true,        # 3-tab indent
    #     }, -- end of ["flag"]  # 2-tab indent
    $flagPattern = "`t`t`t[1] = true,`n`t`t}, -- end of [`"flag`"]"
    $flagReplace = @'
			[1] = true,
			[2] = true,
		}, -- end of ["flag"]
'@
    $flagIdx = $mission.IndexOf($flagPattern)
    if ($flagIdx -ge 0) {
        $mission = $mission.Substring(0, $flagIdx) + $flagReplace + $mission.Substring($flagIdx + $flagPattern.Length)
        Write-Host "Patched trig.flag block"
    } else {
        Write-Host "Note: trig.flag block not updated (block already had multiple entries?)"
    }

    # The legacy startup function explicitly invokes action 1. Extend it to
    # invoke action 2 as well; otherwise a runtime using the legacy trig table
    # can load MOOSE without ever starting the mission script.
    $startupAction = '[1] = "if mission.trig.conditions[1]() then mission.trig.actions[1]() end",'
    $startupReplacement = '[1] = "if mission.trig.conditions[1]() then mission.trig.actions[1]() mission.trig.actions[2]() end",'
    $startupIdx = $mission.IndexOf($startupAction)
    if ($startupIdx -lt 0) {
        throw "trig.funcStartup action not found"
    }
    $mission = $mission.Substring(0, $startupIdx) + $startupReplacement + $mission.Substring($startupIdx + $startupAction.Length)
    Write-Host "Patched trig.funcStartup block"

    # DO SCRIPT FILE actions reference resource keys, not arbitrary archive
    # paths. Register both embedded payloads in mapResource; DCS resolves those
    # names under l10n/DEFAULT at mission start. Literal "Scripts/..." paths are
    # silently ignored by stock DCS.
    $resourceDir = Join-Path $workDir "l10n\DEFAULT"
    $mapResourcePath = Join-Path $resourceDir "mapResource"
    if (-not (Test-Path -LiteralPath $mapResourcePath)) {
        throw "Extracted .miz has no l10n/DEFAULT/mapResource file"
    }
    $mapResource = [System.IO.File]::ReadAllText($mapResourcePath, [System.Text.Encoding]::UTF8)
    foreach ($resourceKey in @($mooseResourceKey, $mainResourceKey)) {
        if ($mapResource.Contains($resourceKey)) {
            throw "mapResource already contains shipping key '$resourceKey'"
        }
    }
    $mapResourceClose = $mapResource.LastIndexOf("}")
    if ($mapResourceClose -lt 0) {
        throw "l10n/DEFAULT/mapResource has no closing brace"
    }
    $resourceEntries = "`r`n`t[`"$mooseResourceKey`"] = `"Moose_.lua`",`r`n`t[`"$mainResourceKey`"] = `"main.lua`",`r`n"
    $mapResource = $mapResource.Substring(0, $mapResourceClose) + $resourceEntries + $mapResource.Substring($mapResourceClose)
    [System.IO.File]::WriteAllText($mapResourcePath, $mapResource, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "Registered embedded scripts in mapResource"

    # Write back the modified mission file.
    [System.IO.File]::WriteAllText($missionPath, $mission, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "Wrote modified mission file"

    # --- 5. Synthesize l10n/DEFAULT/main.lua ---
    Write-Host "Synthesizing l10n/DEFAULT/main.lua ..."
    $scriptsDir = $resourceDir
    New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null

    $devMainText  = [System.IO.File]::ReadAllText($devMain)

    # Strip the dofile(score.lua) and MY_SCRIPTS_ROOT lookup block from the
    # dev main.lua; that logic only exists in dev. The inlined score module
    # below replaces it.
    $rootBlockPattern = '(?ms)^\s*--\s*Load siblings\.[\s\S]*?^dofile\(DIR \.\. "score\.lua"\)\s*\r?\n'
    $devMainText = [regex]::Replace($devMainText, $rootBlockPattern, '')

    # Belt-and-suspenders: also strip the `local ROOT = _G.MY_SCRIPTS_ROOT
    # ... end` block if the previous regex missed it.
    $rootLookupPattern = '(?ms)^\s*--\s*Load siblings[\s\S]*?^end\s*\r?\n'
    $devMainText = [regex]::Replace($devMainText, $rootLookupPattern, '')

    # Replace os.time() (nilled in stock DCS) with timer.getTime()*1000.
    $devMainText = $devMainText -replace 'os\.time\(\)\s*%\s*2147483648', 'math.floor(timer.getTime() * 1000) % 2147483648'

    # Strip the dev `main start` breadcrumb; shipping has its own.
    $devMainText = $devMainText -replace '(?m)^env\.info\("\[duel-dynamic\] main start"\)\r?\n', ''

    # Sanity check: no TraceOn / os.* / io.* / lfs.* in shipping code (outside
    # comments). Fails the build with a clear error if any are present.
    $banned = @('TraceOn', 'TraceLevel', 'os\.', 'io\.open', 'lfs\.')
    foreach ($b in $banned) {
        $hits = [regex]::Matches($devMainText, "^.*$b.*$", 'Multiline') |
            Where-Object { $_.Value -notmatch '^\s*--' } |
            ForEach-Object { $_.Value }
        if ($hits) {
            throw "Refusing to ship: '$b' found in code (not just comments):`n$($hits -join "`n")"
        }
    }

    $shippingHeader = @'
-- main.lua - SHIPPING BUILD resource for duel-dynamic.
-- Generated by build/pack-shipping-miz.ps1 from src/missions/duel-dynamic/.
-- DO NOT EDIT BY HAND - edit the dev sources and re-run the packager.
--
-- This file is loaded as the second DO SCRIPT FILE resource in the .miz's
-- MISSION START trigger (after Moose_.lua). MOOSE is already in _G.
--
-- Diff vs the dev main.lua:
--   * score.lua is INLINED below (no dofile() in stock DCS - the CWD is
--     the DCS install dir, not the mission's .miz directory).
--   * The _G.MY_SCRIPTS_ROOT lookup is removed.
--   * os.time() (nilled in stock DCS) is replaced with
--     math.floor(timer.getTime() * 1000) - see the RNG seed line.
--
-- Known limitation (carried over from dev): round-1 player position is
-- the ME position (DCS ignores setPosition on client-controlled player
-- slots in MP). Round N+1 works because the death respawn path forces
-- the client to refresh. See docs/spec-duel-dynamic.md §6.1.

env.info("[duel-dynamic] shipping build start")

if not _G.BASE then
  env.error("[duel-dynamic] MOOSE not loaded - check the Moose_.lua resource in the .miz")
  return
end

env.info("[duel-dynamic] MOOSE loaded")

-- =====================================================================
-- Inlined score module (was src/missions/duel-dynamic/score.lua)
-- Pure logic, no DCS API - kept here so the shipping .miz is self-contained.
-- =====================================================================
local Tracker = {}
Tracker.kills = {} -- [playerName] = count
Tracker.total = 0

function Tracker:record(playerName)
  if not playerName or playerName == "" then
    return
  end
  self.kills[playerName] = (self.kills[playerName] or 0) + 1
  self.total = self.total + 1
end

function Tracker:reset()
  self.kills = {}
  self.total = 0
end

function Tracker:format()
  if self.total == 0 then
    return "Kills: 0"
  end
  local lines = { string.format("Kills: %d", self.total) }
  local names = {}
  for n, _ in pairs(self.kills) do
    names[#names + 1] = n
  end
  table.sort(names)
  for _, n in ipairs(names) do
    lines[#lines + 1] = string.format("  %s: %d", n, self.kills[n])
  end
  return table.concat(lines, "\n")
end

_G.duel_tracker = Tracker

if not _G.duel_tracker then
  env.error("[duel-dynamic] inlined score module failed to set _G.duel_tracker")
  return
end

-- =====================================================================
-- End of inlined score module. The original main.lua follows.
-- =====================================================================

'@

    $shippingMain = $shippingHeader + "`r`n" + $devMainText
    $shippingMainPath = Join-Path $scriptsDir "main.lua"
    [System.IO.File]::WriteAllText($shippingMainPath, $shippingMain, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "  wrote $shippingMainPath ($((Get-Item $shippingMainPath).Length) bytes)"

    # --- 6. Copy l10n/DEFAULT/Moose_.lua ---
    Write-Host "Copying l10n/DEFAULT/Moose_.lua ..."
    $mooseDest = Join-Path $scriptsDir "Moose_.lua"
    [System.IO.File]::Copy($mooseSrc, $mooseDest, $true)
    Write-Host "  wrote $mooseDest ($((Get-Item $mooseDest).Length) bytes)"

    # --- 7. Re-zip into out/<OutName> (only if -Zip) ---
    if ($Zip) {
        $outPath = Join-Path $OutDir $OutName
        if ([System.StringComparer]::OrdinalIgnoreCase.Equals(
            [System.IO.Path]::GetFullPath($outPath),
            [System.IO.Path]::GetFullPath($DevMizPath)
        )) {
            throw "Output .miz must not overwrite the dev .miz: $DevMizPath"
        }
        if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force }
        New-PortableZipFromDirectory -SourceDirectory $workDir -DestinationPath $outPath

        Write-Host ""
        Write-Host "Entries in ${outPath}:" -ForegroundColor Cyan
        # PowerShell variable names are case-insensitive. Do not call this
        # `$zip`: that would overwrite the [switch]$Zip parameter above.
        $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($outPath)
        try {
            $invalidEntries = @($zipArchive.Entries | Where-Object { $_.FullName.Contains('\') })
            if ($invalidEntries.Count -gt 0) {
                throw "Shipping archive contains Windows-style entry names: $($invalidEntries.FullName -join ', ')"
            }
            foreach ($requiredResource in @('l10n/DEFAULT/Moose_.lua', 'l10n/DEFAULT/main.lua')) {
                if (-not ($zipArchive.Entries | Where-Object { $_.FullName -ceq $requiredResource })) {
                    throw "Shipping archive is missing DCS resource entry '$requiredResource'"
                }
            }
            $zipArchive.Entries | Sort-Object FullName | ForEach-Object {
                Write-Host ("  {0,-40} {1,12} bytes" -f $_.FullName, $_.Length)
            }
        } finally {
            $zipArchive.Dispose()
        }

        Write-Host ""
        Write-Host "Packed: $outPath" -ForegroundColor Green
        Write-Host "Size:   $((Get-Item $outPath).Length) bytes"
    } else {
        Write-Host ""
        Write-Host "Build tree left at: $workDir" -ForegroundColor Yellow
        Write-Host "Inspect / edit it, then re-zip with:" -ForegroundColor Yellow
        Write-Host "  pwsh -File build\pack-shipping-miz.ps1 -Zip  # to re-run + auto-zip"
        Write-Host "  Re-run this command with -Zip after making source changes. Do not use Compress-Archive;" -ForegroundColor Yellow
        Write-Host "  on Windows it can create backslash entry names that DCS cannot resolve as resources." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Test on a STOCK (sanitized) DCS install. See docs/shipping-duel-dynamic.md section 5."
    Write-Host "  2. Drop the .miz into Saved Games\DCS.dcs_serverrelease\Missions\ on the server."
    Write-Host "  3. Watch Saved Games\DCS.dcs_serverrelease\Logs\dcs.log for 'MOOSE INCLUDE END' and"
    Write-Host "     '[duel-dynamic] ...' breadcrumbs."
}
# Note: we do NOT clean up $workDir in finally. It remains available for
# inspection; make changes in src/ and re-run because the next build wipes it.
finally {
    # intentionally empty — see comment above
}
