[CmdletBinding()]
param(
  [string]$Root = "",
  [string]$OutReportPath = "",
  [string]$OutFlagsCsvPath = "",
  [switch]$FailOnErrors
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -------------------------
# Root + default outputs
# -------------------------
$root = if ([string]::IsNullOrWhiteSpace($Root)) {
  if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
} else {
  $Root
}

if ([string]::IsNullOrWhiteSpace($OutReportPath))   { $OutReportPath   = Join-Path $root "reports\data_quality_report.md" }
if ([string]::IsNullOrWhiteSpace($OutFlagsCsvPath)) { $OutFlagsCsvPath = Join-Path $root "reports\data_quality_flags.csv" }

function Ensure-Dir {
  param([Parameter(Mandatory)][string]$Path)
  $d = Split-Path -Parent $Path
  if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

$modulePath = Join-Path $root "src\RailAudit.psm1"
if (-not (Test-Path $modulePath)) { throw "Missing module: $modulePath" }

Import-Module $modulePath -Force

# -------------------------
# Load canonicalized data
# -------------------------
$data = Get-RailAuditData -Root $root
$stations  = @($data.Stations  | Where-Object { $_ -ne $null })
$incidents = @($data.Incidents | Where-Object { $_ -ne $null })
$aed       = @($data.AedEvents | Where-Object { $_ -ne $null })

# -------------------------
# Issue collector
# -------------------------
$issues = New-Object System.Collections.Generic.List[object]

function Add-Issue {
  param(
    [Parameter(Mandatory)][ValidateSet("ERROR","WARN","INFO")][string]$Severity,
    [Parameter(Mandatory)][ValidateSet("station","incident","aed_event")][string]$Kind,
    [AllowNull()][string]$Id,
    [AllowNull()][string]$StationId,
    [Parameter(Mandatory)][string]$Issue,
    [AllowNull()][string]$Detail
  )

  $issues.Add([pscustomobject]@{
    severity   = $Severity
    kind       = $Kind
    id         = $Id
    station_id = $StationId
    issue      = $Issue
    detail     = $Detail
  }) | Out-Null
}

# -------------------------
# Indexes
# -------------------------
$stationIds = @{}
foreach ($s in $stations) {
  $sid = [string]$s.station_id
  if ([string]::IsNullOrWhiteSpace($sid)) {
    Add-Issue -Severity ERROR -Kind station -Id "" -StationId "" -Issue "missing_station_id" -Detail "stations.csv row missing station_id"
    continue
  }
  if ($stationIds.ContainsKey($sid)) {
    Add-Issue -Severity ERROR -Kind station -Id $sid -StationId $sid -Issue "duplicate_station_id" -Detail "Duplicate station_id in stations.csv"
  } else {
    $stationIds[$sid] = $true
  }
}

$incidentIds = @{}
foreach ($i in $incidents) {
  $iid = [string]$i.incident_id
  if ([string]::IsNullOrWhiteSpace($iid)) {
    Add-Issue -Severity ERROR -Kind incident -Id "" -StationId ([string]$i.station_id) -Issue "missing_incident_id" -Detail "incidents.csv row missing incident_id"
    continue
  }
  if ($incidentIds.ContainsKey($iid)) {
    Add-Issue -Severity ERROR -Kind incident -Id $iid -StationId ([string]$i.station_id) -Issue "duplicate_incident_id" -Detail "Duplicate incident_id in incidents.csv"
  } else {
    $incidentIds[$iid] = $true
  }
}

# Map AED events by incident_id (for per-incident checks)
$aedByIncident = @{}
foreach ($e in $aed) {
  $iid = [string]$e.incident_id
  if ([string]::IsNullOrWhiteSpace($iid)) {
    Add-Issue -Severity ERROR -Kind aed_event -Id "" -StationId "" -Issue "missing_incident_id_in_aed" -Detail "aed_events.csv row missing incident_id"
    continue
  }
  if (-not $aedByIncident.ContainsKey($iid)) { $aedByIncident[$iid] = @() }
  $aedByIncident[$iid] += $e
}

# -------------------------
# Incident-level checks
# -------------------------
foreach ($i in $incidents) {
  $iid = [string]$i.incident_id
  $sid = [string]$i.station_id

  if ([string]::IsNullOrWhiteSpace($sid)) {
    Add-Issue -Severity ERROR -Kind incident -Id $iid -StationId "" -Issue "missing_station_id" -Detail "incident has blank station_id"
  } elseif (-not $stationIds.ContainsKey($sid)) {
    Add-Issue -Severity ERROR -Kind incident -Id $iid -StationId $sid -Issue "unknown_station_id" -Detail "incident.station_id not found in stations.csv"
  }

  if ($null -eq $i.event_time_dt) {
    Add-Issue -Severity ERROR -Kind incident -Id $iid -StationId $sid -Issue "unparseable_event_time" -Detail ("event_time_utc='{0}'" -f [string]$i.event_time_utc)
  }

  if ($null -ne $i.ems_arrival_time_utc -and -not [string]::IsNullOrWhiteSpace([string]$i.ems_arrival_time_utc)) {
    if ($null -eq $i.ems_arrival_dt) {
      Add-Issue -Severity WARN -Kind incident -Id $iid -StationId $sid -Issue "unparseable_ems_arrival_time" -Detail ("ems_arrival_time_utc='{0}'" -f [string]$i.ems_arrival_time_utc)
    }
  }

  if ($null -ne $i.event_time_dt -and $null -ne $i.ems_arrival_dt) {
    if ($i.ems_arrival_dt -lt $i.event_time_dt) {
      Add-Issue -Severity ERROR -Kind incident -Id $iid -StationId $sid -Issue "ems_before_event" -Detail "ems_arrival_dt is earlier than event_time_dt"
    }
  }
}

# -------------------------
# AED-event checks
# -------------------------
foreach ($e in $aed) {
  $iid = [string]$e.incident_id

  if (-not $incidentIds.ContainsKey($iid)) {
    Add-Issue -Severity ERROR -Kind aed_event -Id $iid -StationId "" -Issue "aed_unknown_incident_id" -Detail "aed_events.incident_id not found in incidents.csv"
    continue
  }

  # Find station_id for this incident (best effort)
  $inc = $incidents | Where-Object { [string]$_.incident_id -eq $iid } | Select-Object -First 1
  $sid = if ($inc) { [string]$inc.station_id } else { "" }

  if ($null -eq $e.open_dt) {
    Add-Issue -Severity WARN -Kind aed_event -Id $iid -StationId $sid -Issue "missing_or_unparseable_open_time" -Detail ("device_open_time_utc='{0}'" -f [string]$e.device_open_time_utc)
    continue
  }

  if ($inc -and $null -ne $inc.event_time_dt) {
    if ($e.open_dt -lt $inc.event_time_dt) {
      Add-Issue -Severity ERROR -Kind aed_event -Id $iid -StationId $sid -Issue "open_before_event" -Detail "AED open_dt earlier than incident event_time_dt"
    }
  }

  if ($null -ne $e.pads_dt -and $e.pads_dt -lt $e.open_dt) {
    Add-Issue -Severity ERROR -Kind aed_event -Id $iid -StationId $sid -Issue "pads_before_open" -Detail "pads_dt earlier than open_dt"
  }

  if ($null -ne $e.shock_dt -and $null -eq $e.pads_dt) {
    Add-Issue -Severity WARN -Kind aed_event -Id $iid -StationId $sid -Issue "shock_without_pads_time" -Detail "shock_dt exists but pads_dt is missing/unparseable"
  }

  if ($null -ne $e.shock_dt -and $null -ne $e.pads_dt -and $e.shock_dt -lt $e.pads_dt) {
    Add-Issue -Severity ERROR -Kind aed_event -Id $iid -StationId $sid -Issue "shock_before_pads" -Detail "shock_dt earlier than pads_dt"
  }
}

# -------------------------
# Per-incident sanity (pick earliest open_dt as 'best')
# -------------------------
foreach ($i in $incidents) {
  $iid = [string]$i.incident_id
  $sid = [string]$i.station_id
  if (-not $aedByIncident.ContainsKey($iid)) { continue }

  $best = @($aedByIncident[$iid]) |
    Where-Object { $_ -ne $null -and $_.open_dt -ne $null } |
    Sort-Object open_dt |
    Select-Object -First 1

  if (-not $best) { continue }
  if ($null -eq $i.event_time_dt) { continue }

  $callToOpen = ($best.open_dt - $i.event_time_dt).TotalSeconds
  if ($callToOpen -lt 0) {
    Add-Issue -Severity ERROR -Kind incident -Id $iid -StationId $sid -Issue "negative_call_to_open" -Detail ("call_to_open_s={0}" -f [int][Math]::Round($callToOpen))
  } elseif ($callToOpen -gt (4 * 3600)) {
    Add-Issue -Severity WARN -Kind incident -Id $iid -StationId $sid -Issue "call_to_open_outlier" -Detail ("call_to_open_s={0} (>4h)" -f [int][Math]::Round($callToOpen))
  }
}

# -------------------------
# Write outputs
# -------------------------
Ensure-Dir $OutFlagsCsvPath
Ensure-Dir $OutReportPath

$issuesArr = $issues.ToArray()
$issuesArr | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $OutFlagsCsvPath

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Data Quality Report (Rail PAD/OHCA Audit)")
$lines.Add("")
$lines.Add(("- Generated (UTC): {0}" -f [DateTime]::UtcNow.ToString("o")))
$lines.Add(("- stations: {0}" -f $stations.Count))
$lines.Add(("- incidents: {0}" -f $incidents.Count))
$lines.Add(("- aed_events: {0}" -f $aed.Count))
$lines.Add(("- issues: {0}" -f $issuesArr.Count))
$lines.Add("")

$sev = $issuesArr | Group-Object severity | Sort-Object Name
$lines.Add("## Severity summary")
$lines.Add("")
$lines.Add("| severity | n |")
$lines.Add("|---|---:|")
foreach ($g in $sev) { $lines.Add(("| {0} | {1} |" -f $g.Name, $g.Count)) }
$lines.Add("")

$top = $issuesArr | Group-Object issue | Sort-Object Count -Descending
$lines.Add("## Top issues")
$lines.Add("")
$lines.Add("| issue | n |")
$lines.Add("|---|---:|")
foreach ($g in ($top | Select-Object -First 20)) { $lines.Add(("| {0} | {1} |" -f $g.Name, $g.Count)) }
$lines.Add("")

$lines.Add("## Sample flagged rows (first 25)")
$lines.Add("")
$lines.Add("| severity | kind | id | station_id | issue | detail |")
$lines.Add("|---|---|---|---|---|---|")
foreach ($r in ($issuesArr | Select-Object -First 25)) {
  $detail = [string]$r.detail
  if ($detail.Length -gt 80) { $detail = $detail.Substring(0,80) + "…" }
  $lines.Add(("| {0} | {1} | {2} | {3} | {4} | {5} |" -f $r.severity,$r.kind,$r.id,$r.station_id,$r.issue,$detail))
}
$lines.Add("")

$lines | Set-Content -Encoding UTF8 -Path $OutReportPath

$errCount = @($issuesArr | Where-Object { $_.severity -eq "ERROR" }).Count
if ($FailOnErrors -and $errCount -gt 0) {
  throw ("Data quality validation failed: {0} ERROR(s). See: {1}" -f $errCount, $OutReportPath)
}

Write-Host ("OK: wrote {0}" -f $OutReportPath)
Write-Host ("OK: wrote {0}" -f $OutFlagsCsvPath)
Write-Host ("Issues: {0} (ERROR={1}, WARN={2}, INFO={3})" -f
  $issuesArr.Count,
  $errCount,
  @($issuesArr | Where-Object { $_.severity -eq "WARN" }).Count,
  @($issuesArr | Where-Object { $_.severity -eq "INFO" }).Count
)
