# Requires: Microsoft.Graph PowerShell SDK, PowerShell 7+, correct Graph application permissions

# 1. Authentication - interactive browser credential prompt
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All", "User.Read.All", "Group.ReadWrite.All", "GroupMember.ReadWrite.All" -NoWelcome

# 2. Fetch Intune-managed Windows and macOS devices
Write-Host "Fetching Intune managed Windows/macOS devices..." -ForegroundColor Cyan
$devices = Get-MgDeviceManagementManagedDevice -All -Filter "operatingSystem eq 'Windows' or operatingSystem eq 'macOS'" -Property "id,deviceName,operatingSystem,userId,userPrincipalName,azureADDeviceId"

# 3. Fetch all Azure AD devices and build a DeviceId->ObjectId mapping
Write-Host "Fetching Azure AD device IDs..." -ForegroundColor Cyan
$aadDevices = Get-MgDevice -All
$aadDeviceMap = @{}
foreach ($aad in $aadDevices) { $aadDeviceMap[$aad.DeviceId] = $aad.Id }

# 4. Build department mappings
$deviceDeptMap = @{}
$deptDeviceMap = @{}

foreach ($device in $devices) {
    $userId = $device.userId
    $dept = $null
    if ($userId) {
        try {
            $user = Get-MgUser -UserId $userId -Property "department"
            $dept = $user.Department
        } catch {
            Write-Warning "Could not retrieve user $userId"
        }
    }
    # Find valid Azure AD ObjectId for group add
    $aadDeviceId = $null
    if ($device.azureADDeviceId -and $aadDeviceMap.ContainsKey($device.azureADDeviceId)) {
        $aadDeviceId = $aadDeviceMap[$device.azureADDeviceId]
    } else {
        Write-Warning "No AzureAD ObjectId for $($device.deviceName) (AzureADDeviceId: $($device.azureADDeviceId), IntuneId: $($device.id)). Skipping."
        continue
    }
    $deviceDeptMap[$aadDeviceId] = $dept
    if ($dept) {
        if (-not $deptDeviceMap.ContainsKey($dept)) { $deptDeviceMap[$dept] = @() }
        $deptDeviceMap[$dept] += $aadDeviceId
    }
}

# 5. Discover ALL existing department device groups so that departments which now
#    have zero devices still get processed and have stale members removed.
#    FIX: previously only groups for current departments were iterated, meaning
#    reassigned devices were never removed from their old department's group.
$deptGroups = @{}

Write-Host "Discovering existing department device groups..." -ForegroundColor Cyan
$existingGroups = Get-MgGroup `
    -Filter "endsWith(displayName,' Devices') and securityEnabled eq true" `
    -ConsistencyLevel eventual `
    -CountVariable existingCount `
    -All
foreach ($grp in $existingGroups) {
    $existingDept = $grp.DisplayName -replace '\s+Devices$', ''
    if (-not $deptGroups.ContainsKey($existingDept)) {
        $deptGroups[$existingDept] = $grp
    }
}

# Create groups for departments that don't have one yet
foreach ($dept in $deptDeviceMap.Keys) {
    if ($deptGroups.ContainsKey($dept)) { continue }
    try {
        $displayName = "$dept Devices"
        $params = @{
            DisplayName     = $displayName
            Description     = "Device group for $dept department"
            MailEnabled     = $false
            SecurityEnabled = $true
            MailNickname    = (($dept -replace '[^a-zA-Z0-9]', '') + "Devices")
        }
        $newGroup = New-MgGroup @params
        $deptGroups[$dept] = $newGroup
        Write-Host "Created group: $($newGroup.DisplayName)"
    } catch {
        Write-Error "Error creating group for $dept : $_"
    }
}

# 6. Sync membership for ALL dept groups (both current departments and any existing
#    groups whose department now has zero devices).
foreach ($dept in $deptGroups.Keys) {
    $groupId = $deptGroups[$dept].Id

    # Departments with zero current devices get an empty expected list → all members removed
    $expectedDeviceIds = @()
    if ($deptDeviceMap.ContainsKey($dept)) {
        $expectedDeviceIds = $deptDeviceMap[$dept] | Where-Object { $_ } | ForEach-Object { $_.ToLower() }
    }

    # FIX: AdditionalProperties['@odata.type'] is required — $member.'@odata.type'
    # returns nothing from the Graph SDK, leaving $actualMemberIds empty and causing
    # every expected device to attempt an add (resulting in duplicate-member errors).
    $actualMemberIds = @()
    try {
        $members = Get-MgGroupMember -GroupId $groupId -All
        foreach ($member in $members) {
            if ($member.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.device') {
                $actualMemberIds += $member.Id.ToLower()
            }
        }
    } catch {
        Write-Warning "Failed to retrieve members for group '$dept Devices': $_"
        continue
    }

    $toAdd    = $expectedDeviceIds | Where-Object { $_ -notin $actualMemberIds }
    $toRemove = $actualMemberIds   | Where-Object { $_ -notin $expectedDeviceIds }

    foreach ($deviceId in $toAdd) {
        try {
            New-MgGroupMember -GroupId $groupId -DirectoryObjectId $deviceId
            Write-Host "Added $deviceId to '$dept Devices'"
        } catch {
            $errorText = $_ | Out-String
            if ($errorText -match 'already exist' -or $errorText -match 'added object references already exist') {
                Write-Verbose "Device $deviceId already in '$dept Devices' (skipped)."
            } else {
                Write-Warning "Failed to add $deviceId to '$dept Devices': $errorText"
            }
        }
    }

    foreach ($deviceId in $toRemove) {
        try {
            Remove-MgGroupMemberByRef -GroupId $groupId -DirectoryObjectId $deviceId
            Write-Host "Removed $deviceId from '$dept Devices'"
        } catch {
            Write-Warning "Failed to remove $deviceId from '$dept Devices': $_"
        }
    }

    if (-not $toAdd -and -not $toRemove) {
        Write-Host "No changes for '$dept Devices'" -ForegroundColor DarkGray
    }
}

Write-Host "Processing complete." -ForegroundColor Green
