# CLI Tools

Command-line tools for downloading GeoIP databases. Choose the implementation that best fits your environment and requirements.

## 🎯 Quick Decision Guide

| Platform | Recommended | Alternative |
|----------|-------------|-------------|
| **Linux/macOS** | [Bash Script](#bash-script) | [Python CLI](python/README.md) |
| **Windows** | [PowerShell Script](#powershell-script) | [Python CLI](python/README.md) |
| **Docker** | [Docker Images](#docker-images) | [Native Scripts](#native-scripts) |
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
curl -O https://raw.githubusercontent.com/ytzcom/geoip/main/cli/geoip-update.sh
chmod +x geoip-update.sh
./geoip-update.sh -k YOUR_API_KEY

# Or clone repository
git clone https://github.com/ytzcom/geoip.git
cd geoip/cli
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
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/ytzcom/geoip/main/cli/geoip-update.ps1" -OutFile "geoip-update.ps1"
.\geoip-update.ps1 -ApiKey YOUR_API_KEY

# Or clone repository
git clone https://github.com/ytzcom/geoip.git
cd geoip/cli
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

Every client reads these variables as the default for the matching option. A command-line option always wins.

| Variable | Option it defaults |
|----------|--------------------|
| `GEOIP_API_KEY` | API key |
| `GEOIP_API_ENDPOINT` | API endpoint |
| `GEOIP_TARGET_DIR` | Target directory |
| `GEOIP_DATABASES` | Database selection (comma-separated) |
| `GEOIP_CONCURRENT` | Parallel downloads (default `2`; a flag only in Python and Go: `--concurrent`) |
| `GEOIP_LOG_FILE` | Log file |
| `GEOIP_TIMEOUT` | `--timeout` / `-Timeout` (seconds; Go also accepts durations such as `5m`) |
| `GEOIP_MAX_RETRIES` | Retries (`--max-retries` in POSIX, `--retries` in bash/Python/Go, `-MaxRetries` in PowerShell) |
| `GEOIP_ONLY_CHANGED` | `--only-changed` / `-OnlyChanged` (`true`, `1` or `yes`) |
| `GEOIP_LOCK_FILE` | `--lock-file` / `-LockFile` |
| `GEOIP_LOCK_TIMEOUT` | `--lock-timeout` / `-LockTimeout` |

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
| Databases | `-b`, `--databases` | `-Databases` | `-b`, `--databases` | Database selection |
| Quiet | `-q`, `--quiet` | `-Quiet` | `-q`, `--quiet` | Silent mode for automation |
| Verbose | `-v`, `--verbose` | `-Verbose` | `-v`, `--verbose` | Detailed output |
| Log File | `-l`, `--log-file` | `-LogFile` | `-l`, `--log-file` | Log to file |
| **Validate Only** | `-V`, `--validate-only` | `-ValidateOnly` | `--validate-only` | **Validate existing files without downloading** |
| **Check Names** | `-C`, `--check-names` | `-CheckNames` | `--check-names` | **Validate database names with API** |
| Only Changed | `--only-changed` | `-OnlyChanged` | `--only-changed` | Download only databases that changed since the last run |
| Force | `--force` | `-Force` | `--force` | Download everything, ignoring `--only-changed` |
| Lock File | `--lock-file PATH` | `-LockFile` | `--lock-file PATH` | Exclusive lock on a shared path |
| Lock Timeout | `--lock-timeout SECONDS` | `-LockTimeout` | `--lock-timeout SECONDS` | Lock wait limit (default `1800`) |

The POSIX script and the Go binary use the same long option names as bash and Python for these four options.

## 🔁 Change Detection, Shared-Path Locking and Staging

Recommended for daily runs and for targets shared between hosts or containers:

```bash
./geoip-update.sh --only-changed --lock-file /var/lib/geoip/.geoip-update.lock -d /var/lib/geoip
```
```powershell
.\geoip-update.ps1 -OnlyChanged -LockFile C:\GeoIP\.geoip-update.lock -TargetDirectory C:\GeoIP
```

| Purpose | POSIX / bash / Python / Go | PowerShell | Environment | YAML key (POSIX, Python) |
|---------|----------------------------|------------|-------------|--------------------------|
| Download only changed files | `--only-changed` | `-OnlyChanged` | `GEOIP_ONLY_CHANGED` (`true`, `1`, `yes`) | `only_changed` |
| Ignore change detection | `--force` | `-Force` | — | — |
| Lock on a shared path | `--lock-file PATH` | `-LockFile` | `GEOIP_LOCK_FILE` | `lock_file` |
| Lock wait limit | `--lock-timeout SECONDS` (default `1800`) | `-LockTimeout` | `GEOIP_LOCK_TIMEOUT` | `lock_timeout` |

### Change detection (`--only-changed`)

- The manifest `<target>/.geoip-update.json` records each database's ETag, `Last-Modified` and size. Every client writes the same layout, so any client can read a manifest another client wrote.
- A database downloads when `--force` is set, the file is missing, the manifest has no entry for it, or its size on disk differs from the entry. Otherwise the client sends a conditional request (`If-None-Match`). A `304` logs `Unchanged: <name>` and leaves the file as it is.
- The manifest is written once, at the end of the run, through `.geoip-update.json.part` and a rename. Entries for databases not requested in the run are kept. A manifest that cannot be read is treated as absent: everything downloads and a new manifest is written.
- Unchanged files count as successes. A run where every file is unchanged exits `0`.
- Without `--only-changed` no manifest is read or written.
- Two `--only-changed` runs without a lock can race on the manifest: the last writer wins, and a lost entry causes one extra download on a later run. Use `--lock-file` with `--only-changed`.

### Shared-path lock (`--lock-file`)

- The client takes an exclusive kernel lock on `PATH` (created if missing) before it reads the manifest or calls the API, and holds it until it exits. The operating system releases the lock when the process exits for any reason, including `kill -9`.
- A second run waits for the lock, polling, for up to `--lock-timeout` seconds (default `1800`). When that expires it logs `Timed out after N s waiting for lock PATH` and exits `1`.
- After taking the lock, the client writes `pid=<pid> host=<hostname> started=<UTC time>` into the lock file, for diagnosis only.
- Without `--lock-file`, bash, Python, Go and PowerShell keep their default lock in the system temp directory (turned off with `--no-lock` / `-NoLock`); the POSIX script takes no lock.
- `--lock-file` (or `GEOIP_LOCK_FILE`) together with `--no-lock` / `-NoLock` exits `1` with `--lock-file and --no-lock cannot be combined`.
- Shell clients (POSIX, bash):
  - They use `flock` when the command exists. Where `flock` is missing (for example macOS), they lock by creating the directory `PATH.d`, removed on exit. A lock directory left by a killed run is broken as stale after the download ceiling (`--timeout`, default `1800`) plus 300 s.
  - If only the main process is SIGKILLed, its running background downloads keep the lock until they finish (at most `--timeout`).

### Atomic staging

- Every client downloads into `<target>/<name>.part` and renames it to `<target>/<name>`, so a reader sees either the previous complete file or the new complete file, never a partial one. The `.part` file exists only while the download runs.
- A download that finally fails removes its `.part`.
- A resumed download sends `If-Range`. If the object changed mid-download, the file restarts from byte 0 (counted as a retry), so a file is never mixed from two versions.

### What `--timeout` does, per client

| Client | `--timeout` / `-Timeout` |
|--------|--------------------------|
| POSIX, bash | Overall download ceiling in seconds across all retry attempts (default `1800`). `0` means no ceiling. A value that is not a plain decimal number (for example `1e1`) is passed to curl untouched, with no ceiling across attempts. |
| Python, Go | Does not abort a stalled transfer: a download that stalls and then continues still completes. Go also accepts durations (`5m`, `300s`). |
| PowerShell | Does not abort a stalled transfer. `-Timeout 0` fails the download. |

### Exit codes

- When some downloads fail, the run exits `2` in PowerShell, with curl's exit code in bash (for example `22`), and `1` in POSIX, Python and Go. The files that did download are kept.
- PowerShell `-Quiet` only reduces output; exit codes are the same as without it.

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
- `proxy` (or `ip2proxy`) → `IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN`
- `ipv4` → IP2Location IPv4 comprehensive database
- `ipv6` → IP2Location IPv6 comprehensive database
- `maxmind/all`, `ip2location/all` → all databases for that provider

Run `./geoip-update.sh --list-databases` for the authoritative list of names and aliases.

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

A `--lock-file` lock never needs removing by hand: the operating system releases it when the holder exits. `Timed out after N s waiting for lock PATH` means another run held the lock for longer than `--lock-timeout`.

### Debug Mode

Enable verbose output for troubleshooting:
```bash
# Bash
./geoip-update.sh -v

# PowerShell
.\geoip-update.ps1 -Verbose

# Python
python geoip-update.py -v
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
- **[Usage Examples](../USAGE_EXAMPLES.md)** - Programming language examples
- **[Security Guide](../docs/SECURITY.md)** - Security best practices

## 🤝 Contributing

When adding new CLI tools:
1. Follow existing patterns and conventions
2. Support the same environment variables
3. Include comprehensive error handling
4. Add tests for your implementation
5. Update this documentation