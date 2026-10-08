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
    Array of database names or "all", comma-separated names accepted (default: $env:GEOIP_DATABASES or all)

.PARAMETER LogFile
    Path to log file for output

.PARAMETER MaxRetries
    Maximum number of retry attempts (default: $env:GEOIP_MAX_RETRIES or 3)

.PARAMETER Timeout
    Per-request download timeout in seconds (default: $env:GEOIP_TIMEOUT or 1800). Raised from 300 so
    large databases finish on slow links (Invoke-WebRequest has no stall timeout).

.PARAMETER Quiet
    Suppress all output except errors

.PARAMETER NoLock
    Don't use lock file to prevent concurrent runs

.PARAMETER OnlyChanged
    Download only databases whose remote copy changed, tracked in <TargetDirectory>\.geoip-update.json
    (or set $env:GEOIP_ONLY_CHANGED to true, 1 or yes)

.PARAMETER Force
    Download every database even with -OnlyChanged

.PARAMETER LockFile
    Take an exclusive lock on this path, shared by every run that uses it, instead of the
    default lock (default: $env:GEOIP_LOCK_FILE). Cannot be combined with -NoLock.

.PARAMETER LockTimeout
    Seconds to wait for -LockFile before exiting 1 (default: $env:GEOIP_LOCK_TIMEOUT or 1800)

.PARAMETER ValidateOnly
    Validate existing database files without downloading

.PARAMETER CheckNames
    Check if database names are valid with the API

.PARAMETER ListDatabases
    List all available databases

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
    Version: 1.2.0
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
    [int]$Timeout = 1800,
    
    [Parameter()]
    [switch]$Quiet,
    
    [Parameter()]
    [switch]$NoLock,
    
    [Parameter()]
    [switch]$ValidateOnly,
    
    [Parameter()]
    [switch]$CheckNames,
    
    [Parameter()]
    [switch]$ListDatabases,

    [Parameter()]
    [switch]$OnlyChanged,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [string]$LockFile,

    [Parameter()]
    [int]$LockTimeout = 1800
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
$script:PidLockFile = Join-Path $script:TempPath "geoip-update.lock"
$script:DownloadJobs = @()
$script:MaxParallel = 2
$script:SharedLock = $null
$script:Manifest = $null
$script:ManifestUpdates = $null
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
        [Console]::Error.WriteLine($Message)
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

    if (-not (Get-Command cmdkey -ErrorAction SilentlyContinue)) {
        return $false
    }

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
    
    if (Test-Path -Path $script:PidLockFile) {
        try {
            $lockPid = Get-Content -Path $script:PidLockFile -ErrorAction Stop
            
            # Check if process is still running
            $process = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
            if ($process) {
                Exit-WithError -Message "Another instance is already running (PID: $lockPid)"
            }
            else {
                Write-LogMessage -Level WARN -Message "Removing stale lock file (PID: $lockPid)"
                Remove-Item -Path $script:PidLockFile -Force
            }
        }
        catch {
            Write-LogMessage -Level WARN -Message "Error reading lock file: $_"
            Remove-Item -Path $script:PidLockFile -Force -ErrorAction SilentlyContinue
        }
    }
    
    try {
        Set-Content -Path $script:PidLockFile -Value $currentPid -Force
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
    
    if (Test-Path -Path $script:PidLockFile) {
        try {
            $lockPid = Get-Content -Path $script:PidLockFile -ErrorAction Stop
            if ($lockPid -eq $PID) {
                Remove-Item -Path $script:PidLockFile -Force
                Write-LogMessage -Level INFO -Message "Released lock"
            }
        }
        catch {
            # Ignore errors when removing lock file
        }
    }
}

function Test-FileBusy {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    $e = $ErrorRecord.Exception
    while ($e.InnerException -and -not ($e -is [System.IO.IOException])) { $e = $e.InnerException }
    if (-not ($e -is [System.IO.IOException])) { return $false }
    $code = $e.HResult -band 0xFFFF
    return ($code -eq 32 -or $code -eq 33 -or $e.HResult -eq 11 -or $e.HResult -eq 35)
}

function Enter-SharedLock {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$DisplayPath,
        [int]$Timeout
    )

    $waited = 0
    while ($true) {
        try {
            $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            break
        }
        catch {
            if (-not (Test-FileBusy $_)) {
                $cause = $_.Exception
                if ($cause -is [System.Management.Automation.MethodInvocationException] -and $cause.InnerException) { $cause = $cause.InnerException }
                throw "Cannot open lock file ${DisplayPath}: $($cause.Message)"
            }
            if ($waited -ge $Timeout) { throw "Timed out after $Timeout s waiting for lock $DisplayPath" }
            Start-Sleep -Seconds 1
            $waited++
        }
    }

    try {
        $stream.SetLength(0)
        $info = [System.Text.Encoding]::UTF8.GetBytes(("pid={0} host={1} started={2}`n" -f $PID, [System.Net.Dns]::GetHostName(), [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)))
        $stream.Write($info, 0, $info.Length)
        $stream.Flush()
    }
    catch {
        Write-LogMessage -Level WARN -Message "Could not write lock file ${DisplayPath}: $_"
    }
    return $stream
}

$script:ManifestName = '.geoip-update.json'

function New-OrdinalTable {
    return [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
}

function Read-Manifest {
    param([string]$Dir)

    $result = New-OrdinalTable
    $path = Join-Path $Dir $script:ManifestName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $result }
    try {
        $doc = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
        foreach ($p in $doc.files.PSObject.Properties) {
            $result[$p.Name] = @{ etag = [string]$p.Value.etag; last_modified = [string]$p.Value.last_modified; size = [long]$p.Value.size }
        }
    }
    catch {
        $result = New-OrdinalTable
    }
    return $result
}

function Test-ManifestValue {
    param([string]$Value)
    return -not ($Value -match '["\\|\x00-\x1f\x7f]')
}

function Write-Manifest {
    param([string]$Dir, [hashtable]$Entries)

    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Entries.Keys) {
        $e = $Entries[$name]
        if ((Test-ManifestValue $name) -and $e.etag -and -not $e.etag.StartsWith('W/') -and (Test-ManifestValue $e.etag) -and (Test-ManifestValue $e.last_modified)) {
            $names.Add($name)
        }
    }
    $names.Sort([System.StringComparer]::Ordinal)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('{')
    $lines.Add('  "version": 1,')
    $lines.Add('  "files": {')
    for ($i = 0; $i -lt $names.Count; $i++) {
        $e = $Entries[$names[$i]]
        $comma = if ($i -lt $names.Count - 1) { ',' } else { '' }
        $lines.Add([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '    "{0}": {{"etag": "{1}", "last_modified": "{2}", "size": {3}}}{4}', $names[$i], $e.etag, $e.last_modified, [long]$e.size, $comma))
    }
    $lines.Add('  }')
    $lines.Add('}')

    $target = Join-Path $Dir $script:ManifestName
    $part = "$target.part"
    try {
        [System.IO.File]::WriteAllText($part, ($lines -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $part -Destination $target -Force
    }
    catch {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Test-Unchanged {
    param(
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)][string]$Url
    )

    $entry = $script:Manifest[$DatabaseName]
    if (-not $entry -or -not $entry.etag) { return $false }
    $file = Join-Path $script:TargetPath $DatabaseName
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $file).Length -ne $entry.size) { return $false }

    $client = $null; $resp = $null
    try {
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds($(if ($Timeout -gt 0) { $Timeout } else { 60 }))
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
        $req.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new(0, 0)
        [void]$req.Headers.TryAddWithoutValidation('If-None-Match', '"' + $entry.etag + '"')
        $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        return ([int]$resp.StatusCode -eq 304)
    }
    catch {
        Write-LogMessage -Level INFO -Message "${DatabaseName}: change check failed: $_"
        return $false
    }
    finally {
        if ($resp) { $resp.Dispose() }
        if ($client) { $client.Dispose() }
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

# Download $Url to <Directory>\<Name>.part, resuming on interruption/stall via
# an HTTP Range request instead of restarting from byte 0, so large databases
# complete on flaky links. Retries while the transfer keeps making progress;
# gives up only after a few consecutive no-progress attempts. On success returns
# the still-open staging stream with its path, ETag, Last-Modified and size;
# on failure removes the staging file and returns $null.
function Invoke-ResumableDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSec = 1800,
        [int]$MaxRestarts = 3
    )

    $maxNoProgress = 3
    $hardCap = 50
    $noProgress = 0
    $restarts = 0
    $attempt = 0
    $success = $false
    $etag = ''
    $lastModified = ''
    $leaf = $Name

    $getHeader = {
        param($Response, [string]$HeaderName)
        $values = $null
        if ($Response.Headers.TryGetValues($HeaderName, [ref]$values)) { return [string](@($values)[0]) }
        if ($Response.Content -and $Response.Content.Headers.TryGetValues($HeaderName, [ref]$values)) { return [string](@($values)[0]) }
        return ''
    }
    $unquote = {
        param([string]$Value)
        $v = $Value.Trim()
        if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2) }
        return $v
    }

    # Windows needs FileShare.Delete to rename the file while it is held open.
    $share = if ([System.IO.Path]::DirectorySeparatorChar -eq '\') { [System.IO.FileShare]::Delete } else { [System.IO.FileShare]::None }
    $stage = Join-Path $Directory "$Name.part"
    try {
        $fs = [System.IO.FileStream]::new($stage, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, $share)
    }
    catch {
        $stage = Join-Path $Directory "$Name.part.$(Get-Random)"
        $fs = [System.IO.FileStream]::new($stage, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, $share)
    }
    $fs.SetLength(0)

    while ($true) {
        $attempt++
        if ($attempt -gt $hardCap) { break }

        $offset = $fs.Length

        $client = $null; $resp = $null; $stream = $null
        try {
            $client = [System.Net.Http.HttpClient]::new()
            $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
            $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
            if ($offset -gt 0) {
                $req.Headers.Range = [System.Net.Http.Headers.RangeHeaderValue]::new($offset, $null)
                if ($etag -and -not $etag.StartsWith('W/')) {
                    [void]$req.Headers.TryAddWithoutValidation('If-Range', '"' + $etag + '"')
                }
                Write-Host "Resuming $leaf from $offset bytes (attempt $attempt)"
            }

            $resp = $client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $code = [int]$resp.StatusCode
            if ($code -eq 401 -or $code -eq 403) {
                Write-Host "${leaf}: access denied (HTTP $code) - the download URL may have expired; re-run to refresh URLs"
                break
            }
            if ($code -eq 416) {
                # Range past EOF => already complete, when a strong ETag ties those bytes to this object
                if ($etag -and -not $etag.StartsWith('W/')) { $success = $true; break }
                $restarts++
                Write-Host "${leaf}: cannot resume (HTTP $code) - restarting from scratch"
                if ($restarts -gt $MaxRestarts) { break }
                $fs.SetLength(0)
                continue
            }
            if ($code -ne 200 -and $code -ne 206) { throw "HTTP $code" }

            # A 200 to a resume, or a 206 for a different object, means the partial bytes cannot be kept.
            $respETag = & $unquote (& $getHeader $resp 'ETag')
            $changed = ($code -eq 206 -and $etag -and $respETag -and $respETag -ne $etag)
            if ($offset -gt 0 -and ($code -eq 200 -or $changed)) {
                $restarts++
                Write-Host "${leaf}: cannot resume (HTTP $code) - restarting from scratch"
                if ($restarts -gt $MaxRestarts) { break }
                $noProgress = 0
                if ($changed) {
                    $etag = ''
                    $fs.SetLength(0)
                    continue
                }
            }
            if ($code -eq 200) {
                $etag = $respETag
                $lastModified = & $getHeader $resp 'Last-Modified'
                $fs.SetLength(0)
                $offset = 0
            }
            [void]$fs.Seek(0, [System.IO.SeekOrigin]::End)

            $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()

            # Per-read stall guard (120s): abort a transfer that stops delivering
            # bytes, while $client.Timeout is the overall ceiling. This matches
            # the curl --speed-time / aiohttp sock_read / Go idle-reader guard in
            # the other variants (HttpClient.Timeout alone is a total timeout and
            # would let a mid-body stall hang for the full ceiling).
            $buffer = New-Object byte[] 65536
            while ($true) {
                $cts = [System.Threading.CancellationTokenSource]::new()
                $cts.CancelAfter([TimeSpan]::FromSeconds(120))
                try {
                    $read = $stream.ReadAsync($buffer, 0, $buffer.Length, $cts.Token).GetAwaiter().GetResult()
                }
                finally {
                    $cts.Dispose()
                }
                if ($read -le 0) { break }
                $fs.Write($buffer, 0, $read)
            }
            $fs.Flush()
            $success = $true  # read through to EOF => complete
            break
        }
        catch {
            $cur = $fs.Length
            if ($cur -gt $offset) {
                $noProgress = 0
                Write-Host "${leaf}: transfer interrupted at $cur bytes - resuming ($_)"
            }
            else {
                $noProgress++
                if ($noProgress -ge $maxNoProgress) { break }
                Start-Sleep -Seconds 5
            }
        }
        finally {
            if ($stream) { $stream.Dispose() }
            if ($resp) { $resp.Dispose() }
            if ($client) { $client.Dispose() }
        }
    }

    if ($success) {
        return @{ Stream = $fs; Path = $stage; ETag = $etag; LastModified = $lastModified; Size = $fs.Length }
    }
    $fs.Dispose()
    Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
    return $null
}

# Move a successful download's staging file onto $TargetFile and release it.
function Complete-StagedDownload {
    param([hashtable]$Download, [string]$TargetFile)
    Move-Item -LiteralPath $Download.Path -Destination $TargetFile -Force
    $Download.Stream.Dispose()
}

# Release a download's staging file and remove it.
function Remove-StagedDownload {
    param([hashtable]$Download)
    if (-not $Download) { return }
    $Download.Stream.Dispose()
    Remove-Item -LiteralPath $Download.Path -Force -ErrorAction SilentlyContinue
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
    
    $targetFile = Join-Path $script:TargetPath $DatabaseName
    $download = $null
    
    # Show progress bar
    $percentComplete = [int](($Index / $Total) * 100)
    Write-Progress -Activity "Downloading GeoIP Databases" `
                   -Status "Downloading $DatabaseName" `
                   -PercentComplete $percentComplete `
                   -CurrentOperation "$Index of $Total databases"
    
    try {
        # Resumable download: continues a partial transfer instead of restarting
        # from byte 0, so large databases complete on flaky links.
        $download = Invoke-ResumableDownload -Url $Url -Directory $script:TargetPath -Name $DatabaseName -TimeoutSec $Timeout -MaxRestarts $MaxRetries
        if (-not $download) {
            throw "Download failed (could not complete after retries)"
        }

        # Validate downloaded file
        if ($download.Size -gt 0) {
            $fileSize = $download.Size
            
            # Basic validation
            if ($DatabaseName -like "*.mmdb") {
                # Check for MaxMind metadata marker at the end of the file
                # MMDB files have metadata at the end with marker \xab\xcd\xef followed by MaxMind.com
                try {
                    $readSize = [Math]::Min($fileSize, 100000)  # Read last 100KB
                    
                    # Seek the staging stream to the position to start reading
                    $fileStream = $download.Stream
                    $fileStream.Seek($fileSize - $readSize, [System.IO.SeekOrigin]::Begin) | Out-Null
                    
                    # Read the last portion of the file
                    $buffer = New-Object byte[] $readSize
                    $bytesRead = $fileStream.Read($buffer, 0, $readSize)
                    
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
            Complete-StagedDownload -Download $download -TargetFile $targetFile
            
            return @{
                Success = $true
                Database = $DatabaseName
                Size = $fileSize
                ETag = $download.ETag
                LastModified = $download.LastModified
            }
        }
        else {
            throw "Downloaded file is empty or missing"
        }
    }
    catch {
        Remove-StagedDownload -Download $download
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
    
    $targetFile = Join-Path $script:TargetPath $DatabaseName
    
    # Pass the downloader's definitions into the job's runspace.
    $functions = @{}
    foreach ($name in 'Invoke-ResumableDownload', 'Complete-StagedDownload', 'Remove-StagedDownload') {
        $functions[$name] = (Get-Command -Name $name -CommandType Function).ScriptBlock.ToString()
    }

    $job = Start-Job -ScriptBlock {
        param($DatabaseName, $Url, $Directory, $TargetFile, $Timeout, $MaxRetries, $Functions)

        # Re-create the downloader inside this job's runspace.
        foreach ($name in $Functions.Keys) {
            Set-Item -Path "function:$name" -Value ([scriptblock]::Create($Functions[$name]))
        }

        $download = $null
        try {
            # Resumable download: continues a partial transfer instead of
            # restarting from byte 0, so large databases complete on flaky links.
            $download = Invoke-ResumableDownload -Url $Url -Directory $Directory -Name $DatabaseName -TimeoutSec $Timeout -MaxRestarts $MaxRetries
            if (-not $download) {
                throw "Download failed (could not complete after retries)"
            }

            # Verify and move file
            if ($download.Size -gt 0) {
                Complete-StagedDownload -Download $download -TargetFile $TargetFile
                return @{
                    Success = $true
                    Database = $DatabaseName
                    Size = $download.Size
                    ETag = $download.ETag
                    LastModified = $download.LastModified
                }
            }
            else {
                throw "Downloaded file is empty or missing"
            }
        }
        catch {
            Remove-StagedDownload -Download $download
            return @{
                Success = $false
                Database = $DatabaseName
                Error = $_.ToString()
            }
        }
    } -ArgumentList $DatabaseName, $Url, $script:TargetPath, $targetFile, $Timeout, $MaxRetries, $functions
    
    return $job
}

function Add-ManifestUpdate {
    param([hashtable]$Result)
    if ($OnlyChanged) {
        $script:ManifestUpdates[$Result.Database] = @{ etag = [string]$Result.ETag; last_modified = [string]$Result.LastModified; size = [long]$Result.Size }
    }
}

# Main update function
function Update-Databases {
    Write-LogMessage -Level INFO -Message "Starting GeoIP database update"
    Write-LogMessage -Level INFO -Message "Target directory: $TargetDirectory"
    
    $script:TargetPath = (Resolve-Path -LiteralPath $TargetDirectory).ProviderPath
    
    if ($OnlyChanged) {
        $script:Manifest = Read-Manifest -Dir $script:TargetPath
        $script:ManifestUpdates = New-OrdinalTable
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
    $totalCount = @($urls.PSObject.Properties).Count
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
            
            if ($OnlyChanged -and -not $Force -and (Test-Unchanged -DatabaseName $dbName -Url $url)) {
                Write-LogMessage -Level SUCCESS -Message "Unchanged: $dbName"
                $completedCount++
                continue
            }
            
            Write-LogMessage -Level INFO -Message "Downloading: $dbName ($index of $totalCount)"
            
            $result = Start-DatabaseDownloadWithProgress -DatabaseName $dbName -Url $url -Index $index -Total $totalCount
            
            if ($result.Success) {
                Write-LogMessage -Level SUCCESS -Message "Successfully downloaded: $($result.Database) ($('{0:N0}' -f $result.Size) bytes)"
                Add-ManifestUpdate -Result $result
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
        # Parallel downloads without progress bars. Default 2 (was 4):
        # bandwidth-bound downloads finish large files sooner with fewer streams.
        $maxParallel = $script:MaxParallel
        $jobs = @()
        $completedCount = 0
        $failedCount = 0
        
        foreach ($property in $urls.PSObject.Properties) {
            $dbName = $property.Name
            $url = $property.Value
            
            if ($OnlyChanged -and -not $Force -and (Test-Unchanged -DatabaseName $dbName -Url $url)) {
                Write-LogMessage -Level SUCCESS -Message "Unchanged: $dbName"
                $completedCount++
                continue
            }
            
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
                        Add-ManifestUpdate -Result $result
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
                    Add-ManifestUpdate -Result $result
                    $completedCount++
                }
                else {
                    Write-LogMessage -Level ERROR -Message "Failed to download $($result.Database): $($result.Error)"
                    $failedCount++
                }
            }
        }
    }
    
    if ($OnlyChanged) {
        $entries = New-OrdinalTable
        foreach ($name in $script:Manifest.Keys) { $entries[$name] = $script:Manifest[$name] }
        foreach ($name in $script:ManifestUpdates.Keys) { $entries[$name] = $script:ManifestUpdates[$name] }
        try {
            Write-Manifest -Dir $script:TargetPath -Entries $entries
        }
        catch {
            Write-LogMessage -Level ERROR -Message "Failed to write manifest: $_"
        }
    }
    
    Write-LogMessage -Level INFO -Message "Download summary: $completedCount successful, $failedCount failed"
    
    if ($failedCount -gt 0) {
        Exit-WithError -Message "Failed to download $failedCount databases" -ExitCode 2
    }
}

# Validate existing database files
function Test-DatabaseFiles {
    Write-LogMessage -Level INFO -Message "Validating database files in: $TargetDirectory"
    
    if (-not (Test-Path -Path $TargetDirectory)) {
        Exit-WithError -Message "Directory does not exist: $TargetDirectory"
    }
    
    $totalFiles = 0
    $validFiles = 0
    $invalidFiles = 0
    $hasErrors = $false
    
    # Validate MMDB files
    Write-LogMessage -Level INFO -Message "Validating MMDB files..."
    Get-ChildItem -Path $TargetDirectory -Filter "*.mmdb" -ErrorAction SilentlyContinue | ForEach-Object {
        $totalFiles++
        $fileName = $_.Name
        $fileSize = $_.Length
        
        if ($fileSize -lt 1000) {
            Write-Host "  ❌ $fileName - File too small (${fileSize}bytes)" -ForegroundColor Red
            $invalidFiles++
            $hasErrors = $true
        }
        else {
            try {
                # Check for MaxMind.com marker in the last 100KB
                $readSize = [Math]::Min($fileSize, 100000)
                $fileStream = [System.IO.File]::OpenRead($_.FullName)
                $fileStream.Seek($fileSize - $readSize, [System.IO.SeekOrigin]::Begin) | Out-Null
                
                $buffer = New-Object byte[] $readSize
                $bytesRead = $fileStream.Read($buffer, 0, $readSize)
                $fileStream.Close()
                
                # Look for \xab\xcd\xef followed by MaxMind.com
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
                
                if ($found) {
                    $sizeMB = [Math]::Round($fileSize / 1MB, 2)
                    Write-Host "  ✅ $fileName (${sizeMB}MB) - Valid MMDB format" -ForegroundColor Green
                    $validFiles++
                }
                else {
                    Write-Host "  ❌ $fileName - Invalid MMDB format (missing MaxMind metadata)" -ForegroundColor Red
                    $invalidFiles++
                    $hasErrors = $true
                }
            }
            catch {
                Write-Host "  ❌ $fileName - Error validating: $_" -ForegroundColor Red
                $invalidFiles++
                $hasErrors = $true
            }
        }
    }
    
    # Validate BIN files
    Write-LogMessage -Level INFO -Message "Validating BIN files..."
    Get-ChildItem -Path $TargetDirectory -Filter "*.BIN" -ErrorAction SilentlyContinue | ForEach-Object {
        $totalFiles++
        $fileName = $_.Name
        $fileSize = $_.Length
        
        if ($fileSize -lt 1000) {
            Write-Host "  ❌ $fileName - File too small (${fileSize}bytes)" -ForegroundColor Red
            $invalidFiles++
            $hasErrors = $true
        }
        else {
            # Basic check: BIN files should be binary
            try {
                $sizeMB = [Math]::Round($fileSize / 1MB, 2)
                Write-Host "  ✅ $fileName (${sizeMB}MB) - Valid BIN format" -ForegroundColor Green
                $validFiles++
            }
            catch {
                Write-Host "  ⚠️  $fileName - Could not verify BIN format" -ForegroundColor Yellow
            }
        }
    }
    
    # Summary
    Write-Host ""
    Write-LogMessage -Level INFO -Message "Validation Summary:"
    Write-LogMessage -Level INFO -Message "  Total files: $totalFiles"
    Write-LogMessage -Level INFO -Message "  Valid files: $validFiles"
    Write-LogMessage -Level INFO -Message "  Invalid files: $invalidFiles"
    
    if ($totalFiles -eq 0) {
        Exit-WithError -Message "No database files found!"
    }
    
    if ($hasErrors) {
        Exit-WithError -Message "Validation FAILED - some databases are invalid!"
    }
    else {
        Write-LogMessage -Level SUCCESS -Message "Validation PASSED - all databases are valid!"
        exit 0
    }
}

# Check database names with API
function Test-DatabaseNames {
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        Exit-WithError -Message "API key required for validation. Use -ApiKey parameter or set GEOIP_API_KEY environment variable"
    }
    
    # Normalize endpoint
    $ApiEndpoint = $ApiEndpoint.TrimEnd('/', ' ', "`t", "`n", "`r")
    if ($ApiEndpoint -match 'geoipdb\.net$') {
        $ApiEndpoint = "$ApiEndpoint/auth"
    }
    
    if ($Databases -contains 'all') {
        Write-Host "✓ Database selection 'all' is valid" -ForegroundColor Green
        return
    }
    
    # Convert databases to JSON
    $body = @{ databases = @($Databases) } | ConvertTo-Json -Depth 10
    
    Write-LogMessage -Level INFO -Message "Validating database names: $($Databases -join ', ')"
    
    try {
        $headers = @{ 'X-API-Key' = $ApiKey }
        $response = Invoke-WebRequest -Uri $ApiEndpoint `
                                     -Method POST `
                                     -Headers $headers `
                                     -Body $body `
                                     -ContentType 'application/json' `
                                     -UseBasicParsing `
                                     -TimeoutSec 10 `
                                     -ErrorAction Stop
        
        $result = $response.Content | ConvertFrom-Json
        
        if ($result.PSObject.Properties.Count -gt 0) {
            Write-Host "✓ All database names are valid" -ForegroundColor Green
            Write-Host "✓ Resolved to $($result.PSObject.Properties.Count) database(s)" -ForegroundColor Green
            
            # Show resolved databases
            foreach ($prop in $result.PSObject.Properties) {
                Write-Host "  → $($prop.Name)" -ForegroundColor Cyan
            }
        }
        else {
            Write-Host "✗ Validation failed: No databases resolved" -ForegroundColor Red
            exit 1
        }
    }
    catch {
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            if ($statusCode -eq 400) {
                # Try to extract error message
                try {
                    $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                    $errorContent = $reader.ReadToEnd()
                    $reader.Close()
                    $errorJson = $errorContent | ConvertFrom-Json
                    if ($errorJson.detail) {
                        Write-Host "✗ Validation failed: $($errorJson.detail)" -ForegroundColor Red
                    }
                    else {
                        Write-Host "✗ Validation failed: Invalid database names" -ForegroundColor Red
                    }
                }
                catch {
                    Write-Host "✗ Validation failed: Invalid database names" -ForegroundColor Red
                }
            }
            else {
                Write-Host "✗ Validation failed: HTTP $statusCode" -ForegroundColor Red
            }
        }
        else {
            Write-Host "✗ Validation failed: Unable to connect to API" -ForegroundColor Red
        }
        exit 1
    }
}

# List available databases
function Get-AvailableDatabases {
    # Convert /auth endpoint to /databases endpoint
    $databasesEndpoint = $ApiEndpoint -replace '/auth$', '/databases'
    
    Write-LogMessage -Level INFO -Message "Fetching database information from: $databasesEndpoint"
    
    try {
        $response = Invoke-WebRequest -Uri $databasesEndpoint `
                                     -TimeoutSec 10 `
                                     -UseBasicParsing `
                                     -ErrorAction Stop
        
        $dbInfo = $response.Content | ConvertFrom-Json
        
        Write-Host "Available GeoIP Databases:" -ForegroundColor Cyan
        Write-Host "=========================" -ForegroundColor Cyan
        Write-Host ""
        
        Write-Host "Total databases: $($dbInfo.total)" -ForegroundColor Green
        Write-Host ""
        
        if ($dbInfo.providers.maxmind) {
            Write-Host "MaxMind databases ($($dbInfo.providers.maxmind.count)):" -ForegroundColor Yellow
            foreach ($db in $dbInfo.providers.maxmind.databases) {
                Write-Host "  • $($db.name) (aliases: $($db.aliases -join ', '))" -ForegroundColor White
            }
            Write-Host ""
        }
        
        if ($dbInfo.providers.ip2location) {
            Write-Host "IP2Location databases ($($dbInfo.providers.ip2location.count)):" -ForegroundColor Yellow
            foreach ($db in $dbInfo.providers.ip2location.databases) {
                Write-Host "  • $($db.name) (aliases: $($db.aliases -join ', '))" -ForegroundColor White
            }
            Write-Host ""
        }
        
        Write-Host "Bulk Selection Options:" -ForegroundColor Cyan
        Write-Host "  • all - All databases" -ForegroundColor White
        Write-Host "  • maxmind/all - All MaxMind databases" -ForegroundColor White
        Write-Host "  • ip2location/all - All IP2Location databases" -ForegroundColor White
        Write-Host ""
        
        Write-Host "Usage Notes:" -ForegroundColor Cyan
        Write-Host "  • Database names are case-insensitive" -ForegroundColor White
        Write-Host "  • File extensions are optional in most cases" -ForegroundColor White
        Write-Host "  • Use short aliases for easier selection" -ForegroundColor White
    }
    catch {
        Write-LogMessage -Level WARN -Message "Database discovery not available, using fallback mode"
        Write-Host "Database discovery not available." -ForegroundColor Yellow
        Write-Host "Using legacy database list:" -ForegroundColor Yellow
        Write-Host "  • GeoIP2-City.mmdb" -ForegroundColor White
        Write-Host "  • GeoIP2-Country.mmdb" -ForegroundColor White
        Write-Host "  • GeoIP2-ISP.mmdb" -ForegroundColor White
        Write-Host "  • GeoIP2-Connection-Type.mmdb" -ForegroundColor White
        Write-Host "  • IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN" -ForegroundColor White
        Write-Host "  • IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN" -ForegroundColor White
        Write-Host "  • IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN" -ForegroundColor White
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
    
    if ($script:SharedLock) {
        $script:SharedLock.Dispose()
    }
    
    if ($script:ExitCode -eq 0) {
        Write-LogMessage -Level SUCCESS -Message "GeoIP update completed successfully"
    }
    else {
        Write-LogMessage -Level ERROR -Message "GeoIP update failed with exit code: $($script:ExitCode)"
    }
}

function Get-EnvInteger {
    param([string]$Name, [int]$Minimum = 0)
    $raw = [Environment]::GetEnvironmentVariable($Name)
    try {
        $value = [System.Management.Automation.LanguagePrimitives]::ConvertTo($raw, [int])
    }
    catch {
        Exit-WithError -Message "Invalid $Name value: $raw"
    }
    if ($value -lt $Minimum) {
        Exit-WithError -Message "Invalid $Name value: $raw"
    }
    return $value
}

# Environment defaults; parameters given on the command line win
function Split-DatabaseNames {
    param([string[]]$Names)
    return @($Names | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

if (-not $PSBoundParameters.ContainsKey('Databases') -and $env:GEOIP_DATABASES) {
    $fromEnv = Split-DatabaseNames -Names @($env:GEOIP_DATABASES)
    if ($fromEnv.Count -gt 0) {
        $Databases = $fromEnv
    }
}
$Databases = Split-DatabaseNames -Names $Databases
if (-not $PSBoundParameters.ContainsKey('MaxRetries') -and $env:GEOIP_MAX_RETRIES) {
    $MaxRetries = Get-EnvInteger -Name 'GEOIP_MAX_RETRIES'
}
if (-not $PSBoundParameters.ContainsKey('Timeout') -and $env:GEOIP_TIMEOUT) {
    $Timeout = Get-EnvInteger -Name 'GEOIP_TIMEOUT'
}
if ($env:GEOIP_CONCURRENT) {
    $script:MaxParallel = Get-EnvInteger -Name 'GEOIP_CONCURRENT' -Minimum 1
}
if (-not $PSBoundParameters.ContainsKey('OnlyChanged') -and @('true', '1', 'yes') -contains "$env:GEOIP_ONLY_CHANGED".Trim()) {
    $OnlyChanged = $true
}
if (-not $PSBoundParameters.ContainsKey('LockFile') -and $env:GEOIP_LOCK_FILE) {
    $LockFile = $env:GEOIP_LOCK_FILE
}
if (-not $PSBoundParameters.ContainsKey('LockTimeout') -and $env:GEOIP_LOCK_TIMEOUT) {
    $LockTimeout = Get-EnvInteger -Name 'GEOIP_LOCK_TIMEOUT'
}
if ($LockFile -and $NoLock) {
    Exit-WithError -Message '--lock-file and --no-lock cannot be combined' -ExitCode 1
}

# Register cleanup on exit
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    # Note: This handler may not execute in all scenarios
    if (Test-Path -Path $script:PidLockFile) {
        Remove-Item -Path $script:PidLockFile -Force -ErrorAction SilentlyContinue
    }
}

# Main execution
try {
    Write-LogMessage -Level INFO -Message "GeoIP Update Script starting"
    
    # Handle special modes
    if ($ValidateOnly) {
        Test-DatabaseFiles
        exit 0
    }
    
    if ($CheckNames) {
        Test-DatabaseNames
        exit 0
    }
    
    if ($ListDatabases) {
        Get-AvailableDatabases
        exit 0
    }
    
    # Normal update mode
    # Validate configuration
    Test-Configuration
    
    # Store API key in Credential Manager if requested and not already stored
    if ($ApiKey -and -not (Get-ApiKeyFromCredentialManager)) {
        Set-ApiKeyInCredentialManager -ApiKey $ApiKey
    }
    
    # Acquire lock
    if ($LockFile) {
        try {
            $lockPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LockFile)
            $script:SharedLock = Enter-SharedLock -Path $lockPath -DisplayPath $LockFile -Timeout $LockTimeout
            Write-LogMessage -Level INFO -Message "Acquired lock: $LockFile"
        }
        catch {
            Exit-WithError -Message "$($_.Exception.Message)"
        }
    }
    else {
        New-LockFile
    }
    
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