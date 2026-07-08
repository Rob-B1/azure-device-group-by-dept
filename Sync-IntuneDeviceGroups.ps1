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
    5. Removes any device from DEPT groups it no longer belongs to (department changes).
    6. Syncs group membership: adds devices that belong and removes those that don't.

    Run with -WhatIf (or -DryRun) to preview all changes without making them.
    Groups managed by this script must both begin with "DEPT-" AND end with
    " Devices" — groups matching only one of the two are never touched.

    Safety guards:
      - Aborts a sync if the Intune or Entra ID device query returns an
        implausibly low device count (< 5).
      - A device whose assigned user's department lookup fails is treated as
        "unknown" and is never removed from any group during that run.
      - If more than 20% of a group's members would be removed, that group is
        skipped with a warning unless -Force is passed.

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

.PARAMETER DryRun
    Preview actions inline without applying any changes to Entra ID (same as -WhatIf).

.PARAMETER WhatIf
    Preview actions inline without applying any changes to Entra ID.

.PARAMETER Force
    Override the 20% per-group removal safety threshold.

.EXAMPLE
    .\Sync-IntuneDeviceGroups.ps1 -Audit
    .\Sync-IntuneDeviceGroups.ps1 -Audit -OutputCsv .\audit.csv
    .\Sync-IntuneDeviceGroups.ps1 -Report
    .\Sync-IntuneDeviceGroups.ps1 -WhatIf
    .\Sync-IntuneDeviceGroups.ps1 -DryRun
    .\Sync-IntuneDeviceGroups.ps1
    .\Sync-IntuneDeviceGroups.ps1 -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [string] $TenantId = "",
    [switch] $Report,
    [switch] $Audit,
    [string] $OutputCsv = "",
    [switch] $DryRun,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'SharedFunctions.psm1') -Force

#region ── Constants ──────────────────────────────────────────────────────────

$GroupPrefix = 'DEPT-'
$GroupSuffix = ' Devices'

#endregion

#region ── Helpers ────────────────────────────────────────────────────────────

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
            ToAdd     = @($DesiredDeviceIds)
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

function Remove-StaleGroupMembers {
    param (
        [object]    $DeptDeviceMap,       # Dictionary<dept, List<aadObjectId>>
        [hashtable] $DeptGroups,          # dept -> group object
        [string[]]  $ProtectedDeviceIds = @(),  # devices with unknown status — never remove
        [bool]      $DryRun = $false,
        [bool]      $Force = $false
    )

    # Build: aadObjectId -> correct group ID so we can detect misplaced devices.
    $deviceCorrectGroup = @{}
    foreach ($dept in $DeptDeviceMap.Keys) {
        if (-not $DeptGroups.ContainsKey($dept)) { continue }
        foreach ($aadObjectId in $DeptDeviceMap[$dept]) {
            $deviceCorrectGroup[$aadObjectId] = $DeptGroups[$dept].Id
        }
    }

    $removed = 0
    foreach ($dept in ($DeptGroups.Keys | Sort-Object)) {
        $grp = $DeptGroups[$dept]
        try {
            $memberIds = @(
                Get-MgGroupMemberAsDevice -GroupId $grp.Id -All |
                Select-Object -ExpandProperty Id
            )
        }
        catch {
            Write-Warning "    Could not read members of '$($grp.DisplayName)' — skipping cleanup: $_"
            continue
        }

        $staleIds = @($memberIds | Where-Object {
            ($_ -notin $ProtectedDeviceIds) -and
            (-not $deviceCorrectGroup.ContainsKey($_) -or $deviceCorrectGroup[$_] -ne $grp.Id)
        })

        # Safety threshold: refuse to remove more than 20% of a group's members
        # in one cleanup pass unless explicitly forced.
        if (-not $Force -and $memberIds.Count -gt 0 -and ($staleIds.Count / $memberIds.Count) -gt 0.2) {
            Write-Warning ("    Skipping stale cleanup for '{0}': {1} of {2} members would be removed (>20% safety threshold). Re-run with -Force to override." -f $grp.DisplayName, $staleIds.Count, $memberIds.Count)
            continue
        }

        foreach ($memberId in $staleIds) {
            if ($DryRun) {
                Write-Host "    [WHATIF] Would remove stale device $memberId from $($grp.DisplayName)" -ForegroundColor Yellow
            }
            else {
                Write-Host "    - Stale: removing device $memberId from $($grp.DisplayName)" -ForegroundColor Red
                try {
                    Remove-MgGroupMemberByRef -GroupId $grp.Id -DirectoryObjectId $memberId
                    $removed++
                }
                catch {
                    Write-Warning "    Failed to remove stale ${memberId} from $($grp.DisplayName): $_"
                }
            }
        }
    }
    return $removed
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

# $WhatIfPreference is a plain [bool] when -WhatIf is not passed; casting keeps
# this safe under Set-StrictMode (no .IsPresent on a bool).
$isDryRun = [bool]$WhatIfPreference -or $DryRun.IsPresent
if ($isDryRun) {
    Write-Host '[DRY RUN] No changes will be made.' -ForegroundColor Yellow
}

# Install and import required Graph modules
Initialize-GraphModules -Modules @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Identity.DirectoryManagement',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Groups',
    'Microsoft.Graph.DeviceManagement'
)

$runError       = $null
$graphConnected = $false

try {
    # Authenticate interactively (browser prompt)
    Connect-GraphInteractive -TenantId $TenantId
    $graphConnected = $true

    # ── Step 1: Fetch Intune-managed devices ──────────────────────────────────
    Write-Host "`nStep 1/4  Fetching Intune-managed Windows and macOS devices..."
    $intuneDevices = @(Get-MgDeviceManagementManagedDevice -All `
        -Filter "operatingSystem eq 'Windows' or operatingSystem eq 'macOS'" `
        -Property 'id,deviceName,operatingSystem,userId,userPrincipalName,azureADDeviceId')
    Write-Host "  Found $($intuneDevices.Count) device(s)."

    # Guard: an implausibly small device list is almost certainly a query
    # failure; a sync based on it would empty every managed group.
    if (-not $Report -and -not $Audit -and $intuneDevices.Count -lt 5) {
        throw "Intune returned only $($intuneDevices.Count) managed device(s) — implausibly low. Aborting sync to avoid mass-removing group members."
    }

    # ── Step 2: Build Azure AD device ID map ─────────────────────────────────
    Write-Host "`nStep 2/4  Building Azure AD device ID map..."
    $aadDevices = @(Get-MgDevice -All)
    if (-not $Report -and -not $Audit -and $aadDevices.Count -lt 5) {
        throw "Get-MgDevice returned only $($aadDevices.Count) device(s) — implausibly low. Aborting sync to avoid mass-removing group members."
    }
    $aadDeviceMap = @{}
    foreach ($aad in $aadDevices) {
        if ($aad.DeviceId) { $aadDeviceMap[$aad.DeviceId] = $aad.Id }
    }
    Write-Host "  Mapped $($aadDeviceMap.Count) Azure AD device(s)."

    # ── Step 3: Map devices to departments ───────────────────────────────────
    Write-Host "`nStep 3/4  Mapping devices to departments via assigned user lookup..."
    $userCache           = @{}
    $unresolvedDeviceIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $deptDeviceMap       = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)

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

        # Resolve assigned user's department. A FAILED lookup means the device's
        # department is UNKNOWN — protect it from removals this run rather than
        # treating it as department-less.
        if (-not $device.userId) { continue }
        $lookup = Get-DepartmentForUser -UserId $device.userId -Cache $userCache
        if ($lookup.LookupFailed) {
            $null = $unresolvedDeviceIds.Add($aadObjectId)
            continue
        }
        $dept = $lookup.Department
        if (-not $dept) { continue }

        if (-not $deptDeviceMap.ContainsKey($dept)) {
            $deptDeviceMap[$dept] = [System.Collections.Generic.List[string]]::new()
        }
        if ($aadObjectId -notin $deptDeviceMap[$dept]) {
            $deptDeviceMap[$dept].Add($aadObjectId)
        }
    }
    Write-Progress -Activity 'Mapping devices' -Completed

    if ($unresolvedDeviceIds.Count -gt 0) {
        Write-Warning "  $($unresolvedDeviceIds.Count) device(s) had failed user/department lookups — they will not be removed from any group this run."
    }

    $deptList = if ($deptDeviceMap.Count -gt 0) { $deptDeviceMap.Keys -join ', ' } else { '(none)' }
    Write-Host "  Departments found: $deptList"

    # ── Step 4: Sync groups ───────────────────────────────────────────────────
    Write-Host "`nStep 4/4  Syncing groups..."

    $totalAdded    = 0
    $totalRemoved  = 0
    $staleRemoved  = 0
    $groupsCreated = 0
    $groupsSkipped = 0

    # Seed deptGroups from ALL existing "DEPT-* Devices" groups so stale departments
    # are iterated and have their members removed even when they now have zero devices.
    # Only groups matching BOTH the prefix and the suffix are adopted — this enforces
    # the "never touches unrelated groups" guarantee (e.g. "DEPT-Payroll" is skipped).
    $safePrefix = ConvertTo-ODataLiteral -Value $GroupPrefix
    $deptGroups = @{}
    $existingGroups = @(Get-MgGroup `
        -Filter "startsWith(displayName,'$safePrefix') and securityEnabled eq true" `
        -ConsistencyLevel eventual `
        -CountVariable existingCount `
        -All)
    foreach ($grp in $existingGroups) {
        if (-not $grp.DisplayName.EndsWith($GroupSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Verbose "  Ignoring group '$($grp.DisplayName)' — matches prefix but not suffix '$GroupSuffix'."
            continue
        }
        $existingDept = $grp.DisplayName.Substring($GroupPrefix.Length) -replace "$([regex]::Escape($GroupSuffix))$", ''
        if (-not $deptGroups.ContainsKey($existingDept)) {
            $deptGroups[$existingDept] = $grp
        }
    }

    # ── Report mode: show all pending changes and exit without writing anything ──
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
        return
    }

    # ── Audit mode: report current device → user → DEPT group membership ─────
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
                $lookup = Get-DepartmentForUser -UserId $device.userId -Cache $userCache
                if (-not $lookup.LookupFailed) { $dept = $lookup.Department }
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
        return
    }

    # Wire ShouldProcess at the destructive boundary: honors -Confirm, and keeps
    # -WhatIf semantics consistent with the declared SupportsShouldProcess.
    if (-not $isDryRun -and -not $PSCmdlet.ShouldProcess('DEPT-* Devices groups', 'Apply group and membership changes')) {
        $isDryRun = $true
    }

    # ── Cleanup: remove any device found in a group whose department it no longer belongs to ──
    Write-Host "`n  Removing stale group memberships (department changes)..."
    $staleRemoved = Remove-StaleGroupMembers -DeptDeviceMap $deptDeviceMap `
                                             -DeptGroups $deptGroups `
                                             -ProtectedDeviceIds @($unresolvedDeviceIds) `
                                             -DryRun $isDryRun `
                                             -Force $Force.IsPresent
    if (-not $isDryRun -and $staleRemoved -eq 0) {
        Write-Host "    (No stale memberships found)" -ForegroundColor DarkGray
    }

    # Create groups for newly discovered departments that don't have one yet
    foreach ($dept in $deptDeviceMap.Keys) {
        if ($deptGroups.ContainsKey($dept)) { continue }
        $groupName = "$GroupPrefix$dept$GroupSuffix"
        $groupDesc = "Intune-managed device group for $dept department"
        $created = Get-OrCreateGroup -GroupName $groupName -Description $groupDesc -DryRun $isDryRun
        if ($created.Created) { $groupsCreated++ }
        if ($created.Group)   { $deptGroups[$dept] = $created.Group }
    }

    # Sync all groups — current departments and any existing groups whose department
    # now has zero devices (their $deviceIds will be empty, removing all stale
    # members — subject to the 20% safety threshold)
    foreach ($dept in ($deptGroups.Keys | Sort-Object)) {
        $deviceIds = [string[]]@()
        if ($deptDeviceMap.ContainsKey($dept)) {
            $deviceIds = [string[]]$deptDeviceMap[$dept]
        }
        $groupName = "$GroupPrefix$dept$GroupSuffix"
        Write-Host "`n  Department: $dept ($($deviceIds.Count) device(s)) -> Group: $groupName"

        $result = Sync-GroupMembers -GroupId $deptGroups[$dept].Id `
                                    -GroupName $groupName `
                                    -DesiredDeviceIds $deviceIds `
                                    -ProtectedDeviceIds @($unresolvedDeviceIds) `
                                    -DryRun $isDryRun `
                                    -Force $Force.IsPresent
        $totalAdded   += $result.Added
        $totalRemoved += $result.Removed
        if ($result.Skipped) { $groupsSkipped++ }
    }

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Host "`n== Summary ==" -ForegroundColor Cyan
    Write-Host "  Departments processed : $($deptGroups.Count)"
    Write-Host "  Groups created        : $groupsCreated"
    Write-Host "  Groups skipped (guard): $groupsSkipped"
    Write-Host "  Stale memberships     : $staleRemoved"
    Write-Host "  Members added         : $totalAdded"
    Write-Host "  Members removed       : $totalRemoved"

    if ($isDryRun) {
        Write-Host "`n[DRY RUN] Re-run without -WhatIf to apply changes." -ForegroundColor Yellow
    }
}
catch {
    $runError = $_
}
finally {
    # Always disconnect, even when a mid-run failure occurs.
    if ($graphConnected) {
        try { Disconnect-MgGraph | Out-Null } catch { Write-Warning "Disconnect-MgGraph failed: $_" }
    }
}

if ($runError) {
    throw $runError
}

Write-Host "`nDone." -ForegroundColor Green

#endregion
