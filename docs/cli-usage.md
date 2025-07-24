# GeoIP CLI Tools Usage Guide

This guide explains how to use the GeoIP command-line tools to download and update GeoIP databases outside of GitHub Actions.

## Available Tools

We provide several CLI tools for different platforms and use cases:

1. **Bash Script** (`geoip-update.sh`) - For Linux/macOS with cron
2. **PowerShell Script** (`geoip-update.ps1`) - For Windows with Task Scheduler
3. **Python Script** (`geoip-update.py`) - Cross-platform with advanced features
4. **Docker Container** - For containerized environments (coming soon)
5. **Go Binary** - Single executable, no dependencies (coming soon)

## Prerequisites

### API Key
You need a valid GeoIP API key. Store it securely:
- As an environment variable: `GEOIP_API_KEY`
- In a configuration file (Python version only)
- Pass via command-line argument (less secure)

### Dependencies
- **Bash Script**: `curl`, `jq`
- **PowerShell Script**: PowerShell 5.0+
- **Python Script**: Python 3.7+, `aiohttp`, `pyyaml`

## Installation

### Bash Script (Linux/macOS)

```bash
# Download the script
curl -O https://raw.githubusercontent.com/ytzcom/geoip/main/scripts/cli/geoip-update.sh
chmod +x geoip-update.sh

# Move to system location (optional)
sudo mv geoip-update.sh /usr/local/bin/geoip-update
```

### PowerShell Script (Windows)

```powershell
# Download the script
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/ytzcom/geoip/main/scripts/cli/geoip-update.ps1" -OutFile "geoip-update.ps1"

# Allow script execution
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### Python Script (All Platforms)

```bash
# Install via pip
pip install geoip-update

# Or manually
git clone https://github.com/ytzcom/geoip.git
cd geoip/scripts/cli
pip install -r requirements.txt
```

## Basic Usage

### Environment Setup

First, set your API key:

```bash
# Linux/macOS
export GEOIP_API_KEY="geoip_xxxxxxxxxxxxx"

# Windows Command Prompt
set GEOIP_API_KEY=geoip_xxxxxxxxxxxxx

# Windows PowerShell
$env:GEOIP_API_KEY = "geoip_xxxxxxxxxxxxx"
```

### Download All Databases

```bash
# Bash
./geoip-update.sh

# PowerShell
.\geoip-update.ps1

# Python
geoip-update
```

### Download Specific Databases

```bash
# Bash
./geoip-update.sh -b "GeoIP2-City.mmdb,GeoIP2-Country.mmdb"

# PowerShell
.\geoip-update.ps1 -Databases @("GeoIP2-City.mmdb", "GeoIP2-Country.mmdb")

# Python
geoip-update -b GeoIP2-City.mmdb GeoIP2-Country.mmdb
```

### Specify Target Directory

```bash
# Bash
./geoip-update.sh -d /var/lib/geoip

# PowerShell
.\geoip-update.ps1 -TargetDirectory "C:\GeoIP"

# Python
geoip-update -d /var/lib/geoip
```

## Advanced Usage

### Configuration File (Python Only)

Create `config.yaml`:

```yaml
api_key: "geoip_xxxxxxxxxxxxx"
api_endpoint: "https://api.example.com/v1/auth"
target_dir: "/var/lib/geoip"
databases:
  - GeoIP2-City.mmdb
  - GeoIP2-Country.mmdb
max_concurrent: 4
log_file: "/var/log/geoip-update.log"
```

Use it:

```bash
geoip-update --config config.yaml
```

### Logging

```bash
# Bash
./geoip-update.sh -l /var/log/geoip-update.log

# PowerShell
.\geoip-update.ps1 -LogFile "C:\Logs\geoip-update.log"

# Python
geoip-update -l /var/log/geoip-update.log
```

### Quiet Mode (for Automation)

```bash
# Bash
./geoip-update.sh -q

# PowerShell
.\geoip-update.ps1 -Quiet

# Python
geoip-update -q
```

## Scheduling Updates

### Linux/macOS with Cron

Edit crontab:
```bash
crontab -e
```

Add entries:
```bash
# Daily at 3 AM
0 3 * * * /usr/local/bin/geoip-update -q -l /var/log/geoip-update.log

# Weekly on Sundays at 2 AM
0 2 * * 0 /usr/local/bin/geoip-update -q

# With environment variable
GEOIP_API_KEY=geoip_xxxxxxxxxxxxx
0 3 * * * /usr/local/bin/geoip-update -q
```

### Windows with Task Scheduler

Create a scheduled task:

```powershell
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-ExecutionPolicy Bypass -File C:\Scripts\geoip-update.ps1 -Quiet"

$trigger = New-ScheduledTaskTrigger -Daily -At 3am

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" `
    -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "GeoIP Update" `
    -Action $action -Trigger $trigger -Principal $principal
```

Or use the GUI:
1. Open Task Scheduler
2. Create Basic Task
3. Set trigger (daily, weekly, etc.)
4. Action: Start a program
5. Program: `PowerShell.exe`
6. Arguments: `-ExecutionPolicy Bypass -File C:\Scripts\geoip-update.ps1 -Quiet`

### systemd Timer (Modern Linux)

Create service file `/etc/systemd/system/geoip-update.service`:

```ini
[Unit]
Description=Update GeoIP databases
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/geoip-update -q
Environment="GEOIP_API_KEY=geoip_xxxxxxxxxxxxx"
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Create timer file `/etc/systemd/system/geoip-update.timer`:

```ini
[Unit]
Description=Update GeoIP databases daily
Requires=geoip-update.service

[Timer]
OnCalendar=daily
AccuracySec=1h
Persistent=true

[Install]
WantedBy=timers.target
```

Enable and start:
```bash
sudo systemctl daemon-reload
sudo systemctl enable geoip-update.timer
sudo systemctl start geoip-update.timer
```

## Command Reference

### Bash Script Options

```
-k, --api-key KEY       API key (or use GEOIP_API_KEY env var)
-e, --endpoint URL      API endpoint
-d, --directory DIR     Target directory (default: ./geoip)
-b, --databases LIST    Comma-separated list or "all"
-q, --quiet            Quiet mode for cron
-v, --verbose          Verbose output
-l, --log-file FILE    Log to file
-n, --no-lock          Don't use lock file
-r, --retries NUM      Max retries (default: 3)
-t, --timeout SEC      Download timeout (default: 300)
-h, --help             Show help
```

### PowerShell Script Parameters

```
-ApiKey <String>          API key
-ApiEndpoint <String>     API endpoint URL
-TargetDirectory <String> Target directory
-Databases <String[]>     Array of databases or "all"
-LogFile <String>        Log file path
-MaxRetries <Int>        Max retries (default: 3)
-Timeout <Int>           Timeout in seconds (default: 300)
-Quiet                   Suppress output
-NoLock                  Don't use lock file
```

### Python Script Options

```
-k, --api-key KEY      API key
-e, --endpoint URL     API endpoint
-d, --directory DIR    Target directory
-b, --databases LIST   Database names or "all"
-c, --config FILE      Configuration file (YAML)
-l, --log-file FILE    Log file path
-r, --retries NUM      Max retries
-t, --timeout SEC      Timeout in seconds
--concurrent NUM       Max concurrent downloads
-q, --quiet           Quiet mode
-v, --verbose         Verbose output
--no-lock            Don't use lock file
--version            Show version
```

## Available Databases

The following databases can be downloaded:

**MaxMind Databases:**
- `GeoIP2-City.mmdb` - City-level geolocation
- `GeoIP2-Country.mmdb` - Country-level geolocation
- `GeoIP2-ISP.mmdb` - ISP information
- `GeoIP2-Connection-Type.mmdb` - Connection type data

**IP2Location Databases:**
- `IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN` - IPv4 comprehensive
- `IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN` - IPv6 comprehensive
- `IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN` - Proxy detection

## Troubleshooting

### Common Issues

**Authentication Failed**
```
ERROR: Authentication failed (401) - check your API key
```
- Verify your API key is correct
- Ensure the key is active and not expired

**Rate Limit Exceeded**
```
ERROR: Rate limit exceeded (429)
```
- Default limit: 100 requests per hour
- Script will automatically retry after delay

**Permission Denied**
```
ERROR: Target directory is not writable
```
- Check directory permissions
- Run with appropriate privileges

**Lock File Issues**
```
ERROR: Another instance is already running
```
- Check for stuck processes
- Use `--no-lock` to bypass (not recommended)
- Remove stale lock file: `/tmp/geoip-update.lock`

### Debug Mode

Enable verbose output for troubleshooting:

```bash
# Bash
./geoip-update.sh -v

# PowerShell
.\geoip-update.ps1 -Verbose

# Python
geoip-update -v
```

## Security Best Practices

1. **API Key Storage**
   - Use environment variables or secure credential stores
   - Never commit API keys to version control
   - Rotate keys regularly

2. **File Permissions**
   - Restrict access to downloaded databases
   - Secure log files containing sensitive information
   - Use appropriate umask settings

3. **Network Security**
   - Verify SSL certificates (default enabled)
   - Use HTTPS proxy if required
   - Monitor for unusual download patterns

4. **Automation Security**
   - Use dedicated service accounts
   - Limit permissions to minimum required
   - Enable audit logging

## Performance Tips

1. **Parallel Downloads**: Python script supports concurrent downloads
2. **Caching**: Files are only downloaded if updated
3. **Bandwidth**: Schedule during off-peak hours
4. **Storage**: Ensure adequate disk space (2GB+ recommended)

## Integration Examples

### Using in Applications

**Python:**
```python
import geoip2.database

reader = geoip2.database.Reader('/var/lib/geoip/GeoIP2-City.mmdb')
response = reader.city('8.8.8.8')
print(f"{response.city.name}, {response.country.name}")
```

**PHP:**
```php
use GeoIp2\Database\Reader;

$reader = new Reader('/var/lib/geoip/GeoIP2-City.mmdb');
$record = $reader->city('8.8.8.8');
echo $record->city->name . ', ' . $record->country->name;
```

**Node.js:**
```javascript
const maxmind = require('maxmind');

const lookup = await maxmind.open('/var/lib/geoip/GeoIP2-City.mmdb');
const result = lookup.get('8.8.8.8');
console.log(`${result.city.names.en}, ${result.country.names.en}`);
```

## Support

For issues or questions:
1. Check the [troubleshooting section](#troubleshooting)
2. Review script help: `./geoip-update.sh --help`
3. Open an issue in the GitHub repository
4. Contact the maintainer for API key issues