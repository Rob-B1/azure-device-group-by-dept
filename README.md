# azure-device-group-by-dept

PowerShell scripts that query **Entra ID (Azure AD)** for devices, look up the
**department** attribute on each device's owner, and maintain one **security group
per department** containing that department's devices.

Two approaches are provided depending on your device management platform:

| Approach | Script | Device source |
|---|---|---|
| **Entra ID** | `Sync-DeviceGroups.ps1` / `Get-DeviceReport.ps1` | `Get-MgDevice` + registered owner |
| **Intune (MDM)** | `Sync-IntuneDeviceGroups.ps1` | `Get-MgDeviceManagementManagedDevice` + assigned user |

---

## Files

| File | Purpose |
|---|---|
| `config.json` | Tenant / client ID, group naming, exclusions |
| `Get-DeviceReport.ps1` | Read & report Entra ID devices grouped by department |
| `Sync-DeviceGroups.ps1` | Create / update one group per department (Entra ID approach) |
| `Sync-IntuneDeviceGroups.ps1` | Create / update one group per department (Intune approach) |

---

## Prerequisites

| Requirement | Notes |
|---|---|
| PowerShell 7+ | Recommended; 5.1 works but is slower |
| Microsoft.Graph modules | Auto-installed by `Sync-DeviceGroups.ps1` and `Get-DeviceReport.ps1` on first run |
| Entra ID permissions | See table below |

### Required Graph API Permissions

| Script | Permission |
|---|---|
| `Get-DeviceReport.ps1` | `Device.Read.All`, `User.Read.All`, `Group.Read.All` |
| `Sync-DeviceGroups.ps1` | `Device.Read.All`, `User.Read.All`, `Group.ReadWrite.All`, `GroupMember.ReadWrite.All` |
| `Sync-IntuneDeviceGroups.ps1` | `DeviceManagementManagedDevices.Read.All`, `User.Read.All`, `Group.ReadWrite.All`, `GroupMember.ReadWrite.All` |

Grant as **delegated permissions** on your app registration for interactive sign-in.

---

## Approach 1 — Entra ID (`Sync-DeviceGroups.ps1`)

Uses `Get-MgDevice` and each device's **registered owner** to determine department.
Groups are named `<GroupNamePrefix><Department>` (e.g. `DEPT-DEVICES-Engineering`).

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
| `ClientId` | App registration client ID |
| `GroupNamePrefix` | Prefix for created groups |
| `GroupDescription` | Group description; `{Department}` is replaced at runtime |
| `ExcludeDepartments` | Departments to skip entirely |
| `DryRun` | Set `true` to preview without making changes |

### 2. Run the report

```powershell
.\Get-DeviceReport.ps1

# Export to CSV
.\Get-DeviceReport.ps1 -OutputCsv .\report.csv
```

### 3. Sync groups

```powershell
# Preview changes – nothing is written to Azure AD
.\Sync-DeviceGroups.ps1 -WhatIf

# Apply changes
.\Sync-DeviceGroups.ps1
```

### How it works

```
Entra ID devices (Get-MgDevice)
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
              ├─ Discover all existing DEPT-DEVICES-* groups
              ├─ Create missing groups
              ├─ Add devices that should be members
              └─ Remove devices that no longer belong
```

Devices with no registered owner or whose owner has no department set are skipped.
A device can appear in multiple groups if it has owners across different departments.

---

## Approach 2 — Intune (`Sync-IntuneDeviceGroups.ps1`)

Uses `Get-MgDeviceManagementManagedDevice` and each device's **assigned user** (`userId`)
to determine department. Targets Windows and macOS Intune-managed devices only.
Groups are named `DEPT-<Department> Devices` (e.g. `DEPT-Engineering Devices`).
The `DEPT-` prefix ensures the script only ever touches groups it created and never
modifies unrelated groups that happen to end in " Devices".

### Run

```powershell
.\Sync-IntuneDeviceGroups.ps1
```

A browser credential prompt will appear on launch. No config file is required —
update the `TenantId` / scopes at the top of the script if needed.

### How it works

```
Intune devices (Get-MgDeviceManagementManagedDevice)
  Filter: Windows + macOS only
      │
      ▼
Assigned user (userId)  ──► User.Department attribute
      │
      ▼
AzureADDeviceId  ──► AAD Object ID lookup (Get-MgDevice)
      │
      ▼
Map: Department → [AAD Device Object IDs]
      │
      └─► Sync groups
              ├─ Discover all existing "* Devices" groups
              ├─ Create missing groups
              ├─ Add devices that should be members
              └─ Remove devices that no longer belong
```

Devices with no assigned user, no department, or no matching AAD object ID are skipped.

---

## Automation

Schedule `Sync-DeviceGroups.ps1` as an **Azure Automation runbook** or a
**Windows Task Scheduler** job to keep groups up to date automatically.

Example Task Scheduler command:
```
pwsh.exe -NonInteractive -File "C:\Scripts\azure-device-group-by-dept\Sync-DeviceGroups.ps1"
```
