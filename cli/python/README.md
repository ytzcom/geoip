# Python CLI

Full-featured Python client for GeoIP database updates with async downloads, configuration files, and advanced features.

## ✨ Key Features

- 🚀 **Async Downloads**: Concurrent downloads for maximum speed
- 📁 **Config Files**: YAML configuration support for complex setups
- 🔄 **Smart Retry**: Exponential backoff with jitter
- 📊 **Progress Bars**: Real-time download progress
- 🔐 **Secure**: Input validation and safe file handling
- 🐳 **Docker Ready**: Multi-platform container support

## 🚀 Quick Start

### Docker Run
```bash
# Simple download
docker run --rm \
  -e GEOIP_API_KEY=your-key \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater:latest

# With specific databases
docker run --rm \
  -e GEOIP_API_KEY=your-key \
  -e GEOIP_DATABASES="city,country" \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater:latest
```

### Native Installation
```bash
# Install dependencies
pip install aiohttp pyyaml tqdm

# Download script
curl -O https://raw.githubusercontent.com/ytzcom/geoip-updater/main/cli/python/geoip-update.py
chmod +x geoip-update.py

# Run
./geoip-update.py --api-key your-key
```

## 🔧 Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GEOIP_API_KEY` | *(required)* | Your authentication API key |
| `GEOIP_API_ENDPOINT` | `https://geoipdb.net/auth` | API endpoint URL |
| `GEOIP_TARGET_DIR` | `/data` | Database storage directory |
| `GEOIP_DATABASES` | `all` | Databases to download |
| `GEOIP_CONFIG_FILE` | - | Path to configuration file |
| `GEOIP_LOG_FILE` | - | Log file path |

### Configuration File

Create `config.yaml` for advanced setups:

```yaml
# Authentication
api_key: "your-api-key-here"
api_endpoint: "https://geoipdb.net/auth"

# Storage
target_dir: "/var/lib/geoip"
temp_dir: "/tmp/geoip"

# Database selection
databases:
  - "GeoIP2-City.mmdb"
  - "GeoIP2-Country.mmdb"
  - "GeoIP2-ISP.mmdb"

# Performance
max_concurrent: 6
chunk_size: 8192
timeout: 300

# Retry logic
max_retries: 3
retry_delay: 2.0
retry_multiplier: 2.0

# Logging
log_file: "/var/log/geoip-update.log"
log_level: "INFO"
quiet_mode: false
verbose: false

# Security
verify_ssl: true
user_agent: "GeoIP-Updater/1.0"

# File handling
create_dirs: true
preserve_timestamps: true
atomic_updates: true
```

Use configuration file:
```bash
./geoip-update.py --config config.yaml
```

## 💻 Command Line Options

### Basic Options
```bash
# Required
-k, --api-key KEY          API authentication key
-e, --endpoint URL         API endpoint URL
-d, --directory DIR        Target directory for databases

# Database Selection
-b, --databases LIST       Specific databases (comma-separated) or "all"

# Configuration
-c, --config FILE          YAML configuration file path
```

### Advanced Options
```bash
# Performance
--concurrent NUM           Max concurrent downloads (default: 4)
--timeout SECONDS          Download timeout per file (default: 300)
--chunk-size BYTES         Download chunk size (default: 8192)

# Retry Logic
--max-retries NUM          Maximum retry attempts (default: 3)
--retry-delay SECONDS      Initial retry delay (default: 2.0)
--retry-multiplier FLOAT   Retry delay multiplier (default: 2.0)

# Logging & Output
-l, --log-file FILE        Log file path
-q, --quiet               Suppress progress output
-v, --verbose             Detailed output and debugging
--log-level LEVEL         Log level (DEBUG, INFO, WARNING, ERROR)

# Behavior
--no-lock                 Skip lock file (allows concurrent runs)
--test-connection         Test API connectivity and exit
--dry-run                 Show what would be downloaded without action
--force-update            Download files even if up-to-date
```

## 📋 Database Selection

### Selection Methods

```bash
# All databases
./geoip-update.py --databases all

# Specific databases by filename
./geoip-update.py --databases "GeoIP2-City.mmdb,GeoIP2-Country.mmdb"

# Using aliases (case-insensitive)
./geoip-update.py --databases "city,country,isp"

# Provider-specific
./geoip-update.py --databases "maxmind/*"
./geoip-update.py --databases "ip2location/*"
```

### Smart Database Discovery

The tool supports intelligent database name resolution:

```bash
# These all resolve to the same database
--databases "city"
--databases "City"  
--databases "GeoIP2-City"
--databases "GeoIP2-City.mmdb"

# Partial matching
--databases "proxy"  # Matches IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN

# Multiple aliases
--databases "city,isp,proxy"
```

### Available Aliases

| Alias | Full Database Name | Provider |
|-------|-------------------|----------|
| `city` | `GeoIP2-City.mmdb` | MaxMind |
| `country` | `GeoIP2-Country.mmdb` | MaxMind |
| `isp` | `GeoIP2-ISP.mmdb` | MaxMind |
| `connection` | `GeoIP2-Connection-Type.mmdb` | MaxMind |
| `db23-ipv4` | `IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN` | IP2Location |
| `db23-ipv6` | `IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN` | IP2Location |
| `px2` | `IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN` | IP2Location |

## 🚀 Performance Optimization

### Concurrent Downloads

```bash
# Conservative (good for limited bandwidth)
./geoip-update.py --concurrent 2

# Balanced (default)
./geoip-update.py --concurrent 4

# Aggressive (fast networks only)
./geoip-update.py --concurrent 8
```

### Timeout Configuration

```bash
# Quick timeout for local networks
./geoip-update.py --timeout 60

# Extended timeout for slow connections
./geoip-update.py --timeout 600

# Configuration file approach
timeout: 300
chunk_size: 16384  # Larger chunks for faster networks
```

### Progress Monitoring

```bash
# Standard progress bars
./geoip-update.py

# Quiet mode for automation
./geoip-update.py --quiet

# Verbose debugging
./geoip-update.py --verbose
```

## 🔄 Automation & Scheduling

### Cron Example
```bash
# Daily updates at 3 AM
0 3 * * * /usr/local/bin/geoip-update.py --config /etc/geoip/config.yaml --quiet

# Weekly with logging
0 2 * * 0 /usr/local/bin/geoip-update.py --quiet --log-file /var/log/geoip-update.log
```

### systemd Service
```ini
[Unit]
Description=GeoIP Database Update
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/geoip-update.py --config /etc/geoip/config.yaml
User=geoip
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

### Docker Compose for Automation
```yaml
version: '3.8'
services:
  geoip-updater:
    image: ytzcom/geoip-updater:latest
    environment:
      GEOIP_API_KEY: ${GEOIP_API_KEY}
      GEOIP_DATABASES: "city,country,isp"
    volumes:
      - geoip-data:/data
      - ./config.yaml:/config.yaml:ro
    command: ["python", "geoip-update.py", "--config", "/config.yaml"]
    
volumes:
  geoip-data:
```

## 🛡️ Security Features

### Input Validation
- API key format validation
- Path traversal protection  
- File extension validation
- Size limit enforcement

### Safe File Handling
- Atomic file updates (temp → final)
- Checksum verification (when available)
- Permission preservation
- Backup creation option

### SSL/TLS Security
```yaml
# Configuration options
verify_ssl: true          # Verify SSL certificates
user_agent: "Custom/1.0"  # Custom user agent
```

## 🏠️ Technical Details

### Architecture
- **Async I/O**: `aiohttp` for concurrent downloads
- **Progress Tracking**: `tqdm` for user feedback
- **Configuration**: `PyYAML` for complex setups
- **Error Handling**: Comprehensive exception management

### Dependencies
```bash
# Core requirements
aiohttp>=3.8.0      # Async HTTP client
pyyaml>=6.0         # YAML configuration
tqdm>=4.64.0        # Progress bars

# Optional enhancements
aiofiles>=0.8.0     # Async file I/O
ujson>=5.0.0        # Faster JSON parsing
```

### Error Handling
- **Network errors**: Automatic retry with exponential backoff
- **API errors**: Detailed error messages with troubleshooting tips
- **File errors**: Fallback strategies and recovery options
- **Configuration errors**: Clear validation messages

## 🔍 Troubleshooting

### Common Issues

**ModuleNotFoundError**
```bash
# Install missing dependencies
pip install aiohttp pyyaml tqdm

# Or install all requirements
pip install -r requirements.txt
```

**Permission Denied**
```bash
# Fix directory permissions
sudo chown -R $USER:$USER /var/lib/geoip
chmod 755 /var/lib/geoip

# Or use user directory
./geoip-update.py --directory ~/geoip
```

**API Connection Issues**
```bash
# Test connectivity
./geoip-update.py --test-connection

# Debug with verbose output
./geoip-update.py --verbose

# Check SSL issues
./geoip-update.py --verbose --log-level DEBUG
```

**Concurrent Download Issues**
```bash
# Reduce concurrency
./geoip-update.py --concurrent 1

# Increase timeout
./geoip-update.py --timeout 600

# Check system limits
ulimit -n  # File descriptor limit
```

### Debug Mode

Enable comprehensive debugging:
```bash
# Maximum debugging
./geoip-update.py --verbose --log-level DEBUG

# Log to file for analysis
./geoip-update.py --verbose --log-file debug.log --log-level DEBUG

# Test mode (no actual downloads)
./geoip-update.py --dry-run --verbose
```

## 🔗 Related Documentation

- **[CLI Overview](../README.md)** - All CLI implementations comparison
- **[Docker Cron](../python-cron/README.md)** - Automated scheduling version  
- **[Kubernetes](../python-k8s/README.md)** - Production deployment version
- **[Usage Examples](../../docs/USAGE_EXAMPLES.md)** - Programming language integration
- **[Security Guide](../../docs/SECURITY.md)** - Security best practices

## 🤝 Contributing

To modify this Python implementation:

1. **Setup environment**:
   ```bash
   python -m venv venv
   source venv/bin/activate
   pip install -r requirements.txt
   ```

2. **Test changes**:
   ```bash
   python geoip-update.py --test-connection
   python geoip-update.py --dry-run --verbose
   ```

3. **Submit pull request**: Include tests and documentation updates