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
    5. Writes a JSON run summary to AuditOutputDir (default: ./audit-logs).
    6. Uploads the summary to S3 if S3Bucket is configured in config.json.

    Run with -WhatIf to preview all changes without making them.

    Config fields (config.json):
      TenantId            — Entra ID tenant ID
      GroupNamePrefix     — prefix for all managed groups (e.g. "DEPT-DEVICES-")
      GroupDescription    — group description template; {Department} is substituted
      ExcludeDepartments  — departments to always skip (blocklist)
      AllowedDepartments  — if non-empty, only these departments are processed;
                            anything else triggers a warning and is skipped (allowlist)
      DryRun              — if true, preview changes without applying
      AuditOutputDir      — local directory for JSON run summaries (default: ./audit-logs)
      S3Bucket            — S3 bucket name for long-term audit retention (optional)
      S3Prefix            — S3 key prefix for uploads (default: "azure-device-sync/")

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

    # Use Get-MgGroupMemberAsDevice which returns only device-type members directly,
    # avoiding unreliable @odata.type filtering on generic DirectoryObject results.
    $currentDeviceIds = @(
        Get-MgGroupMemberAsDevice -GroupId $GroupId -All -ErrorAction SilentlyContinue |
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

function Export-RunSummary {
    param (
        [hashtable] $Summary,
        [string]    $OutputDir,
        [string]    $S3Bucket,
        [string]    $S3Prefix
    )

    # Always write locally
    $null = New-Item -ItemType Directory -Force -Path $OutputDir
    $timestamp = $Summary.timestamp_utc -replace '[:\-]', '' -replace 'T', '_' -replace 'Z', ''
    $fileName  = "sync_$timestamp.json"
    $localPath = Join-Path $OutputDir $fileName
    $Summary | ConvertTo-Json -Depth 5 | Set-Content -Path $localPath -Encoding UTF8
    Write-Host "  Audit log : $localPath" -ForegroundColor DarkGray

    # Upload to S3 if configured
    if ($S3Bucket) {
        $s3Key = "$S3Prefix$fileName"
        try {
            aws s3 cp $localPath "s3://$S3Bucket/$s3Key" --quiet
            Write-Host "  S3 upload : s3://$S3Bucket/$s3Key" -ForegroundColor DarkGray
        }
        catch {
            Write-Warning "  S3 upload failed: $_"
        }
    }
}

#endregion

#region ── Main ───────────────────────────────────────────────────────────────

Write-Host '== Entra ID – Sync Device Groups by Department ==' -ForegroundColor Cyan

$runId    = [System.Guid]::NewGuid().ToString()
$startUtc = [DateTime]::UtcNow

$isDryRun = $WhatIfPreference.IsPresent

# Load config
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config        = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$groupPrefix   = $config.GroupNamePrefix
$excludeDepts  = [string[]]($config.ExcludeDepartments ?? @())
$allowedDepts  = [string[]]($config.AllowedDepartments ?? @())
$auditDir      = if ($config.AuditOutputDir) { $config.AuditOutputDir } else { Join-Path $PSScriptRoot 'audit-logs' }
$s3Bucket      = $config.S3Bucket ?? ''
$s3Prefix      = if ($config.S3Prefix) { $config.S3Prefix } else { 'azure-device-sync/' }

if ($config.DryRun -eq $true) { $isDryRun = $true }

if ($isDryRun) {
    Write-Host '[DRY RUN] No changes will be made.' -ForegroundColor Yellow
}
if ($allowedDepts.Count -gt 0) {
    Write-Host "AllowedDepartments filter active ($($allowedDepts.Count) departments)." -ForegroundColor DarkGray
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
$executedBy = (Get-MgContext).Account ?? 'unknown'

# ── Step 1: Fetch all devices ─────────────────────────────────────────────────
Write-Host "`nStep 1/3  Fetching all devices..."
$devices = Get-MgDevice -All -Property 'Id,DisplayName,AccountEnabled'
Write-Host "  Found $($devices.Count) device(s)."

# ── Step 2: Map devices to departments ───────────────────────────────────────
Write-Host "`nStep 2/3  Mapping devices to departments via owner lookup..."
$userCache     = @{}
$unknownDepts  = [System.Collections.Generic.HashSet[string]]::new()
$deptDeviceMap = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new()

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

        # AllowedDepartments check — warn and skip if not on the allowlist
        if ($allowedDepts.Count -gt 0 -and $dept -notin $allowedDepts) {
            $null = $unknownDepts.Add($dept)
            continue
        }

        if (-not $deptDeviceMap.ContainsKey($dept)) {
            $deptDeviceMap[$dept] = [System.Collections.Generic.List[string]]::new()
        }
        if ($device.Id -notin $deptDeviceMap[$dept]) {
            $deptDeviceMap[$dept].Add($device.Id)
        }
    }
}
Write-Progress -Activity 'Mapping devices' -Completed

if ($unknownDepts.Count -gt 0) {
    Write-Warning "  $($unknownDepts.Count) department(s) not in AllowedDepartments — skipped: $($unknownDepts -join ', ')"
    Write-Warning "  Add them to AllowedDepartments in config.json to sync, or to ExcludeDepartments to suppress this warning."
}

Write-Host "  Departments to sync: $($deptDeviceMap.Keys -join ', ')"

# ── Step 3: Sync groups ───────────────────────────────────────────────────────
Write-Host "`nStep 3/3  Syncing groups..."

$totalAdded    = 0
$totalRemoved  = 0
$groupsCreated = 0
$groupChanges  = [System.Collections.Generic.List[hashtable]]::new()

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

    $groupChanges.Add(@{
        department    = $dept
        group         = $groupName
        members_added = $result.Added
        members_removed = $result.Removed
    })
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n== Summary ==" -ForegroundColor Cyan
Write-Host "  Departments processed : $($deptGroups.Count)"
Write-Host "  Groups created        : $groupsCreated"
Write-Host "  Members added         : $totalAdded"
Write-Host "  Members removed       : $totalRemoved"
if ($unknownDepts.Count -gt 0) {
    Write-Host "  Unknown departments   : $($unknownDepts.Count) (skipped — see warnings above)" -ForegroundColor Yellow
}

if ($isDryRun) {
    Write-Host "`n[DRY RUN] Re-run without -WhatIf to apply changes." -ForegroundColor Yellow
}

# ── Audit export ─────────────────────────────────────────────────────────────
$runSummary = @{
    run_id              = $runId
    timestamp_utc       = $startUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
    executed_by         = $executedBy
    dry_run             = $isDryRun
    config = @{
        group_prefix         = $groupPrefix
        exclude_departments  = $excludeDepts
        allowed_departments  = $allowedDepts
    }
    results = @{
        devices_total           = $devices.Count
        departments_processed   = $deptGroups.Count
        groups_created          = $groupsCreated
        members_added           = $totalAdded
        members_removed         = $totalRemoved
        unknown_departments     = @($unknownDepts)
    }
    group_changes = @($groupChanges)
}

Write-Host "`n== Audit log ==" -ForegroundColor Cyan
Export-RunSummary -Summary $runSummary -OutputDir $auditDir -S3Bucket $s3Bucket -S3Prefix $s3Prefix

Disconnect-MgGraph | Out-Null
Write-Host "`nDone." -ForegroundColor Green

#endregion
