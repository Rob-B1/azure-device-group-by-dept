<#
.SYNOPSIS
    Creates or updates one Entra ID (Azure AD) group per department containing
    all Intune-managed devices whose assigned user belongs to that department.

.DESCRIPTION
    1. Queries Intune for all Windows and macOS managed devices.
    2. Looks up each device's assigned user's department attribute.
    3. Resolves each Intune device to its Azure AD object ID.
    4. For each discovered department, ensures a security group named
       "DEPT-<Department> Devices" exists (creates it if missing).
    5. Syncs group membership: adds devices that belong and removes those that don't.

    Run with -WhatIf to preview all changes without making them.
    Groups managed by this script always begin with "DEPT-" and end with " Devices"
    so the script never touches unrelated groups.

.PARAMETER TenantId
    Entra ID tenant ID. Optional — narrows the interactive login to a specific tenant.

.PARAMETER Report
    Compute and display all pending adds, removes, and group creations without
    applying any changes. Useful for reviewing what the sync will do before running it.

.PARAMETER Audit
    Report the current state: for every Intune-managed device show its assigned user,
    department, and which DEPT-* group(s) it currently belongs to. No changes are made.

.PARAMETER OutputCsv
    When used with -Audit, writes the audit rows to this CSV file path.

.PARAMETER WhatIf
    Preview actions inline without applying any changes to Entra ID.

.EXAMPLE
    .\Sync-IntuneDeviceGroups.ps1 -Audit
    .\Sync-IntuneDeviceGroups.ps1 -Audit -OutputCsv .\audit.csv
    .\Sync-IntuneDeviceGroups.ps1 -Report
    .\Sync-IntuneDeviceGroups.ps1 -WhatIf
    .\Sync-IntuneDeviceGroups.ps1
    .\Sync-IntuneDeviceGroups.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [string] $TenantId = "",
    [switch] $Report,
    [switch] $Audit,
    [string] $OutputCsv = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Constants ──────────────────────────────────────────────────────────

$GroupPrefix = 'DEPT-'
$GroupSuffix = ' Devices'

#endregion

#region ── Helpers ────────────────────────────────────────────────────────────

function Install-GraphModules {
    $modules = @(
        'Microsoft.Graph.Authentication',
        'Microsoft.Graph.Identity.DirectoryManagement',
        'Microsoft.Graph.Users',
        'Microsoft.Graph.Groups',
        'Microsoft.Graph.DeviceManagement'
    )
    foreach ($module in $modules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Host "Installing $module ..." -ForegroundColor Yellow
            Install-Module $module -Scope CurrentUser -Force -AllowClobber
        }
        Import-Module $module -ErrorAction Stop
    }
}

function Connect-GraphInteractive {
    param ([string] $TenantId)

    $scopes = @(
        'DeviceManagementManagedDevices.Read.All',
        'User.Read.All',
        'Group.ReadWrite.All',
        'GroupMember.ReadWrite.All'
    )

    $connectParams = @{ Scopes = $scopes; NoWelcome = $true }
    if ($TenantId) { $connectParams['TenantId'] = $TenantId }

    Connect-MgGraph @connectParams
}

function Get-DepartmentForUser {
    param ([string] $UserId, [hashtable] $Cache)

    if ($Cache.ContainsKey($UserId)) { return $Cache[$UserId] }

    try {
        $user = Get-MgUser -UserId $UserId -Property 'Department' -ErrorAction Stop
        $dept = if ([string]::IsNullOrWhiteSpace($user.Department)) { $null } else { $user.Department.Trim() }
        $Cache[$UserId] = $dept
        return $dept
    }
    catch {
        Write-Warning "  Could not retrieve user ${UserId}: $_"
        $Cache[$UserId] = $null
        return $null
    }
}

function Get-OrCreateGroup {
    param ([string] $GroupName, [string] $Description, [bool] $DryRun)

    $existing = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction SilentlyContinue |
                Select-Object -First 1

    if ($existing) {
        Write-Host "    Group exists: $GroupName" -ForegroundColor DarkGray
        return $existing
    }

    if ($DryRun) {
        Write-Host "    [WHATIF] Would create group: $GroupName" -ForegroundColor Yellow
        return $null
    }

    Write-Host "    Creating group: $GroupName" -ForegroundColor Green
    $mailNickname = 'DEPT' + (($GroupName -replace "^$([regex]::Escape($GroupPrefix))", '') -replace '[^a-zA-Z0-9]', '')
    $newGroup = New-MgGroup -DisplayName $GroupName `
                            -Description $Description `
                            -MailEnabled:$false `
                            -MailNickname $mailNickname `
                            -SecurityEnabled:$true
    return $newGroup
}

function Sync-GroupMembers {
    param (
        [string]   $GroupId,
        [string[]] $DesiredDeviceIds,
        [bool]     $DryRun
    )

    # Read current membership inside a try-catch so that a failed API call
    # does not produce an empty list and cause every device to be re-added.
    try {
        $currentDeviceIds = @(
            Get-MgGroupMemberAsDevice -GroupId $GroupId -All |
            Select-Object -ExpandProperty Id
        )
    }
    catch {
        Write-Warning "      Could not read membership for group $GroupId — skipping sync: $_"
        return [PSCustomObject]@{ Added = 0; Removed = 0 }
    }

    $toAdd    = $DesiredDeviceIds | Where-Object { $_ -notin $currentDeviceIds }
    $toRemove = $currentDeviceIds | Where-Object { $_ -notin $DesiredDeviceIds }

    foreach ($deviceId in $toAdd) {
        if ($DryRun) {
            Write-Host "      [WHATIF] Would add device $deviceId" -ForegroundColor Yellow
        }
        else {
            Write-Host "      + Adding device $deviceId" -ForegroundColor Green
            try {
                $odataBody = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$deviceId" }
                New-MgGroupMemberByRef -GroupId $GroupId -BodyParameter $odataBody
            }
            catch {
                if (($_ | Out-String) -match 'already exist') {
                    Write-Verbose "      Device $deviceId already in group (skipped)."
                }
                else {
                    Write-Warning "      Failed to add ${deviceId}: $_"
                }
            }
        }
    }

    foreach ($deviceId in $toRemove) {
        if ($DryRun) {
            Write-Host "      [WHATIF] Would remove device $deviceId" -ForegroundColor Yellow
        }
        else {
            Write-Host "      - Removing device $deviceId" -ForegroundColor Red
            try {
                Remove-MgGroupMemberByRef -GroupId $GroupId -DirectoryObjectId $deviceId
            }
            catch {
                Write-Warning "      Failed to remove ${deviceId}: $_"
            }
        }
    }

    if (-not $toAdd -and -not $toRemove) {
        Write-Host "      (No membership changes)" -ForegroundColor DarkGray
    }

    return [PSCustomObject]@{ Added = $toAdd.Count; Removed = $toRemove.Count }
}

function Get-GroupChanges {
    param (
        [string]   $GroupId,           # $null when the group doesn't exist yet
        [string]   $GroupName,
        [string[]] $DesiredDeviceIds
    )

    if (-not $GroupId) {
        return [PSCustomObject]@{
            GroupName = $GroupName
            IsNew     = $true
            ToAdd     = $DesiredDeviceIds
            ToRemove  = @()
            Error     = $null
        }
    }

    try {
        $current = @(
            Get-MgGroupMemberAsDevice -GroupId $GroupId -All |
            Select-Object -ExpandProperty Id
        )
    }
    catch {
        return [PSCustomObject]@{
            GroupName = $GroupName
            IsNew     = $false
            ToAdd     = @()
            ToRemove  = @()
            Error     = "Could not read membership: $_"
        }
    }

    return [PSCustomObject]@{
        GroupName = $GroupName
        IsNew     = $false
        ToAdd     = @($DesiredDeviceIds | Where-Object { $_ -notin $current })
        ToRemove  = @($current | Where-Object { $_ -notin $DesiredDeviceIds })
        Error     = $null
    }
}

function Write-ChangeReport {
    param ([object[]] $Changes)

    Write-Host "`n== Pending Changes Report ==" -ForegroundColor Cyan
    Write-Host "  No changes will be applied. Run without -Report to sync.`n" -ForegroundColor DarkGray

    $totalNew      = 0
    $totalToAdd    = 0
    $totalToRemove = 0
    $unchanged     = 0
    $errorCount    = 0

    foreach ($change in ($Changes | Sort-Object GroupName)) {
        $hasChanges = $change.IsNew -or $change.ToAdd.Count -gt 0 -or $change.ToRemove.Count -gt 0
        $newLabel   = if ($change.IsNew) { '  [NEW GROUP]' } else { '' }

        Write-Host "  $($change.GroupName)$newLabel" -ForegroundColor White

        if ($change.Error) {
            Write-Host "    [ERROR] $($change.Error)" -ForegroundColor Red
            $errorCount++
        }
        elseif (-not $hasChanges) {
            Write-Host "    No changes" -ForegroundColor DarkGray
            $unchanged++
        }
        else {
            if ($change.IsNew) { $totalNew++ }
            if ($change.ToAdd.Count -gt 0) {
                Write-Host "    Add ($($change.ToAdd.Count)):" -ForegroundColor Green
                $change.ToAdd | ForEach-Object { Write-Host "      + $_" -ForegroundColor Green }
                $totalToAdd += $change.ToAdd.Count
            }
            if ($change.ToRemove.Count -gt 0) {
                Write-Host "    Remove ($($change.ToRemove.Count)):" -ForegroundColor Red
                $change.ToRemove | ForEach-Object { Write-Host "      - $_" -ForegroundColor Red }
                $totalToRemove += $change.ToRemove.Count
            }
        }
        Write-Host ""
    }

    Write-Host "── Summary ──────────────────────────────────────────────────────" -ForegroundColor Cyan
    Write-Host "  Groups to create  : $totalNew"
    Write-Host "  Devices to add    : $totalToAdd"
    Write-Host "  Devices to remove : $totalToRemove"
    Write-Host "  Groups unchanged  : $unchanged"
    if ($errorCount -gt 0) {
        Write-Host "  Read errors       : $errorCount" -ForegroundColor Red
    }
}

function Get-DeviceGroupMap {
    param ([hashtable] $DeptGroups)

    $map = @{}   # aadObjectId -> List<groupDisplayName>
    foreach ($dept in $DeptGroups.Keys) {
        $grp = $DeptGroups[$dept]
        try {
            $memberIds = @(
                Get-MgGroupMemberAsDevice -GroupId $grp.Id -All |
                Select-Object -ExpandProperty Id
            )
        }
        catch {
            Write-Warning "  Could not read members of '$($grp.DisplayName)': $_"
            continue
        }
        foreach ($memberId in $memberIds) {
            if (-not $map.ContainsKey($memberId)) {
                $map[$memberId] = [System.Collections.Generic.List[string]]::new()
            }
            $map[$memberId].Add($grp.DisplayName)
        }
    }
    return $map
}

function Write-AuditReport {
    param (
        [object[]] $Rows,
        [string]   $OutputCsv
    )

    Write-Host "`n== Intune Device Audit Report ==" -ForegroundColor Cyan
    Write-Host "  Showing current device, user, and DEPT group membership.`n" -ForegroundColor DarkGray

    $grouped = $Rows | Group-Object Department | Sort-Object Name
    foreach ($grp in $grouped) {
        Write-Host "  Department: $($grp.Name) ($($grp.Count) device(s))" -ForegroundColor White
        foreach ($row in ($grp.Group | Sort-Object DeviceName)) {
            $color = if ($row.DeptGroups -eq '(Not in any DEPT group)') { 'DarkGray' } else { 'Green' }
            Write-Host ("    {0,-32} {1,-35} {2}" -f $row.DeviceName, $row.UserUPN, $row.DeptGroups) -ForegroundColor $color
        }
        Write-Host ""
    }

    $inGroup    = @($Rows | Where-Object { $_.DeptGroups -ne '(Not in any DEPT group)' }).Count
    $notInGroup = @($Rows | Where-Object { $_.DeptGroups -eq '(Not in any DEPT group)' }).Count
    $noUser     = @($Rows | Where-Object { $_.UserUPN -eq '(No user)' }).Count
    $noAAD      = @($Rows | Where-Object { $_.AADObjectId -eq '(Not in AAD)' }).Count

    Write-Host "── Summary ──────────────────────────────────────────────────────" -ForegroundColor Cyan
    Write-Host "  Total devices       : $($Rows.Count)"
    Write-Host "  In a DEPT group     : $inGroup"
    Write-Host "  Not in any group    : $notInGroup"
    if ($noUser  -gt 0) { Write-Host "  No assigned user    : $noUser"  -ForegroundColor Yellow }
    if ($noAAD   -gt 0) { Write-Host "  Not found in AAD    : $noAAD"   -ForegroundColor Yellow }

    if ($OutputCsv) {
        $Rows | Sort-Object Department, DeviceName |
            Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
        Write-Host "`n  Report saved to: $OutputCsv" -ForegroundColor Green
    }
}

#endregion

#region ── Main ───────────────────────────────────────────────────────────────

Write-Host '== Intune – Sync Device Groups by Department ==' -ForegroundColor Cyan

$isDryRun = $WhatIfPreference.IsPresent
if ($isDryRun) {
    Write-Host '[DRY RUN] No changes will be made.' -ForegroundColor Yellow
}

# Install and import required Graph modules
Install-GraphModules

# Authenticate interactively (browser prompt)
Connect-GraphInteractive -TenantId $TenantId

# ── Step 1: Fetch Intune-managed devices ──────────────────────────────────────
Write-Host "`nStep 1/4  Fetching Intune-managed Windows and macOS devices..."
$intuneDevices = Get-MgDeviceManagementManagedDevice -All `
    -Filter "operatingSystem eq 'Windows' or operatingSystem eq 'macOS'" `
    -Property 'id,deviceName,operatingSystem,userId,userPrincipalName,azureADDeviceId'
Write-Host "  Found $($intuneDevices.Count) device(s)."

# ── Step 2: Build Azure AD device ID map ─────────────────────────────────────
Write-Host "`nStep 2/4  Building Azure AD device ID map..."
$aadDevices = Get-MgDevice -All
$aadDeviceMap = @{}
foreach ($aad in $aadDevices) {
    if ($aad.DeviceId) { $aadDeviceMap[$aad.DeviceId] = $aad.Id }
}
Write-Host "  Mapped $($aadDeviceMap.Count) Azure AD device(s)."

# ── Step 3: Map devices to departments ───────────────────────────────────────
Write-Host "`nStep 3/4  Mapping devices to departments via assigned user lookup..."
$userCache     = @{}
$deptDeviceMap = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new()

$i = 0
foreach ($device in $intuneDevices) {
    $i++
    Write-Progress -Activity 'Mapping devices' -Status $device.deviceName -PercentComplete (($i / $intuneDevices.Count) * 100)

    # Resolve Intune device to Azure AD object ID
    if (-not $device.azureADDeviceId -or -not $aadDeviceMap.ContainsKey($device.azureADDeviceId)) {
        Write-Verbose "  No AAD object ID for $($device.deviceName) (azureADDeviceId: $($device.azureADDeviceId)). Skipping."
        continue
    }
    $aadObjectId = $aadDeviceMap[$device.azureADDeviceId]

    # Resolve assigned user's department
    if (-not $device.userId) { continue }
    $dept = Get-DepartmentForUser -UserId $device.userId -Cache $userCache
    if (-not $dept) { continue }

    if (-not $deptDeviceMap.ContainsKey($dept)) {
        $deptDeviceMap[$dept] = [System.Collections.Generic.List[string]]::new()
    }
    if ($aadObjectId -notin $deptDeviceMap[$dept]) {
        $deptDeviceMap[$dept].Add($aadObjectId)
    }
}
Write-Progress -Activity 'Mapping devices' -Completed

$deptList = if ($deptDeviceMap.Count -gt 0) { $deptDeviceMap.Keys -join ', ' } else { '(none)' }
Write-Host "  Departments found: $deptList"

# ── Step 4: Sync groups ───────────────────────────────────────────────────────
Write-Host "`nStep 4/4  Syncing groups..."

$totalAdded    = 0
$totalRemoved  = 0
$groupsCreated = 0

# Seed deptGroups from ALL existing DEPT-* Devices groups so stale departments
# are iterated and have their members removed even when they now have zero devices.
$deptGroups = @{}
$existingGroups = Get-MgGroup `
    -Filter "startsWith(displayName,'$GroupPrefix') and securityEnabled eq true" `
    -ConsistencyLevel eventual `
    -CountVariable existingCount `
    -All
foreach ($grp in $existingGroups) {
    $existingDept = $grp.DisplayName.Substring($GroupPrefix.Length) -replace "$([regex]::Escape($GroupSuffix))$", ''
    if (-not $deptGroups.ContainsKey($existingDept)) {
        $deptGroups[$existingDept] = $grp
    }
}

# ── Report mode: show all pending changes and exit without writing anything ───
if ($Report) {
    $allDepts = @(@($deptGroups.Keys) + @($deptDeviceMap.Keys) | Sort-Object -Unique)
    $changes  = foreach ($dept in $allDepts) {
        $deviceIds = [string[]]@()
        if ($deptDeviceMap.ContainsKey($dept)) { $deviceIds = [string[]]$deptDeviceMap[$dept] }
        $groupName = "$GroupPrefix$dept$GroupSuffix"
        $groupId   = if ($deptGroups.ContainsKey($dept)) { $deptGroups[$dept].Id } else { $null }
        Get-GroupChanges -GroupId $groupId -GroupName $groupName -DesiredDeviceIds $deviceIds
    }
    Write-ChangeReport -Changes $changes
    Disconnect-MgGraph | Out-Null
    return
}

# ── Audit mode: report current device → user → DEPT group membership ─────────
if ($Audit) {
    Write-Host "`nBuilding device group membership map..."
    $deviceGroupMap = Get-DeviceGroupMap -DeptGroups $deptGroups

    $auditRows = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($device in $intuneDevices) {
        $aadObjectId = $null
        if ($device.azureADDeviceId -and $aadDeviceMap.ContainsKey($device.azureADDeviceId)) {
            $aadObjectId = $aadDeviceMap[$device.azureADDeviceId]
        }

        $dept = $null
        if ($device.userId) {
            $dept = Get-DepartmentForUser -UserId $device.userId -Cache $userCache
        }

        $groupStr = if ($aadObjectId -and $deviceGroupMap.ContainsKey($aadObjectId)) {
            $deviceGroupMap[$aadObjectId] -join '; '
        } else {
            '(Not in any DEPT group)'
        }

        $auditRows.Add([PSCustomObject]@{
            DeviceName  = $device.deviceName
            OS          = $device.operatingSystem
            UserUPN     = if ($device.userPrincipalName) { $device.userPrincipalName } else { '(No user)' }
            Department  = if ($dept) { $dept } else { '(No department)' }
            DeptGroups  = $groupStr
            AADObjectId = if ($aadObjectId) { $aadObjectId } else { '(Not in AAD)' }
            IntuneId    = $device.id
        })
    }

    Write-AuditReport -Rows $auditRows -OutputCsv $OutputCsv
    Disconnect-MgGraph | Out-Null
    return
}

# Create groups for newly discovered departments that don't have one yet
foreach ($dept in $deptDeviceMap.Keys) {
    if ($deptGroups.ContainsKey($dept)) { continue }
    $groupName = "$GroupPrefix$dept$GroupSuffix"
    $groupDesc = "Intune-managed device group for $dept department"
    $group = Get-OrCreateGroup -GroupName $groupName -Description $groupDesc -DryRun $isDryRun
    if ($group) { $deptGroups[$dept] = $group } else { $groupsCreated++ }
}

# Sync all groups — current departments and any existing groups whose department
# now has zero devices (their $deviceIds will be empty, removing all stale members)
foreach ($dept in ($deptGroups.Keys | Sort-Object)) {
    $deviceIds = [string[]]@()
    if ($deptDeviceMap.ContainsKey($dept)) {
        $deviceIds = [string[]]$deptDeviceMap[$dept]
    }
    $groupName = "$GroupPrefix$dept$GroupSuffix"
    Write-Host "`n  Department: $dept ($($deviceIds.Count) device(s)) -> Group: $groupName"

    $result = Sync-GroupMembers -GroupId $deptGroups[$dept].Id -DesiredDeviceIds $deviceIds -DryRun $isDryRun
    $totalAdded   += $result.Added
    $totalRemoved += $result.Removed
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n== Summary ==" -ForegroundColor Cyan
Write-Host "  Departments processed : $($deptGroups.Count)"
Write-Host "  Groups created        : $groupsCreated"
Write-Host "  Members added         : $totalAdded"
Write-Host "  Members removed       : $totalRemoved"

if ($isDryRun) {
    Write-Host "`n[DRY RUN] Re-run without -WhatIf to apply changes." -ForegroundColor Yellow
}

Disconnect-MgGraph | Out-Null
Write-Host "`nDone." -ForegroundColor Green

#endregion
