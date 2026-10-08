# GeoIP Scripts Docker Image

This directory contains the scripts-only Docker image for easy GeoIP integration.

## 📦 What's Included

- **geoip-update-amd64** - Pre-compiled Go binary for AMD64/x86_64 (fastest option)
- **geoip-update-arm64** - Pre-compiled Go binary for ARM64/aarch64 (fastest option)
- **geoip-update-posix.sh** - POSIX-compliant script (works on Alpine/ash/dash)
- **geoip-update.sh** - Full-featured bash script (requires bash)
- **geoip-update.py** - Python async script (requires Python 3.7+ and aiohttp)
- **geoip-update.ps1** - PowerShell script (for Windows containers)
- **entrypoint-helper.sh** - Smart Docker entrypoint helper with auto-detection
- **setup-cron.sh** - Multi-system cron configuration
- **validate.sh** - Enhanced database validation with MMDB format verification

## 🧠 Smart Script Selection

The helper automatically detects your system architecture and environment, then selects the best available script:

### Architecture Detection
- **AMD64/x86_64**: Uses `geoip-update-amd64` binary
- **ARM64/aarch64**: Uses `geoip-update-arm64` binary
- **Other architectures**: Falls back to shell scripts

### Priority Order
1. **Go binary** (architecture-specific) - Fastest, self-contained, ~5MB
2. **Python** (if Python + aiohttp available) - Async, parallel downloads
3. **Bash** (if bash available) - Full features, widely compatible
4. **PowerShell** (if pwsh available) - Windows containers
5. **POSIX** (fallback) - Maximum compatibility

You can override auto-detection by setting `GEOIP_SCRIPT_TYPE`:
```bash
# Force a specific script type
export GEOIP_SCRIPT_TYPE=python  # Options: auto, bash, posix, python, powershell, go
```

## 🐧 Alpine Linux Compatibility

The image includes a POSIX-compliant version that works perfectly on Alpine Linux and other minimal shells without requiring bash. The helper automatically detects Alpine environments and uses the appropriate script.

## 📊 Image Size

The scripts-only image is ultra-minimal:
- Base scripts: ~200KB
- Go binaries: ~5MB each (AMD64 + ARM64 = ~10MB total)
- **Total image size: ~10.2MB**

Both Go binaries are included to ensure optimal performance on any architecture. The appropriate binary is automatically selected at runtime.

## 🚀 Quick Start

### Method 1: Docker Multi-Stage Build (Recommended)

Add these 2 lines to your Dockerfile:

```dockerfile
# Copy GeoIP scripts from our image
FROM ytzcom/geoip-scripts:latest as geoip
COPY --from=geoip /opt/geoip /opt/geoip
```

Then in your entrypoint:

```sh
#!/bin/sh
# Source the helper functions
. /opt/geoip/entrypoint-helper.sh

# Initialize GeoIP (downloads, validates, sets up cron)
geoip_init

# Start your application
exec your-app
```

### Method 2: Direct Integration

```dockerfile
# In your Dockerfile
FROM ytzcom/geoip-scripts:latest as geoip
FROM your-base-image

# Copy scripts
COPY --from=geoip /opt/geoip /opt/geoip

# Set environment variables
ENV GEOIP_API_KEY=your-api-key \
    GEOIP_TARGET_DIR=/app/resources/geoip \
    GEOIP_DOWNLOAD_ON_START=true \
    GEOIP_SETUP_CRON=true

# Your entrypoint
ENTRYPOINT ["/bin/sh", "-c", ". /opt/geoip/entrypoint-helper.sh && geoip_init && exec your-app"]
```

## 🔧 Available Functions

When you source `entrypoint-helper.sh`, these functions become available:

### Core Functions

- **`geoip_init`** - Complete initialization (recommended)
  - Checks for existing databases
  - Downloads if needed (based on GEOIP_DOWNLOAD_ON_START)
  - Validates databases (based on GEOIP_VALIDATE_ON_START)
  - Sets up cron (based on GEOIP_SETUP_CRON)

- **`geoip_check_databases`** - Check if databases exist
  - Returns 0 if all required databases present
  - Returns 1 if databases missing

- **`geoip_download_databases`** - Download databases
  - Uses configured API key and endpoint
  - Downloads to GEOIP_TARGET_DIR
  - Handles retries and errors

- **`geoip_validate_databases`** - Validate databases
  - Tries Python validation first (if available)
  - Falls back to basic size/format checks
  - Returns 0 if valid, 1 if invalid

- **`geoip_setup_cron`** - Setup automatic updates
  - Auto-detects cron system
  - Configures appropriate scheduler
  - Uses GEOIP_UPDATE_SCHEDULE

- **`geoip_health_check`** - Health check for monitoring
  - Returns database status
  - Shows count and total size
  - Useful for Docker health checks

### Validation Functions

- **`geoip_validate_specific`** - Validate specific databases
  - Usage: `geoip_validate_specific /path/to/databases`
  - Enhanced MMDB validation with reliable binary pattern matching
  - Cross-platform BIN file validation
  - Returns detailed validation results

### Logging Functions

- `geoip_log_info` - Information messages
- `geoip_log_error` - Error messages (stderr)
- `geoip_log_warning` - Warning messages
- `geoip_log_success` - Success messages

## 🌍 Environment Variables

### Required

- **`GEOIP_API_KEY`** - Your API key for authentication

### Optional

- **`GEOIP_ENABLED`** - Enable/disable GeoIP functionality (default: `true`)
- **`GEOIP_TARGET_DIR`** - Where to store databases (default: `/app/resources/geoip`)
- **`GEOIP_API_ENDPOINT`** - API endpoint URL (default: `https://geoipdb.net/auth`)
  - Note: Scripts auto-append `/auth` if you provide just `https://geoipdb.net`
- **`GEOIP_SCRIPT_TYPE`** - Force specific script type (default: `auto`)
  - Options: `auto`, `bash`, `posix`, `python`, `powershell`, `go`
- **`GEOIP_DOWNLOAD_ON_START`** - Download on container start (default: `true`)
- **`GEOIP_VALIDATE_ON_START`** - Validate on start (default: `true`)
- **`GEOIP_SETUP_CRON`** - Setup automatic updates (default: `true`)
- **`GEOIP_UPDATE_SCHEDULE`** - Cron schedule (default: `0 2 * * *` - 2 AM daily)
- **`GEOIP_FAIL_ON_ERROR`** - Exit on initialization error (default: `false`)
- **`GEOIP_DATABASES`** - Specific databases or "all" (default: `all`)
- **`GEOIP_QUIET_MODE`** - Suppress output (default: `false`)
- **`GEOIP_LOG_FILE`** - Log file path (optional)

### Read by every bundled client

Each client (Go, Python, Bash, POSIX, PowerShell) reads these from its environment as the default for the matching option; options given on the command line win:

- **`GEOIP_CONCURRENT`** - Parallel downloads (default: `2`)
- **`GEOIP_TIMEOUT`** - Download timeout in seconds (see the per-client table below)
- **`GEOIP_MAX_RETRIES`** - Maximum retry attempts (default: `3`)
- **`GEOIP_ONLY_CHANGED`** - Download only databases that changed since the last run (`true`, `1`, `yes`)
- **`GEOIP_LOCK_FILE`** - Exclusive lock on a shared path, for example `$GEOIP_TARGET_DIR/.geoip-update.lock`
- **`GEOIP_LOCK_TIMEOUT`** - Seconds to wait for `GEOIP_LOCK_FILE` (default: `1800`)

`GEOIP_API_KEY`, `GEOIP_API_ENDPOINT`, `GEOIP_TARGET_DIR`, `GEOIP_DATABASES` and `GEOIP_LOG_FILE` are read by every client too.

## 🔁 Change Detection and Shared-Path Locking

Recommended when several containers share the database volume, and for daily updates:

```yaml
    environment:
      GEOIP_ONLY_CHANGED: "true"
      GEOIP_LOCK_FILE: /app/resources/geoip/.geoip-update.lock
```

`geoip_download_databases` runs the selected client in the container's environment, so these variables apply to it. `setup-cron.sh` writes the scheduled command with `--api-key`, `--endpoint`, `--directory`, `--quiet` and `--databases` only.

| Purpose | Go / Python / Bash / POSIX | PowerShell | Environment |
|---------|----------------------------|------------|-------------|
| Download only changed files | `--only-changed` | `-OnlyChanged` | `GEOIP_ONLY_CHANGED` |
| Ignore change detection | `--force` | `-Force` | — |
| Lock on a shared path | `--lock-file PATH` | `-LockFile` | `GEOIP_LOCK_FILE` |
| Lock wait limit | `--lock-timeout SECONDS` | `-LockTimeout` | `GEOIP_LOCK_TIMEOUT` |

- **Manifest.** Change detection keeps `<target>/.geoip-update.json` (ETag, `Last-Modified` and size per database) in a layout every client reads and writes, so the clients can take turns on one directory. A database whose conditional request (`If-None-Match`) gets `304` logs `Unchanged: <name>` and is left as it is. `--force` downloads everything. An unreadable manifest is treated as absent. A run where everything is unchanged exits `0`.
- **Lock.** The lock file is an exclusive kernel lock held until the client exits; the operating system releases it on any exit, including `kill -9`. A second run waits up to the lock timeout, then logs `Timed out after N s waiting for lock PATH` and exits `1`. A lock file together with `--no-lock` / `-NoLock` exits `1` with `--lock-file and --no-lock cannot be combined`.
- **Shell clients (Bash, POSIX).** Where `flock` is missing, they lock by creating the directory `PATH.d`; one left by a killed run is broken as stale after the download ceiling (`--timeout`, default `1800`) plus 300 s. If only the main process is SIGKILLed, its running background downloads keep the lock until they finish (at most `--timeout`).
- **Staging.** Every client downloads to `<target>/<name>.part` and renames it into place, so the application never reads a partial file. A failed download removes its `.part`.

| Client | `--timeout` / `-Timeout` |
|--------|--------------------------|
| Bash, POSIX | Overall download ceiling in seconds across retry attempts (default `1800`); `0` means no ceiling; a value that is not a plain decimal number is passed to curl untouched |
| Go, Python | Does not abort a stalled transfer |
| PowerShell | Does not abort a stalled transfer; `-Timeout 0` fails the download |

PowerShell `-Quiet` keeps the exit codes of a run without it. Details: [CLI Overview](../cli/README.md#-change-detection-shared-path-locking-and-staging).

## 📅 Cron Support

The `setup-cron.sh` script automatically detects and configures:

1. **Supercronic** - Lightweight cron for containers (preferred)
2. **Crond** - Alpine/BusyBox standard
3. **Cron** - Debian/Ubuntu standard
4. **Systemd Timers** - For host systems

### Custom Schedule

Set `GEOIP_UPDATE_SCHEDULE` to customize:

```sh
# Every 6 hours
GEOIP_UPDATE_SCHEDULE="0 */6 * * *"

# Weekly on Sunday at 3 AM
GEOIP_UPDATE_SCHEDULE="0 3 * * 0"

# Monthly on the 1st
GEOIP_UPDATE_SCHEDULE="0 4 1 * *"
```

## 🐳 Docker Compose Example

```yaml
version: '3.8'

services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
    environment:
      GEOIP_API_KEY: ${GEOIP_API_KEY}
      GEOIP_TARGET_DIR: /app/data/geoip
      GEOIP_DOWNLOAD_ON_START: "true"
      GEOIP_SETUP_CRON: "true"
      GEOIP_UPDATE_SCHEDULE: "0 2 * * *"
    volumes:
      - geoip-data:/app/data/geoip
    healthcheck:
      test: ["/bin/sh", "-c", ". /opt/geoip/entrypoint-helper.sh && geoip_health_check"]
      interval: 30s
      timeout: 3s
      retries: 3

volumes:
  geoip-data:
```

## 🔍 Enhanced Validation

The validation system provides comprehensive database verification:

### MMDB Files (MaxMind)
- **Metadata marker validation**: Searches for `\xab\xcd\xefMaxMind.com` using reliable binary pattern matching
- **Cross-platform detection**: Uses `xxd` with hex pattern matching, falls back to `strings` or `grep`
- **Spec compliance**: Searches last 128KB of file per MaxMind DB specification
- **Size verification**: Ensures files aren't error pages or corrupted downloads

### BIN Files (IP2Location)
- **Binary format validation**: Verifies files contain binary data patterns
- **IP2Location markers**: Detects IP2Location-specific strings and metadata
- **Provider verification**: Confirms files match expected IP2Location format
- **Fallback validation**: Multiple detection methods for maximum compatibility

### Usage Examples

```bash
# Direct validation script
./validate.sh --directory /app/resources/geoip --verbose

# Via CLI scripts with validation flag
./geoip-update.sh --validate-only --directory /data/geoip

# In Docker container
docker run --rm -v /data:/data ytzcom/geoip-updater --validate-only
```

### Validation Features
- **Exit codes**: 0 for success, 1 for validation failures, 2 for invalid arguments
- **Detailed logging**: Shows which files pass/fail validation with reasons
- **Quiet mode**: Silent operation suitable for health checks and monitoring
- **Verbose mode**: Detailed debugging information for troubleshooting

## 🚑 Troubleshooting

### Databases not downloading

1. Check API key is set: `[ -n "$GEOIP_API_KEY" ] && echo "API key is configured" || echo "API key is missing"`
2. Test manually: `/opt/geoip/geoip-update.sh --api-key $GEOIP_API_KEY`
3. Check logs: `cat $GEOIP_LOG_FILE`

### Cron not working

1. Check cron system: `setup-cron.sh` output
2. Verify crontab: `crontab -l`
3. Check logs: `/var/log/geoip-update.log`

### Validation failing

1. Check file sizes: `ls -lh $GEOIP_TARGET_DIR`
2. Run enhanced validation: `/opt/geoip/validate.sh --directory $GEOIP_TARGET_DIR --verbose`
3. Try script validation: `/opt/geoip/geoip-update.sh --validate-only --verbose`
4. Check for validation tools: `which xxd strings file` (validation uses available tools)
5. Force redownload: `rm $GEOIP_TARGET_DIR/*.{mmdb,BIN} && geoip_download_databases`

## 📚 Advanced Usage

### Custom initialization

```sh
#!/bin/sh
. /opt/geoip/entrypoint-helper.sh

# Custom logic
if [ "$ENVIRONMENT" = "production" ]; then
    GEOIP_FAIL_ON_ERROR=true
fi

# Check before downloading
if ! geoip_check_databases; then
    echo "Databases missing, downloading..."
    geoip_download_databases || exit 1
fi

# Validate
geoip_validate_databases || echo "Validation failed but continuing"

# Setup cron only in production
if [ "$ENVIRONMENT" = "production" ]; then
    geoip_setup_cron
fi
```

### Health check integration

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD sh -c '. /opt/geoip/entrypoint-helper.sh && geoip_health_check'
```

## 📄 License

Same as parent project