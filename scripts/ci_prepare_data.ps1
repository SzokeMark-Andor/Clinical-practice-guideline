[CmdletBinding()]
param(
  [string]$Root = "",
  [int]$StationCount = 5,
  [int]$IncidentCount = 60,
  [int]$Seed = 42
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = if ([string]::IsNullOrWhiteSpace($Root)) {
  if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
} else {
  $Root
}

$gen = Join-Path $root "scripts\generate_synthetic.ps1"
if (-not (Test-Path $gen)) { throw "Missing generator: $gen" }

# 1) Generate into examples\raw
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gen `
  -StationCount $StationCount -IncidentCount $IncidentCount -Seed $Seed

# 2) Copy into audited location data\raw
$examples = Join-Path $root "examples\raw"
if (-not (Test-Path $examples)) { throw "Missing examples folder after generation: $examples" }

$dataRaw = Join-Path $root "data\raw"
New-Item -ItemType Directory -Force -Path $dataRaw | Out-Null

Copy-Item -Force (Join-Path $examples "*.csv") $dataRaw

Write-Host "OK: CI data prepared:"
Write-Host ("  examples: {0}" -f $examples)
Write-Host ("  data\raw : {0}" -f $dataRaw)

Write-Host "Header aed_events.csv:"
Get-Content (Join-Path $dataRaw "aed_events.csv") -TotalCount 1
