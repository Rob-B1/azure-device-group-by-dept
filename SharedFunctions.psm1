<#
.SYNOPSIS
    Shared helper functions for azure-device-group-by-dept scripts.

.DESCRIPTION
    Single source of truth for helpers that were previously duplicated (with
    drift) across Sync-DeviceGroups.ps1, Sync-IntuneDeviceGroups.ps1, and
    Get-DeviceReport.ps1:

      Initialize-GraphModules  — install/import required Microsoft.Graph modules
      ConvertTo-ODataLiteral   — escape single quotes for OData filter strings
      New-GroupMailNickname    — collision-resistant mailNickname (hash suffix, <=64 chars)
      Get-DepartmentForUser    — cached department lookup; distinguishes
                                 "no department" from "lookup failed"
      Get-OrCreateGroup        — idempotent group creation with dry-run support
      Sync-GroupMembers        — membership sync with read-failure guard,
                                 protected-device skip list, 20% removal safety
                                 threshold, and confirmed (not planned) counts
#>

Set-StrictMode -Version Latest

function Initialize-GraphModules {
    <#
    .SYNOPSIS
        Installs (CurrentUser scope) and imports the given Microsoft.Graph modules.
    #>
    param (
        [Parameter(Mandatory)] [string[]] $Modules
    )

    foreach ($module in $Modules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            Write-Host "Installing $module ..." -ForegroundColor Yellow
            Install-Module $module -Scope CurrentUser -Force -AllowClobber
        }
        # -Global so the cmdlets are visible to the calling script, not just this module.
        Import-Module $module -ErrorAction Stop -Global
    }
}

function ConvertTo-ODataLiteral {
    <#
    .SYNOPSIS
        Escapes a string for safe embedding inside a single-quoted OData filter
        literal (single quotes are doubled per the OData spec).
    #>
    param (
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value
    )
    return ($Value -replace "'", "''")
}

function New-GroupMailNickname {
    <#
    .SYNOPSIS
        Builds a deterministic, collision-resistant mailNickname for a group.

    .DESCRIPTION
        Sanitizing display names to alphanumerics can collide (e.g. "R&D" and
        "RD" both become "RD"). A short hash of the FULL group name is appended
        to disambiguate, and the result is clamped to 64 characters.
    #>
    param (
        [Parameter(Mandatory)] [string] $GroupName
    )

    $base = $GroupName -replace '[^a-zA-Z0-9]', ''
    if (-not $base) { $base = 'grp' }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($GroupName))
    }
    finally {
        $sha.Dispose()
    }
    $hash8 = -join ($hashBytes[0..3] | ForEach-Object { $_.ToString('x2') })

    $maxBaseLength = 64 - $hash8.Length
    if ($base.Length -gt $maxBaseLength) { $base = $base.Substring(0, $maxBaseLength) }

    return "$base$hash8"
}

function Get-DepartmentForUser {
    <#
    .SYNOPSIS
        Looks up a user's department, with caching.

    .OUTPUTS
        [PSCustomObject] with:
          Department   — trimmed department string, or $null if the user has none
          LookupFailed — $true when the Graph call failed (transient error, deleted
                         user, throttling). Callers MUST treat LookupFailed as
                         "unknown" and skip destructive actions for the device,
                         NOT as "user has no department".
    #>
    param (
        [Parameter(Mandatory)] [string]    $UserId,
        [Parameter(Mandatory)] [hashtable] $Cache
    )

    if ($Cache.ContainsKey($UserId)) { return $Cache[$UserId] }

    $result = $null
    try {
        $user = Get-MgUser -UserId $UserId -Property 'Department' -ErrorAction Stop
        $dept = if ([string]::IsNullOrWhiteSpace($user.Department)) { $null } else { $user.Department.Trim() }
        $result = [PSCustomObject]@{ Department = $dept; LookupFailed = $false }
    }
    catch {
        Write-Warning "  Could not retrieve user ${UserId}: $_"
        $result = [PSCustomObject]@{ Department = $null; LookupFailed = $true }
    }

    $Cache[$UserId] = $result
    return $result
}

function Get-OrCreateGroup {
    <#
    .SYNOPSIS
        Returns an existing group by display name, or creates it.

    .OUTPUTS
        [PSCustomObject] with:
          Group   — the group object ($null in dry-run when the group would be created)
          Created — $true when a group was created (or would be created in dry-run)
    #>
    param (
        [Parameter(Mandatory)] [string] $GroupName,
        [string] $Description = '',
        [bool]   $DryRun = $false
    )

    $safeName = ConvertTo-ODataLiteral -Value $GroupName
    $existing = Get-MgGroup -Filter "displayName eq '$safeName'" -ErrorAction SilentlyContinue |
                Select-Object -First 1

    if ($existing) {
        Write-Host "    Group exists: $GroupName" -ForegroundColor DarkGray
        return [PSCustomObject]@{ Group = $existing; Created = $false }
    }

    if ($DryRun) {
        Write-Host "    [WHATIF] Would create group: $GroupName" -ForegroundColor Yellow
        return [PSCustomObject]@{ Group = $null; Created = $true }
    }

    Write-Host "    Creating group: $GroupName" -ForegroundColor Green
    $newGroup = New-MgGroup -DisplayName $GroupName `
                            -Description $Description `
                            -MailEnabled:$false `
                            -MailNickname (New-GroupMailNickname -GroupName $GroupName) `
                            -SecurityEnabled:$true
    return [PSCustomObject]@{ Group = $newGroup; Created = $true }
}

function Sync-GroupMembers {
    <#
    .SYNOPSIS
        Syncs a group's device membership to a desired list.

    .DESCRIPTION
        Safety behavior:
          - If the current membership cannot be read, the group is skipped
            entirely (treated as no-change) rather than as empty.
          - Devices in ProtectedDeviceIds (owner/department lookup failed this
            run — status unknown) are never removed.
          - If more than 20% of current members would be removed, the group is
            skipped with a warning unless -Force.
        Returned Added/Removed counts are CONFIRMED successes (per-call), not
        planned counts. In dry-run they reflect what would be attempted.

    .OUTPUTS
        [PSCustomObject] with Added, Removed, Skipped.
    #>
    param (
        [Parameter(Mandatory)] [string] $GroupId,
        [string]   $GroupName = '',
        [string[]] $DesiredDeviceIds = @(),
        [string[]] $ProtectedDeviceIds = @(),
        [bool]     $DryRun = $false,
        [bool]     $Force = $false
    )

    $label = if ($GroupName) { $GroupName } else { $GroupId }

    # Read current membership inside a try-catch so a failed API call does not
    # produce an empty list and cause every device to be re-added (or, worse,
    # be treated as removable elsewhere). Failure = skip, not empty.
    try {
        $currentDeviceIds = @(
            Get-MgGroupMemberAsDevice -GroupId $GroupId -All -ErrorAction Stop |
            Select-Object -ExpandProperty Id
        )
    }
    catch {
        Write-Warning "      Could not read membership for group '$label' — skipping sync (treated as no-change): $_"
        return [PSCustomObject]@{ Added = 0; Removed = 0; Skipped = $true }
    }

    $toAdd    = @($DesiredDeviceIds | Where-Object { $_ -notin $currentDeviceIds })
    $toRemove = @($currentDeviceIds | Where-Object { $_ -notin $DesiredDeviceIds -and $_ -notin $ProtectedDeviceIds })

    # Safety threshold: refuse to remove more than 20% of a group's members in
    # one run unless explicitly forced. Protects against transient Graph
    # failures or bad data mass-emptying groups.
    if (-not $Force -and $currentDeviceIds.Count -gt 0 -and ($toRemove.Count / $currentDeviceIds.Count) -gt 0.2) {
        Write-Warning ("      Skipping group '{0}': {1} of {2} members would be removed (>20% safety threshold). Re-run with -Force to override." -f $label, $toRemove.Count, $currentDeviceIds.Count)
        return [PSCustomObject]@{ Added = 0; Removed = 0; Skipped = $true }
    }

    $added   = 0
    $removed = 0

    foreach ($deviceId in $toAdd) {
        if ($DryRun) {
            Write-Host "      [WHATIF] Would add device $deviceId" -ForegroundColor Yellow
            $added++
        }
        else {
            Write-Host "      + Adding device $deviceId" -ForegroundColor Green
            try {
                $odataBody = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$deviceId" }
                New-MgGroupMemberByRef -GroupId $GroupId -BodyParameter $odataBody -ErrorAction Stop
                $added++
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
            $removed++
        }
        else {
            Write-Host "      - Removing device $deviceId" -ForegroundColor Red
            try {
                Remove-MgGroupMemberByRef -GroupId $GroupId -DirectoryObjectId $deviceId -ErrorAction Stop
                $removed++
            }
            catch {
                Write-Warning "      Failed to remove ${deviceId}: $_"
            }
        }
    }

    if ($toAdd.Count -eq 0 -and $toRemove.Count -eq 0) {
        Write-Host "      (No membership changes)" -ForegroundColor DarkGray
    }

    return [PSCustomObject]@{ Added = $added; Removed = $removed; Skipped = $false }
}

Export-ModuleMember -Function @(
    'Initialize-GraphModules',
    'ConvertTo-ODataLiteral',
    'New-GroupMailNickname',
    'Get-DepartmentForUser',
    'Get-OrCreateGroup',
    'Sync-GroupMembers'
)
