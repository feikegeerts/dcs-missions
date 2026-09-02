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
#   4. Embeds the shipping Lua sources into Scripts/ inside the .miz:
#        - Scripts/Moose_.lua   (copied from src/lib/Moose_.lua)
#        - Scripts/main.lua     (synthesized: inlines score.lua and
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
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Resolve inputs.
if (-not (Test-Path -LiteralPath $DevMizPath)) {
    throw "Dev .miz not found: $DevMizPath. Edit -DevMizPath or save the mission first."
}
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
# can iterate (edit mission / Scripts/main.lua, re-zip) without running
# the packager again. Wiped on every run so it always reflects the
# current dev .miz + src/.
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$workDir = Join-Path $OutDir $BuildName
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
    $newInnerActions = "[1] =`n`t`t`t`t{`n`t`t`t`t`t[`"file`"] = `"Scripts/Moose_.lua`",`n`t`t`t`t`t[`"predicate`"] = `"a_do_script_file`",`n`t`t`t`t}, -- end of [1]`n`t`t`t`t[2] =`n`t`t`t`t{`n`t`t`t`t`t[`"file`"] = `"Scripts/main.lua`",`n`t`t`t`t`t[`"predicate`"] = `"a_do_script_file`",`n`t`t`t`t}, -- end of [2]"
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
[1] = "a_do_script_file(\"Scripts/Moose_.lua\");",
			[2] = "a_do_script_file(\"Scripts/main.lua\");",
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

    # Write back the modified mission file.
    [System.IO.File]::WriteAllText($missionPath, $mission, (New-Object System.Text.UTF8Encoding $false))
    Write-Host "Wrote modified mission file"

    # --- 5. Synthesize Scripts/main.lua ---
    Write-Host "Synthesizing Scripts/main.lua ..."
    $scriptsDir = Join-Path $workDir "Scripts"
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
-- Scripts/main.lua - SHIPPING BUILD for duel-dynamic.
-- Generated by build/pack-shipping-miz.ps1 from src/missions/duel-dynamic/.
-- DO NOT EDIT BY HAND - edit the dev sources and re-run the packager.
--
-- This file is loaded as the second DO SCRIPT FILE in the .miz's
-- MISSION START trigger (after Scripts/Moose_.lua). MOOSE is already in _G.
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
  env.error("[duel-dynamic] MOOSE not loaded - check Scripts/Moose_.lua in the .miz")
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

    # --- 6. Copy Scripts/Moose_.lua ---
    Write-Host "Copying Moose_.lua ..."
    $mooseDest = Join-Path $scriptsDir "Moose_.lua"
    [System.IO.File]::Copy($mooseSrc, $mooseDest, $true)
    Write-Host "  wrote $mooseDest ($((Get-Item $mooseDest).Length) bytes)"

    # --- 7. Re-zip into out/<OutName> (only if -Zip) ---
    if ($Zip) {
        $outPath = Join-Path $OutDir $OutName
        if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory(
            $workDir,
            $outPath,
            [System.IO.Compression.CompressionLevel]::Optimal,
            $false
        ) | Out-Null

        Write-Host ""
        Write-Host "Entries in ${outPath}:" -ForegroundColor Cyan
        # PowerShell variable names are case-insensitive. Do not call this
        # `$zip`: that would overwrite the [switch]$Zip parameter above.
        $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($outPath)
        try {
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
        Write-Host "  Compress-Archive -Path '$workDir\*' -DestinationPath 'out\${OutName}' -Force  # to zip manually"
    }

    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Test on a STOCK (sanitized) DCS install. See docs/shipping-duel-dynamic.md §5."
    Write-Host "  2. Drop the .miz into Saved Games\DCS.dcs_serverrelease\Missions\ on the server."
    Write-Host "  3. Watch Saved Games\DCS.dcs_serverrelease\Logs\dcs.log for 'MOOSE INCLUDE END' and"
    Write-Host "     '[duel-dynamic] ...' breadcrumbs."
}
# Note: we do NOT clean up $workDir in finally. The whole point of this
# refactor is to leave the staged tree on disk for inspection / manual
# edits / re-zipping. Re-running the packager wipes it for you.
finally {
    # intentionally empty — see comment above
}
