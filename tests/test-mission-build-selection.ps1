param([string]$MissionDirectory = "$env:USERPROFILE\Saved Games\DCS\Missions\Telemetry")
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$build = Join-Path $root 'build\pack-shipping-miz.ps1'
$bvr = Join-Path $MissionDirectory 'duel-dynamic-bvr.miz'
$survival = Join-Path $MissionDirectory 'air-superiority-survival.miz'

function Expect-Rejection($label, $expected, $arguments) {
    try {
        & $build @arguments
        throw "Unexpected build success: $label"
    } catch {
        if (-not $_.Exception.Message.Contains($expected)) { throw }
        "PASS: $label"
    }
}

Expect-Rejection 'implicit mission selection' 'requires explicit -MissionName' @{ DevMizPath = $survival }
Expect-Rejection 'unknown mission has no legacy fallback' 'Dev source not found' @{ MissionName = 'not-a-registered-mission'; DevMizPath = $bvr }
$negativeOutput = Join-Path $root 'out\selection-negative.miz'
if (Test-Path -LiteralPath $negativeOutput) { throw "Negative test output already exists: $negativeOutput" }
Expect-Rejection 'ACM configuration rejects BVR four-slot template' 'Mission configuration/template validation failed' @{
    MissionName = 'duel-dynamic-acm'
    DevMizPath = $bvr
    BuildName = 'selection-negative'
    OutName = 'selection-negative.miz'
    Zip = $true
}
if (Test-Path -LiteralPath $negativeOutput) { throw 'Rejected build created a shipping artifact' }
'Mission build selection: 3 rejection checks passed; no negative artifact created'
exit 0
