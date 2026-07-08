<#
.SYNOPSIS
    Reports all Entra ID (Azure AD) devices grouped by their owner's department.

.DESCRIPTION
    Connects to Microsoft Graph, queries all devices and their registered owners,
    looks up each owner's department attribute, then outputs a grouped report.
    Optionally exports results to a CSV file.

.PARAMETER ConfigPath
    Path to config.json. Defaults to config.json in the same directory as this script.

.PARAMETER OutputCsv
    If specified, writes the report to this CSV file path.

.EXAMPLE
    .\Get-DeviceReport.ps1
    .\Get-DeviceReport.ps1 -OutputCsv .\report.csv
#>
[CmdletBinding()]
param (
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string] $OutputCsv
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
        -Scopes 'Device.Read.All', 'User.Read.All', 'Group.Read.All' `
        -NoWelcome
}

#endregion

#region ── Main ───────────────────────────────────────────────────────────────

Write-Host '== Entra ID – Device Report by Department ==' -ForegroundColor Cyan

# Load config
if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json

# Ensure Microsoft.Graph modules are available
Initialize-GraphModules -Modules @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Identity.DirectoryManagement',
    'Microsoft.Graph.Users'
)

Connect-GraphSession -Config $config

# Fetch all devices
Write-Host "`nFetching all devices..."
$devices = Get-MgDevice -All -Property 'Id,DisplayName,OperatingSystem,OperatingSystemVersion,AccountEnabled,ApproximateLastSignInDateTime'
Write-Host "  Found $($devices.Count) device(s)."

# Build report rows
$userCache   = @{}
$reportRows  = [System.Collections.Generic.List[PSCustomObject]]::new()

$i = 0
foreach ($device in $devices) {
    $i++
    Write-Progress -Activity 'Processing devices' -Status $device.DisplayName -PercentComplete (($i / $devices.Count) * 100)

    $owners = Get-MgDeviceRegisteredOwner -DeviceId $device.Id -All -ErrorAction SilentlyContinue
    $ownerInfo = if ($owners) {
        $owners | ForEach-Object {
            $lookup = Get-DepartmentForUser -UserId $_.Id -Cache $userCache
            $dept = if ($lookup.LookupFailed) { '(Unknown)' }
                    elseif ($lookup.Department) { $lookup.Department }
                    else { '(No Department)' }
            [PSCustomObject]@{ OwnerUPN = $_.AdditionalProperties['userPrincipalName']; Department = $dept }
        }
    }
    else {
        @([PSCustomObject]@{ OwnerUPN = '(No Owner)'; Department = '(No Department)' })
    }

    foreach ($owner in $ownerInfo) {
        $reportRows.Add([PSCustomObject]@{
            Department                 = $owner.Department
            DeviceName                 = $device.DisplayName
            OS                         = $device.OperatingSystem
            OSVersion                  = $device.OperatingSystemVersion
            Enabled                    = $device.AccountEnabled
            LastSignIn                 = $device.ApproximateLastSignInDateTime
            OwnerUPN                   = $owner.OwnerUPN
            DeviceId                   = $device.Id
        })
    }
}

Write-Progress -Activity 'Processing devices' -Completed

# Display grouped summary
$grouped = $reportRows | Group-Object Department | Sort-Object Name
Write-Host "`n== Summary ==" -ForegroundColor Cyan
$grouped | ForEach-Object {
    Write-Host ("  [{0}] {1} device(s)" -f $_.Name, $_.Count) -ForegroundColor White
}

# Display full table
Write-Host "`n== Device List ==" -ForegroundColor Cyan
$reportRows | Sort-Object Department, DeviceName | Format-Table Department, DeviceName, OS, Enabled, LastSignIn, OwnerUPN -AutoSize

# Optional CSV export
if ($OutputCsv) {
    $reportRows | Sort-Object Department, DeviceName | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Host "`nReport saved to: $OutputCsv" -ForegroundColor Green
}

Disconnect-MgGraph | Out-Null
Write-Host "`nDone." -ForegroundColor Green

#endregion
