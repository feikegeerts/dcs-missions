# Deploy a verified collector build without touching credentials or spool state.
# Run elevated after `npm --prefix collector run check` and `... run build`.
[CmdletBinding()]
param(
  [string]$ServiceRoot = 'C:\Users\g_for\dcs-telemetry-service',
  [string]$ServiceName = 'DcsTelemetryCollector'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceDist = Join-Path $repoRoot 'collector\dist'
$targetDist = Join-Path $ServiceRoot 'dist'
$backup = Join-Path $ServiceRoot ('dist-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))

foreach ($path in @($ServiceRoot, $sourceDist, $targetDist, (Join-Path $ServiceRoot 'state'))) {
  if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Missing required directory: $path" }
}
if (Test-Path -LiteralPath $backup) { throw "Backup already exists: $backup" }
if (-not (Test-Path -LiteralPath (Join-Path $sourceDist 'src\health-post.js'))) {
  throw 'Build is missing health-post.js; rebuild the collector before deploying.'
}
# This narrow updater deliberately refuses schema or dependency changes. Those
# require a separately reviewed upgrade, not silently replacing runtime state.
$sourcePackage = Get-Content -LiteralPath (Join-Path $repoRoot 'collector\package.json') -Raw | ConvertFrom-Json
$targetPackage = Get-Content -LiteralPath (Join-Path $ServiceRoot 'package.json') -Raw | ConvertFrom-Json
if (($sourcePackage.dependencies | ConvertTo-Json -Compress) -ne ($targetPackage.dependencies | ConvertTo-Json -Compress)) {
  throw 'Runtime dependencies differ; provision compatible dependencies before deploying.'
}
$sourceSchema = Get-FileHash -LiteralPath (Join-Path $repoRoot 'contracts\telemetry-event-v1.schema.json') -Algorithm SHA256
$targetSchema = Get-FileHash -LiteralPath (Join-Path $ServiceRoot 'contracts\telemetry-event-v1.schema.json') -Algorithm SHA256
if ($sourceSchema.Hash -ne $targetSchema.Hash) { throw 'Installed schema differs; review the schema upgrade separately.' }
$service = Get-Service -Name $ServiceName
if ($service.Status -ne 'Running') { throw 'Expected the existing collector to be running; inspect its state before upgrading.' }

# Stage the rollback copy before downtime. Never copy or delete state/config.
Copy-Item -LiteralPath $targetDist -Destination $backup -Recurse
$stopped = $false
try {
  Stop-Service -Name $ServiceName
  (Get-Service -Name $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(40))
  $stopped = $true
  Copy-Item -Path (Join-Path $sourceDist '*') -Destination $targetDist -Recurse -Force
  $sourceEntry = Get-FileHash -LiteralPath (Join-Path $sourceDist 'src\service.js') -Algorithm SHA256
  $targetEntry = Get-FileHash -LiteralPath (Join-Path $targetDist 'src\service.js') -Algorithm SHA256
  if ($sourceEntry.Hash -ne $targetEntry.Hash) { throw 'Deployed service entry hash does not match the build.' }
  Start-Service -Name $ServiceName
  (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(40))
  Start-Sleep -Seconds 12
  if ((Get-Service -Name $ServiceName).Status -ne 'Running') { throw 'Collector did not remain running after restart.' }
} catch {
  if ($stopped) {
    Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue
    (Get-Service -Name $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(40))
    # Only replace the distribution, never the durable spool or configuration.
    Remove-Item -LiteralPath $targetDist -Recurse -Force
    Copy-Item -LiteralPath $backup -Destination $targetDist -Recurse
    Start-Service -Name $ServiceName
  }
  throw
}

[pscustomobject]@{
  Service = $ServiceName
  Status = (Get-Service -Name $ServiceName).Status
  ServiceEntrySHA256 = $targetEntry.Hash
  RollbackDistribution = $backup
  NextCheck = 'GET /api/telemetry/collector-health: verify fresh generated_at/updated_at and inspect collector logs.'
}
