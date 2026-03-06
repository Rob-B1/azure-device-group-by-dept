<#
.SYNOPSIS
    Creates or updates one Entra ID (Azure AD) group per department containing
    all devices whose registered owner belongs to that department.

.DESCRIPTION
    1. Queries all Entra ID devices and their registered owners.
    2. Looks up each owner's department attribute.
    3. For each discovered department, ensures a security group named
       "<GroupNamePrefix><Department>" exists (creates it if missing).
    4. Syncs group membership: adds devices that belong and removes those that don't.

    Run with -WhatIf to preview all changes without making them.

.PARAMETER ConfigPath
    Path to config.json. Defaults to config.json in the same directory as this script.

.PARAMETER WhatIf
    Preview actions without applying any changes to Azure AD.

.EXAMPLE
    .\Sync-DeviceGroups.ps1 -WhatIf
    .\Sync-DeviceGroups.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Helpers ────────────────────────────────────────────────────────────

function Connect-Graph {
    param ($Config)
    Connect-MgGraph -TenantId $Config.TenantId `
        -Scopes 'Device.Read.All', 'User.Read.All', 'Group.ReadWrite.All', 'GroupMember.ReadWrite.All' `
        -NoWelcome
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
        Write-Warning "  Could not retrieve user $UserId : $_"
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
    $newGroup = New-MgGroup -DisplayName $GroupName `
                            -Description $Description `
                            -MailEnabled:$false `
                            -MailNickname ($GroupName -replace '[^a-zA-Z0-9]', '') `
                            -SecurityEnabled:$true
    return $newGroup
}

function Sync-GroupMembers {
    param (
        [string]   $GroupId,
        [string[]] $DesiredDeviceIds,
        [bool]     $DryRun
    )

    # Current members (devices only – OData type lives in AdditionalProperties in the Graph SDK)
    $currentMembers = Get-MgGroupMember -GroupId $GroupId -All -ErrorAction SilentlyContinue
    $currentDeviceIds = @(
        $currentMembers |
        Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.device' } |
        Select-Object -ExpandProperty Id
    )

    $toAdd    = $DesiredDeviceIds | Where-Object { $_ -notin $currentDeviceIds }
    $toRemove = $currentDeviceIds | Where-Object { $_ -notin $DesiredDeviceIds }

    foreach ($deviceId in $toAdd) {
        if ($DryRun) {
            Write-Host "      [WHATIF] Would add device $deviceId" -ForegroundColor Yellow
        }
        else {
            Write-Host "      + Adding device $deviceId" -ForegroundColor Green
            $odataBody = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$deviceId" }
            New-MgGroupMemberByRef -GroupId $GroupId -BodyParameter $odataBody -ErrorAction SilentlyContinue
        }
    }

    foreach ($deviceId in $toRemove) {
        if ($DryRun) {
            Write-Host "      [WHATIF] Would remove device $deviceId" -ForegroundColor Yellow
        }
        else {
            Write-Host "      - Removing device $deviceId" -ForegroundColor Red
            Remove-MgGroupMemberByRef -GroupId $GroupId -DirectoryObjectId $deviceId -ErrorAction SilentlyContinue
        }
    }

    if (-not $toAdd -and -not $toRemove) {
        Write-Host "      (No membership changes)" -ForegroundColor DarkGray
    }

    return [PSCustomObject]@{ Added = $toAdd.Count; Removed = $toRemove.Count }
}

#endregion

#region ── Main ───────────────────────────────────────────────────────────────

Write-Host '== Entra ID – Sync Device Groups by Department ==' -ForegroundColor Cyan

$isDryRun = $WhatIfPreference.IsPresent

# Load config
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config       = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$groupPrefix  = $config.GroupNamePrefix
$excludeDepts = [string[]]($config.ExcludeDepartments ?? @())
if ($config.DryRun -eq $true) { $isDryRun = $true }

if ($isDryRun) {
    Write-Host '[DRY RUN] No changes will be made.' -ForegroundColor Yellow
}

# Ensure Microsoft.Graph modules are available
foreach ($module in @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.DirectoryManagement', 'Microsoft.Graph.Users', 'Microsoft.Graph.Groups')) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing $module ..." -ForegroundColor Yellow
        Install-Module $module -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module $module -ErrorAction Stop
}

Connect-Graph -Config $config

# ── Step 1: Fetch all devices ─────────────────────────────────────────────────
Write-Host "`nStep 1/3  Fetching all devices..."
$devices = Get-MgDevice -All -Property 'Id,DisplayName,AccountEnabled'
Write-Host "  Found $($devices.Count) device(s)."

# ── Step 2: Map devices to departments ───────────────────────────────────────
Write-Host "`nStep 2/3  Mapping devices to departments via owner lookup..."
$userCache        = @{}
# dept -> list of device IDs
$deptDeviceMap    = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new()

$i = 0
foreach ($device in $devices) {
    $i++
    Write-Progress -Activity 'Mapping devices' -Status $device.DisplayName -PercentComplete (($i / $devices.Count) * 100)

    $owners = Get-MgDeviceRegisteredOwner -DeviceId $device.Id -All -ErrorAction SilentlyContinue
    if (-not $owners) { continue }

    foreach ($owner in $owners) {
        $dept = Get-DepartmentForUser -UserId $owner.Id -Cache $userCache
        if (-not $dept) { continue }
        if ($dept -in $excludeDepts) { continue }

        if (-not $deptDeviceMap.ContainsKey($dept)) {
            $deptDeviceMap[$dept] = [System.Collections.Generic.List[string]]::new()
        }
        if ($device.Id -notin $deptDeviceMap[$dept]) {
            $deptDeviceMap[$dept].Add($device.Id)
        }
    }
}
Write-Progress -Activity 'Mapping devices' -Completed

Write-Host "  Departments found: $($deptDeviceMap.Keys -join ', ')"

# ── Step 3: Sync groups ───────────────────────────────────────────────────────
Write-Host "`nStep 3/3  Syncing groups..."

$totalAdded    = 0
$totalRemoved  = 0
$groupsCreated = 0

# Seed $deptGroups from ALL existing groups that match the prefix so that departments
# which now have zero devices are still iterated and have stale members removed.
$deptGroups = @{}
$existingGroups = Get-MgGroup `
    -Filter "startsWith(displayName,'$groupPrefix') and securityEnabled eq true" `
    -ConsistencyLevel eventual `
    -CountVariable existingCount `
    -All
foreach ($grp in $existingGroups) {
    $existingDept = $grp.DisplayName.Substring($groupPrefix.Length)
    if (-not $deptGroups.ContainsKey($existingDept)) {
        $deptGroups[$existingDept] = $grp
    }
}

# Create groups for departments that don't have one yet
foreach ($dept in $deptDeviceMap.Keys) {
    if ($deptGroups.ContainsKey($dept)) { continue }
    $groupName = "$groupPrefix$dept"
    $groupDesc = $config.GroupDescription -replace '\{Department\}', $dept
    $group = Get-OrCreateGroup -GroupName $groupName -Description $groupDesc -DryRun $isDryRun
    if ($group) { $deptGroups[$dept] = $group } else { $groupsCreated++ }
}

# Sync ALL groups — current departments AND existing groups whose department now
# has zero devices (their $deviceIds will be empty, removing all stale members)
foreach ($dept in ($deptGroups.Keys | Sort-Object)) {
    $deviceIds = @()
    if ($deptDeviceMap.ContainsKey($dept)) {
        $deviceIds = [string[]]$deptDeviceMap[$dept]
    }
    $groupName = "$groupPrefix$dept"

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
