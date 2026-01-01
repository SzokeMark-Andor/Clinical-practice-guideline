[CmdletBinding()]
param(
  [string]$Root = "",
  [string]$ReportPath = "",
  [string]$MetricsCsvPath = "",
  [string]$ManuscriptMdPath = "",
  [string]$ManuscriptTexPath = "",
  [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -------------------------
# Root + paths
# -------------------------
$root = if ([string]::IsNullOrWhiteSpace($Root)) {
  if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
} else {
  $Root
}

if ([string]::IsNullOrWhiteSpace($ReportPath))       { $ReportPath       = Join-Path $root "reports\audit_report.md" }
if ([string]::IsNullOrWhiteSpace($MetricsCsvPath))   { $MetricsCsvPath   = Join-Path $root "reports\metrics.csv" }
if ([string]::IsNullOrWhiteSpace($ManuscriptMdPath)) { $ManuscriptMdPath = Join-Path $root "reports\manuscript_snippet.md" }
if ([string]::IsNullOrWhiteSpace($ManuscriptTexPath)){ $ManuscriptTexPath= Join-Path $root "reports\manuscript_table.tex" }

$modulePath = Join-Path $root "src\RailAudit.psm1"
if (-not (Test-Path $modulePath)) { throw "Missing module: $modulePath" }

# -------------------------
# Helpers (PS 5.1 safe)
# -------------------------
function Read-JsonMaybe {
  param([AllowNull()][string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  if (-not (Test-Path $Path)) { return $null }
  try { Get-Content -Raw -Encoding UTF8 $Path | ConvertFrom-Json } catch { return $null }
}

function Resolve-Config {
  param([AllowNull()][string]$PreferredPath)

  $c = Read-JsonMaybe $PreferredPath
  if ($c) { return $c }

  $candidates = @(
    (Join-Path $root "config\audit_config.json"),
    (Join-Path $root "config\config.json"),
    (Join-Path $root "config.json")
  )

  foreach ($p in $candidates) {
    $c = Read-JsonMaybe $p
    if ($c) { return $c }
  }

  # Default config (safe if you don't have config yet)
  # Targets are *local policy* placeholders; tune to your setting.
  return [pscustomobject]@{
    Targets = [pscustomobject]@{
      TargetCallToShockSeconds      = 300
      TargetOpenToPadsSeconds       = 60
      TargetPadsToShockSeconds      = 60
      TargetCallToEmsArrivalSeconds = 480
    }
    Reporting = [pscustomobject]@{
      MinEventsToRankStation = 5
    }
  }
}

function Get-IntArray {
  param([AllowNull()][object]$Values)
  $out = New-Object System.Collections.Generic.List[int]
  if ($null -ne $Values) {
    foreach ($v in @($Values)) {
      if ($null -eq $v) { continue }
      try { $out.Add([int]$v) | Out-Null } catch { }
    }
  }
  $out.ToArray()
}

function Get-QuantilesLocal {
  param([AllowNull()][object]$Values)
  $vals = Get-IntArray $Values
  if ($vals.Length -eq 0) { return $null }
  $s = @($vals | Sort-Object)

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

function Get-ComplianceLocal {
  param(
    [Parameter(Mandatory)][string]$Metric,
    [Parameter(Mandatory)][int]$TargetSeconds,
    [AllowNull()][object]$Values
  )

  $vals = Get-IntArray $Values
  if ($vals.Length -eq 0) {
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
  $pct  = [Math]::Round(100.0 * $meet / $vals.Length, 1)
  $q    = Get-QuantilesLocal -Values $vals

  [pscustomobject]@{
    metric   = $Metric
    target_s = $TargetSeconds
    n        = $vals.Length
    meet     = $meet
    pct_meet = $pct
    median_s = $q.median
    p90_s    = $q.p90
  }
}

function Ensure-Dir {
  param([Parameter(Mandatory)][string]$Path)
  $d = Split-Path -Parent $Path
  if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

function SecToMinStr {
  param([AllowNull()][object]$Seconds)
  if ($null -eq $Seconds) { return "" }
  try {
    $m = [Math]::Round(([double]$Seconds) / 60.0, 2)
    return "{0:N2}" -f $m
  } catch { return "" }
}

function Append-ExtraSectionsToReport {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][object[]]$Metrics,
    [Parameter(Mandatory)][object]$Config
  )

  $mArr = @($Metrics | Where-Object { $_ -ne $null })

  $callToEmsVals   = Get-IntArray @($mArr | ForEach-Object { $_.call_to_ems_arrival_s } | Where-Object { $_ -ne $null })
  $callToOpenVals  = Get-IntArray @($mArr | ForEach-Object { $_.call_to_open_s }        | Where-Object { $_ -ne $null })
  $openToPadsVals  = Get-IntArray @($mArr | ForEach-Object { $_.open_to_pads_s }        | Where-Object { $_ -ne $null })
  $padsToShockVals = Get-IntArray @($mArr | ForEach-Object { $_.pads_to_shock_s }       | Where-Object { $_ -ne $null })
  $callToShockVals = Get-IntArray @($mArr | ForEach-Object { $_.call_to_shock_s }       | Where-Object { $_ -ne $null })

  $tEms = 480
  if ($Config -and $Config.Targets -and $Config.Targets.PSObject.Properties["TargetCallToEmsArrivalSeconds"]) {
    try { $tEms = [int]$Config.Targets.TargetCallToEmsArrivalSeconds } catch { $tEms = 480 }
  }

  $qEms   = Get-QuantilesLocal -Values $callToEmsVals
  $qShock = Get-QuantilesLocal -Values $callToShockVals

  $compEms = Get-ComplianceLocal -Metric "call→EMS arrival" -TargetSeconds $tEms -Values $callToEmsVals

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("")
  $lines.Add("---")
  $lines.Add("")
  $lines.Add("## EMS response (call→EMS arrival)")
  $lines.Add("")
  if ($qEms -eq $null) {
    $lines.Add("No incidents with EMS arrival time available yet.")
  } else {
    $lines.Add("| n | median (s) | p75 (s) | p90 (s) | median (min) | p90 (min) | target (s) | % meet |")
    $lines.Add("|---:|----------:|--------:|--------:|-------------:|----------:|----------:|------:|")
    $pct = if ($compEms.pct_meet -eq $null) { "" } else { "{0:N1}" -f $compEms.pct_meet }
    $lines.Add((
      "| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} |" -f
      [int]$qEms.n,
      [int]$qEms.median,
      [int]$qEms.p75,
      [int]$qEms.p90,
      (SecToMinStr $qEms.median),
      (SecToMinStr $qEms.p90),
      [int]$tEms,
      $pct
    ))
  }

  $lines.Add("")
  $lines.Add("## Data quality checks")
  $lines.Add("")
  $nInc = $mArr.Count
  $nOpen  = $callToOpenVals.Length
  $nPads  = $openToPadsVals.Length
  $nShock = $callToShockVals.Length
  $lines.Add("| check | value |")
  $lines.Add("|---|---:|")
  $lines.Add(("| incidents total | {0} |" -f $nInc))
  $lines.Add(("| call→open available | {0} |" -f $nOpen))
  $lines.Add(("| open→pads available | {0} |" -f $nPads))
  $lines.Add(("| call→shock available | {0} |" -f $nShock))

  # Simple bottleneck hint (median components, if available)
  $qCallOpen  = Get-QuantilesLocal -Values $callToOpenVals
  $qOpenPads  = Get-QuantilesLocal -Values $openToPadsVals
  $qPadsShock = Get-QuantilesLocal -Values $padsToShockVals

  $lines.Add("")
  $lines.Add("## Quick bottleneck hint (median seconds)")
  $lines.Add("")
  $lines.Add("| component | median (s) |")
  $lines.Add("|---|---:|")
  $lines.Add(("| call→open | {0} |"  -f ($(if ($qCallOpen)  { [int]$qCallOpen.median }  else { "" }))))
  $lines.Add(("| open→pads | {0} |"  -f ($(if ($qOpenPads)  { [int]$qOpenPads.median }  else { "" }))))
  $lines.Add(("| pads→shock | {0} |" -f ($(if ($qPadsShock) { [int]$qPadsShock.median } else { "" }))))
  if ($qShock) {
    $lines.Add(("| call→shock (overall) | {0} |" -f [int]$qShock.median))
  }

  $lines | Add-Content -Encoding UTF8 -Path $Path
}

function Write-ManuscriptSnippet {
  param(
    [Parameter(Mandatory)][string]$MdPath,
    [Parameter(Mandatory)][string]$TexPath,
    [Parameter(Mandatory)][object[]]$Metrics,
    [Parameter(Mandatory)][object]$Config
  )

  $mArr = @($Metrics | Where-Object { $_ -ne $null })

  $callToOpenVals  = Get-IntArray @($mArr | ForEach-Object { $_.call_to_open_s }   | Where-Object { $_ -ne $null })
  $openToPadsVals  = Get-IntArray @($mArr | ForEach-Object { $_.open_to_pads_s }   | Where-Object { $_ -ne $null })
  $padsToShockVals = Get-IntArray @($mArr | ForEach-Object { $_.pads_to_shock_s }  | Where-Object { $_ -ne $null })
  $callToShockVals = Get-IntArray @($mArr | ForEach-Object { $_.call_to_shock_s }  | Where-Object { $_ -ne $null })

  $tShock = [int]$Config.Targets.TargetCallToShockSeconds
  $tOpenPads = [int]$Config.Targets.TargetOpenToPadsSeconds
  $tPadsShock= [int]$Config.Targets.TargetPadsToShockSeconds

  $compShock    = Get-ComplianceLocal -Metric "call→shock" -TargetSeconds $tShock    -Values $callToShockVals
  $compOpenPads = Get-ComplianceLocal -Metric "open→pads"  -TargetSeconds $tOpenPads -Values $openToPadsVals
  $compPadsShock= Get-ComplianceLocal -Metric "pads→shock" -TargetSeconds $tPadsShock -Values $padsToShockVals

  $qShock   = Get-QuantilesLocal -Values $callToShockVals
  $qCallOpen= Get-QuantilesLocal -Values $callToOpenVals
  $qOpenPads= Get-QuantilesLocal -Values $openToPadsVals
  $qPadsShk = Get-QuantilesLocal -Values $padsToShockVals

  Ensure-Dir $MdPath
  Ensure-Dir $TexPath

  $md = New-Object System.Collections.Generic.List[string]
  $md.Add("## Manuscript-ready results snippet")
  $md.Add("")
  $md.Add(("- Dataset: n={0} incidents; call→open available={1}; open→pads available={2}; call→shock available={3}." -f
    $mArr.Count, $callToOpenVals.Length, $openToPadsVals.Length, $callToShockVals.Length))
  $md.Add("")
  if ($qShock) {
    $md.Add(("- Overall call→shock: median {0}s (p90 {1}s). Compliance with target ≤{2}s: {3}% (n={4})." -f
      [int]$qShock.median, [int]$qShock.p90, [int]$tShock,
      $(if ($compShock.pct_meet -eq $null) { "NA" } else { "{0:N1}" -f $compShock.pct_meet }),
      [int]$compShock.n))
  } else {
    $md.Add("- Overall call→shock: not yet available (no recorded shock times).")
  }
  $md.Add("")
  $md.Add("| Component | n | median (s) | p90 (s) | target (s) | % meet |")
  $md.Add("|---|---:|---:|---:|---:|---:|")
  $md.Add(("| call→open | {0} | {1} | {2} |  |  |" -f
    $callToOpenVals.Length,
    $(if ($qCallOpen) { [int]$qCallOpen.median } else { "" }),
    $(if ($qCallOpen) { [int]$qCallOpen.p90 } else { "" })
  ))
  $md.Add(("| open→pads | {0} | {1} | {2} | {3} | {4} |" -f
    $openToPadsVals.Length,
    $(if ($qOpenPads) { [int]$qOpenPads.median } else { "" }),
    $(if ($qOpenPads) { [int]$qOpenPads.p90 } else { "" }),
    $tOpenPads,
    $(if ($compOpenPads.pct_meet -eq $null) { "" } else { "{0:N1}" -f $compOpenPads.pct_meet })
  ))
  $md.Add(("| pads→shock | {0} | {1} | {2} | {3} | {4} |" -f
    $padsToShockVals.Length,
    $(if ($qPadsShk) { [int]$qPadsShk.median } else { "" }),
    $(if ($qPadsShk) { [int]$qPadsShk.p90 } else { "" }),
    $tPadsShock,
    $(if ($compPadsShock.pct_meet -eq $null) { "" } else { "{0:N1}" -f $compPadsShock.pct_meet })
  ))
  $md.Add("")
  $md.Add("> Note: This is an implementation audit / quality-improvement report, not a clinical efficacy study.")
  $md | Set-Content -Encoding UTF8 -Path $MdPath

  # Minimal LaTeX table (copy/paste into manuscript)
  $tex = New-Object System.Collections.Generic.List[string]
  $tex.Add("% Auto-generated: implementation audit timing table")
  $tex.Add("\begin{table}[t]")
  $tex.Add("\centering")
  $tex.Add("\caption{Implementation audit timing and target compliance.}")
  $tex.Add("\begin{tabular}{lrrrrr}")
  $tex.Add("\hline")
  $tex.Add("Metric & n & Median (s) & P90 (s) & Target (s) & \% meet \\")
  $tex.Add("\hline")
  $tex.Add(("{0} & {1} & {2} & {3} & {4} & {5} \\" -f
    "call`$\rightarrow`$shock",
    $compShock.n,
    $(if ($qShock) { [int]$qShock.median } else { 0 }),
    $(if ($qShock) { [int]$qShock.p90 } else { 0 }),
    $tShock,
    $(if ($compShock.pct_meet -eq $null) { 0 } else { "{0:N1}" -f $compShock.pct_meet })
  ))
  $tex.Add(("{0} & {1} & {2} & {3} & {4} & {5} \\" -f
    "open`$\rightarrow`$pads",
    $compOpenPads.n,
    $(if ($qOpenPads) { [int]$qOpenPads.median } else { 0 }),
    $(if ($qOpenPads) { [int]$qOpenPads.p90 } else { 0 }),
    $tOpenPads,
    $(if ($compOpenPads.pct_meet -eq $null) { 0 } else { "{0:N1}" -f $compOpenPads.pct_meet })
  ))
  $tex.Add(("{0} & {1} & {2} & {3} & {4} & {5} \\" -f
    "pads`$\rightarrow`$shock",
    $compPadsShock.n,
    $(if ($qPadsShk) { [int]$qPadsShk.median } else { 0 }),
    $(if ($qPadsShk) { [int]$qPadsShk.p90 } else { 0 }),
    $tPadsShock,
    $(if ($compPadsShock.pct_meet -eq $null) { 0 } else { "{0:N1}" -f $compPadsShock.pct_meet })
  ))
  $tex.Add("\hline")
  $tex.Add("\end{tabular}")
  $tex.Add("\end{table}")
  $tex | Set-Content -Encoding UTF8 -Path $TexPath
}

# -------------------------
# Run pipeline
# -------------------------
Import-Module $modulePath -Force

$config = Resolve-Config -PreferredPath $ConfigPath

$data    = Get-RailAuditData -Root $root
$metrics = Get-RailAuditMetrics -Data $data

Ensure-Dir $ReportPath
Ensure-Dir $MetricsCsvPath

$metrics | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $MetricsCsvPath

Write-MarkdownReport -Path $ReportPath -Metrics $metrics -Stations $data.Stations -Config $config
Append-ExtraSectionsToReport -Path $ReportPath -Metrics $metrics -Config $config

Write-ManuscriptSnippet -MdPath $ManuscriptMdPath -TexPath $ManuscriptTexPath -Metrics $metrics -Config $config

Write-Host ("OK: wrote {0}" -f $ReportPath)
Write-Host ("OK: wrote {0}" -f $MetricsCsvPath)
Write-Host ("OK: wrote {0}" -f $ManuscriptMdPath)
Write-Host ("OK: wrote {0}" -f $ManuscriptTexPath)


