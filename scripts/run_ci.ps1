[CmdletBinding()]
param(
  [string]$Root = "",
  [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$root = if ([string]::IsNullOrWhiteSpace($Root)) {
  if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
} else {
  $Root
}

$validate = Join-Path $root "scripts\validate_data.ps1"
$runAll   = Join-Path $root "scripts\run_all.ps1"

if (-not (Test-Path $validate)) { throw "Missing: $validate" }
if (-not (Test-Path $runAll))   { throw "Missing: $runAll" }

# 1) Validate (fail build if any ERROR)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $validate -Root $root -FailOnErrors

# 2) Run main pipeline
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runAll -Root $root
} else {
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runAll -Root $root -ConfigPath $ConfigPath
}

Write-Host "OK: CI pipeline finished (validation + run_all)."
