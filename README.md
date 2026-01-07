# Clinical-practice-guideline

[![CI](https://github.com/SzokeMark-Andor/Clinical-practice-guideline/actions/workflows/ci.yml/badge.svg)](https://github.com/SzokeMark-Andor/Clinical-practice-guideline/actions/workflows/ci.yml)

Implementation-audit toolkit (PowerShell) accompanying the clinical practice guideline manuscript on OHCA response and public-access defibrillation in railway/metro stations. It generates data-quality checks, time-interval metrics, and manuscript-ready outputs from CSV inputs.

> **Disclaimer**: Research / quality-improvement software artifact. **Not medical advice.** The **clinical practice guideline** is reported in the manuscript; this repository provides the accompanying audit toolkit and does **not** constitute a guideline by itself.

---

## What this repo does

Given 3 CSV tables, the pipeline produces:

- **Data-quality report** (IDs, missingness, timestamp order checks, duplicate/sanity checks)
- **Time-interval metrics** (call→open, open→pads, pads→shock, call→shock)
- **Manuscript-ready outputs**:
  - a Markdown snippet
  - a LaTeX table

---

## Repository structure

- `.github/workflows/ci.yml` — Windows CI that runs the pipeline
- `config/` — pipeline configuration (e.g., `config/audit.config.json`)
- `data/raw/` — input CSVs (**not included**; ignored by default)
- `data/processed/` — optional intermediates
- `examples/raw/` — synthetic example inputs (**generated**; ignored by default)
- `schema/` — input schemas (`*.schema.json`)
- `scripts/` — pipeline entry points (PowerShell)
- `src/` — PowerShell module (`RailAudit.psm1`)
- `reports/` — generated outputs (**ignored by default**; CI uploads as artifact)

---

## Requirements

- Windows PowerShell **5.1** or PowerShell **7+**
- Git (only if you want to commit/push)

No Python / R dependencies.

---

## Inputs

Place these files in `data/raw/` (see `schema/*.schema.json` for required headers):

- `stations.csv`
- `incidents.csv`
- `aed_events.csv`

Example header (synthetic generator uses):
`incident_id,device_id,device_open_time_utc,pads_applied_time_utc,first_shock_time_utc`

---

## Quickstart

From the repository root:

```powershell
# 1) Generate deterministic synthetic dataset (smoke test)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\ci_prepare_data.ps1 -StationCount 5 -IncidentCount 60 -Seed 42

# 2) Validate data quality (fails if any ERROR is found)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate_data.ps1 -FailOnErrors

# 3) Run the full audit pipeline
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\run_all.ps1
