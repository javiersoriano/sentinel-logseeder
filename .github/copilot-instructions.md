# Copilot Instructions — Sentinel LogSeeder

This repository contains tools for generating and ingesting sample data into Microsoft Sentinel / Log Analytics workspaces.

## Project Structure

- `scripts/` — PowerShell scripts for data ingestion
  - `Invoke-SampleDataIngestion.ps1` — single-table ingestion engine
  - `Invoke-AttackScenarioIngestion.ps1` — multi-table attack scenario orchestrator
- `config/` — workspace and entity configuration
- `schemas/` — table schema definitions (JSON)
- `samples/` — sample data files for realistic value distributions
- `scenarios/` — attack scenario definitions (JSON)
- `.github/skills/SKILL.md` — detailed agent skill file with workflows

## Key Rules

1. Always read `config/workspace.json` for workspace coordinates — never ask the user
2. Always read `config/entities.json` for entity pools
3. Schema files use the format: `{ "columns": [ { "name": "...", "type": "...", "values": [...] } ] }`
4. Use `string` for GUID/UUID fields — `guid` type is not supported by DCR stream declarations
5. Always confirm schema with the user before ingesting
6. For attack scenarios, ensure all table schemas exist before running
7. Data takes 5–10 minutes to appear in Log Analytics after ingestion
8. When the user requests ingestion by **product name** (not explicit table name), always do table discovery first using connector documentation (Sentinel docs/GitHub/Sentinel Ninja)
9. If a product maps to multiple destination tables, do not pick one implicitly — present all valid table options and get explicit user confirmation before ingesting
10. Never select a table solely because a similarly named local schema file exists; local files are hints, not authority for connector destination table mapping
