# azure-device-group-by-dept

PowerShell scripts that query **Entra ID (Azure AD)** for all registered devices,
look up the **department** attribute on each device's owner, and maintain one
**security group per department** containing that department's devices.

---

## Files

| File | Purpose |
|---|---|
| `config.json` | Tenant / client ID, group naming, exclusions |
| `Get-DeviceReport.ps1` | Read & report devices grouped by department |
| `Sync-DeviceGroups.ps1` | Create / update one group per department |

---

## Prerequisites

| Requirement | Notes |
|---|---|
| PowerShell 7+ | Recommended; 5.1 works but is slower |
| Microsoft.Graph modules | Auto-installed by the scripts on first run |
| Entra ID permissions | See table below |

### Required Graph API Permissions

| Script | Permission |
|---|---|
| `Get-DeviceReport.ps1` | `Device.Read.All`, `User.Read.All`, `Group.Read.All` |
| `Sync-DeviceGroups.ps1` | `Device.Read.All`, `User.Read.All`, `Group.ReadWrite.All`, `GroupMember.ReadWrite.All` |

Grant these as **application permissions** on your app registration if using a
service principal, or as **delegated permissions** for interactive sign-in.

---

## Quick Start

### 1. Configure

Edit `config.json`:

```json
{
  "TenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "ClientId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
  "GroupNamePrefix": "DEPT-DEVICES-",
  "GroupDescription": "Auto-managed group for {Department} department devices",
  "ExcludeDepartments": ["Test", "Temp"],
  "DryRun": false
}
```

| Field | Description |
|---|---|
| `TenantId` | Your Entra ID tenant ID |
| `ClientId` | App registration client ID (used for service-principal auth) |
| `GroupNamePrefix` | Prefix for created groups, e.g. `DEPT-DEVICES-Engineering` |
| `GroupDescription` | Group description; `{Department}` is replaced at runtime |
| `ExcludeDepartments` | Departments to skip entirely |
| `DryRun` | Set `true` to preview without making changes |

### 2. Run the report

```powershell
# Interactive sign-in
.\Get-DeviceReport.ps1

# Export to CSV
.\Get-DeviceReport.ps1 -OutputCsv .\report.csv

# Managed identity (Azure Automation / Azure VM)
.\Get-DeviceReport.ps1 -UseManagedIdentity

# Service principal
$secret = Read-Host -AsSecureString "Client secret"
.\Get-DeviceReport.ps1 -ClientSecret $secret
```

### 3. Sync groups (dry-run first)

```powershell
# Preview changes – nothing is written to Azure AD
.\Sync-DeviceGroups.ps1 -WhatIf

# Apply changes
.\Sync-DeviceGroups.ps1

# Service principal
$secret = Read-Host -AsSecureString "Client secret"
.\Sync-DeviceGroups.ps1 -ClientSecret $secret
```

---

## How It Works

```
Entra ID devices
      │
      ▼
Registered owners  ──► User.Department attribute
      │
      ▼
Map: Department → [Device IDs]
      │
      ├─► Get-DeviceReport  → console table / CSV
      │
      └─► Sync-DeviceGroups
              ├─ Ensure group "DEPT-DEVICES-<Dept>" exists (create if missing)
              ├─ Add devices that should be members
              └─ Remove devices that no longer belong
```

Devices with **no registered owner** or whose owner has **no department** set are
skipped. Devices can appear in multiple groups if they have multiple owners across
different departments.

---

## Automation

Schedule `Sync-DeviceGroups.ps1` as an **Azure Automation runbook** or a
**Windows Task Scheduler** job to keep groups up to date automatically.

Example Task Scheduler command:
```
pwsh.exe -NonInteractive -File "C:\Scripts\azure-device-group-by-dept\Sync-DeviceGroups.ps1" -UseManagedIdentity
```
