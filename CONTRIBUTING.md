# Contributing

Thanks for considering a contribution.

## How to contribute
- Open an issue describing the bug/feature.
- If you submit a PR, keep changes focused and reproducible.

## Local run (smoke test)
From the repo root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\ci_prepare_data.ps1 -StationCount 5 -IncidentCount 60 -Seed 42
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate_data.ps1 -FailOnErrors
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_all.ps1
