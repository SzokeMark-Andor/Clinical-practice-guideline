param(
  [int]$StationCount  = 5,
  [int]$IncidentCount = 60,
  [int]$Seed          = 42,
  [string]$OutDir     = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Root detection:
# - if executed as a script, $PSScriptRoot is ".../<repo>/scripts" => root is parent
# - if pasted / interactive, fall back to current directory (assumed repo root)
$root = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }

if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $root "examples\raw"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Get-RequiredColumns {
  param(
    [Parameter(Mandatory)][string]$SchemaPath,
    [Parameter(Mandatory)][string[]]$Fallback
  )

  if (Test-Path $SchemaPath) {
    $json = Get-Content -Raw -Encoding UTF8 $SchemaPath | ConvertFrom-Json

    if ($json -is [System.Array]) {
      $arr = @($json | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if ($arr.Count -gt 0) { return $arr }
    } else {
      foreach ($k in @("required_columns","requiredColumns","required","columns","headers")) {
        $p = $json.PSObject.Properties[$k]
        if ($null -ne $p -and $null -ne $p.Value) {
          $v = $p.Value
          if ($v -is [System.Array]) {
            $arr = @($v | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($arr.Count -gt 0) { return $arr }
          }
        }
      }
    }
  }

  return @($Fallback)
}

function IsoZ([datetime]$dt) { $dt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }
function New-IncidentId([int]$n) { "I{0:0000}" -f $n }

$rand = [System.Random]::new($Seed)

$stationZones  = @("north","south","east","west","central")
$incidentZones = @("concourse","platform","ticket_hall","stairs","gate_line")
$deviceIds     = @("AED-01","AED-02","AED-03","AED-04")
$stationTypes  = @("railway","metro","subway","tram","mixed")

# Read schema-required columns (but ALWAYS include canonical columns too)
$stationsReq = Get-RequiredColumns -SchemaPath (Join-Path $root "schema\stations.schema.json") -Fallback @(
  "station_id","station_name","station_type","open_24_7","zone","city","country","notes"
)
$incReq = Get-RequiredColumns -SchemaPath (Join-Path $root "schema\incidents.schema.json") -Fallback @(
  "incident_id","station_id","zone","event_time_utc","ems_arrival_time_utc","witnessed","bystander_cpr","ems_activated"
)
$aedReq = Get-RequiredColumns -SchemaPath (Join-Path $root "schema\aed_events.schema.json") -Fallback @(
  "incident_id","device_id","device_open_time_utc","pads_applied_time_utc","first_shock_time_utc"
)

$canonStations = @("station_id","station_name","station_type","open_24_7","zone","city","country","notes")
$canonInc      = @("incident_id","station_id","zone","event_time_utc","ems_arrival_time_utc","witnessed","bystander_cpr","ems_activated")
$canonAed      = @("incident_id","device_id","device_open_time_utc","pads_applied_time_utc","first_shock_time_utc")

$stationsCols = @($stationsReq + $canonStations | Select-Object -Unique)
$incCols      = @($incReq      + $canonInc      | Select-Object -Unique)
$aedCols      = @($aedReq      + $canonAed      | Select-Object -Unique)

# ----- stations.csv -----
$stationRows = New-Object System.Collections.Generic.List[object]

for ($i = 1; $i -le $StationCount; $i++) {
  $sid = ("ST{0:000}" -f $i)

  $row = [ordered]@{}
  foreach ($col in $stationsCols) {
    switch -Regex ($col) {
      'station.*id'      { $row[$col] = $sid; break }
      'station.*name'    { $row[$col] = "Synthetic Station $i"; break }
      'type'             { $row[$col] = $stationTypes[$rand.Next(0, $stationTypes.Count)]; break }
      'open.*24|24_7'     { $row[$col] = if ($rand.NextDouble() -lt 0.2) { "true" } else { "false" }; break }
      '^zone$|zone'       { $row[$col] = $stationZones[$rand.Next(0, $stationZones.Count)]; break }
      'city'              { $row[$col] = "ExampleCity"; break }
      'country'           { $row[$col] = "ExampleCountry"; break }
      'notes?'            { $row[$col] = "synthetic demo row"; break }
      default             { $row[$col] = "" }
    }
  }

  $stationRows.Add([pscustomobject]$row) | Out-Null
}

$stationRows | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $OutDir "stations.csv")

# ----- incidents.csv -----
$incidentRows = New-Object System.Collections.Generic.List[object]
$start = [datetime]"2025-12-01T00:00:00Z"
$spanSeconds = 31 * 24 * 3600

for ($i = 1; $i -le $IncidentCount; $i++) {
  $sid  = $stationRows[$rand.Next(0, $stationRows.Count)].station_id
  $zone = $incidentZones[$rand.Next(0, $incidentZones.Count)]

  $t0  = $start.AddSeconds($rand.Next(0, $spanSeconds))
  $ems = $t0.AddSeconds($rand.Next(240, 900)) # 4–15 min

  $witnessed = ($rand.NextDouble() -lt 0.60)
  $cpr       = ($rand.NextDouble() -lt 0.50)

  $row = [ordered]@{}
  foreach ($col in $incCols) {
    switch -Regex ($col) {
      'incident.*id'                { $row[$col] = New-IncidentId $i; break }
      'station.*id'                 { $row[$col] = $sid; break }
      '^zone$|zone'                 { $row[$col] = $zone; break }
      'event.*time.*utc|event.*time|call.*time|^event_time_utc$' { $row[$col] = IsoZ $t0; break }
      'ems.*arrival.*utc|arrival.*time.*utc|^ems_arrival_time_utc$|ems.*arrival|arrival.*time' { $row[$col] = IsoZ $ems; break }
      'witness'                     { $row[$col] = $witnessed.ToString().ToLowerInvariant(); break }
      'cpr'                         { $row[$col] = $cpr.ToString().ToLowerInvariant(); break }
      'ems.*activat|ems.*called|^ems_activated$' { $row[$col] = "true"; break }
      default                       { $row[$col] = "" }
    }
  }

  $incidentRows.Add([pscustomobject]$row) | Out-Null
}

$incidentRows | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $OutDir "incidents.csv")

# ----- aed_events.csv -----
$aedRows = New-Object System.Collections.Generic.List[object]

foreach ($incRow in $incidentRows) {
  if ($rand.NextDouble() -ge 0.85) { continue } # 85% have AED interaction

  $incId = [string]$incRow.incident_id
  $t0 = [datetime]::Parse(
    [string]$incRow.event_time_utc,
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
  )

  $device = $deviceIds[$rand.Next(0, $deviceIds.Count)]
  $open   = $t0.AddSeconds($rand.Next(40, 481))   # call→open
  $pads   = $open.AddSeconds($rand.Next(10, 91))  # open→pads

  $missingPads = ($rand.NextDouble() -lt 0.10)
  $noShock     = ($rand.NextDouble() -lt 0.30)

  $padsIso  = if ($missingPads) { "" } else { IsoZ $pads }
  $shockIso = ""
  if (-not $noShock -and -not $missingPads) {
    $shock = $pads.AddSeconds($rand.Next(10, 61)) # pads→shock
    $shockIso = IsoZ $shock
  }

  $row = [ordered]@{}
  foreach ($col in $aedCols) {
    switch -Regex ($col) {
      'incident.*id'                      { $row[$col] = $incId; break }
      'device.*id|aed.*id'                { $row[$col] = $device; break }
      'open'                              { $row[$col] = IsoZ $open; break }
      'pads|pad|electrode'                { $row[$col] = $padsIso; break }
      'shock|defib|defibrill'             { $row[$col] = $shockIso; break }
      default                             { $row[$col] = "" }
    }
  }

  $aedRows.Add([pscustomobject]$row) | Out-Null
}

$aedRows | Export-Csv -NoTypeInformation -Encoding UTF8 (Join-Path $OutDir "aed_events.csv")

Write-Host "OK: wrote synthetic examples to:"
Write-Host ("  {0}" -f $OutDir)
