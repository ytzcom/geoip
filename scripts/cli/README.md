# GeoIP Database CLI Update Scripts

Cross-platform command-line scripts for downloading GeoIP databases from the authenticated API.

## Docker Images

Pre-built Docker images are available on Docker Hub. See [DOCKER_HUB.md](DOCKER_HUB.md) for detailed usage instructions.

```bash
# Quick start with Docker
docker run --rm \
  -e GEOIP_API_KEY=your-api-key \
  -e GEOIP_API_ENDPOINT=https://geoip.ytrack.io/auth \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater:latest
```

## Available Scripts

### Bash Script (`geoip-update.sh`)
- **Platform**: Linux, macOS, BSD
- **Requirements**: bash, curl, jq
- **Scheduler**: cron, systemd timers

### PowerShell Script (`geoip-update.ps1`)
- **Platform**: Windows
- **Requirements**: PowerShell 5.1+
- **Scheduler**: Windows Task Scheduler
- **Features**: Windows Credential Manager integration, progress bars

### Python Script (`geoip-update.py`)
- **Platform**: Cross-platform (Windows, Linux, macOS)
- **Requirements**: Python 3.7+, pip packages (see requirements.txt)
- **Scheduler**: Any (cron, Task Scheduler, systemd)
- **Features**: Async downloads, YAML config support

## Initial Setup

### 1. Deploy Infrastructure

First, deploy the AWS infrastructure:

```bash
cd infrastructure/terraform
terraform init
terraform apply
```

### 2. Configure Domain (Optional)

The scripts are pre-configured to use `https://geoip.ytrack.io/auth` as the default endpoint. If you want to use your own domain:

```bash
# Update all scripts with your custom endpoint
cd scripts/cli
chmod +x update-api-endpoint.sh
./update-api-endpoint.sh "https://your-custom-domain.com/auth"
```

### 3. Install Dependencies

#### For Bash Script
```bash
# Ubuntu/Debian
sudo apt-get install curl jq

# CentOS/RHEL
sudo yum install curl jq

# macOS
brew install curl jq
```

#### For Python Script
```bash
pip install -r requirements.txt
# or
pip install aiohttp pyyaml click
```

## Usage Examples

### Basic Usage

```bash
# Bash
./geoip-update.sh -k YOUR_API_KEY

# PowerShell
.\geoip-update.ps1 -ApiKey YOUR_API_KEY

# Python
python geoip-update.py --api-key YOUR_API_KEY
```

### Using Environment Variables

```bash
export GEOIP_API_KEY="your_api_key_here"
export GEOIP_TARGET_DIR="/var/lib/geoip"

# All scripts will use these environment variables
./geoip-update.sh
```

### Download Specific Databases

```bash
# Bash
./geoip-update.sh -k YOUR_API_KEY -b "GeoIP2-City.mmdb,GeoIP2-Country.mmdb"

# PowerShell
.\geoip-update.ps1 -ApiKey YOUR_API_KEY -Databases @("GeoIP2-City.mmdb", "GeoIP2-Country.mmdb")

# Python
python geoip-update.py --api-key YOUR_API_KEY --databases GeoIP2-City.mmdb --databases GeoIP2-Country.mmdb
```

### Quiet Mode for Schedulers

```bash
# Bash (for cron)
./geoip-update.sh -q -l /var/log/geoip-update.log

# PowerShell (for Task Scheduler)
.\geoip-update.ps1 -Quiet -LogFile C:\Logs\geoip-update.log

# Python
python geoip-update.py --quiet --log-file /var/log/geoip-update.log
```

## Scheduler Configuration

### Cron (Linux/macOS)

Add to crontab (`crontab -e`):

```cron
# Update GeoIP databases daily at 2 AM
0 2 * * * /path/to/geoip-update.sh -q -l /var/log/geoip-update.log
```

### Windows Task Scheduler

Create a scheduled task:

```powershell
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-ExecutionPolicy Bypass -File C:\Scripts\geoip-update.ps1 -Quiet -LogFile C:\Logs\geoip-update.log"

$trigger = New-ScheduledTaskTrigger -Daily -At 2am

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount

Register-ScheduledTask -TaskName "GeoIP Database Update" `
    -Action $action -Trigger $trigger -Principal $principal
```

### Systemd Timer (Modern Linux)

See the `systemd/` directory for timer unit files.

## Configuration Files

### Python YAML Configuration

Create `config.yaml`:

```yaml
api_key: "your_api_key_here"
api_endpoint: "https://xxx.execute-api.region.amazonaws.com/v1/auth"
target_dir: "/var/lib/geoip"
databases:
  - "all"
max_retries: 3
timeout: 300
max_concurrent: 4
log_file: "/var/log/geoip-update.log"
```

Use with:
```bash
python geoip-update.py --config config.yaml
```

## Security Considerations

### API Key Storage

1. **Environment Variables** (Recommended for servers)
   ```bash
   # Add to /etc/environment or ~/.bashrc
   export GEOIP_API_KEY="your_secure_key_here"
   ```

2. **Windows Credential Manager** (PowerShell only)
   ```powershell
   # Store API key (will be prompted for key)
   .\geoip-update.ps1 -ApiKey YOUR_KEY
   # Future runs will use stored key automatically
   ```

3. **Configuration Files** (Ensure proper permissions)
   ```bash
   chmod 600 config.yaml
   chown root:root config.yaml
   ```

### File Permissions

```bash
# Restrict script permissions
chmod 755 geoip-update.sh
chmod 600 /etc/geoip-api-key.conf  # If storing key in file

# Restrict download directory
chmod 755 /var/lib/geoip
chown geoip:geoip /var/lib/geoip  # Use dedicated user
```

## Monitoring and Logging

### Log Locations

- **Linux**: `/var/log/geoip-update.log`
- **Windows**: `C:\Logs\geoip-update.log`
- **macOS**: `~/Library/Logs/geoip-update.log`

### Log Rotation

For Linux systems, create `/etc/logrotate.d/geoip-update`:

```
/var/log/geoip-update.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 0644 geoip geoip
}
```

### Monitoring

Check script execution:

```bash
# Check last run
tail -n 50 /var/log/geoip-update.log

# Monitor in real-time
tail -f /var/log/geoip-update.log

# Check for errors
grep ERROR /var/log/geoip-update.log
```

## Troubleshooting

### Common Issues

1. **"jq is required but not found"**
   - Install jq: See installation instructions above

2. **"API key not provided"**
   - Set GEOIP_API_KEY environment variable or use -k flag

3. **"Another instance is already running"**
   - Check for stale lock file: `rm /tmp/geoip-update.lock`

4. **HTTP 401 Unauthorized**
   - Verify API key is correct
   - Check API key has necessary permissions in DynamoDB

5. **HTTP 429 Rate Limited**
   - Script will automatically retry with backoff
   - Reduce frequency of updates if persistent

6. **SSL Certificate Errors**
   - Update system CA certificates
   - Python: Use `--no-ssl-verify` (not recommended for production)

### Debug Mode

Run scripts in verbose mode for detailed output:

```bash
# Bash
./geoip-update.sh -v

# PowerShell
.\geoip-update.ps1 -Verbose

# Python
python geoip-update.py --verbose
```

## Advanced Usage

### Parallel Downloads

Control concurrent downloads:

```bash
# Python (default: 4)
python geoip-update.py --concurrent 8
```

### Custom Timeouts

```bash
# Bash (seconds)
./geoip-update.sh -t 600

# PowerShell (seconds)
.\geoip-update.ps1 -Timeout 600

# Python (seconds)
python geoip-update.py --timeout 600
```

### No Lock File

For testing or special cases:

```bash
# All scripts support --no-lock
./geoip-update.sh --no-lock
```

## License

See the main project LICENSE file.