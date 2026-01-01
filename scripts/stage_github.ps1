Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$root      = Split-Path -Parent $scriptDir

$desktop = [Environment]::GetFolderPath("Desktop")
$stamp   = (Get-Date).ToString("yyyyMMdd_HHmmss")
$dest    = Join-Path $desktop ("RailAudit_GitHub_Stage_{0}" -f $stamp)

Write-Host "Staging to: $dest"
New-Item -ItemType Directory -Force -Path $dest | Out-Null

function Copy-IfExists([string]$srcRel) {
  $src = Join-Path $root $srcRel
  if (Test-Path $src) {
    $dst = Join-Path $dest $srcRel
    $dstDir = Split-Path -Parent $dst
    if ($dstDir -and -not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
    Copy-Item -Force -Recurse -Path $src -Destination $dst
  }
}

# Copy core folders
Copy-IfExists "src"
Copy-IfExists "scripts"
Copy-IfExists "schema"
Copy-IfExists "config"

# Copy ONLY templates from data/raw (never real raw data)
$destRaw = Join-Path $dest "data\raw"
New-Item -ItemType Directory -Force -Path $destRaw | Out-Null

$rawDir = Join-Path $root "data\raw"
if (Test-Path $rawDir) {
  Get-ChildItem -Path $rawDir -Filter "*.template.csv" -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item -Force $_.FullName (Join-Path $destRaw $_.Name)
  }
}

# Synthetic runnable example (safe to publish)
$exRaw = Join-Path $dest "examples\raw"
New-Item -ItemType Directory -Force -Path $exRaw | Out-Null

@"
station_id,station_name,zone,city,country,notes
ST001,Example Station,concourse,ExampleCity,ExampleCountry,synthetic demo row
"@ | Set-Content -Encoding UTF8 (Join-Path $exRaw "stations.csv")

@"
incident_id,station_id,zone,event_time_utc,ems_arrival_time_utc,witnessed,bystander_cpr,ems_activated
I0001,ST001,concourse,2025-12-01T10:15:00Z,2025-12-01T10:22:30Z,true,true,true
"@ | Set-Content -Encoding UTF8 (Join-Path $exRaw "incidents.csv")

@"
incident_id,device_id,device_open_time_utc,pads_applied_time_utc,first_shock_time_utc
I0001,AED-01,2025-12-01T10:18:10Z,2025-12-01T10:19:00Z,2025-12-01T10:19:30Z
"@ | Set-Content -Encoding UTF8 (Join-Path $exRaw "aed_events.csv")

# README
@"
# Rail PAD/OHCA Implementation Audit Toolkit

This repository contains a reproducible PowerShell pipeline that generates:
- `data/processed/metrics_by_incident.csv`
- `reports/audit_report.md`

## Quickstart (synthetic example)
1. Copy example raw CSVs:
   - `examples/raw/*.csv` -> `data/raw/` (create `data/raw` if missing)
2. Run:
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_all.ps1

Outputs:
- `reports/audit_report.md`
- `data/processed/metrics_by_incident.csv`

## Real deployments
- Start from `data/raw/*.template.csv`
- Keep real raw data OUT of GitHub. Use `.gitignore` (included).
"@ | Set-Content -Encoding UTF8 (Join-Path $dest "README.md")

# .gitignore (protect raw data + ignore generated outputs)
@"
# Raw sensitive data (do not commit)
data/raw/*.csv
!data/raw/*.template.csv

# Outputs
data/processed/
reports/

# PowerShell noise
*.log
"@ | Set-Content -Encoding UTF8 (Join-Path $dest ".gitignore")

Write-Host ""
Write-Host "DONE. Upload this folder to GitHub:"
Write-Host ("  {0}" -f $dest)
Write-Host ""
Write-Host "Tip: to test the staged folder, copy examples/raw/*.csv -> data/raw/ and run run_all.ps1 there."
