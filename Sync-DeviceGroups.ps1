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
    5. Writes a JSON run summary to AuditOutputDir (default: ./audit-logs) —
       including on failed runs, with a status/error field.
    6. Uploads the summary to S3 if S3Bucket is configured in config.json.

    Run with -WhatIf to preview all changes without making them.

    Safety guards:
      - Aborts if Get-MgDevice returns an implausibly low device count (< 5).
      - A device whose owner or department lookup fails is treated as
        "unknown" and is never removed from any group during that run.
      - If more than 20% of a group's members would be removed, that group is
        skipped with a warning unless -Force is passed.

    Config fields (config.json):
      TenantId            — Entra ID tenant ID
      GroupNamePrefix     — prefix for all managed groups (e.g. "DEPT-DEVICES-");
                            must be at least 3 characters
      GroupDescription    — group description template; {Department} is substituted
      ExcludeDepartments  — departments to always skip (blocklist)
      AllowedDepartments  — if non-empty, only these departments are processed;
                            anything else triggers a warning and is skipped (allowlist)
      DryRun              — if true, preview changes without applying (optional)
      AuditOutputDir      — local directory for JSON run summaries (default: ./audit-logs)
      S3Bucket            — S3 bucket name for long-term audit retention (optional)
      S3Prefix            — S3 key prefix for uploads (default: "azure-device-sync/")

.PARAMETER ConfigPath
    Path to config.json. Defaults to config.json in the same directory as this script.

.PARAMETER WhatIf
    Preview actions without applying any changes to Azure AD.

.PARAMETER Audit
    Report current group membership without making any changes and write an
    audit log with audit_only=true. Equivalent to -WhatIf but produces a
    structured audit log for compliance review.

.PARAMETER Force
    Override the 20% per-group removal safety threshold.

.EXAMPLE
    .\Sync-DeviceGroups.ps1 -WhatIf
    .\Sync-DeviceGroups.ps1
    .\Sync-DeviceGroups.ps1 -Audit
    .\Sync-DeviceGroups.ps1 -Force
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch] $Audit,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'SharedFunctions.psm1') -Force

#region ── Helpers ────────────────────────────────────────────────────────────

# Named Connect-GraphSession (not Connect-Graph) because recent
# Microsoft.Graph.Authentication versions export a 'Connect-Graph' alias that
# would shadow a local function of the same name.
function Connect-GraphSession {
    param ($Config)
    Connect-MgGraph -TenantId $Config.TenantId `
        -Scopes 'Device.Read.All', 'User.Read.All', 'Group.ReadWrite.All', 'GroupMember.ReadWrite.All' `
        -NoWelcome
}

function Export-RunSummary {
    param (
        [hashtable] $Summary,
        [string]    $OutputDir,
        [string]    $S3Bucket,
        [string]    $S3Prefix
    )

    # Always write locally. -WhatIf:$false: the audit record itself must be
    # written even on -WhatIf runs (it carries the dry_run/status fields).
    $null = New-Item -ItemType Directory -Force -Path $OutputDir -WhatIf:$false
    $timestamp = $Summary.timestamp_utc -replace '[:\-]', '' -replace 'T', '_' -replace 'Z', ''
    $fileName  = "sync_$timestamp.json"
    $localPath = Join-Path $OutputDir $fileName
    $Summary | ConvertTo-Json -Depth 5 | Set-Content -Path $localPath -Encoding UTF8 -WhatIf:$false
    Write-Host "  Audit log : $localPath" -ForegroundColor DarkGray

    # Upload to S3 if configured. Note: try/catch does NOT catch native command
    # failures, so the exit code must be checked explicitly.
    if ($S3Bucket) {
        if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
            Write-Warning "  S3 upload FAILED: AWS CLI ('aws') not found on PATH. Audit log retained locally at $localPath"
            return
        }

        $s3Key = "$S3Prefix$fileName"
        aws s3 cp "$localPath" "s3://$S3Bucket/$s3Key" --quiet
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "  S3 upload FAILED (aws exit code $LASTEXITCODE) for s3://$S3Bucket/$s3Key. Audit log retained locally at $localPath"
        }
        else {
            Write-Host "  S3 upload : s3://$S3Bucket/$s3Key" -ForegroundColor DarkGray
        }
    }
}

#endregion

#region ── Main ───────────────────────────────────────────────────────────────

Write-Host '== Entra ID – Sync Device Groups by Department ==' -ForegroundColor Cyan

$runId    = [System.Guid]::NewGuid().ToString()
$startUtc = [DateTime]::UtcNow

# $WhatIfPreference is a plain [bool] when -WhatIf is not passed; casting keeps
# this safe under Set-StrictMode (no .IsPresent on a bool).
$isDryRun = [bool]$WhatIfPreference -or $Audit.IsPresent

# ── Load and validate config ─────────────────────────────────────────────────
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

$requiredFields = @('TenantId', 'GroupNamePrefix', 'GroupDescription', 'ExcludeDepartments',
                    'AllowedDepartments', 'AuditOutputDir', 'S3Bucket', 'S3Prefix')
$missingFields = @($requiredFields | Where-Object { $config.PSObject.Properties.Name -notcontains $_ })
if ($missingFields.Count -gt 0) {
    throw "config.json is missing required field(s): $($missingFields -join ', '). See README for the full example config."
}

$groupPrefix = [string]$config.GroupNamePrefix
# An empty/short prefix would match (and destructively manage) far too many
# groups tenant-wide. Refuse to run.
if ([string]::IsNullOrWhiteSpace($groupPrefix) -or $groupPrefix.Trim().Length -lt 3) {
    throw "GroupNamePrefix must be non-empty and at least 3 characters (got: '$groupPrefix'). Refusing to run with a tenant-wide group scope."
}

$excludeDepts = [string[]]($config.ExcludeDepartments ?? @())
$allowedDepts = [string[]]($config.AllowedDepartments ?? @())
$auditDir     = if ($config.AuditOutputDir) { $config.AuditOutputDir } else { Join-Path $PSScriptRoot 'audit-logs' }
$s3Bucket     = $config.S3Bucket ?? ''
$s3Prefix     = if ($config.S3Prefix) { $config.S3Prefix } else { 'azure-device-sync/' }

if (($config.PSObject.Properties.Name -contains 'DryRun') -and $config.DryRun -eq $true) {
    $isDryRun = $true
}

# Wire ShouldProcess at the destructive boundary: honors -Confirm, and keeps
# -WhatIf semantics consistent with the declared SupportsShouldProcess.
if (-not $isDryRun -and -not $PSCmdlet.ShouldProcess('Entra ID department device groups', 'Apply group and membership changes')) {
    $isDryRun = $true
}

if ($Audit.IsPresent) {
    Write-Host '[AUDIT] Read-only audit run — no changes will be made.' -ForegroundColor Cyan
} elseif ($isDryRun) {
    Write-Host '[DRY RUN] No changes will be made.' -ForegroundColor Yellow
}
if ($allowedDepts.Count -gt 0) {
    Write-Host "AllowedDepartments filter active ($($allowedDepts.Count) departments)." -ForegroundColor DarkGray
}

# ── State initialized up front so the finally block can always build a summary ──
$executedBy          = 'unknown'
$devices             = @()
$deptGroups          = @{}
$totalAdded          = 0
$totalRemoved        = 0
$groupsCreated       = 0
$groupsSkipped       = 0
$groupChanges        = [System.Collections.Generic.List[hashtable]]::new()
$unknownDepts        = [System.Collections.Generic.HashSet[string]]::new()
$unresolvedDeviceIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$runError            = $null
$graphConnected      = $false

try {
    # Ensure Microsoft.Graph modules are available
    Initialize-GraphModules -Modules @(
        'Microsoft.Graph.Authentication',
        'Microsoft.Graph.Identity.DirectoryManagement',
        'Microsoft.Graph.Users',
        'Microsoft.Graph.Groups'
    )

    Connect-GraphSession -Config $config
    $graphConnected = $true

    # Managed identities have no .Account — fall back to app identity fields.
    $mgContext  = Get-MgContext
    $executedBy = $mgContext.Account ?? $mgContext.AppDisplayName ?? $mgContext.ClientId ?? 'unknown'

    # ── Step 1: Fetch all devices ─────────────────────────────────────────────
    Write-Host "`nStep 1/3  Fetching all devices..."
    $devices = @(Get-MgDevice -All -Property 'Id,DisplayName')
    Write-Host "  Found $($devices.Count) device(s)."

    # Guard: an empty/implausibly small device list is almost certainly a Graph
    # failure; proceeding would empty every managed group.
    if ($devices.Count -lt 5) {
        throw "Get-MgDevice returned only $($devices.Count) device(s) — implausibly low. Aborting sync to avoid mass-removing group members."
    }

    # ── Step 2: Map devices to departments ───────────────────────────────────
    Write-Host "`nStep 2/3  Mapping devices to departments via owner lookup..."
    $userCache     = @{}
    $deptDeviceMap = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)

    $i = 0
    foreach ($device in $devices) {
        $i++
        Write-Progress -Activity 'Mapping devices' -Status $device.DisplayName -PercentComplete (($i / $devices.Count) * 100)

        # A failed owner lookup means the device's status is UNKNOWN, not
        # ownerless — mark it protected so it is never removed this run.
        try {
            $owners = @(Get-MgDeviceRegisteredOwner -DeviceId $device.Id -All -ErrorAction Stop)
        }
        catch {
            Write-Warning "  Could not read owners of device $($device.DisplayName) ($($device.Id)) — skipping (protected from removal): $_"
            $null = $unresolvedDeviceIds.Add($device.Id)
            continue
        }
        if (-not $owners) { continue }   # genuinely ownerless

        foreach ($owner in $owners) {
            $lookup = Get-DepartmentForUser -UserId $owner.Id -Cache $userCache
            if ($lookup.LookupFailed) {
                # Unknown department — protect the device from removals this run.
                $null = $unresolvedDeviceIds.Add($device.Id)
                continue
            }
            $dept = $lookup.Department
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
    if ($unresolvedDeviceIds.Count -gt 0) {
        Write-Warning "  $($unresolvedDeviceIds.Count) device(s) had failed owner/department lookups — they will not be removed from any group this run."
    }

    Write-Host "  Departments to sync: $($deptDeviceMap.Keys -join ', ')"

    # ── Step 3: Sync groups ───────────────────────────────────────────────────
    Write-Host "`nStep 3/3  Syncing groups..."

    # Seed $deptGroups from ALL existing groups that match the prefix so that
    # departments which now have zero devices are still iterated and have stale
    # members removed.
    $safePrefix = ConvertTo-ODataLiteral -Value $groupPrefix
    $existingGroups = @(Get-MgGroup `
        -Filter "startsWith(displayName,'$safePrefix') and securityEnabled eq true" `
        -ConsistencyLevel eventual `
        -CountVariable existingCount `
        -All)
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
        $created = Get-OrCreateGroup -GroupName $groupName -Description $groupDesc -DryRun $isDryRun
        if ($created.Created) { $groupsCreated++ }
        if ($created.Group)   { $deptGroups[$dept] = $created.Group }
    }

    # Sync ALL groups — current departments AND existing groups whose department
    # now has zero devices (their $deviceIds will be empty, removing all stale
    # members — subject to the 20% safety threshold)
    foreach ($dept in ($deptGroups.Keys | Sort-Object)) {
        $deviceIds = @()
        if ($deptDeviceMap.ContainsKey($dept)) {
            $deviceIds = [string[]]$deptDeviceMap[$dept]
        }
        $groupName = "$groupPrefix$dept"

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

        $groupChanges.Add(@{
            department      = $dept
            group           = $groupName
            members_added   = $result.Added
            members_removed = $result.Removed
            skipped         = $result.Skipped
        })
    }

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Host "`n== Summary ==" -ForegroundColor Cyan
    Write-Host "  Departments processed : $($deptGroups.Count)"
    Write-Host "  Groups created        : $groupsCreated"
    Write-Host "  Groups skipped (guard): $groupsSkipped"
    Write-Host "  Members added         : $totalAdded"
    Write-Host "  Members removed       : $totalRemoved"
    if ($unknownDepts.Count -gt 0) {
        Write-Host "  Unknown departments   : $($unknownDepts.Count) (skipped — see warnings above)" -ForegroundColor Yellow
    }

    if ($isDryRun) {
        Write-Host "`n[DRY RUN] Re-run without -WhatIf to apply changes." -ForegroundColor Yellow
    }
}
catch {
    $runError = $_
}
finally {
    # ── Audit export — always runs, even on failure ──────────────────────────
    $runSummary = @{
        run_id        = $runId
        timestamp_utc = $startUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
        executed_by   = $executedBy
        dry_run       = $isDryRun
        audit_only    = $Audit.IsPresent
        status        = if ($runError) { 'failed' } else { 'success' }
        error         = if ($runError) { "$runError" } else { $null }
        config = @{
            group_prefix        = $groupPrefix
            exclude_departments = $excludeDepts
            allowed_departments = $allowedDepts
        }
        results = @{
            devices_total         = $devices.Count
            departments_processed = $deptGroups.Count
            groups_created        = $groupsCreated
            groups_skipped        = $groupsSkipped
            members_added         = $totalAdded
            members_removed       = $totalRemoved
            unknown_departments   = @($unknownDepts)
            unresolved_devices    = $unresolvedDeviceIds.Count
        }
        group_changes = @($groupChanges)
    }

    Write-Host "`n== Audit log ==" -ForegroundColor Cyan
    try {
        Export-RunSummary -Summary $runSummary -OutputDir $auditDir -S3Bucket $s3Bucket -S3Prefix $s3Prefix
    }
    catch {
        Write-Warning "Failed to write run summary: $_"
    }

    if ($graphConnected) {
        try { Disconnect-MgGraph | Out-Null } catch { Write-Warning "Disconnect-MgGraph failed: $_" }
    }
}

if ($runError) {
    throw $runError
}

Write-Host "`nDone." -ForegroundColor Green

#endregion
