# CLI Tools

Command-line tools for downloading GeoIP databases. Choose the implementation that best fits your environment and requirements.

## 🎯 Quick Decision Guide

| Platform | Recommended | Alternative |
|----------|-------------|-------------|
| **Linux/macOS** | [Bash Script](#bash-script) | [Python CLI](python/README.md) |
| **Windows** | [PowerShell Script](#powershell-script) | [Python CLI](python/README.md) |
| **Docker** | [Docker Images](../README.md#choose-your-implementation) | [Native Scripts](#native-scripts) |
| **Cross-platform** | [Python CLI](python/README.md) | [Go Binary](go/README.md) |
| **Minimal footprint** | [Go Binary](go/README.md) | [Bash Script](#bash-script) |
| **Advanced features** | [Python CLI](python/README.md) | [Bash Script](#bash-script) |

## 📦 Available Implementations

### Docker Images
- **[Python CLI](python/README.md)** - Full-featured Docker image
- **[Python + Cron](python-cron/README.md)** - Automated updates with supercronic
- **[Kubernetes-optimized](python-k8s/README.md)** - Production K8s deployments
- **[Go Binary](go/README.md)** - Minimal Docker image (~10MB)

### Native Scripts

#### Bash Script
**Best for:** Linux/macOS servers, cron scheduling, minimal dependencies

```bash
# Download and run
curl -O https://raw.githubusercontent.com/ytzcom/geoip-updater/main/cli/geoip-update.sh
chmod +x geoip-update.sh
./geoip-update.sh -k YOUR_API_KEY

# Or clone repository
git clone https://github.com/ytzcom/geoip-updater.git
cd geoip-updater/cli
./geoip-update.sh -k YOUR_API_KEY
```

**Features:**
- ✅ Parallel downloads
- ✅ Retry logic with exponential backoff
- ✅ Cross-platform (Linux, macOS, BSD)
- ✅ Cron-friendly (quiet mode)
- ✅ Lock file support
- ✅ Comprehensive logging

**Dependencies:** `curl`, `jq`

#### PowerShell Script
**Best for:** Windows servers, Task Scheduler integration

```powershell
# Download and run
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/ytzcom/geoip-updater/main/cli/geoip-update.ps1" -OutFile "geoip-update.ps1"
.\geoip-update.ps1 -ApiKey YOUR_API_KEY

# Or clone repository
git clone https://github.com/ytzcom/geoip-updater.git
cd geoip-updater/cli
.\geoip-update.ps1 -ApiKey YOUR_API_KEY
```

**Features:**
- ✅ Windows Credential Manager integration
- ✅ Progress indicators
- ✅ Comprehensive error handling
- ✅ Task Scheduler ready
- ✅ Verbose logging options

**Dependencies:** PowerShell 5.1+

#### POSIX Shell Script
**Best for:** Minimal POSIX-compliant environments

```bash
# More portable version for older systems
./geoip-update-posix.sh -k YOUR_API_KEY
```

**Features:**
- ✅ POSIX-compliant (works on busybox, ash, dash)
- ✅ Minimal dependencies
- ✅ Embedded systems friendly

## 🔧 Common Configuration

All CLI tools use the same environment variables and command-line options:

### Environment Variables
```bash
export GEOIP_API_KEY="your-api-key"
export GEOIP_API_ENDPOINT="https://geoipdb.net/auth"
export GEOIP_TARGET_DIR="/var/lib/geoip"
export GEOIP_DATABASES="all"  # or "city,country" for specific ones
```

### Command-line Options

| Option | Bash | PowerShell | Python | Description |
|--------|------|------------|--------|-------------|
| API Key | `-k`, `--api-key` | `-ApiKey` | `-k`, `--api-key` | Authentication key |
| Endpoint | `-e`, `--endpoint` | `-ApiEndpoint` | `-e`, `--endpoint` | API endpoint URL |
| Directory | `-d`, `--directory` | `-TargetDirectory` | `-d`, `--directory` | Target directory |
| Databases | `-D`, `--databases` | `-Databases` | `-b`, `--databases` | Database selection |
| Quiet | `-q`, `--quiet` | `-Quiet` | `-q`, `--quiet` | Silent mode for automation |
| Verbose | `-v`, `--verbose` | `-Verbose` | `-v`, `--verbose` | Detailed output |
| Log File | `-l`, `--log-file` | `-LogFile` | `-l`, `--log-file` | Log to file |
| **Validate Only** | `-V`, `--validate-only` | `-ValidateOnly` | `--validate-only` | **Validate existing files without downloading** |
| **Check Names** | `-C`, `--check-names` | `-CheckNames` | `--check-names` | **Validate database names with API** |

## 📋 Database Selection

All tools support flexible database selection:

### Selection Methods
```bash
# All databases
./geoip-update.sh --databases all

# Specific databases
./geoip-update.sh --databases "GeoIP2-City.mmdb,GeoIP2-Country.mmdb"

# Aliases (case-insensitive)
./geoip-update.sh --databases "city,country,isp"

# Provider-specific
./geoip-update.sh --databases "maxmind/all"
./geoip-update.sh --databases "ip2location/all"
```

### Available Aliases
- `city` → `GeoIP2-City.mmdb`
- `country` → `GeoIP2-Country.mmdb`
- `isp` → `GeoIP2-ISP.mmdb`
- `connection` → `GeoIP2-Connection-Type.mmdb`
- `px2` → `IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN`
- `db23-ipv4` → IPv4 comprehensive database
- `db23-ipv6` → IPv6 comprehensive database

## ✅ Database Validation

All CLI tools include comprehensive validation capabilities for both file integrity and database name validation.

### File Validation (`--validate-only`)

Validates existing database files without downloading:

```bash
# Validate all databases in default directory
./geoip-update.sh --validate-only

# Validate databases in specific directory
./geoip-update.sh --validate-only --directory /var/lib/geoip

# Validate with verbose output
./geoip-update.sh --validate-only --verbose

# PowerShell equivalent
.\geoip-update.ps1 -ValidateOnly -TargetDirectory "C:\GeoIP"

# Python equivalent
python geoip-update.py --validate-only --directory /data/geoip
```

**What gets validated:**
- **MMDB files**: MaxMind metadata marker validation using reliable binary pattern matching
- **BIN files**: IP2Location format validation and binary data verification
- **File sizes**: Ensures files aren't error pages or corrupted downloads
- **File integrity**: Cross-platform validation with multiple fallback methods

### Name Validation (`--check-names`)

Validates database names with the API before downloading:

```bash
# Check if database names are valid
./geoip-update.sh --check-names --databases "city,country,isp" --api-key YOUR_KEY

# Check all databases
./geoip-update.sh --check-names --databases "all" --api-key YOUR_KEY

# Check specific database combinations
./geoip-update.sh --check-names --databases "GeoIP2-City.mmdb,IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN" --api-key YOUR_KEY
```

**What gets validated:**
- Database name resolution against API
- Alias expansion (e.g., "city" → "GeoIP2-City.mmdb")
- Provider-specific selections (e.g., "maxmind/all")
- Shows resolved database list before download

### Docker Validation

```bash
# Validate databases in Docker container
docker run --rm -v /data:/data ytzcom/geoip-updater --validate-only

# Validate specific directory
docker run --rm -v /path/to/geoip:/geoip ytzcom/geoip-updater --validate-only --directory /geoip
```

### Exit Codes

All validation commands return appropriate exit codes:
- `0` - All validations passed
- `1` - One or more validations failed
- `2` - Invalid arguments or configuration

## 🔄 Scheduling Updates

### Linux/macOS with Cron

```bash
# Edit crontab
crontab -e

# Add daily update at 3 AM
0 3 * * * /usr/local/bin/geoip-update.sh -q -l /var/log/geoip-update.log

# With environment variable
GEOIP_API_KEY=your-key-here
0 3 * * * /usr/local/bin/geoip-update.sh -q
```

### Windows with Task Scheduler

Using PowerShell:
```powershell
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-ExecutionPolicy Bypass -File C:\Scripts\geoip-update.ps1 -Quiet"

$trigger = New-ScheduledTaskTrigger -Daily -At 3am

Register-ScheduledTask -TaskName "GeoIP Update" -Action $action -Trigger $trigger
```

### systemd (Modern Linux)

Create service file:
```ini
[Unit]
Description=Update GeoIP databases

[Service]
Type=oneshot
ExecStart=/usr/local/bin/geoip-update.sh -q
Environment="GEOIP_API_KEY=your-key"
```

Create timer file:
```ini
[Unit]
Description=Daily GeoIP update

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
```

Enable:
```bash
sudo systemctl enable --now geoip-update.timer
```

## 🚨 Troubleshooting

### Common Issues

**Permission Denied**
```bash
# Fix script permissions
chmod +x geoip-update.sh

# Fix directory permissions
sudo chown -R $USER:$USER /var/lib/geoip
```

**API Authentication Failed**
```bash
# Test database name validation (requires API key)
./geoip-update.sh --check-names --databases "all" --api-key your-key

# Check API endpoint manually
curl -H "X-API-Key: your-key" https://geoipdb.net/auth
```

**Database Validation Errors**
```bash
# Validate existing databases
./geoip-update.sh --validate-only --verbose

# Check specific directory
./geoip-update.sh --validate-only --directory /path/to/geoip

# Force redownload if validation fails
rm /path/to/geoip/*.mmdb /path/to/geoip/*.BIN
./geoip-update.sh --api-key your-key
```

**Lock File Issues**
```bash
# Check for running processes
ps aux | grep geoip-update

# Remove stale lock file
rm /tmp/geoip-update.lock

# Run without lock (not recommended for automation)
./geoip-update.sh --no-lock
```

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

## 📊 Performance Comparison

| Implementation | Startup | Memory | Download Speed | Binary Size |
|---------------|---------|---------|----------------|-------------|
| **Bash** | ~50ms | ~5MB | Fast (parallel) | ~15KB |
| **PowerShell** | ~200ms | ~25MB | Medium | ~20KB |
| **Python** | ~500ms | ~50MB | Fastest (async) | ~25KB + deps |
| **Go** | ~10ms | ~10MB | Fast | ~8MB |

## 🔗 Related Documentation

- **[Python CLI Details](python/README.md)** - Advanced features and configuration
- **[Go Binary Guide](go/README.md)** - Minimal deployment option
- **[Docker Integration](../docker-scripts/README.md)** - Container integration
- **[Usage Examples](../docs/USAGE_EXAMPLES.md)** - Programming language examples
- **[Security Guide](../docs/SECURITY.md)** - Security best practices

## 🤝 Contributing

When adding new CLI tools:
1. Follow existing patterns and conventions
2. Support the same environment variables
3. Include comprehensive error handling
4. Add tests for your implementation
5. Update this documentation