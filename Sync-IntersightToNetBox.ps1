<#
.SYNOPSIS
    Syncs server inventory from Cisco Intersight to NetBox as unracked equipment.

.DESCRIPTION
    This script retrieves physical servers from Cisco Intersight and adds them to NetBox.
    Devices are created as unracked equipment in a specified Site and Role.

.PARAMETER IntersightApiKeyId
    The API Key ID for Cisco Intersight.

.PARAMETER IntersightApiKeyFilePath
    The path to the secret key file for Cisco Intersight.

.PARAMETER IntersightBasePath
    The base URL for Intersight API (defaults to https://intersight.com).

.PARAMETER NetBoxUrl
    The base URL for NetBox (e.g., https://netbox.example.com).

.PARAMETER NetBoxToken
    The API token for NetBox.

.PARAMETER NetBoxSite
    The name or slug of the NetBox Site to add devices to.

.PARAMETER NetBoxRole
    The name or slug of the NetBox Device Role to assign to new devices.

.EXAMPLE
    .\Sync-IntersightToNetBox.ps1 -IntersightApiKeyId "..." -IntersightApiKeyFilePath "C:\keys\secret.txt" -NetBoxUrl "http://netbox" -NetBoxToken "..." -NetBoxSite "DataCenter1" -NetBoxRole "Server"
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$IntersightApiKeyId,

    [Parameter(Mandatory = $true)]
    [string]$IntersightApiKeyFilePath,

    [string]$IntersightBasePath = "https://intersight.com",

    [Parameter(Mandatory = $true)]
    [string]$NetBoxUrl,

    [Parameter(Mandatory = $true)]
    [string]$NetBoxToken,

    [Parameter(Mandatory = $true)]
    [string]$NetBoxSite,

    [Parameter(Mandatory = $true)]
    [string]$NetBoxRole
)

# --- Initialization ---

# Check for Intersight module
if (-not (Get-Module -ListAvailable -Name Intersight.PowerShell)) {
    Write-Error "The Intersight.PowerShell module is required. Please install it using 'Install-Module Intersight.PowerShell'."
    return
}

Import-Module Intersight.PowerShell

# Configure Intersight Connection
$intersightConfig = @{
    ApiKeyId          = $IntersightApiKeyId
    ApiKeyFilePath    = $IntersightApiKeyFilePath
    BasePath          = $IntersightBasePath
    HttpSigningHeader = @("(request-target)", "Host", "Date", "Digest")
}

try {
    Write-Host "Authenticating with Cisco Intersight..." -ForegroundColor Cyan
    Set-IntersightConfiguration @intersightConfig
}
catch {
    Write-Error "Failed to configure Intersight connection: $_"
    return
}

# NetBox Headers
$netboxHeaders = @{
    "Authorization" = "Token $NetBoxToken"
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
}

# --- Fetch Intersight Servers ---
Write-Host "Fetching servers from Intersight..." -ForegroundColor Cyan
$allServers = [System.Collections.Generic.List[object]]::new()
$skip = 0
$top = 100

try {
    # Get total count first
    $totalCountResult = Get-IntersightComputePhysicalSummary -Count $true
    $totalCount = $totalCountResult.Count
    Write-Host "Found $totalCount physical servers in Intersight."

    while ($skip -lt $totalCount) {
        $batch = Get-IntersightComputePhysicalSummary -Top $top -Skip $skip
        if ($null -eq $batch) { break }

        $results = if ($batch.PSObject.Properties['Results']) { $batch.Results } else { $batch }
        if ($null -eq $results -or $results.Count -eq 0) { break }

        $allServers.AddRange($results)
        $skip += $top
    }
}
catch {
    Write-Error "Error retrieving servers from Intersight: $_"
    return
}

Write-Host "Successfully retrieved $($allServers.Count) servers from Intersight." -ForegroundColor Green

# --- NetBox Integration ---

function Invoke-NetBoxApi {
    param(
        [string]$Endpoint,
        [string]$Method = "GET",
        [object]$Body = $null,
        [string]$Query = ""
    )

    $url = "$NetBoxUrl/api/$Endpoint/"
    if ($Query) { $url += "?$Query" }

    $params = @{
        Uri     = $url
        Method  = $Method
        Headers = $netboxHeaders
    }

    if ($Body) {
        $params.Body = $Body | ConvertTo-Json -Depth 10
    }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        Write-Error "NetBox API Error ($Method $Endpoint): $_"
        return $null
    }
}

# 1. Look up Site
Write-Host "Looking up NetBox Site: $NetBoxSite"
$siteResult = Invoke-NetBoxApi -Endpoint "dcim/sites" -Query "name=$NetBoxSite"
if (-not $siteResult.results) {
    $siteResult = Invoke-NetBoxApi -Endpoint "dcim/sites" -Query "slug=$NetBoxSite"
}
if (-not $siteResult.results) {
    Write-Error "Site '$NetBoxSite' not found in NetBox."
    return
}
$siteId = $siteResult.results[0].id
Write-Host "Found Site ID: $siteId"

# 2. Look up Role
Write-Host "Looking up NetBox Role: $NetBoxRole"
$roleResult = Invoke-NetBoxApi -Endpoint "dcim/device-roles" -Query "name=$NetBoxRole"
if (-not $roleResult.results) {
    $roleResult = Invoke-NetBoxApi -Endpoint "dcim/device-roles" -Query "slug=$NetBoxRole"
}
if (-not $roleResult.results) {
    Write-Error "Role '$NetBoxRole' not found in NetBox."
    return
}
$roleId = $roleResult.results[0].id
Write-Host "Found Role ID: $roleId"

# 3. Iterate through servers
Write-Host "Synchronizing servers to NetBox..." -ForegroundColor Cyan
foreach ($server in $allServers) {
    $deviceName = $server.Name
    $serial = $server.Serial
    $model = $server.Model

    Write-Host "Processing server: $deviceName (Serial: $serial, Model: $model)"

    # Check if device already exists in NetBox
    $existingDevice = Invoke-NetBoxApi -Endpoint "dcim/devices" -Query "serial=$serial"
    if ($existingDevice.count -gt 0) {
        Write-Host "Device with serial $serial already exists in NetBox (ID: $($existingDevice.results[0].id)). Skipping." -ForegroundColor Yellow
        continue
    }

    # Look up Device Type by Model
    $dtResult = Invoke-NetBoxApi -Endpoint "dcim/device-types" -Query "model=$model"
    if (-not $dtResult.results) {
        # Try slug match as fallback
        $modelSlug = $model.ToLower().Replace(" ", "-").Replace("/", "-")
        $dtResult = Invoke-NetBoxApi -Endpoint "dcim/device-types" -Query "slug=$modelSlug"
    }

    if (-not $dtResult.results) {
        Write-Warning "Device Type for model '$model' not found in NetBox. Skipping server $deviceName."
        continue
    }
    $deviceTypeId = $dtResult.results[0].id

    # Create the Device
    $newDevice = @{
        name        = $deviceName
        device_type = $deviceTypeId
        role        = $roleId
        site        = $siteId
        serial      = $serial
        status      = "planned"
    }

    $createResult = Invoke-NetBoxApi -Endpoint "dcim/devices" -Method "POST" -Body $newDevice
    if ($createResult) {
        Write-Host "Successfully created unracked device '$deviceName' in NetBox." -ForegroundColor Green
    }
    else {
        Write-Error "Failed to create device '$deviceName' in NetBox."
    }
}

Write-Host "Sync complete." -ForegroundColor Green
