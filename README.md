# GeoIP Database Updater

![Workflow Status](https://github.com/ytzcom/geoip/workflows/Update%20GeoIP%20Databases/badge.svg)
![Last Update](https://img.shields.io/badge/Last%20Update-2025--08--04%2000:27:15%20UTC-blue)
![Database Count](https://img.shields.io/badge/Databases-7-green)
![MaxMind Databases](https://img.shields.io/badge/MaxMind-4-orange)
![IP2Location Databases](https://img.shields.io/badge/IP2Location-3-purple)

Automated GeoIP database updater for MaxMind and IP2Location databases with authenticated API access. This system provides secure, automated downloads of GeoIP databases through multiple client options.

## 📅 Update Schedule

Databases are automatically updated **every Monday at midnight UTC**.

## 🚀 Quick Start

### Docker Integration (2 Lines!)

For ANY Docker project, add these 2 lines to your Dockerfile:

```dockerfile
# Copy GeoIP scripts
FROM ytzcom/geoip-scripts:latest as geoip
COPY --from=geoip /opt/geoip /opt/geoip
```

Then in your entrypoint:
```sh
. /opt/geoip/entrypoint-helper.sh && geoip_init
```

### One-Line Linux Installer

```bash
# Install GeoIP tools to /opt/geoip
curl -sSL https://geoip.ytrack.io/install | sh

# With automatic updates via cron
curl -sSL "https://geoip.ytrack.io/install?with_cron=true" | sh
```

### Docker CLI (Direct Download)

```bash
# One-time download with Docker
docker run --rm \
  -e GEOIP_API_KEY=your-api-key \
  -e GEOIP_API_ENDPOINT=https://geoip.ytrack.io/auth \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater:latest

# Download specific databases only
docker run --rm \
  -e GEOIP_API_KEY=your-api-key \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater:latest \
  --databases GeoIP2-City.mmdb,GeoIP2-Country.mmdb
```

### Quick Install Scripts

```bash
# Clone the repository
git clone https://github.com/ytzcom/geoip.git
cd geoip-updater/scripts/cli

# Run with your preferred script
./geoip-update.sh -k YOUR_API_KEY        # Bash (Linux/macOS)
python geoip-update.py -k YOUR_API_KEY   # Python (cross-platform)
./geoip-update.ps1 -ApiKey YOUR_API_KEY  # PowerShell (Windows)
```

## 📊 Database Information

| Database | Provider | Format | Size | Description |
|----------|----------|--------|------|-------------|
| GeoIP2-City | MaxMind | MMDB | 115MB | City-level IP geolocation data |
| GeoIP2-Country | MaxMind | MMDB | 9MB | Country-level IP geolocation data |
| GeoIP2-ISP | MaxMind | MMDB | 17MB | ISP and organization data |
| GeoIP2-Connection-Type | MaxMind | MMDB | 11MB | Connection type data |
| DB23 IPv4 | IP2Location | BIN | 633MB | Comprehensive IPv4 geolocation data |
| DB23 IPv6 | IP2Location | BIN | 805MB | Comprehensive IPv6 geolocation data |
| PX2 IPv4 | IP2Location | BIN | 192MB | IPv4 proxy detection data |

## 🛠️ CLI Download Tools

### Bash Script (Linux/macOS/BSD)

```bash
# Basic usage with API key
./scripts/cli/geoip-update.sh -k YOUR_API_KEY

# Download to specific directory
./scripts/cli/geoip-update.sh -k YOUR_API_KEY -d /var/lib/geoip

# Download specific databases only
./scripts/cli/geoip-update.sh -k YOUR_API_KEY -D "GeoIP2-City.mmdb,GeoIP2-Country.mmdb"

# Use custom API endpoint
./scripts/cli/geoip-update.sh -k YOUR_API_KEY -e https://your-api.example.com/auth

# With environment variables
export GEOIP_API_KEY="your_api_key"
export GEOIP_TARGET_DIR="/var/lib/geoip"
./scripts/cli/geoip-update.sh
```

### Python Script (Cross-platform)

```bash
# Basic usage
python scripts/cli/geoip-update.py --api-key YOUR_API_KEY

# With configuration file
python scripts/cli/geoip-update.py --config config.yaml

# Download specific databases
python scripts/cli/geoip-update.py -k YOUR_API_KEY \
  --databases GeoIP2-City.mmdb \
  --databases GeoIP2-Country.mmdb

# Verbose output with custom directory
python scripts/cli/geoip-update.py -k YOUR_API_KEY \
  --target-dir /opt/geoip \
  --verbose
```

### PowerShell Script (Windows)

```powershell
# Basic usage
.\scripts\cli\geoip-update.ps1 -ApiKey YOUR_API_KEY

# Save to specific directory
.\scripts\cli\geoip-update.ps1 -ApiKey YOUR_API_KEY -TargetDir "C:\GeoIP"

# Use Windows Credential Manager (secure storage)
.\scripts\cli\geoip-update.ps1 -SaveCredentials
.\scripts\cli\geoip-update.ps1  # Uses saved credentials

# Download specific databases
.\scripts\cli\geoip-update.ps1 -ApiKey YOUR_API_KEY `
  -Databases @("GeoIP2-City.mmdb", "GeoIP2-Country.mmdb")
```

### Go Binary (Compiled)

```bash
# Build the binary
cd scripts/cli/go
go build -o geoip-updater

# Run with API key
./geoip-updater -api-key YOUR_API_KEY

# With all options
./geoip-updater \
  -api-key YOUR_API_KEY \
  -api-endpoint https://geoip.ytrack.io/auth \
  -target-dir /var/lib/geoip \
  -databases "GeoIP2-City.mmdb,GeoIP2-Country.mmdb"
```

## 🐳 Docker Deployments

### Docker CLI Images

```bash
# Python CLI (default) - Full featured
docker run --rm \
  -e GEOIP_API_KEY=your-api-key \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater:latest

# Cron scheduler with supercronic - Automated updates
docker run -d \
  --name geoip-cron \
  -e GEOIP_API_KEY=your-api-key \
  -e CRON_SCHEDULE="0 2 * * *" \
  -v geoip-data:/data \
  ytzcom/geoip-updater-cron:latest

# Kubernetes optimized - Minimal size, fast startup
docker run --rm \
  -e GEOIP_API_KEY=your-api-key \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater-k8s:latest

# Go binary version - Smallest image
docker run --rm \
  -e GEOIP_API_KEY=your-api-key \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater-go:latest
```

### Docker Compose Setup

```bash
# Clone repository
git clone https://github.com/ytzcom/geoip.git
cd geoip-updater/scripts/cli/docker

# Configure environment
cp .env.example .env
# Edit .env with your API key

# One-time download
docker-compose run --rm geoip-updater

# Start scheduled updates (runs daily at 2 AM)
docker-compose up -d geoip-cron

# View logs
docker-compose logs -f geoip-cron

# Access downloaded databases
docker-compose run --rm geoip-updater ls -la /data
```

### Docker Compose with API Server

```bash
# Development setup with local storage
cd infrastructure/docker-api
docker-compose -f docker-compose.yml up -d

# Production with S3 backend and Nginx
docker-compose -f docker-compose.prod.yml up -d

# Check status
docker-compose ps
docker-compose logs -f
```

## 📅 Scheduled Updates

### Systemd (Linux)

```bash
# Install service
cd scripts/cli/systemd
sudo ./install.sh

# Configure
sudo nano /etc/geoip-update/config
# Add: GEOIP_API_KEY=your_api_key

# Enable timer
sudo systemctl enable --now geoip-update.timer

# Check status
sudo systemctl status geoip-update.timer
sudo journalctl -u geoip-update.service
```

### Kubernetes CronJob

```bash
# Edit secret with your API key
kubectl create secret generic geoip-api-credentials \
  --from-literal=api-key=YOUR_API_KEY \
  --from-literal=api-endpoint=https://geoip.ytrack.io/auth

# Deploy CronJob
kubectl apply -k scripts/cli/k8s/

# Or for specific environment
kubectl apply -k scripts/cli/k8s/overlays/prod

# Check status
kubectl get cronjobs -n geoip-updater
kubectl get jobs -n geoip-updater
kubectl logs -n geoip-updater -l app=geoip-updater
```

### Docker Compose Cron

```yaml
# docker-compose.yml
version: '3.8'
services:
  geoip-cron:
    image: ytzcom/geoip-updater-cron:latest
    environment:
      GEOIP_API_KEY: ${GEOIP_API_KEY}
      CRON_SCHEDULE: "0 2 * * *"  # Daily at 2 AM
    volumes:
      - geoip-data:/data
      - geoip-logs:/logs
    restart: unless-stopped

volumes:
  geoip-data:
  geoip-logs:
```

## 🔄 Integration Guide

### Docker Projects

The easiest way to integrate GeoIP databases into your Docker project:

```dockerfile
# In your Dockerfile - just 2 lines!
FROM ytzcom/geoip-scripts:latest as geoip
COPY --from=geoip /opt/geoip /opt/geoip

# Your base image
FROM your-base-image

# Copy the scripts
COPY --from=geoip /opt/geoip /opt/geoip

# Configure environment
ENV GEOIP_API_KEY=your-api-key \
    GEOIP_TARGET_DIR=/app/geoip \
    GEOIP_DOWNLOAD_ON_START=true \
    GEOIP_SETUP_CRON=true

# In your entrypoint
ENTRYPOINT ["/bin/sh", "-c", ". /opt/geoip/entrypoint-helper.sh && geoip_init && exec your-app"]
```

### Available Functions

When you source `entrypoint-helper.sh`, you get:
- `geoip_init` - Complete initialization (download, validate, setup cron)
- `geoip_check_databases` - Check if databases exist
- `geoip_download_databases` - Download databases
- `geoip_validate_databases` - Validate databases
- `geoip_health_check` - Health check for monitoring

### Example: Laravel/PHP Application

```dockerfile
FROM ytzcom/geoip-scripts:latest as geoip
FROM php:8.3-fpm

# Copy GeoIP scripts
COPY --from=geoip /opt/geoip /opt/geoip

# Your app code
COPY . /var/www/html

# Configure GeoIP
ENV GEOIP_API_KEY=${GEOIP_API_KEY} \
    GEOIP_TARGET_DIR=/var/www/html/resources/geoip \
    GEOIP_DOWNLOAD_ON_START=true

# Entrypoint that initializes GeoIP
RUN echo '#!/bin/sh\n\
. /opt/geoip/entrypoint-helper.sh\n\
geoip_init\n\
exec php-fpm' > /entrypoint.sh && chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

### Example: Node.js Application

```dockerfile
FROM ytzcom/geoip-scripts:latest as geoip
FROM node:20-alpine

# Copy GeoIP scripts
COPY --from=geoip /opt/geoip /opt/geoip

# Your app
WORKDIR /app
COPY . .
RUN npm ci --production

# Configure
ENV GEOIP_API_KEY=${GEOIP_API_KEY} \
    GEOIP_TARGET_DIR=/app/data/geoip

# Initialize and start
CMD sh -c '. /opt/geoip/entrypoint-helper.sh && geoip_init && node server.js'
```

### Linux Systems

One-line installation for any Linux system:

```bash
# Basic installation
curl -sSL https://geoip.ytrack.io/install | sh

# With cron for automatic updates
curl -sSL "https://geoip.ytrack.io/install?with_cron=true" | sh

# Custom installation directory
curl -sSL "https://geoip.ytrack.io/install?install_dir=/usr/local/geoip" | sh
```

After installation:
```bash
# Set your API key
export GEOIP_API_KEY=your-api-key

# Download databases
/opt/geoip/geoip-update.sh

# Setup automatic updates (if not done during install)
/opt/geoip/setup-cron.sh
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `GEOIP_API_KEY` | **Required** - Your API key | - |
| `GEOIP_TARGET_DIR` | Where to store databases | `/app/resources/geoip` |
| `GEOIP_API_ENDPOINT` | API endpoint URL | `https://geoip.ytrack.io/auth` |
| `GEOIP_DOWNLOAD_ON_START` | Download on container start | `true` |
| `GEOIP_VALIDATE_ON_START` | Validate on start | `true` |
| `GEOIP_SETUP_CRON` | Setup automatic updates | `true` |
| `GEOIP_UPDATE_SCHEDULE` | Cron schedule | `0 2 * * *` (2 AM daily) |
| `GEOIP_FAIL_ON_ERROR` | Exit on initialization error | `false` |
| `GEOIP_DATABASES` | Specific databases or "all" | `all` |

### Health Checks

Add health checks to your Docker containers:

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD sh -c '. /opt/geoip/entrypoint-helper.sh && geoip_health_check'
```

Or in docker-compose.yml:
```yaml
healthcheck:
  test: ["CMD", "sh", "-c", ". /opt/geoip/entrypoint-helper.sh && geoip_health_check"]
  interval: 30s
  timeout: 3s
  retries: 3
```

## 🔧 API Server Deployment

### Quick Start

```bash
# Run API server with Docker
docker run -p 8080:8080 \
  -e API_KEYS=key1,key2,key3 \
  -e STORAGE_MODE=s3 \
  -e S3_BUCKET=your-s3-bucket \
  -e AWS_ACCESS_KEY_ID=your-key \
  -e AWS_SECRET_ACCESS_KEY=your-secret \
  ytzcom/geoip-api:latest

# Test the API
curl -X POST http://localhost:8080/auth \
  -H "X-API-Key: key1" \
  -H "Content-Type: application/json" \
  -d '{"databases": "all"}'
```

### Production Deployment

```bash
# With Nginx reverse proxy
docker run -d \
  --name geoip-api \
  -p 80:80 -p 443:443 \
  -e API_KEYS=${API_KEYS} \
  -e S3_BUCKET=your-s3-bucket \
  -e AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
  -e AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
  -v ./ssl:/etc/nginx/ssl:ro \
  ytzcom/geoip-api-nginx:latest
```

### Manual Deployment to Servers

```bash
# Using GitHub Actions for deployment
# 1. Set up repository secrets:
#    - DEPLOY_KEY (SSH private key)
#    - DEPLOY_USER (SSH username)
#    - DEPLOY_HOST (target server)

# 2. Trigger manual deployment:
# Go to Actions → Manual Deploy → Run workflow
# Enter target host and branch to deploy
```

## 🔧 Usage Examples

### Python (with geoip2)

```python
import geoip2.database

# Load the database
reader = geoip2.database.Reader('GeoIP2-City.mmdb')

# Lookup an IP
response = reader.city('8.8.8.8')
print(f"Country: {response.country.name}")
print(f"City: {response.city.name}")
print(f"Latitude: {response.location.latitude}")
print(f"Longitude: {response.location.longitude}")

reader.close()
```

### Python (with IP2Location)

```python
import IP2Location

# Load the database
db = IP2Location.IP2Location('IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN')

# Lookup an IP
result = db.get_all('8.8.8.8')
print(f"Country: {result.country_long}")
print(f"City: {result.city}")
print(f"ISP: {result.isp}")
```

### Python (with IP2Proxy)

```python
import IP2Proxy

# Load the database
db = IP2Proxy.IP2Proxy('IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN')

# Check if IP is a proxy
result = db.get_all('8.8.8.8')
print(f"Is Proxy: {result.is_proxy}")
print(f"Proxy Type: {result.proxy_type}")
print(f"Country: {result.country_long}")
```

### PHP (with GeoIP2)

```php
<?php
require_once 'vendor/autoload.php';
use GeoIp2\Database\Reader;

// Load the database
$reader = new Reader('GeoIP2-City.mmdb');

// Lookup an IP
$record = $reader->city('8.8.8.8');
echo "Country: " . $record->country->name . "\n";
echo "City: " . $record->city->name . "\n";
echo "Latitude: " . $record->location->latitude . "\n";
echo "Longitude: " . $record->location->longitude . "\n";

// Close the reader (not required, but recommended)
$reader->close();
?>
```

### PHP (with IP2Location)

```php
<?php
require_once 'vendor/autoload.php';
use IP2Location\Database;

// Load the database
$db = new Database('IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN', IP2Location\Database::FILE_IO);

// Lookup an IP
$records = $db->lookup('8.8.8.8', IP2Location\Database::ALL);
echo "Country: " . $records['countryLong'] . "\n";
echo "City: " . $records['city'] . "\n";
echo "ISP: " . $records['isp'] . "\n";
?>
```

### Laravel (with GeoIP)

```php
<?php
namespace App\Http\Controllers;

use Illuminate\Http\Request;
use Torann\GeoIP\Facades\GeoIP;

class LocationController extends Controller
{
    public function getLocation(Request $request)
    {
        // Get client IP or use a specific IP
        $ip = $request->ip() ?? '8.8.8.8';
        
        // Get location data
        $location = GeoIP::getLocation($ip);
        
        return response()->json([
            'country' => $location['country'],
            'city' => $location['city'],
            'latitude' => $location['lat'],
            'longitude' => $location['lon'],
            'timezone' => $location['timezone']
        ]);
    }
}
?>
```

## 🛠️ Integration

### CDN/CloudFront Integration

```javascript
// Example CloudFront function
const geoip = require('geoip-lite');

exports.handler = async (event) => {
    const request = event.Records[0].cf.request;
    const clientIp = request.clientIp;
    
    const geo = geoip.lookup(clientIp);
    if (geo) {
        request.headers['cloudfront-viewer-country'] = [{
            key: 'CloudFront-Viewer-Country',
            value: geo.country
        }];
    }
    
    return request;
};
```

### Nginx Integration

```nginx
# Load MaxMind module
load_module modules/ngx_http_geoip2_module.so;

http {
    # Define GeoIP2 databases
    geoip2 /path/to/GeoIP2-City.mmdb {
        auto_reload 60m;
        $geoip2_city_country_code country iso_code;
        $geoip2_city_name city names en;
    }
    
    # Use in server block
    server {
        location / {
            add_header X-Country-Code $geoip2_city_country_code;
            add_header X-City $geoip2_city_name;
        }
    }
}
```

## 📋 Requirements

To use these databases in your applications, you'll need:

- **MaxMind databases**: `geoip2` Python library or equivalent
- **IP2Location databases**: `IP2Location` Python library or equivalent
- **IP2Proxy databases**: `IP2Proxy` Python library or equivalent

Install Python libraries:

```bash
pip install geoip2 IP2Location IP2Proxy
```

## 📖 Configuration

### Using Environment Variables

```bash
# For CLI scripts
export GEOIP_API_KEY="your_api_key"
export GEOIP_API_ENDPOINT="https://geoip.ytrack.io/auth"
export GEOIP_TARGET_DIR="/var/lib/geoip"

# For Docker
docker run --rm \
  -e GEOIP_API_KEY=your-api-key \
  -e GEOIP_API_ENDPOINT=https://geoip.ytrack.io/auth \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater:latest
```

### Using Configuration File (Python/Docker)

Create `config.yaml`:
```yaml
api_key: "your_api_key_here"
api_endpoint: "https://geoip.ytrack.io/auth"
target_dir: "/var/lib/geoip"
databases:
  - "GeoIP2-City.mmdb"
  - "GeoIP2-Country.mmdb"
  - "IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN"
max_retries: 5
timeout: 300
```

Then use:
```bash
python scripts/cli/geoip-update.py --config config.yaml
```

### API Authentication

All download methods require an API key. The authentication flow:

1. Client sends POST request with API key in header
2. Server validates key and returns signed download URLs
3. Client downloads databases from provided URLs

Example API call:
```bash
curl -X POST https://geoip.ytrack.io/auth \
  -H "X-API-Key: your-api-key" \
  -H "Content-Type: application/json" \
  -d '{"databases": "all"}'
```

## 🔐 Security

- **API Key Authentication**: All downloads require valid API keys
- **Database Validation**: All databases are validated before distribution
- **Secure Storage**: Databases stored in S3 with controlled access
- **HTTPS Only**: All API endpoints use SSL/TLS encryption
- **License Compliance**: Ensure compliance with MaxMind and IP2Location terms

## 🚀 Deployment Options

### AWS Lambda (Serverless)
See [infrastructure/terraform](infrastructure/terraform) for AWS Lambda deployment using Terraform.

### Docker API Server
See [infrastructure/docker-api](infrastructure/docker-api) for containerized API deployment.

### GitHub Actions CI/CD
- Automated weekly database updates
- Docker image builds on push
- Manual deployment workflows available

## 🤝 Contributing

### Triggering Manual Updates
1. Go to the [Actions tab](https://github.com/ytzcom/geoip/actions)
2. Select "Update GeoIP Databases"
3. Click "Run workflow"

### Adding New Features
1. Fork the repository
2. Create a feature branch
3. Submit a pull request

### Reporting Issues
Please use the [Issues tab](https://github.com/ytzcom/geoip/issues) to report bugs or request features.

## 📄 License

This repository's code is licensed under the MIT License. The GeoIP databases themselves are subject to their respective licenses:

- **MaxMind databases**: [MaxMind End User License Agreement](https://www.maxmind.com/en/geolite2/eula)
- **IP2Location databases**: [IP2Location License Agreement](https://www.ip2location.com/licensing)

## 🔗 Resources

### Documentation
- [CLI Scripts Documentation](scripts/cli/README.md)
- [Docker API Documentation](infrastructure/docker-api/README.md)
- [Kubernetes Deployment](scripts/cli/k8s/README.md)
- [Systemd Service Setup](scripts/cli/systemd/README.md)

### External Links
- [MaxMind GeoIP2](https://www.maxmind.com/en/geoip2-databases)
- [IP2Location](https://www.ip2location.com/)
- [Docker Hub Images](https://hub.docker.com/u/ytzcom)

### Related Projects
- [geoip2](https://github.com/maxmind/GeoIP2-python) - MaxMind Python library
- [IP2Location Python](https://github.com/ip2location/ip2location-python) - IP2Location Python library
- [IP2Proxy Python](https://github.com/ip2location/ip2proxy-python) - IP2Proxy Python library

---

**Last Update:** See [GitHub Actions](https://github.com/ytzcom/geoip/actions/workflows/update-geoip.yml) for latest run
