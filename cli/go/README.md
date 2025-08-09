# Go Binary CLI

Minimal, high-performance single binary for GeoIP database downloads with zero dependencies and lightning-fast startup.

## ✨ Key Features

- ⚡ **Lightning Fast**: ~10ms startup time, optimized for speed
- 📦 **Single Binary**: No dependencies, just download and run
- 🪶 **Minimal Size**: ~8MB binary, ~25MB Docker image
- 🌍 **Cross-Platform**: Available for all major OS/architectures
- 🔒 **Memory Safe**: Built with Go's memory safety guarantees
- 🚀 **High Performance**: Concurrent downloads with connection pooling

## 🚀 Quick Start

### Docker Run
```bash
# Smallest container option (~25MB)
docker run --rm \
  -e GEOIP_API_KEY=your-key \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater-go:latest

# With specific databases
docker run --rm \
  -e GEOIP_API_KEY=your-key \
  -e GEOIP_DATABASES="city,country" \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater-go:latest
```

### Native Binary

#### Download Pre-built Binary (Recommended)
```bash
# Download for your platform (Linux amd64 example)
curl -LO https://github.com/ytzcom/geoip/releases/latest/download/geoip-updater-linux-amd64
chmod +x geoip-updater-linux-amd64

# Run
./geoip-updater-linux-amd64 --api-key your-key
```

#### Available Pre-built Binaries

Pre-compiled binaries are available from the [GitHub Releases page](https://github.com/ytzcom/geoip/releases/latest):

| Platform | Architecture | Binary Name | Direct Download |
|----------|-------------|-------------|-----------------|
| **Linux** | amd64 (x86_64) | `geoip-updater-linux-amd64` | [Download](https://github.com/ytzcom/geoip/releases/latest/download/geoip-updater-linux-amd64) |
| **Linux** | arm64 | `geoip-updater-linux-arm64` | [Download](https://github.com/ytzcom/geoip/releases/latest/download/geoip-updater-linux-arm64) |
| **Linux** | arm/v7 | `geoip-updater-linux-arm` | [Download](https://github.com/ytzcom/geoip/releases/latest/download/geoip-updater-linux-arm) |
| **macOS** | amd64 (Intel) | `geoip-updater-darwin-amd64` | [Download](https://github.com/ytzcom/geoip/releases/latest/download/geoip-updater-darwin-amd64) |
| **macOS** | arm64 (M1/M2/M3) | `geoip-updater-darwin-arm64` | [Download](https://github.com/ytzcom/geoip/releases/latest/download/geoip-updater-darwin-arm64) |
| **Windows** | amd64 | `geoip-updater-windows-amd64.exe` | [Download](https://github.com/ytzcom/geoip/releases/latest/download/geoip-updater-windows-amd64.exe) |
| **Windows** | arm64 | `geoip-updater-windows-arm64.exe` | [Download](https://github.com/ytzcom/geoip/releases/latest/download/geoip-updater-windows-arm64.exe) |
| **FreeBSD** | amd64 | `geoip-updater-freebsd-amd64` | [Download](https://github.com/ytzcom/geoip/releases/latest/download/geoip-updater-freebsd-amd64) |

#### Quick Download Examples

```bash
# macOS Apple Silicon (M1/M2/M3)
curl -LO https://github.com/ytzcom/geoip/releases/latest/download/geoip-updater-darwin-arm64
chmod +x geoip-updater-darwin-arm64
./geoip-updater-darwin-arm64 --version

# macOS Intel
curl -LO https://github.com/ytzcom/geoip/releases/latest/download/geoip-updater-darwin-amd64
chmod +x geoip-updater-darwin-amd64
./geoip-updater-darwin-amd64 --version

# Linux ARM64 (Raspberry Pi 64-bit, AWS Graviton)
curl -LO https://github.com/ytzcom/geoip/releases/latest/download/geoip-updater-linux-arm64
chmod +x geoip-updater-linux-arm64
./geoip-updater-linux-arm64 --version

# Windows PowerShell
Invoke-WebRequest -Uri "https://github.com/ytzcom/geoip/releases/latest/download/geoip-updater-windows-amd64.exe" -OutFile "geoip-updater.exe"
.\geoip-updater.exe --version
```

#### Verify Download

Each release includes checksums for verification:

```bash
# Download checksums
curl -LO https://github.com/ytzcom/geoip/releases/latest/download/checksums-sha256.txt

# Verify your download (Linux/macOS)
sha256sum -c checksums-sha256.txt 2>/dev/null | grep "geoip-updater-linux-amd64"

# Or manually compare
sha256sum geoip-updater-linux-amd64
cat checksums-sha256.txt | grep "geoip-updater-linux-amd64"
```

## 🔧 Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GEOIP_API_KEY` | *(required)* | Your authentication API key |
| `GEOIP_API_ENDPOINT` | `https://geoipdb.net/auth` | API endpoint URL |
| `GEOIP_TARGET_DIR` | `./geoip` | Database storage directory |
| `GEOIP_DATABASES` | `all` | Databases to download |
| `GEOIP_TIMEOUT` | `300s` | HTTP timeout duration |
| `GEOIP_MAX_RETRIES` | `3` | Maximum retry attempts |

### Command Line Options

```bash
# Basic usage
./geoip-updater [OPTIONS]

# Required
--api-key, -k STRING        API authentication key
--endpoint, -e STRING       API endpoint URL
--directory, -d STRING      Target directory for databases

# Database selection
--databases, -b STRING      Comma-separated list or "all"
--list-databases           Show available databases
--validate-databases       Validate database selection without download

# Performance
--timeout DURATION         HTTP timeout (default: 5m0s)
--max-retries INT          Maximum retry attempts (default: 3)
--concurrent INT           Max concurrent downloads (default: 4)
--user-agent STRING        Custom User-Agent header

# Output control
--quiet, -q                Suppress output except errors
--verbose, -v              Detailed output with timing information
--json                     Output progress in JSON format
--no-color                 Disable colored output

# Behavior
--force                    Force download even if files are up-to-date
--dry-run                  Show what would be downloaded without downloading
--version                  Show version information
```

## 📋 Database Selection

### Selection Examples

```bash
# All databases
./geoip-updater --databases all

# Specific databases
./geoip-updater --databases "GeoIP2-City.mmdb,GeoIP2-Country.mmdb"

# Using aliases (case-insensitive)
./geoip-updater --databases "city,country,isp"

# Provider-specific
./geoip-updater --databases "maxmind/*"

# Validate before downloading
./geoip-updater --databases "city,invalid-db" --validate-databases
```

### Smart Database Discovery

```bash
# List all available databases
./geoip-updater --list-databases

# These all resolve to the same database
--databases "city"
--databases "City"
--databases "GeoIP2-City"
--databases "GeoIP2-City.mmdb"
```

### Available Aliases

| Alias | Full Database Name | Size | Provider |
|-------|-------------------|------|----------|
| `city` | `GeoIP2-City.mmdb` | ~115MB | MaxMind |
| `country` | `GeoIP2-Country.mmdb` | ~9MB | MaxMind |
| `isp` | `GeoIP2-ISP.mmdb` | ~17MB | MaxMind |
| `connection` | `GeoIP2-Connection-Type.mmdb` | ~11MB | MaxMind |
| `db23-ipv4` | `IP-COUNTRY-REGION-CITY...BIN` | ~633MB | IP2Location |
| `db23-ipv6` | `IPV6-COUNTRY-REGION-CITY...BIN` | ~805MB | IP2Location |
| `px2` | `IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN` | ~192MB | IP2Location |

## ⚡ Performance Features

### Concurrent Downloads

```bash
# Conservative (slow networks)
./geoip-updater --concurrent 2

# Balanced (default)
./geoip-updater --concurrent 4

# Aggressive (fast networks)
./geoip-updater --concurrent 8
```

### Timeout Configuration

```bash
# Quick timeout
./geoip-updater --timeout 1m

# Extended timeout for large files
./geoip-updater --timeout 10m

# Per-database timeout (automatic)
# Calculates timeout based on file size
```

### Progress Monitoring

```bash
# Standard progress bar
./geoip-updater

# JSON output for automation
./geoip-updater --json

# Quiet mode
./geoip-updater --quiet

# Verbose timing information
./geoip-updater --verbose
```

## 🔄 Automation Examples

### Cron Job
```bash
# Daily updates at 3 AM
0 3 * * * /usr/local/bin/geoip-updater --quiet --api-key="${GEOIP_API_KEY}"

# With logging
0 3 * * * /usr/local/bin/geoip-updater --quiet 2>&1 | logger -t geoip-updater
```

### systemd Service
```ini
[Unit]
Description=GeoIP Database Update
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/geoip-updater --quiet
Environment="GEOIP_API_KEY=your-key-here"
User=geoip
StandardOutput=journal

[Install]
WantedBy=multi-user.target
```

### Docker Compose
```yaml
version: '3.8'
services:
  geoip-updater:
    image: ytzcom/geoip-updater-go:latest
    environment:
      GEOIP_API_KEY: ${GEOIP_API_KEY}
      GEOIP_DATABASES: "city,country,isp"
    volumes:
      - geoip-data:/data
    restart: "no"  # Run once
    
volumes:
  geoip-data:
```

### Shell Script Wrapper
```bash
#!/bin/bash
# geoip-update-wrapper.sh

set -euo pipefail

GEOIP_DIR="/var/lib/geoip"
LOG_FILE="/var/log/geoip-update.log"

# Ensure directory exists
mkdir -p "$GEOIP_DIR"

# Run updater with logging
/usr/local/bin/geoip-updater \
  --directory "$GEOIP_DIR" \
  --databases "city,country,isp" \
  --verbose \
  2>&1 | tee -a "$LOG_FILE"

# Notify on success
echo "$(date): GeoIP databases updated successfully" | logger -t geoip-updater
```

## 🛡️ Security Features

### Input Validation
- **API key format validation**: Prevents invalid keys
- **Path sanitization**: Prevents directory traversal
- **Database name validation**: Only allows known databases
- **URL validation**: Ensures valid endpoints

### Safe Operations
- **Atomic writes**: Uses temporary files then renames
- **Permission preservation**: Maintains file permissions
- **No shell execution**: Pure Go implementation
- **Memory safety**: Go's built-in memory management

### Network Security
```bash
# Custom User-Agent
./geoip-updater --user-agent "MyApp/1.0"

# Timeout protection
./geoip-updater --timeout 30s

# TLS verification (always enabled)
```

## 🏠️ Technical Details

### Architecture
- **Language**: Go 1.21+
- **Concurrency**: Goroutines for parallel downloads
- **HTTP Client**: Custom transport with connection pooling
- **Memory**: Efficient streaming downloads
- **Binary Size**: ~8MB (statically linked)

### Build Information
```bash
# Check build information
./geoip-updater --version

# Example output:
# geoip-updater v1.2.3
# Built: 2025-08-09T10:30:00Z
# Commit: abc123def456
# Go version: go1.21.5
# Platform: linux/amd64
```

### Performance Characteristics

| Metric | Value | Notes |
|--------|-------|-------|
| **Startup Time** | ~10ms | Near-instantaneous |
| **Memory Usage** | 15-30MB | Efficient streaming |
| **Binary Size** | ~8MB | Statically linked |
| **Docker Image** | ~25MB | Minimal Alpine base |
| **CPU Usage** | Low | Efficient Go runtime |

### Optimization Features
- **Connection reuse**: HTTP/2 connection pooling
- **Streaming downloads**: No memory buffering
- **Parallel processing**: Concurrent database downloads
- **Smart caching**: ETag/Last-Modified support
- **Progress tracking**: Real-time progress updates

## 🔍 Troubleshooting

### Common Issues

**Binary not found**
```bash
# Check download
ls -la geoip-updater*

# Make executable
chmod +x geoip-updater

# Check architecture
file geoip-updater
```

**Permission denied**
```bash
# Fix directory permissions
sudo chown $USER:$USER /var/lib/geoip
chmod 755 /var/lib/geoip

# Or use user directory
./geoip-updater --directory ~/geoip
```

**Network connectivity issues**
```bash
# Test with verbose output
./geoip-updater --verbose --dry-run

# Check with increased timeout
./geoip-updater --timeout 10m --verbose

# Test specific endpoint
curl -v https://geoipdb.net/auth
```

**Large file timeouts**
```bash
# Increase timeout for large databases
./geoip-updater --timeout 15m --databases db23-ipv4

# Reduce concurrency
./geoip-updater --concurrent 1 --databases all
```

### Debug Mode

```bash
# Maximum verbosity
./geoip-updater --verbose

# JSON output for parsing
./geoip-updater --json --verbose

# Dry run to test configuration
./geoip-updater --dry-run --verbose

# Validate database selection
./geoip-updater --validate-databases --databases "city,invalid"
```

### Performance Debugging

```bash
# Monitor system resources
top -p $(pgrep geoip-updater)

# Check network usage
nethogs -p $(pgrep geoip-updater)

# Memory profiling (requires Go build)
go tool pprof http://localhost:6060/debug/pprof/heap
```

## 📊 Benchmarks

### Startup Performance
```
$ time ./geoip-updater --version
geoip-updater v1.2.3

real    0m0.009s
user    0m0.003s
sys     0m0.004s
```

### Download Performance
```
# Single database (GeoIP2-City.mmdb ~115MB)
$ time ./geoip-updater --databases city
Downloaded GeoIP2-City.mmdb (115.2 MB) in 12.4s

real    0m12.456s
user    0m0.234s
sys     0m0.145s
```

### Memory Usage
```
# Peak memory usage during all database download
RSS: ~28MB
VSZ: ~45MB
```

## 🔗 Related Documentation

- **[CLI Overview](../README.md)** - All CLI implementations comparison
- **[Python CLI](../python/README.md)** - Feature-rich alternative
- **[Docker Cron](../python-cron/README.md)** - Automated scheduling
- **[Usage Examples](../../docs/USAGE_EXAMPLES.md)** - Integration examples

## 🔨 Building from Source

If pre-built binaries are not available for your platform or you want to customize the build:

### Prerequisites
- Go 1.21 or later
- Git

### Build Instructions

1. **Clone the repository**:
   ```bash
   git clone https://github.com/ytzcom/geoip.git
   cd geoip/cli/go
   ```

2. **Build for current platform**:
   ```bash
   go build -o geoip-updater .
   ./geoip-updater --version
   ```

3. **Cross-compile for other platforms**:
   ```bash
   # Linux AMD64
   GOOS=linux GOARCH=amd64 go build -o geoip-updater-linux-amd64 .
   
   # Linux ARM64
   GOOS=linux GOARCH=arm64 go build -o geoip-updater-linux-arm64 .
   
   # Linux ARM v7
   GOOS=linux GOARCH=arm GOARM=7 go build -o geoip-updater-linux-arm .
   
   # macOS Intel
   GOOS=darwin GOARCH=amd64 go build -o geoip-updater-darwin-amd64 .
   
   # macOS Apple Silicon
   GOOS=darwin GOARCH=arm64 go build -o geoip-updater-darwin-arm64 .
   
   # Windows AMD64
   GOOS=windows GOARCH=amd64 go build -o geoip-updater-windows-amd64.exe .
   
   # Windows ARM64
   GOOS=windows GOARCH=arm64 go build -o geoip-updater-windows-arm64.exe .
   
   # FreeBSD AMD64
   GOOS=freebsd GOARCH=amd64 go build -o geoip-updater-freebsd-amd64 .
   ```

4. **Build with optimizations**:
   ```bash
   # Smaller binary size
   go build -ldflags="-s -w" -o geoip-updater .
   
   # With version information
   VERSION=$(git describe --tags --always --dirty)
   go build -ldflags="-s -w -X main.version=$VERSION" -o geoip-updater .
   
   # Maximum optimization
   go build -ldflags="-s -w" -trimpath -o geoip-updater .
   ```

5. **Using the Makefile**:
   ```bash
   # Build for current platform
   make build
   
   # Build for all platforms
   make build-all
   
   # Create release archives
   make release
   
   # Install locally
   make install
   
   # See all options
   make help
   ```

## 🤝 Contributing

To modify this Go implementation:

1. **Setup development environment**:
   ```bash
   go version  # Ensure Go 1.21+ is installed
   git clone https://github.com/ytzcom/geoip.git
   cd geoip/cli/go
   ```

2. **Make your changes and test**:
   ```bash
   # Run tests
   go test ./...
   
   # Build and test locally
   go build -o geoip-updater .
   ./geoip-updater --dry-run --verbose
   
   # Test with real download (requires API key)
   ./geoip-updater --api-key YOUR_KEY --databases city --verbose
   ```

3. **Submit pull request**: 
   - Include tests for new features
   - Update documentation
   - Follow Go best practices and conventions
   - Ensure all tests pass