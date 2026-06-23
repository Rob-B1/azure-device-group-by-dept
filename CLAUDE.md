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

### Done
- **Local audit export** — structured JSON summary written to `AuditOutputDir` (default `./audit-logs`) after every run; includes `run_id`, `timestamp_utc`, per-group change counts, and unknown departments list
- **S3 archival** — audit summary uploaded to `s3://{S3Bucket}/{S3Prefix}{filename}` via `aws s3 cp` when `S3Bucket` is configured in config.json
- **Run identity captured** — `executed_by = (Get-MgContext).Account` included in every run summary (the authenticated Graph identity)
- **AllowedDepartments allowlist** — unknown department values trigger a warning and are skipped; add to `AllowedDepartments` in config.json to enable, or `ExcludeDepartments` to suppress the warning
- **Run summary block** — totals (departments processed, groups created, members added/removed, unknown departments) printed at end of each run

### Done (continued)
- **`-Audit` flag** — `Sync-DeviceGroups.ps1` now accepts `-Audit` switch; sets `isDryRun=true` (no group or membership changes), labels console output `[AUDIT]`, and writes `audit_only=true` in the JSON run summary exported to `AuditOutputDir` and S3 — produces a compliance artifact showing current state without modification

### Pending — Medium Priority
- No S3 Object Lock on audit log bucket — SOX 7-year retention requires immutable storage; configure Object Lock GOVERNANCE on the target S3 bucket outside this script

## NIST CSF 2.0 Alignment (Sections 3 & 4 — Profiles / Tier 2–3 Repeatable)

| Function | Subcategory | How this tool addresses it |
|---|---|---|
| GOVERN | GV.PO-01 | `AllowedDepartments` allowlist in config.json documents the authorized group policy; drift surfaces as warnings |
| IDENTIFY | ID.AM-01 | Inventories all Entra ID / Intune devices and maps each to a department-scoped security group |

### Security Log Retention
- No AWS CDK stack — audit exports written to local `./audit-logs/` directory; S3 upload optional via `S3Bucket` in config.json
- When using S3 archival: configure **Object Lock GOVERNANCE 2555 days** and **Glacier transition at 365 days** on the target bucket for 1-year accessible security log retention
- **Tier target**: Tier 2–3 — WhatIf/Audit dry-run mode, structured JSON audit export with `run_id` + `executed_by` identity; upgrade to Tier 3 by scheduling via Azure Automation runbook and adding CloudTrail/S3 Object Lock to the audit bucket
