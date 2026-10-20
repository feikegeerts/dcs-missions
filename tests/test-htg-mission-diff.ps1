# tests/test-htg-mission-diff.ps1
#
# Proves that the shipping build changed nothing in a mission file except the
# two trigger blocks it replaces: everything before ["trig"], everything
# between ["trig"] and ["trigrules"], and everything after ["trigrules"] must be
# byte-identical between the source and the built mission file.
#
# Without this, "the .miz still loads" would be an assumption about the mission
# content the packager never touched.
#
# Usage:
#   pwsh -File tests/test-htg-mission-diff.ps1 -SourceMission <file> -BuiltMission <file>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceMission,
    [Parameter(Mandatory = $true)][string]$BuiltMission
)

$ErrorActionPreference = "Stop"
$src = Get-Content $SourceMission
$bld = Get-Content $BuiltMission

function Find-Line($lines, $pattern, $from) {
    for ($i = $from; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) { return $i }
    }
    return -1
}

$sTrigStart = Find-Line $src '^\s*\["trig"\] = ' 0
$sTrigEnd = Find-Line $src '^\s*\}, -- end of \["trig"\]' $sTrigStart
$sRulesStart = Find-Line $src '^\s*\["trigrules"\] = ' 0
$sRulesEnd = if ($src[$sRulesStart] -match '^\s*\["trigrules"\] = \{\},\s*$') {
    $sRulesStart
} else {
    Find-Line $src '^\s*\}, -- end of \["trigrules"\]' $sRulesStart
}

$bTrigStart = Find-Line $bld '^\s*\["trig"\] = ' 0
$bTrigEnd = Find-Line $bld '^\s*\}, -- end of \["trig"\]' $bTrigStart
$bRulesStart = Find-Line $bld '^\s*\["trigrules"\] = ' $bTrigEnd
$bRulesEnd = Find-Line $bld '^\s*\}, -- end of \["trigrules"\]' $bRulesStart

foreach ($pair in @(
        @('source', $sTrigStart, $sTrigEnd, $sRulesStart, $sRulesEnd),
        @('built', $bTrigStart, $bTrigEnd, $bRulesStart, $bRulesEnd))) {
    if ($pair[1] -lt 0 -or $pair[2] -lt 0 -or $pair[3] -lt 0 -or $pair[4] -lt 0) {
        throw "$($pair[0]) mission file is not in the expected shape"
    }
}

$regions = @(
    @('head', $src[0..($sTrigStart - 1)], $bld[0..($bTrigStart - 1)]),
    @('mission content', $src[($sTrigEnd + 1)..($sRulesStart - 1)], $bld[($bTrigEnd + 1)..($bRulesStart - 1)]),
    @('tail', $src[($sRulesEnd + 1)..($src.Count - 1)], $bld[($bRulesEnd + 1)..($bld.Count - 1)])
)

$mismatches = 0
foreach ($region in $regions) {
    $name, $a, $b = $region
    if ($a.Count -ne $b.Count) { throw "$name length differs: $($a.Count) vs $($b.Count)" }
    for ($i = 0; $i -lt $a.Count; $i++) {
        if ($a[$i] -cne $b[$i]) {
            $mismatches++
            Write-Host "  $name diff at offset $i : '$($a[$i])' vs '$($b[$i])'"
        }
    }
}
if ($mismatches -gt 0) { throw "$mismatches line(s) outside the trigger differ" }

Write-Host ("OK - only the trigger changed: head {0} + content {1} + tail {2} lines identical; trig {3} -> {4} lines, trigrules {5} -> {6} lines" -f `
        $regions[0][1].Count, $regions[1][1].Count, $regions[2][1].Count, `
        ($sTrigEnd - $sTrigStart + 1), ($bTrigEnd - $bTrigStart + 1), `
        ($sRulesEnd - $sRulesStart + 1), ($bRulesEnd - $bRulesStart + 1))
