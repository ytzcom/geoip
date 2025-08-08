# GeoIP Scripts Docker Image

This directory contains the scripts-only Docker image for easy GeoIP integration.

## 📦 What's Included

- **geoip-update-posix.sh** - POSIX-compliant script (works on Alpine/ash/dash)
- **geoip-update.sh** - Full-featured bash script (requires bash)
- **geoip-update.py** - Python validation script (optional)
- **entrypoint-helper.sh** - Docker entrypoint helper functions
- **setup-cron.sh** - Multi-system cron configuration
- **validate.sh** - Basic validation without Python

## 🐧 Alpine Linux Compatibility

The image now includes a POSIX-compliant version that works perfectly on Alpine Linux and other minimal shells without requiring bash. The helper automatically detects and uses the appropriate script.

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
- **`GEOIP_DOWNLOAD_ON_START`** - Download on container start (default: `true`)
- **`GEOIP_VALIDATE_ON_START`** - Validate on start (default: `true`)
- **`GEOIP_SETUP_CRON`** - Setup automatic updates (default: `true`)
- **`GEOIP_UPDATE_SCHEDULE`** - Cron schedule (default: `0 2 * * *` - 2 AM daily)
- **`GEOIP_FAIL_ON_ERROR`** - Exit on initialization error (default: `false`)
- **`GEOIP_DATABASES`** - Specific databases or "all" (default: `all`)
- **`GEOIP_QUIET_MODE`** - Suppress output (default: `false`)
- **`GEOIP_LOG_FILE`** - Log file path (optional)

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

## 🔍 Validation

The validation script checks:

1. Required databases exist (GeoIP2-City.mmdb, GeoIP2-Country.mmdb)
2. File sizes are reasonable (not error pages)
3. MMDB format markers (if tools available)
4. Optional databases (logged but don't fail)

## 🚑 Troubleshooting

### Databases not downloading

1. Check API key is set: `echo $GEOIP_API_KEY`
2. Test manually: `/opt/geoip/geoip-update.sh --api-key your-key`
3. Check logs: `cat $GEOIP_LOG_FILE`

### Cron not working

1. Check cron system: `setup-cron.sh` output
2. Verify crontab: `crontab -l`
3. Check logs: `/var/log/geoip-update.log`

### Validation failing

1. Check file sizes: `ls -lh $GEOIP_TARGET_DIR`
2. Run manual validation: `/opt/geoip/validate.sh`
3. Try Python validation: `python3 /opt/geoip/geoip-update.py --validate`

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