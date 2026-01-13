# Clinical-practice-guideline (Rail/Metro OHCA + PAD)

[![CI](https://github.com/SzokeMark-Andor/Clinical-practice-guideline/actions/workflows/ci.yml/badge.svg)](https://github.com/SzokeMark-Andor/Clinical-practice-guideline/actions/workflows/ci.yml)

Implementation-audit toolkit (**PowerShell**) accompanying a clinical practice guideline manuscript on **out-of-hospital cardiac arrest (OHCA)** response and **public-access defibrillation (PAD)** in **railway/metro stations**.  
It generates **data-quality checks**, **time-interval metrics**, and **manuscript-ready outputs** from CSV inputs.

> **Disclaimer**: Research / quality-improvement software artifact. **Not medical advice.**  
> The **clinical practice guideline** is reported in the manuscript; this repository provides the accompanying **audit toolkit** and does **not** constitute a guideline by itself.

---

## What this repo does

Given 3 CSV tables, the pipeline produces:

- **Data-quality report** (IDs, missingness, timestamp order checks, duplicates/sanity checks)
- **Time-interval metrics** (call→open, open→pads, pads→shock, call→shock)
- **Manuscript-ready outputs**
  - a Markdown snippet (`reports/manuscript_snippet.md`)
  - a LaTeX table (`reports/manuscript_table.tex`)

---

## Public download (ZIP “public pack”, split into 2 parts)

Because GitHub’s **web UI** upload limit is **25 MiB per file**, the “public pack” is provided as:

- `CPG_public_pack_..._part1.zip`
- `CPG_public_pack_..._part2.zip`

### How to reconstruct
1) Download **both** ZIP parts.  
2) Extract **part1** into an empty folder.  
3) Extract **part2** into the **same folder** (allow overwrite if asked).  
4) Run the toolkit from the extracted folder.

> Tip: If you can use git, cloning the repository is cleaner than downloading the split pack.

GitHub limits reference:
- Upload via browser: https://docs.github.com/en/enterprise-cloud@latest/get-started/writing-on-github/working-with-advanced-formatting/attaching-files  
- Large files / 100 MiB block / LFS: https://docs.github.com/enterprise-cloud@latest/repositories/working-with-files/managing-large-files/about-large-files-on-github

---

## Repository structure

- `.github/workflows/ci.yml` — Windows CI that runs the pipeline
- `config/` — pipeline configuration (e.g., `config/audit.config.json`)
- `schema/` — input schemas (`*.schema.json`)
- `scripts/` — pipeline entry points (PowerShell)
- `src/` — PowerShell module (e.g., `RailAudit.psm1`)
- `reports/` — generated outputs (**ignored by default**; CI uploads as artifact)

**Not committed:**
- `data/raw/` — operator-owned inputs (real deployments)
- any private/pseudonymized registries, linkage tables, or row-level extracts

---

## Requirements

- Windows PowerShell **5.1** or PowerShell **7+** (`pwsh`)
- No Python / R dependencies

---

## Inputs (operator-owned)

Place these files in `data/raw/` (see `schema/*.schema.json` for required headers):

- `stations.csv`
- `incidents.csv`
- `aed_events.csv`

Example fields (illustrative; see schemas for authoritative headers):
`incident_id, device_id, device_open_time_utc, pads_applied_time_utc, first_shock_time_utc`

---

## Quickstart (synthetic, reproducible)

From the repository root:

```powershell
# 1) Generate deterministic synthetic dataset (smoke test)
pwsh -NoProfile -File .\scripts\ci_prepare_data.ps1 -StationCount 5 -IncidentCount 60 -Seed 42 -Clean

# 2) Validate data quality (fails if any ERROR is found)
pwsh -NoProfile -File .\scripts\validate_data.ps1 -FailOnErrors

# 3) Run the full audit pipeline (reports/ + manuscript assets)
pwsh -NoProfile -File .\scripts\run_all.ps1
