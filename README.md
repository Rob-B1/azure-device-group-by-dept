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

### Operating modes

#### Report mode — preview pending changes without connecting to Entra ID

```powershell
# Show what would change (requires Intune, reads current state)
.\Sync-IntuneDeviceGroups.ps1 -Report
```

Prints a table of all devices with their current department, target group, and whether they need to be added or removed. No API writes are made.

#### Audit mode — show current group membership and flag mismatches

```powershell
# Display full membership audit in the console
.\Sync-IntuneDeviceGroups.ps1 -Audit

# Save audit to CSV
.\Sync-IntuneDeviceGroups.ps1 -Audit -OutputCsv .\audit.csv
```

Lists every device grouped by department, showing which group they belong to and flagging any device that is in the wrong group (i.e. whose department has changed). Useful before running a full sync.

#### Sync mode — apply changes

```powershell
# Apply — creates/updates groups, adds/removes members, cleans up stale memberships
.\Sync-IntuneDeviceGroups.ps1

# Dry run — show changes without writing anything
.\Sync-IntuneDeviceGroups.ps1 -DryRun
```

#### Stale membership cleanup

When a user moves to a different department their device needs to leave the old group and join the new one. The sync includes a cleanup step that:

1. Builds a map of device → correct group based on current department data
2. Scans all `DEPT-*` groups for devices that belong in a different group
3. Removes stale memberships before adding correct ones

This runs automatically as part of every sync. Use `-DryRun` to preview removals first.

### Run

```powershell
# Interactive sign-in (browser prompt)
.\Sync-IntuneDeviceGroups.ps1

# Dry run first to see what would change
.\Sync-IntuneDeviceGroups.ps1 -DryRun
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
      ├─► -Report  → preview table (no writes)
      ├─► -Audit   → membership audit table / CSV
      └─► Sync
              ├─ Remove stale memberships (department changes)
              ├─ Discover all existing DEPT-* groups
              ├─ Create missing groups
              ├─ Add devices that should be members
              └─ Remove devices that no longer belong
```

Devices with no assigned user, no department, or no matching AAD object ID are skipped.

---

## Automation

Schedule `Sync-DeviceGroups.ps1` or `Sync-IntuneDeviceGroups.ps1` as an **Azure Automation runbook** or a **Windows Task Scheduler** job to keep groups up to date automatically.

### Windows Task Scheduler

```
pwsh.exe -NonInteractive -File "C:\Scripts\azure-device-group-by-dept\Sync-IntuneDeviceGroups.ps1"
```

### Azure Automation runbook

1. Create an **Automation Account** in Azure Portal
2. Under **Modules**, import `Microsoft.Graph.Authentication`, `Microsoft.Graph.DeviceManagement`, `Microsoft.Graph.Groups`, `Microsoft.Graph.Users`
3. Create a **Managed Identity** for the Automation Account and grant it the required Graph API permissions
4. Create a **PowerShell 7.2 runbook** and paste the script content
5. Update the `TenantId` at the top of the script to use the managed identity sign-in method:
   ```powershell
   Connect-MgGraph -Identity
   ```
6. Schedule the runbook (daily recommended)

The managed identity removes the interactive browser prompt — the script will authenticate silently using the Automation Account's identity.
