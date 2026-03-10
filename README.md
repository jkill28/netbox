# Cisco Intersight to NetBox Sync

This project provides a PowerShell script to pull server inventory from Cisco Intersight and add them to NetBox as unracked equipment.

## Prerequisites

- **PowerShell 7.4.0** or later.
- **Intersight.PowerShell** module. You can install it using:
  ```powershell
  Install-Module -Name Intersight.PowerShell
  ```
- **Cisco Intersight API Key and Secret Key**: Generate these from the Cisco Intersight GUI.
- **NetBox API Token**: Generate this from your NetBox instance.

## Usage

The script `Sync-IntersightToNetBox.ps1` takes several parameters to connect to both Cisco Intersight and NetBox.

### Parameters

- `IntersightApiKeyId`: Your Intersight API Key ID.
- `IntersightApiKeyFilePath`: Path to the file containing your Intersight secret key.
- `NetBoxUrl`: The base URL of your NetBox instance (e.g., `https://netbox.example.com`).
- `NetBoxToken`: Your NetBox API token.
- `NetBoxSite`: The name or slug of the NetBox Site where devices should be added.
- `NetBoxRole`: The name or slug of the NetBox Device Role to assign to new devices.
- `IntersightLocation` (Optional): Filter Intersight servers by their User Defined Location.
- `IntersightBasePath` (Optional): Defaults to `https://intersight.com`.

### Example

```powershell
.\Sync-IntersightToNetBox.ps1 `
    -IntersightApiKeyId "5f.../61.../62..." `
    -IntersightApiKeyFilePath "C:\keys\SecretKey.txt" `
    -NetBoxUrl "https://netbox.internal" `
    -NetBoxToken "0123456789abcdef0123456789abcdef01234567" `
    -NetBoxSite "Main-DC" `
    -NetBoxRole "Server" `
    -IntersightLocation "San Jose"
```

## How it Works

1. **Authentication**: Connects to Cisco Intersight using the provided API key.
2. **Retrieval**: Fetches all physical servers (blades and rack units) from Intersight, handling pagination automatically.
3. **Lookup**: For each server found, it looks up the corresponding Site, Role, and Device Type in NetBox.
4. **Validation**: Checks if a device with the same serial number already exists in NetBox to prevent duplicates.
5. **Creation**: If the device does not exist, it creates a new "unracked" device in NetBox with the status "planned".
