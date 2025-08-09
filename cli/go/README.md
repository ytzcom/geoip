# GeoIP Updater - Go Implementation

High-performance, single-binary GeoIP database updater written in Go.

## Features

- **Zero Dependencies**: Uses only Go standard library
- **Cross-Platform**: Supports Windows, Linux, macOS (x64/ARM)
- **Small Binary**: ~5MB uncompressed, ~2MB with UPX compression
- **Fast**: Concurrent downloads with connection pooling
- **Production Ready**: Includes retry logic, validation, and proper error handling

## Quick Start

### Download Pre-built Binary

Download the appropriate binary for your platform from the releases page, or build from source:

### Build from Source

```bash
# Clone the repository
git clone https://github.com/ytzcom/geoip.git
cd geoip-updater/scripts/cli/go

# Build for current platform
make build

# Or build for all platforms
make build-all
```

## Usage

### Basic Usage

```bash
# Using API key directly
./geoip-update -api-key YOUR_API_KEY

# Using environment variable
export GEOIP_API_KEY="your_api_key_here"
./geoip-update

# Download specific databases
./geoip-update -api-key YOUR_API_KEY -databases "GeoIP2-City.mmdb,GeoIP2-Country.mmdb"
```

### Command Line Options

```
-api-key, -k        API key for authentication (or use GEOIP_API_KEY env var)
-endpoint, -e       API endpoint URL (default: from env or predefined)
-directory, -d      Target directory (default: ./geoip)
-databases, -b      Comma-separated database list or "all" (default: all)
-log-file, -l       Log file path
-retries, -r        Max retries (default: 3)
-timeout, -t        Download timeout in seconds (default: 300)
-concurrent         Max concurrent downloads (default: 4)
-quiet, -q          Quiet mode (no output except errors)
-verbose, -v        Verbose output
-no-lock, -n        Don't use lock file
-version            Show version
-help               Show help
```

### Environment Variables

- `GEOIP_API_KEY` - API key for authentication
- `GEOIP_API_ENDPOINT` - API endpoint URL
- `GEOIP_TARGET_DIR` - Target directory for downloads
- `GEOIP_LOG_FILE` - Log file path

## Scheduler Integration

### Linux Cron

Add to crontab:
```cron
# Update GeoIP databases daily at 2 AM
0 2 * * * /usr/local/bin/geoip-update -quiet -log-file /var/log/geoip-update.log
```

### Windows Task Scheduler

Create a basic task:
```powershell
schtasks /create /tn "GeoIP Update" /tr "C:\Program Files\geoip-update.exe -quiet" /sc daily /st 02:00
```

### macOS launchd

Create `/Library/LaunchDaemons/com.geoip.update.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.geoip.update</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/geoip-update</string>
        <string>-quiet</string>
        <string>-log-file</string>
        <string>/var/log/geoip-update.log</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>2</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardErrorPath</key>
    <string>/var/log/geoip-update.error.log</string>
</dict>
</plist>
```

Load with:
```bash
sudo launchctl load /Library/LaunchDaemons/com.geoip.update.plist
```

## Building

### Development

```bash
# Run directly
make run ARGS="-help"

# Run tests
make test

# Format code
make fmt

# Run linters
make lint
```

### Production Builds

```bash
# Build for current platform
make build

# Build for all platforms
make build-all

# Build with compression (requires upx)
make build-compressed

# Create release archives
make release
```

### Supported Platforms

- **macOS**: darwin/amd64, darwin/arm64 (M1/M2)
- **Linux**: linux/amd64, linux/arm64, linux/arm/7
- **Windows**: windows/amd64, windows/arm64

## Installation

### System-wide Installation

```bash
# Build and install
make install

# Or manually
sudo cp geoip-update /usr/local/bin/
sudo chmod 755 /usr/local/bin/geoip-update
```

### Uninstall

```bash
make uninstall
# Or
sudo rm /usr/local/bin/geoip-update
```

## Performance

The Go implementation offers several performance advantages:

- **Concurrent Downloads**: Up to 4 parallel downloads by default
- **Connection Pooling**: Reuses HTTP connections
- **Minimal Memory**: ~20MB RAM usage during operation
- **Fast Startup**: No runtime dependencies or initialization

### Benchmarks

Typical download times (4 concurrent downloads):
- All databases: ~15-30 seconds
- Single database: ~3-5 seconds

## Advanced Usage

### Custom Timeout and Retries

```bash
# Increase timeout for slow connections
./geoip-update -timeout 600 -retries 5

# More concurrent downloads for fast connections
./geoip-update -concurrent 8
```

### Integration with Applications

```go
// Example: Check if update is needed
cmd := exec.Command("/usr/local/bin/geoip-update", "-quiet")
cmd.Env = append(os.Environ(), "GEOIP_API_KEY="+apiKey)
if err := cmd.Run(); err != nil {
    log.Printf("GeoIP update failed: %v", err)
}
```

### Monitoring

Check the last update:
```bash
# Check modification time of databases
ls -la /path/to/geoip/*.mmdb

# Check logs
tail -n 50 /var/log/geoip-update.log

# Check for errors
grep ERROR /var/log/geoip-update.log
```

## Troubleshooting

### Common Issues

1. **"Another instance is already running"**
   ```bash
   # Remove stale lock file
   rm /tmp/geoip-update.lock
   ```

2. **"API key not provided"**
   ```bash
   # Set environment variable
   export GEOIP_API_KEY="your_key_here"
   ```

3. **SSL/TLS Errors**
   ```bash
   # Update CA certificates
   # Linux
   sudo update-ca-certificates
   # macOS
   brew install ca-certificates
   ```

### Debug Mode

Run with verbose output:
```bash
./geoip-update -verbose -api-key YOUR_KEY
```

## Security

- **API Key**: Never commit API keys to version control
- **Permissions**: Restrict binary permissions (`chmod 755`)
- **Lock File**: Prevents concurrent executions
- **TLS 1.2+**: Enforces modern TLS versions

## License

See the main project LICENSE file.