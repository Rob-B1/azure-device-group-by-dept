# azure-device-group-by-dept — Claude Code Project Notes

## What This Is
Entra ID / Intune device group sync tool. Queries all Entra ID devices and their registered owners, looks up each owner's department attribute, and ensures one security group per department exists containing exactly those devices. Supports WhatIf dry-run, audit mode (report current state without changes), stale device cleanup, and Azure Automation runbook deployment.

## Scripts

| Script | Purpose |
|---|---|
| `Sync-DeviceGroups.ps1` | Core sync: ensures one group per dept, adds/removes devices, cleans up stale dept groups |
| `Sync-IntuneDeviceGroups.ps1` | Variant targeting Intune-managed devices (Compliance/OS-level filtering) |
| `Get-DeviceReport.ps1` | Read-only audit: reports current device → owner → department → group membership |

## How It Works (Sync-DeviceGroups.ps1)
1. Fetch all Entra ID devices (`Get-MgDevice`)
2. For each device, look up registered owners (`Get-MgDeviceRegisteredOwner`) and resolve `Department` attribute from user profile (cached)
3. Build a `dept → [deviceId, ...]` map
4. For each department, ensure a group `<GroupNamePrefix><Department>` exists (create if missing)
5. Sync group membership: add devices that belong, remove those that don't
6. Optional: remove groups for departments with no matching devices (stale cleanup)

## Configuration (`config.json`)
```json
{
  "TenantId": "...",
  "GroupNamePrefix": "DEPT-",
  "ExcludeDepartments": ["Contractors"],
  "DryRun": false
}
```

## Running
```powershell
.\Sync-DeviceGroups.ps1 -WhatIf                 # Preview all changes
.\Sync-DeviceGroups.ps1                          # Apply changes
.\Get-DeviceReport.ps1                           # Audit current membership
.\Sync-DeviceGroups.ps1 -ConfigPath .\prod.json  # Use alternate config
```

## Tech Stack
- PowerShell 7+, Microsoft.Graph SDK (`Authentication`, `Identity.DirectoryManagement`, `Users`, `Groups`)
- Azure Automation for scheduled unattended runs (Managed Identity)
- `CmdletBinding(SupportsShouldProcess)` + `-WhatIf` throughout

## Known Patterns
- Modules are auto-installed if missing (Scope CurrentUser)
- Department lookup is cached in a hashtable to minimize Graph API calls
- `Get-MgGroupMemberAsDevice` is used instead of `Get-MgGroupMember` + type filtering to avoid unreliable `@odata.type` results on DirectoryObject returns

## Security Posture (Least Privilege / OWASP Top 10)

### Good
- Connects via `Connect-MgGraph` with explicit scopes (`Device.Read.All`, `User.Read.All`, `Group.ReadWrite.All`, `GroupMember.ReadWrite.All`) — no over-broad `Directory.ReadWrite.All`
- No credentials stored in script; auth delegated to Managed Identity (Azure Automation) or interactive login
- `-WhatIf` / dry-run prevents accidental bulk changes
- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` prevent silent failures

### Fixed
- **A05 Security Misconfiguration — AllowedDepartments allowlist added**: unknown department values now trigger a warning and are skipped instead of silently creating new groups; add departments to `AllowedDepartments` in config.json to enable them, or to `ExcludeDepartments` to suppress the warning permanently — `Sync-DeviceGroups.ps1`, `config.json`
- **A09 Security Logging/Monitoring — run summary exported after every sync**: structured JSON written to `AuditOutputDir` (default `./audit-logs`) after every run, including `run_id`, `timestamp_utc`, `executed_by` (the authenticated Graph identity), `dry_run` flag, per-group change counts, and unknown departments list; if `S3Bucket` is set in config.json the file is also uploaded via `aws s3 cp` for long-term retention — `Sync-DeviceGroups.ps1`, `config.json`

## Public Biotech Compliance (GxP / SOX / HIPAA)

### Done
- `-WhatIf` / `-Audit` modes prevent accidental bulk changes
- `Get-DeviceReport.ps1` provides a read-only snapshot of current membership
- Azure Audit Logs record all group membership changes made by the sync identity

### Pending — High Priority
- **No local audit export** — sync actions (devices added, removed, groups created) are written to the terminal only; if the script runs unattended (Azure Automation), this output is lost after the job expires; export a structured CSV/JSON summary of every run to a durable location (S3 or Azure Blob Storage)
- **No S3 / Blob archival** — Azure Audit Logs retain group changes for 30 days (P1) or 7 days (free/P0); for SOX 7-year and GxP retention requirements, sync run summaries must be exported to long-term storage with immutable retention
- **No run identity captured in output** — the script does not log which Azure Automation Managed Identity (or user) executed it; add `(Get-MgContext).Account` to the run summary header

### Pending — Medium Priority
- `Sync-DeviceGroups.ps1` has no `-Audit` flag (only `Get-DeviceReport.ps1` does) — consolidate so a single script can both report and sync
- No validation that `Department` attribute values conform to a canonical list — misspelled departments silently create new groups; add a config-driven allowed-departments list with a warning on unknown values
- No summary block at the end of a run (total devices processed, groups created, members added/removed) — required for operators to confirm the run completed successfully
