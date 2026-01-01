Set-StrictMode -Version Latest

function Read-JsonFile {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path $Path)) { throw "Missing file: $Path" }
  Get-Content -Raw -Encoding UTF8 $Path | ConvertFrom-Json
}

function Import-CsvUtf8 {
  param([Parameter(Mandatory)][string]$Path)
  if (-not (Test-Path $Path)) { throw "Missing CSV: $Path" }
  # Windows PowerShell 5.1: Import-Csv has no -Encoding => use Get-Content UTF8 + ConvertFrom-Csv
  $lines = Get-Content -Encoding UTF8 -Path $Path
  @(($lines | ConvertFrom-Csv) | Where-Object { $_ -ne $null })
}

function Get-RequiredColumnsFromSchema {
  param(
    [Parameter(Mandatory)][object]$SchemaObj,
    [Parameter(Mandatory)][string[]]$Fallback
  )

  if ($SchemaObj -is [System.Array]) {
    $arr = @($SchemaObj | Where-Object { $_ -ne $null } | ForEach-Object { [string]$_ })
    if ($arr.Count -gt 0) { return $arr }
    return @($Fallback)
  }

  foreach ($name in @("required_columns","requiredColumns","required","columns","headers")) {
    $p = $SchemaObj.PSObject.Properties[$name]
    if ($null -ne $p -and $null -ne $p.Value) {
      $v = $p.Value
      if ($v -is [System.Array]) {
        $arr = @($v | Where-Object { $_ -ne $null } | ForEach-Object { [string]$_ })
        if ($arr.Count -gt 0) { return $arr }
      }
    }
  }

  return @($Fallback)
}

function Assert-Columns {
  param(
    [Parameter(Mandatory)][object[]]$Rows,
    [Parameter(Mandatory)][string[]]$RequiredColumns,
    [Parameter(Mandatory)][string]$Name
  )

  $rowsArr = @($Rows | Where-Object { $_ -ne $null })
  if ($rowsArr.Count -eq 0) { throw "[$Name] CSV has 0 rows." }

  $cols = @($rowsArr[0].PSObject.Properties.Name)
  $missing = @()
  foreach ($c in $RequiredColumns) {
    if ($cols -notcontains $c) { $missing += $c }
  }
  if ($missing.Count -gt 0) {
    throw "[$Name] Missing required columns: $([string]::Join(', ', $missing))"
  }
}

function Get-PropValue {
  param([Parameter(Mandatory)][object]$Obj, [Parameter(Mandatory)][string]$Name)
  $p = $Obj.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  $v = $p.Value
  if ($null -eq $v) { return $null }
  [string]$v
}

function Find-FirstCol {
  param([string[]]$Cols, [string[]]$Regexes)
  foreach ($rx in $Regexes) {
    $hit = $Cols | Where-Object { $_ -match $rx } | Select-Object -First 1
    if ($hit) { return $hit }
  }
  return $null
}

function Parse-Utc {
  param([AllowNull()][string]$Iso)
  if ([string]::IsNullOrWhiteSpace($Iso)) { return $null }
  try {
    [DateTime]::Parse(
      $Iso,
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    )
  } catch {
    return $null
  }
}

# Null-tolerant + PS5.1-safe
function DeltaSec {
  param(
    [AllowNull()][object]$A,
    [AllowNull()][object]$B
  )
  if ($null -eq $A -or $null -eq $B) { return $null }
  try {
    $da = [DateTime]$A
    $db = [DateTime]$B
  } catch {
    return $null
  }
  [int][Math]::Round(($db - $da).TotalSeconds)
}

function Get-RailAuditData {
  param([Parameter(Mandatory)][string]$Root)

  $schemaStations  = Read-JsonFile (Join-Path $Root "schema\stations.schema.json")
  $schemaIncidents = Read-JsonFile (Join-Path $Root "schema\incidents.schema.json")
  $schemaAed       = Read-JsonFile (Join-Path $Root "schema\aed_events.schema.json")

  $stationsReq  = Get-RequiredColumnsFromSchema -SchemaObj $schemaStations  -Fallback @("station_id","station_name","zone","city","country","notes")
  $incReq       = Get-RequiredColumnsFromSchema -SchemaObj $schemaIncidents -Fallback @("incident_id","station_id","zone","event_time_utc","ems_arrival_time_utc","witnessed","bystander_cpr","ems_activated")
  $aedReq       = Get-RequiredColumnsFromSchema -SchemaObj $schemaAed       -Fallback @("incident_id","device_id","device_open_time_utc","pads_applied_time_utc","first_shock_time_utc")

  $stationsPath  = Join-Path $Root "data\raw\stations.csv"
  $incidentsPath = Join-Path $Root "data\raw\incidents.csv"
  $aedPath       = Join-Path $Root "data\raw\aed_events.csv"

  if (-not (Test-Path $stationsPath))  { throw "Create stations.csv (start from stations.template.csv)" }
  if (-not (Test-Path $incidentsPath)) { throw "Create incidents.csv (start from incidents.template.csv)" }
  if (-not (Test-Path $aedPath))       { throw "Create aed_events.csv (start from aed_events.template.csv)" }

  $stations  = Import-CsvUtf8 $stationsPath
  $incidents = Import-CsvUtf8 $incidentsPath
  $aed       = Import-CsvUtf8 $aedPath

  Assert-Columns $stations  $stationsReq  "stations"
  Assert-Columns $incidents $incReq       "incidents"
  Assert-Columns $aed       $aedReq       "aed_events"

  # --- Canonicalize incident timestamps/flags (tolerant to alternate column names) ---
  $incCols = @($incidents[0].PSObject.Properties.Name)

  $eventCol = Find-FirstCol $incCols @('^event_time_utc$','event.*time.*utc','event.*time','call.*time','time.*utc')
  $emsCol   = Find-FirstCol $incCols @('^ems_arrival_time_utc$','ems.*arrival.*time.*utc','ems.*arrival.*utc','arrival.*time.*utc','ems.*arrival','arrival.*time')
  if (-not $eventCol) { throw "[incidents] Could not locate an event-time column in incidents.csv headers." }
  if (-not $emsCol)   { throw "[incidents] Could not locate an EMS-arrival column in incidents.csv headers." }

  $witCol    = Find-FirstCol $incCols @('^witnessed$','witness')
  $cprCol    = Find-FirstCol $incCols @('^bystander_cpr$','cpr')
  $emsActCol = Find-FirstCol $incCols @('^ems_activated$','ems.*activated','ems.*called','ems')

  foreach ($r in @($incidents)) {
    $eventIso = Get-PropValue $r $eventCol
    $emsIso   = Get-PropValue $r $emsCol

    $r | Add-Member -NotePropertyName event_time_utc       -NotePropertyValue $eventIso -Force
    $r | Add-Member -NotePropertyName ems_arrival_time_utc -NotePropertyValue $emsIso   -Force

    if ($witCol)    { $r | Add-Member -NotePropertyName witnessed     -NotePropertyValue (Get-PropValue $r $witCol)    -Force }
    if ($cprCol)    { $r | Add-Member -NotePropertyName bystander_cpr -NotePropertyValue (Get-PropValue $r $cprCol)    -Force }
    if ($emsActCol) { $r | Add-Member -NotePropertyName ems_activated -NotePropertyValue (Get-PropValue $r $emsActCol) -Force }

    $r | Add-Member -NotePropertyName event_time_dt  -NotePropertyValue (Parse-Utc $eventIso) -Force
    $r | Add-Member -NotePropertyName ems_arrival_dt -NotePropertyValue (Parse-Utc $emsIso)   -Force
  }

  # --- Canonicalize AED timestamps (tolerant to alternate column names) ---
  $aedCols = @($aed[0].PSObject.Properties.Name)

  $devCol   = Find-FirstCol $aedCols @('^device_id$','aed.*id','device')
  $openCol  = Find-FirstCol $aedCols @('^device_open_time_utc$','open.*time.*utc','device.*open.*time','open')
  $padsCol  = Find-FirstCol $aedCols @(
    '^pads_applied_time_utc$',
    'pads.*applied.*time.*utc','pads.*time.*utc','pad.*time.*utc',
    'electrode.*applied.*time.*utc','electrode.*time.*utc','electrode',
    'pads.*time','pads','pad'
  )
  $shockCol = Find-FirstCol $aedCols @(
    '^first_shock_time_utc$',
    'first.*shock.*time.*utc','shock.*time.*utc','shock.*time','shock',
    'defib.*time.*utc','defibrill.*time.*utc','defib','defibrill'
  )

  if (-not $openCol) { throw "[aed_events] Could not locate an AED open-time column in aed_events.csv headers." }

  foreach ($r in @($aed)) {
    if ($devCol) { $r | Add-Member -NotePropertyName device_id -NotePropertyValue (Get-PropValue $r $devCol) -Force }

    $openIso  = Get-PropValue $r $openCol
    $padsIso  = if ($padsCol)  { Get-PropValue $r $padsCol }  else { $null }
    $shockIso = if ($shockCol) { Get-PropValue $r $shockCol } else { $null }

    $r | Add-Member -NotePropertyName device_open_time_utc  -NotePropertyValue $openIso  -Force
    $r | Add-Member -NotePropertyName pads_applied_time_utc -NotePropertyValue $padsIso  -Force
    $r | Add-Member -NotePropertyName first_shock_time_utc  -NotePropertyValue $shockIso -Force

    $r | Add-Member -NotePropertyName open_dt  -NotePropertyValue (Parse-Utc $openIso)  -Force
    $r | Add-Member -NotePropertyName pads_dt  -NotePropertyValue (Parse-Utc $padsIso)  -Force
    $r | Add-Member -NotePropertyName shock_dt -NotePropertyValue (Parse-Utc $shockIso) -Force
  }

  [pscustomobject]@{
    Stations  = $stations
    Incidents = $incidents
    AedEvents = $aed
  }
}

function Get-RailAuditMetrics {
  param([Parameter(Mandatory)][object]$Data)

  $aedByIncident = @{}
  foreach ($row in @($Data.AedEvents)) {
    $iid = $row.incident_id
    if (-not $aedByIncident.ContainsKey($iid)) { $aedByIncident[$iid] = @() }
    $aedByIncident[$iid] += $row
  }

  $out = New-Object System.Collections.Generic.List[object]

  foreach ($inc in @($Data.Incidents)) {
    $iid = $inc.incident_id

    $events = if ($aedByIncident.ContainsKey($iid)) { $aedByIncident[$iid] } else { $null }
    $eventsArr = if ($null -ne $events) { @($events) } else { @() }

    $best = $eventsArr |
      Where-Object { $_ -ne $null -and $_.open_dt -ne $null } |
      Sort-Object open_dt |
      Select-Object -First 1

    $callToOpen       = if ($best) { DeltaSec $inc.event_time_dt $best.open_dt } else { $null }
    $openToPads       = if ($best) { DeltaSec $best.open_dt $best.pads_dt } else { $null }
    $padsToShock      = if ($best) { DeltaSec $best.pads_dt $best.shock_dt } else { $null }
    $callToShock      = if ($best) { DeltaSec $inc.event_time_dt $best.shock_dt } else { $null }
    $callToEmsArrival = DeltaSec $inc.event_time_dt $inc.ems_arrival_dt

    $out.Add([pscustomobject]@{
      incident_id            = $iid
      station_id             = $inc.station_id
      zone                   = $inc.zone
      event_time_utc         = $inc.event_time_utc
      event_hour_utc         = if ($inc.event_time_dt) { [int]$inc.event_time_dt.Hour } else { $null }
      witnessed              = $inc.witnessed
      bystander_cpr          = $inc.bystander_cpr
      ems_activated          = $inc.ems_activated

      device_id              = if ($best) { $best.device_id } else { $null }
      call_to_open_s         = $callToOpen
      open_to_pads_s         = $openToPads
      pads_to_shock_s        = $padsToShock
      call_to_shock_s        = $callToShock
      call_to_ems_arrival_s  = $callToEmsArrival
    })
  }

  $out.ToArray()
}

# Empty-array safe
function Get-Quantiles {
  [CmdletBinding()]
  param(
    [AllowNull()][object]$Values
  )

  $vals = New-Object System.Collections.Generic.List[int]
  if ($null -ne $Values) {
    foreach ($v in @($Values)) {
      if ($null -eq $v) { continue }
      try { $vals.Add([int]$v) | Out-Null } catch { }
    }
  }

  if ($vals.Count -eq 0) { return $null }

  $s = @($vals.ToArray() | Sort-Object)

  function Q([double]$p) {
    $idx = [int][Math]::Floor(($s.Count - 1) * $p)
    $s[$idx]
  }

  [pscustomobject]@{
    n      = $s.Count
    median = (Q 0.50)
    p75    = (Q 0.75)
    p90    = (Q 0.90)
  }
}

function Get-ComplianceRow {
  param(
    [Parameter(Mandatory)][string]$Metric,
    [Parameter(Mandatory)][int]$TargetSeconds,
    [AllowNull()][object]$Values
  )

  $vals = @()
  if ($null -ne $Values) { $vals = @($Values | Where-Object { $_ -ne $null } | ForEach-Object { [int]$_ }) }

  if ($vals.Count -eq 0) {
    return [pscustomobject]@{
      metric   = $Metric
      target_s = $TargetSeconds
      n        = 0
      meet     = 0
      pct_meet = $null
      median_s = $null
      p90_s    = $null
    }
  }

  $meet = @($vals | Where-Object { $_ -le $TargetSeconds }).Count
  $pct  = [Math]::Round(100.0 * $meet / $vals.Count, 1)
  $q    = Get-Quantiles -Values $vals

  [pscustomobject]@{
    metric   = $Metric
    target_s = $TargetSeconds
    n        = $vals.Count
    meet     = $meet
    pct_meet = $pct
    median_s = $q.median
    p90_s    = $q.p90
  }
}

function Write-MarkdownReport {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][object[]]$Metrics,
    [Parameter(Mandatory)][object[]]$Stations,
    [Parameter(Mandatory)][object]$Config
  )

  $targets = $Config.Targets
  $minN    = [int]$Config.Reporting.MinEventsToRankStation

  $mArr = @($Metrics | Where-Object { $_ -ne $null })
  $nIncTotal = $mArr.Count

  $callToShockVals = @($mArr | Where-Object { $_.call_to_shock_s -ne $null } | ForEach-Object { [int]$_.call_to_shock_s })
  $callToOpenVals  = @($mArr | Where-Object { $_.call_to_open_s  -ne $null } | ForEach-Object { [int]$_.call_to_open_s  })
  $openToPadsVals  = @($mArr | Where-Object { $_.open_to_pads_s  -ne $null } | ForEach-Object { [int]$_.open_to_pads_s  })
  $padsToShockVals = @($mArr | Where-Object { $_.pads_to_shock_s -ne $null } | ForEach-Object { [int]$_.pads_to_shock_s })

  $qShock = Get-Quantiles -Values $callToShockVals

  $compliance = @(
    Get-ComplianceRow -Metric "call→shock" -TargetSeconds ([int]$targets.TargetCallToShockSeconds) -Values $callToShockVals
    Get-ComplianceRow -Metric "open→pads"  -TargetSeconds ([int]$targets.TargetOpenToPadsSeconds)  -Values $openToPadsVals
    Get-ComplianceRow -Metric "pads→shock" -TargetSeconds ([int]$targets.TargetPadsToShockSeconds) -Values $padsToShockVals
  )

  $rank = @(
    $mArr |
      Where-Object { $_.call_to_shock_s -ne $null } |
      Group-Object station_id |
      ForEach-Object {
        $vals = @($_.Group | ForEach-Object { [int]$_.call_to_shock_s })
        $q = Get-Quantiles -Values $vals
        if ($q -ne $null) {
          [pscustomobject]@{
            station_id = $_.Name
            n = $q.n
            median_call_to_shock_s = $q.median
            p90_call_to_shock_s = $q.p90
          }
        }
      } |
      Where-Object { $_ -ne $null -and $_.n -ge $minN } |
      Sort-Object median_call_to_shock_s, p90_call_to_shock_s
  )

  $zone = @(
    $mArr |
      Where-Object { $_.call_to_shock_s -ne $null } |
      Group-Object zone |
      ForEach-Object {
        $vals = @($_.Group | ForEach-Object { [int]$_.call_to_shock_s })
        $q = Get-Quantiles -Values $vals
        if ($q -ne $null) {
          [pscustomobject]@{ zone=$_.Name; n=$q.n; median_s=$q.median; p90_s=$q.p90 }
        }
      } |
      Where-Object { $_ -ne $null } |
      Sort-Object median_s
  )

  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("# Rail PAD/OHCA Implementation Audit Report")
  $lines.Add("")
  $lines.Add("- Generated (UTC): $([DateTime]::UtcNow.ToString('o'))")
  $lines.Add("- Incidents in dataset: $nIncTotal")
  $lines.Add(("- Targets (local policy): call→shock ≤ {0}s; open→pads ≤ {1}s; pads→shock ≤ {2}s" -f `
    [int]$targets.TargetCallToShockSeconds, [int]$targets.TargetOpenToPadsSeconds, [int]$targets.TargetPadsToShockSeconds))
  $lines.Add("")

  $lines.Add("## Data completeness")
  $nWithOpen  = @($mArr | Where-Object { $_.call_to_open_s  -ne $null }).Count
  $nWithPads  = @($mArr | Where-Object { $_.open_to_pads_s  -ne $null }).Count
  $nWithShock = @($mArr | Where-Object { $_.call_to_shock_s -ne $null }).Count
  $lines.Add("")
  $lines.Add("| metric | n available |")
  $lines.Add("|---|---:|")
  $lines.Add(("| call→open | {0} |"  -f $nWithOpen))
  $lines.Add(("| open→pads | {0} |"  -f $nWithPads))
  $lines.Add(("| call→shock | {0} |" -f $nWithShock))
  $lines.Add("")

  $lines.Add("## Target compliance (by metric)")
  $lines.Add("")
  $lines.Add("| metric | target (s) | n | meet | % meet | median (s) | p90 (s) |")
  $lines.Add("|---|---:|---:|---:|---:|---:|---:|")
  foreach ($c in $compliance) {
    $pct = if ($c.pct_meet -eq $null) { "" } else { "{0:N1}" -f $c.pct_meet }
    $med = if ($c.median_s -eq $null) { "" } else { [int]$c.median_s }
    $p90 = if ($c.p90_s    -eq $null) { "" } else { [int]$c.p90_s }
    $lines.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6} |" -f $c.metric,[int]$c.target_s,[int]$c.n,[int]$c.meet,$pct,$med,$p90))
  }
  $lines.Add("")

  $lines.Add("## Overall timing summary (call→shock)")
  if ($qShock -eq $null) {
    $lines.Add("No incidents with call_to_shock available yet.")
  } else {
    $lines.Add("")
    $lines.Add("| n | median (s) | p75 (s) | p90 (s) |")
    $lines.Add("|---:|----------:|--------:|--------:|")
    $lines.Add(("| {0} | {1} | {2} | {3} |" -f [int]$qShock.n,[int]$qShock.median,[int]$qShock.p75,[int]$qShock.p90))
  }

  $lines.Add("")
  $lines.Add("## Component delays (seconds)")
  $qCallOpen  = Get-Quantiles -Values $callToOpenVals
  $qOpenPads  = Get-Quantiles -Values $openToPadsVals
  $qPadsShock = Get-Quantiles -Values $padsToShockVals

  $lines.Add("")
  $lines.Add("| metric | n | median (s) | p90 (s) |")
  $lines.Add("|---|---:|---:|---:|")
  foreach ($row in @(
    [pscustomobject]@{ name="call→open";   q=$qCallOpen  }
    [pscustomobject]@{ name="open→pads";  q=$qOpenPads  }
    [pscustomobject]@{ name="pads→shock"; q=$qPadsShock }
  )) {
    if ($row.q -eq $null) {
      $lines.Add(("| {0} | 0 |  |  |" -f $row.name))
    } else {
      $lines.Add(("| {0} | {1} | {2} | {3} |" -f $row.name,[int]$row.q.n,[int]$row.q.median,[int]$row.q.p90))
    }
  }

  $lines.Add("")
  $lines.Add("## Station ranking (median call→shock; min n = $minN)")
  if ($rank.Count -eq 0) {
    $lines.Add("Not enough station events to rank yet. Increase data volume or lower MinEventsToRankStation.")
  } else {
    $lines.Add("")
    $lines.Add("| station_id | n | median (s) | p90 (s) |")
    $lines.Add("|---|---:|---:|---:|")
    foreach ($r in $rank) {
      $lines.Add(("| {0} | {1} | {2} | {3} |" -f $r.station_id,[int]$r.n,[int]$r.median_call_to_shock_s,[int]$r.p90_call_to_shock_s))
    }
  }

  $lines.Add("")
  $lines.Add("## Zone summary (call→shock)")
  if ($zone.Count -eq 0) {
    $lines.Add("No zone-level timing data yet.")
  } else {
    $lines.Add("")
    $lines.Add("| zone | n | median (s) | p90 (s) |")
    $lines.Add("|---|---:|---:|---:|")
    foreach ($z in $zone) {
      $lines.Add(("| {0} | {1} | {2} | {3} |" -f $z.zone,[int]$z.n,[int]$z.median_s,[int]$z.p90_s))
    }
  }

  $lines.Add("")
  $lines.Add("## Notes for manuscript integration")
  $lines.Add("- This output is an implementation audit (quality improvement), not a clinical efficacy study.")
  $lines.Add("- Use it to quantify bottlenecks and guide station operations; it supports 'living' guideline updates.")
  $lines.Add("")

  $lines | Set-Content -Encoding UTF8 $Path
}

Export-ModuleMember -Function Get-RailAuditData, Get-RailAuditMetrics, Write-MarkdownReport, Read-JsonFile
