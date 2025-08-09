<#
.SYNOPSIS
    Downloads GeoIP databases from authenticated API

.DESCRIPTION
    This script downloads GeoIP databases using API authentication.
    It supports retry logic, parallel downloads, and is compatible
    with Windows Task Scheduler.

.PARAMETER ApiKey
    API key for authentication (or use $env:GEOIP_API_KEY)

.PARAMETER ApiEndpoint
    API endpoint URL (default: from environment or predefined)

.PARAMETER TargetDirectory
    Target directory for downloads (default: .\geoip)

.PARAMETER Databases
    Array of database names or "all" (default: all)

.PARAMETER LogFile
    Path to log file for output

.PARAMETER MaxRetries
    Maximum number of retry attempts (default: 3)

.PARAMETER Timeout
    Download timeout in seconds (default: 300)

.PARAMETER Quiet
    Suppress all output except errors

.PARAMETER NoLock
    Don't use lock file to prevent concurrent runs

.EXAMPLE
    .\geoip-update.ps1 -ApiKey "your_key"
    Downloads all databases using production endpoint

.EXAMPLE
    .\geoip-update.ps1 -ApiKey "test-key-1" -ApiEndpoint "http://localhost:8080/auth"
    Local testing with Docker API

.EXAMPLE
    $env:GEOIP_API_ENDPOINT="http://localhost:8080/auth"; .\geoip-update.ps1 -ApiKey "test-key-1"
    Using environment variables for local testing

.EXAMPLE
    .\geoip-update.ps1 -ApiKey "your_key" -Databases @("GeoIP2-City.mmdb", "GeoIP2-Country.mmdb")
    Downloads specific databases

.EXAMPLE
    .\geoip-update.ps1 -Quiet -LogFile "C:\Logs\geoip-update.log"
    Runs in quiet mode with logging (ideal for Task Scheduler)

.NOTES
    Author: GeoIP Update Script
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$ApiKey = $env:GEOIP_API_KEY,
    
    [Parameter()]
    [string]$ApiEndpoint = $(if ($env:GEOIP_API_ENDPOINT) { $env:GEOIP_API_ENDPOINT } else { "https://geoipdb.net/auth" }),
    
    [Parameter()]
    [string]$TargetDirectory = $(if ($env:GEOIP_TARGET_DIR) { $env:GEOIP_TARGET_DIR } else { ".\geoip" }),
    
    [Parameter()]
    [string[]]$Databases = @("all"),
    
    [Parameter()]
    [string]$LogFile = $env:GEOIP_LOG_FILE,
    
    [Parameter()]
    [int]$MaxRetries = 3,
    
    [Parameter()]
    [int]$Timeout = 300,
    
    [Parameter()]
    [switch]$Quiet,
    
    [Parameter()]
    [switch]$NoLock
)

# Set error action preference
$ErrorActionPreference = 'Stop'

# Clean and normalize the API endpoint
$ApiEndpoint = $ApiEndpoint.TrimEnd('/', ' ', "`t", "`n", "`r")

# Auto-append /auth if it's the base geoipdb.net domain
if ($ApiEndpoint -eq 'https://geoipdb.net' -or $ApiEndpoint -eq 'http://geoipdb.net') {
    $ApiEndpoint = "$ApiEndpoint/auth"
    Write-Host "Appended /auth to endpoint: $ApiEndpoint" -ForegroundColor Cyan
}
elseif (-not $ApiEndpoint.EndsWith('/auth')) {
    # For other endpoints, just note what we're using
    Write-Verbose "Using endpoint as provided: $ApiEndpoint"
}

# Script configuration
$script:ScriptName = Split-Path -Leaf $MyInvocation.MyCommand.Path
$script:TempPath = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } elseif ($env:TMP) { $env:TMP } else { "/tmp" }
$script:LockFile = Join-Path $script:TempPath "geoip-update.lock"
$script:TempDirectory = Join-Path $script:TempPath "geoip-update-$(Get-Random)"
$script:DownloadJobs = @()
$script:ExitCode = 0

# Logging functions
function Write-LogMessage {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]
        [string]$Level,
        
        [Parameter(Mandatory)]
        [string]$Message
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Write to log file if specified
    if ($LogFile) {
        try {
            Add-Content -Path $LogFile -Value $logEntry -ErrorAction SilentlyContinue
        }
        catch {
            # If we can't write to log file, continue anyway
        }
    }
    
    # Write to console unless in quiet mode
    if (-not $Quiet) {
        switch ($Level) {
            'ERROR' {
                Write-Host $logEntry -ForegroundColor Red
            }
            'WARN' {
                Write-Host $logEntry -ForegroundColor Yellow
            }
            'SUCCESS' {
                Write-Host $logEntry -ForegroundColor Green
            }
            'INFO' {
                if ($VerbosePreference -eq 'Continue') {
                    Write-Host $logEntry -ForegroundColor Cyan
                }
            }
        }
    }
    elseif ($Level -eq 'ERROR') {
        # Always output errors, even in quiet mode
        Write-Error $Message
    }
}

function Exit-WithError {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [int]$ExitCode = 1
    )
    
    Write-LogMessage -Level ERROR -Message $Message
    $script:ExitCode = $ExitCode
    exit $ExitCode
}

# Try to get API key from Windows Credential Manager if not provided
function Get-ApiKeyFromCredentialManager {
    try {
        # Try using CredentialManager module if available
        if (Get-Module -ListAvailable -Name CredentialManager -ErrorAction SilentlyContinue) {
            Import-Module CredentialManager -ErrorAction SilentlyContinue
            $cred = Get-StoredCredential -Target "GeoIP-API-Key" -ErrorAction SilentlyContinue
            if ($cred) {
                Write-LogMessage -Level INFO -Message "Retrieved API key from Windows Credential Manager (Module)"
                return $cred.GetNetworkCredential().Password
            }
        }
        
        # Fallback: Try to retrieve using Windows Credential Manager APIs directly
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class CredentialManager {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CredRead(string target, int type, int reservedFlag, out IntPtr credentialPtr);
    
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool CredFree([In] IntPtr cred);
    
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL {
        public int Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }
    
    public static string GetCredential(string target) {
        IntPtr credPtr;
        if (CredRead(target, 1, 0, out credPtr)) {
            CREDENTIAL cred = (CREDENTIAL)Marshal.PtrToStructure(credPtr, typeof(CREDENTIAL));
            string password = Marshal.PtrToStringUni(cred.CredentialBlob, cred.CredentialBlobSize / 2);
            CredFree(credPtr);
            return password;
        }
        return null;
    }
}
"@ -ErrorAction SilentlyContinue

        $apiKey = [CredentialManager]::GetCredential("GeoIP-API-Key")
        if ($apiKey) {
            Write-LogMessage -Level INFO -Message "Retrieved API key from Windows Credential Manager (API)"
            return $apiKey
        }
    }
    catch {
        Write-LogMessage -Level INFO -Message "Could not retrieve API key from Credential Manager: $_"
    }
    return $null
}

# Store API key in Windows Credential Manager
function Set-ApiKeyInCredentialManager {
    param(
        [Parameter(Mandatory)]
        [string]$ApiKey
    )
    
    try {
        # Use cmdkey to store credential (available on all Windows versions)
        $result = & cmdkey /generic:GeoIP-API-Key /user:GeoIP-API-Key /pass:$ApiKey 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-LogMessage -Level INFO -Message "Stored API key in Windows Credential Manager"
            return $true
        }
        else {
            Write-LogMessage -Level WARN -Message "Failed to store API key using cmdkey: $result"
        }
    }
    catch {
        Write-LogMessage -Level WARN -Message "Failed to store API key in Credential Manager: $_"
    }
    return $false
}

# Validate configuration
function Test-Configuration {
    Write-LogMessage -Level INFO -Message "Validating configuration"
    
    # Check API key - try Credential Manager if not provided
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        $credKey = Get-ApiKeyFromCredentialManager
        if ($credKey) {
            $script:ApiKey = $credKey
        }
        else {
            Exit-WithError -Message "API key not provided. Use -ApiKey parameter, set GEOIP_API_KEY environment variable, or store in Windows Credential Manager"
        }
    }
    
    # Validate API key format
    if ($ApiKey -notmatch '^[a-zA-Z0-9_-]{20,64}$') {
        Exit-WithError -Message "Invalid API key format"
    }
    
    # Check API endpoint
    if ([string]::IsNullOrWhiteSpace($ApiEndpoint)) {
        Exit-WithError -Message "API endpoint not configured"
    }
    
    # Log endpoint being used (helpful for debugging)
    if ($ApiEndpoint -match '^http://localhost|^http://127\.0\.0\.1') {
        Write-LogMessage -Level INFO -Message "Using local API endpoint: $ApiEndpoint"
    }
    elseif ($ApiEndpoint -eq "https://geoipdb.net/auth") {
        Write-LogMessage -Level INFO -Message "Using production API endpoint: $ApiEndpoint"
    }
    else {
        Write-LogMessage -Level INFO -Message "Using custom API endpoint: $ApiEndpoint"
    }
    
    # Create target directory if it doesn't exist
    if (-not (Test-Path -Path $TargetDirectory)) {
        Write-LogMessage -Level INFO -Message "Creating target directory: $TargetDirectory"
        try {
            New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
        }
        catch {
            Exit-WithError -Message "Failed to create target directory: $_"
        }
    }
    
    # Check if target directory is writable
    try {
        $testFile = Join-Path $TargetDirectory ".write_test_$(Get-Random)"
        New-Item -ItemType File -Path $testFile -Force | Out-Null
        Remove-Item -Path $testFile -Force
    }
    catch {
        Exit-WithError -Message "Target directory is not writable: $TargetDirectory"
    }
    
    # Create log directory if log file is specified
    if ($LogFile) {
        $logDir = Split-Path -Parent $LogFile
        if ($logDir -and -not (Test-Path -Path $logDir)) {
            try {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            catch {
                Exit-WithError -Message "Failed to create log directory: $_"
            }
        }
    }
}

# Lock file management
function New-LockFile {
    if ($NoLock) {
        return $true
    }
    
    $currentPid = $PID
    
    if (Test-Path -Path $script:LockFile) {
        try {
            $lockPid = Get-Content -Path $script:LockFile -ErrorAction Stop
            
            # Check if process is still running
            $process = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
            if ($process) {
                Exit-WithError -Message "Another instance is already running (PID: $lockPid)"
            }
            else {
                Write-LogMessage -Level WARN -Message "Removing stale lock file (PID: $lockPid)"
                Remove-Item -Path $script:LockFile -Force
            }
        }
        catch {
            Write-LogMessage -Level WARN -Message "Error reading lock file: $_"
            Remove-Item -Path $script:LockFile -Force -ErrorAction SilentlyContinue
        }
    }
    
    try {
        Set-Content -Path $script:LockFile -Value $currentPid -Force
        Write-LogMessage -Level INFO -Message "Acquired lock (PID: $currentPid)"
        return $true
    }
    catch {
        Exit-WithError -Message "Failed to create lock file: $_"
    }
}

function Remove-LockFile {
    if ($NoLock) {
        return
    }
    
    if (Test-Path -Path $script:LockFile) {
        try {
            $lockPid = Get-Content -Path $script:LockFile -ErrorAction Stop
            if ($lockPid -eq $PID) {
                Remove-Item -Path $script:LockFile -Force
                Write-LogMessage -Level INFO -Message "Released lock"
            }
        }
        catch {
            # Ignore errors when removing lock file
        }
    }
}

# HTTP request with retry logic
function Invoke-HttpRequest {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,
        
        [string]$Method = 'GET',
        
        [hashtable]$Headers = @{},
        
        [object]$Body,
        
        [string]$OutFile
    )
    
    $retryCount = 0
    $retryDelay = 1
    
    while ($retryCount -lt $MaxRetries) {
        Write-LogMessage -Level INFO -Message "HTTP $Method request to: $Uri (attempt $($retryCount + 1)/$MaxRetries)"
        
        try {
            $params = @{
                Uri = $Uri
                Method = $Method
                Headers = $Headers
                TimeoutSec = $Timeout
                ErrorAction = 'Stop'
                UseBasicParsing = $true
            }
            
            if ($Body) {
                $params['Body'] = $Body
                $params['ContentType'] = 'application/json'
            }
            
            if ($OutFile) {
                $params['OutFile'] = $OutFile
                Invoke-WebRequest @params
                
                # Verify file was downloaded
                if (-not (Test-Path -Path $OutFile) -or (Get-Item -Path $OutFile).Length -eq 0) {
                    throw "Downloaded file is empty or missing"
                }
            }
            else {
                $response = Invoke-WebRequest @params
                return $response.Content
            }
            
            Write-LogMessage -Level INFO -Message "HTTP request successful"
            return $true
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            
            if ($statusCode -eq 429) {
                Write-LogMessage -Level WARN -Message "Rate limit exceeded (HTTP 429)"
                $retryDelay = 60  # Wait longer for rate limit
            }
            elseif ($statusCode -eq 401) {
                Exit-WithError -Message "Authentication failed (HTTP 401) - check your API key"
            }
            elseif ($statusCode -eq 403) {
                Exit-WithError -Message "Access forbidden (HTTP 403) - check your permissions"
            }
            elseif ($statusCode -ge 500) {
                Write-LogMessage -Level WARN -Message "Server error (HTTP $statusCode)"
            }
            else {
                Write-LogMessage -Level WARN -Message "Request failed: $_"
            }
            
            $retryCount++
            if ($retryCount -lt $MaxRetries) {
                Write-LogMessage -Level INFO -Message "Retrying in $retryDelay seconds..."
                Start-Sleep -Seconds $retryDelay
                $retryDelay = [Math]::Min($retryDelay * 2, 60)  # Exponential backoff, cap at 60 seconds
            }
        }
    }
    
    Exit-WithError -Message "Failed after $MaxRetries attempts"
}

# Download database with progress
function Start-DatabaseDownloadWithProgress {
    param(
        [Parameter(Mandatory)]
        [string]$DatabaseName,
        
        [Parameter(Mandatory)]
        [string]$Url,
        
        [int]$Index,
        
        [int]$Total
    )
    
    $targetFile = Join-Path $TargetDirectory $DatabaseName
    $tempFile = Join-Path $script:TempDirectory $DatabaseName
    
    # Show progress bar
    $percentComplete = [int](($Index / $Total) * 100)
    Write-Progress -Activity "Downloading GeoIP Databases" `
                   -Status "Downloading $DatabaseName" `
                   -PercentComplete $percentComplete `
                   -CurrentOperation "$Index of $Total databases"
    
    try {
        # Download with progress tracking
        $response = Invoke-WebRequest -Uri $Url -OutFile $tempFile `
                                    -TimeoutSec $Timeout `
                                    -ErrorAction Stop `
                                    -UseBasicParsing `
                                    -PassThru
        
        # Validate downloaded file
        if ((Test-Path -Path $tempFile) -and (Get-Item -Path $tempFile).Length -gt 0) {
            $fileSize = (Get-Item -Path $tempFile).Length
            
            # Basic validation
            if ($DatabaseName -like "*.mmdb") {
                # Check for MaxMind metadata marker at the end of the file
                # MMDB files have metadata at the end with marker \xab\xcd\xef followed by MaxMind.com
                try {
                    # PowerShell 5.1 and PowerShell Core compatible approach
                    $fileInfo = Get-Item -Path $tempFile
                    $fileSize = $fileInfo.Length
                    $readSize = [Math]::Min($fileSize, 100000)  # Read last 100KB
                    
                    # Open file and seek to the position to start reading
                    $fileStream = [System.IO.File]::OpenRead($tempFile)
                    $fileStream.Seek($fileSize - $readSize, [System.IO.SeekOrigin]::Begin) | Out-Null
                    
                    # Read the last portion of the file
                    $buffer = New-Object byte[] $readSize
                    $bytesRead = $fileStream.Read($buffer, 0, $readSize)
                    $fileStream.Close()
                    
                    # Look for the MMDB metadata marker: \xab\xcd\xef followed by MaxMind.com
                    $marker = [byte[]]@(0xab, 0xcd, 0xef) + [System.Text.Encoding]::ASCII.GetBytes("MaxMind.com")
                    $found = $false
                    
                    for ($i = 0; $i -le $bytesRead - $marker.Length; $i++) {
                        $match = $true
                        for ($j = 0; $j -lt $marker.Length; $j++) {
                            if ($buffer[$i + $j] -ne $marker[$j]) {
                                $match = $false
                                break
                            }
                        }
                        if ($match) {
                            $found = $true
                            break
                        }
                    }
                    
                    if (-not $found) {
                        Write-LogMessage -Level WARN -Message "MMDB file $DatabaseName may be invalid: missing MaxMind metadata marker"
                    }
                }
                catch {
                    Write-LogMessage -Level WARN -Message "Failed to validate MMDB file ${DatabaseName}: $_"
                }
            }
            elseif ($DatabaseName -like "*.BIN") {
                if ($fileSize -lt 1000) {
                    throw "BIN file is too small to be valid"
                }
            }
            
            # Move to target location
            Move-Item -Path $tempFile -Destination $targetFile -Force
            
            return @{
                Success = $true
                Database = $DatabaseName
                Size = $fileSize
            }
        }
        else {
            throw "Downloaded file is empty or missing"
        }
    }
    catch {
        return @{
            Success = $false
            Database = $DatabaseName
            Error = $_.ToString()
        }
    }
}

# Download database function (for background jobs)
function Start-DatabaseDownload {
    param(
        [Parameter(Mandatory)]
        [string]$DatabaseName,
        
        [Parameter(Mandatory)]
        [string]$Url
    )
    
    $targetFile = Join-Path $TargetDirectory $DatabaseName
    $tempFile = Join-Path $script:TempDirectory $DatabaseName
    
    $job = Start-Job -ScriptBlock {
        param($DatabaseName, $Url, $TempFile, $TargetFile, $MaxRetries, $Timeout)
        
        try {
            # Download to temporary file
            $params = @{
                Uri = $Url
                OutFile = $TempFile
                TimeoutSec = $Timeout
                ErrorAction = 'Stop'
                UseBasicParsing = $true
            }
            
            Invoke-WebRequest @params
            
            # Verify and move file
            if ((Test-Path -Path $TempFile) -and (Get-Item -Path $TempFile).Length -gt 0) {
                Move-Item -Path $TempFile -Destination $TargetFile -Force
                return @{
                    Success = $true
                    Database = $DatabaseName
                    Size = (Get-Item -Path $TargetFile).Length
                }
            }
            else {
                throw "Downloaded file is empty or missing"
            }
        }
        catch {
            return @{
                Success = $false
                Database = $DatabaseName
                Error = $_.ToString()
            }
        }
    } -ArgumentList $DatabaseName, $Url, $tempFile, $targetFile, $MaxRetries, $Timeout
    
    return $job
}

# Main update function
function Update-Databases {
    Write-LogMessage -Level INFO -Message "Starting GeoIP database update"
    Write-LogMessage -Level INFO -Message "Target directory: $TargetDirectory"
    
    # Create temporary directory
    try {
        New-Item -ItemType Directory -Path $script:TempDirectory -Force | Out-Null
        Write-LogMessage -Level INFO -Message "Temporary directory: $script:TempDirectory"
    }
    catch {
        Exit-WithError -Message "Failed to create temporary directory: $_"
    }
    
    # Prepare API request
    $headers = @{
        'X-API-Key' = $ApiKey
    }
    
    if ($Databases -contains 'all') {
        $body = @{ databases = 'all' } | ConvertTo-Json
    } else {
        # Force array in JSON even for single item
        $body = @{ databases = @($Databases) } | ConvertTo-Json -Depth 10
    }
    
    # Get pre-signed URLs from API
    Write-LogMessage -Level INFO -Message "Authenticating with API endpoint"
    
    try {
        $response = Invoke-HttpRequest -Uri $ApiEndpoint -Method POST -Headers $headers -Body $body
        $urls = $response | ConvertFrom-Json
    }
    catch {
        Exit-WithError -Message "Failed to authenticate with API: $_"
    }
    
    if (-not $urls -or $urls.PSObject.Properties.Count -eq 0) {
        Exit-WithError -Message "No download URLs received from API"
    }
    
    # Count total databases
    $totalCount = [int]($urls.PSObject.Properties.Count)
    Write-LogMessage -Level INFO -Message "Received URLs for $totalCount databases"
    
    # Check if we should use progress bars (when not in quiet mode and reasonable number of databases)
    $useProgressBars = -not $Quiet -and $totalCount -le 10
    
    if ($useProgressBars) {
        # Sequential downloads with progress bars
        $completedCount = 0
        $failedCount = 0
        $index = 0
        
        foreach ($property in $urls.PSObject.Properties) {
            $index++
            $dbName = $property.Name
            $url = $property.Value
            
            Write-LogMessage -Level INFO -Message "Downloading: $dbName ($index of $totalCount)"
            
            $result = Start-DatabaseDownloadWithProgress -DatabaseName $dbName -Url $url -Index $index -Total $totalCount
            
            if ($result.Success) {
                Write-LogMessage -Level SUCCESS -Message "Successfully downloaded: $($result.Database) ($('{0:N0}' -f $result.Size) bytes)"
                $completedCount++
            }
            else {
                Write-LogMessage -Level ERROR -Message "Failed to download $($result.Database): $($result.Error)"
                $failedCount++
            }
        }
        
        # Clear progress bar
        Write-Progress -Activity "Downloading GeoIP Databases" -Completed
    }
    else {
        # Parallel downloads without progress bars
        $maxParallel = 4
        $jobs = @()
        $completedCount = 0
        $failedCount = 0
        
        foreach ($property in $urls.PSObject.Properties) {
            $dbName = $property.Name
            $url = $property.Value
            
            Write-LogMessage -Level INFO -Message "Starting download: $dbName"
            
            # Wait if we have too many parallel downloads
            while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $maxParallel) {
                Start-Sleep -Milliseconds 100
                
                # Check for completed jobs
                $completed = $jobs | Where-Object { $_.State -eq 'Completed' }
                foreach ($job in $completed) {
                    $result = Receive-Job -Job $job
                    Remove-Job -Job $job
                    $jobs = $jobs | Where-Object { $_.Id -ne $job.Id }
                    
                    if ($result.Success) {
                        Write-LogMessage -Level SUCCESS -Message "Successfully downloaded: $($result.Database) ($('{0:N0}' -f $result.Size) bytes)"
                        $completedCount++
                    }
                    else {
                        Write-LogMessage -Level ERROR -Message "Failed to download $($result.Database): $($result.Error)"
                        $failedCount++
                    }
                }
            }
            
            # Start new download job
            $job = Start-DatabaseDownload -DatabaseName $dbName -Url $url
            $jobs += $job
        }
        
        # Wait for remaining jobs
        while ($jobs.Count -gt 0) {
            Start-Sleep -Milliseconds 100
            
            $completed = $jobs | Where-Object { $_.State -ne 'Running' }
            foreach ($job in $completed) {
                $result = Receive-Job -Job $job
                Remove-Job -Job $job
                $jobs = $jobs | Where-Object { $_.Id -ne $job.Id }
                
                if ($result.Success) {
                    Write-LogMessage -Level SUCCESS -Message "Successfully downloaded: $($result.Database) ($($result.Size) bytes)"
                    $completedCount++
                }
                else {
                    Write-LogMessage -Level ERROR -Message "Failed to download $($result.Database): $($result.Error)"
                    $failedCount++
                }
            }
        }
    }
    
    Write-LogMessage -Level INFO -Message "Download summary: $completedCount successful, $failedCount failed"
    
    if ($failedCount -gt 0) {
        Exit-WithError -Message "Failed to download $failedCount databases" -ExitCode 2
    }
}

# Cleanup function
function Invoke-Cleanup {
    Write-LogMessage -Level INFO -Message "Performing cleanup"
    
    # Stop any remaining jobs
    if ($script:DownloadJobs.Count -gt 0) {
        $script:DownloadJobs | Stop-Job -PassThru | Remove-Job -Force
    }
    
    # Remove lock file
    Remove-LockFile
    
    # Remove temporary directory
    if (Test-Path -Path $script:TempDirectory) {
        Write-LogMessage -Level INFO -Message "Removing temporary directory"
        Remove-Item -Path $script:TempDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    if ($script:ExitCode -eq 0) {
        Write-LogMessage -Level SUCCESS -Message "GeoIP update completed successfully"
    }
    else {
        Write-LogMessage -Level ERROR -Message "GeoIP update failed with exit code: $($script:ExitCode)"
    }
}

# Register cleanup on exit
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    # Note: This handler may not execute in all scenarios
    if (Test-Path -Path $script:LockFile) {
        Remove-Item -Path $script:LockFile -Force -ErrorAction SilentlyContinue
    }
}

# Main execution
try {
    Write-LogMessage -Level INFO -Message "GeoIP Update Script starting"
    
    # Validate configuration
    Test-Configuration
    
    # Store API key in Credential Manager if requested and not already stored
    if ($ApiKey -and -not (Get-ApiKeyFromCredentialManager)) {
        Set-ApiKeyInCredentialManager -ApiKey $ApiKey
    }
    
    # Acquire lock
    New-LockFile
    
    # Update databases
    Update-Databases
    
    # Success
    $script:ExitCode = 0
}
catch {
    Write-LogMessage -Level ERROR -Message "Unexpected error: $_"
    $script:ExitCode = 1
}
finally {
    # Always perform cleanup
    Invoke-Cleanup
    
    # Exit with appropriate code
    exit $script:ExitCode
}