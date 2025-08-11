# GeoIP Database Updater

![Workflow Status](https://github.com/ytzcom/geoip/workflows/Update%20GeoIP%20Databases/badge.svg)
![Docker Pulls](https://img.shields.io/docker/pulls/ytzcom/geoip-updater)
![Release](https://img.shields.io/github/v/release/ytzcom/geoip)
![Last Update](https://img.shields.io/badge/Last%20Update-2025--08--11%2000:26:03%20UTC-blue)
![Database Count](https://img.shields.io/badge/Databases-7-green)
![MaxMind Databases](https://img.shields.io/badge/MaxMind-4-orange)
![IP2Location Databases](https://img.shields.io/badge/IP2Location-3-purple)

Automated GeoIP database updater for MaxMind and IP2Location databases. This repository automatically downloads, validates, and uploads GeoIP databases to S3 for public distribution. Available as Docker images, Go binaries, and direct database downloads.

## 📅 Update Schedule

Databases are automatically updated **every Monday at midnight UTC**.

## 🚀 Quick Start

### Docker Images

The GeoIP Updater is available as Docker images for easy deployment:

```bash
# Pull the main Python CLI image
docker pull ytzcom/geoip-updater:latest

# Run with your credentials
docker run --rm \
  -e MAXMIND_ACCOUNT_ID=your_account_id \
  -e MAXMIND_LICENSE_KEY=your_license_key \
  -e IP2LOCATION_TOKEN=your_token \
  -v /path/to/geoip:/geoip \
  ytzcom/geoip-updater:latest

# For Kubernetes deployments
docker pull ytzcom/geoip-updater-k8s:latest

# For cron-based updates
docker pull ytzcom/geoip-updater-cron:latest
```

Available Docker images:
- `ytzcom/geoip-scripts` - Scripts-only for 2-line Docker integration
- `ytzcom/geoip-updater` - Python CLI version
- `ytzcom/geoip-updater-cron` - Secure cron with supercronic
- `ytzcom/geoip-updater-k8s` - Kubernetes optimized
- `ytzcom/geoip-updater-go` - Minimal Go binary Docker
- `ytzcom/geoip-api` - FastAPI server with S3 backend
- `ytzcom/geoip-api-nginx` - Production API with Nginx
- `ytzcom/geoip-api-dev` - Development API server

All images support multi-platform (linux/amd64, linux/arm64) and are signed with Cosign.

### Go Binaries

Download pre-compiled binaries for your platform from the [releases page](https://github.com/ytzcom/geoip/releases):

```bash
# Linux AMD64
curl -LO https://github.com/ytzcom/geoip/releases/latest/download/geoip-updater-linux-amd64
chmod +x geoip-updater-linux-amd64
./geoip-updater-linux-amd64 --version

# macOS Apple Silicon
curl -LO https://github.com/ytzcom/geoip/releases/latest/download/geoip-updater-darwin-arm64
chmod +x geoip-updater-darwin-arm64
./geoip-updater-darwin-arm64 --version

# Windows
curl -LO https://github.com/ytzcom/geoip/releases/latest/download/geoip-updater-windows-amd64.exe
geoip-updater-windows-amd64.exe --version
```

Supported platforms:
- **Linux**: amd64, arm64, arm/v7
- **macOS**: amd64 (Intel), arm64 (Apple Silicon)
- **Windows**: amd64, arm64
- **FreeBSD**: amd64

### Direct Download Links

#### MaxMind Databases (MMDB Format)

```bash
# GeoIP2 City Database
curl -O https://ytz-geoip.s3.amazonaws.com/raw/maxmind/GeoIP2-City.mmdb

# GeoIP2 Country Database
curl -O https://ytz-geoip.s3.amazonaws.com/raw/maxmind/GeoIP2-Country.mmdb

# GeoIP2 ISP Database
curl -O https://ytz-geoip.s3.amazonaws.com/raw/maxmind/GeoIP2-ISP.mmdb

# GeoIP2 Connection Type Database
curl -O https://ytz-geoip.s3.amazonaws.com/raw/maxmind/GeoIP2-Connection-Type.mmdb
```

#### IP2Location Databases (BIN Format)

```bash
# IP2Location IPv4 Database
curl -O https://ytz-geoip.s3.amazonaws.com/raw/ip2location/IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN

# IP2Location IPv6 Database
curl -O https://ytz-geoip.s3.amazonaws.com/raw/ip2location/IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN

# IP2Proxy IPv4 Database
curl -O https://ytz-geoip.s3.amazonaws.com/raw/ip2location/IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN
```

### Download Compressed Archives

Compressed archives are also available:

- MaxMind: `https://ytz-geoip.s3.amazonaws.com/compressed/maxmind/[database-name].tar.gz`
- IP2Location: `https://ytz-geoip.s3.amazonaws.com/compressed/ip2location/[database-name].zip`

## 📊 Database Information

| Database | Provider | Format | Size | Description |
|----------|----------|--------|------|-------------|
| GeoIP2-City | MaxMind | MMDB | 114MB | City-level IP geolocation data |
| GeoIP2-Country | MaxMind | MMDB | 8MB | Country-level IP geolocation data |
| GeoIP2-ISP | MaxMind | MMDB | 17MB | ISP and organization data |
| GeoIP2-Connection-Type | MaxMind | MMDB | 11MB | Connection type data |
| DB23 IPv4 | IP2Location | BIN | 633MB | Comprehensive IPv4 geolocation data |
| DB23 IPv6 | IP2Location | BIN | 806MB | Comprehensive IPv6 geolocation data |
| PX2 IPv4 | IP2Location | BIN | 190MB | IPv4 proxy detection data |

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

## 🛠️ Integration

### Docker Compose Example

```yaml
version: '3.8'
services:
  # Option 1: Using cron image for automatic updates
  geoip-updater:
    image: ytzcom/geoip-updater-cron:latest
    environment:
      - GEOIP_API_KEY=${GEOIP_API_KEY}  # Your API key for geoipdb.net
      - GEOIP_API_ENDPOINT=https://geoipdb.net/auth  # Optional, this is the default
      - GEOIP_TARGET_DIR=/geoip
      - GEOIP_UPDATE_SCHEDULE=0 2 * * *  # Daily at 2 AM
    volumes:
      - geoip-data:/geoip
    restart: unless-stopped

  # Option 2: Using scripts image with custom entrypoint
  app-with-geoip:
    build: .
    environment:
      - GEOIP_API_KEY=${GEOIP_API_KEY}
      - GEOIP_DOWNLOAD_ON_START=true
      - GEOIP_SETUP_CRON=true
    volumes:
      - geoip-data:/app/resources/geoip
```

**Note**: The Docker images download databases from the GeoIP API server (geoipdb.net), which serves the databases from S3. You need a `GEOIP_API_KEY` for authentication - you do NOT need MaxMind or IP2Location credentials.

### Kubernetes CronJob

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: geoip-updater
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: geoip-updater
            image: ytzcom/geoip-updater-k8s:latest
            env:
            - name: GEOIP_API_KEY
              valueFrom:
                secretKeyRef:
                  name: geoip-api-credentials
                  key: api-key
            - name: GEOIP_TARGET_DIR
              value: "/geoip"
            volumeMounts:
            - name: geoip-data
              mountPath: /geoip
          volumes:
          - name: geoip-data
            persistentVolumeClaim:
              claimName: geoip-pvc
          restartPolicy: OnFailure
```

### GitHub Actions

For GitHub Actions, you DO need the provider credentials as it downloads directly from MaxMind and IP2Location:

```yaml
- name: Update GeoIP Databases
  uses: ytzcom/geoip@v1
  with:
    maxmind-account-id: ${{ secrets.MAXMIND_ACCOUNT_ID }}
    maxmind-license-key: ${{ secrets.MAXMIND_LICENSE_KEY }}
    ip2location-token: ${{ secrets.IP2LOCATION_TOKEN }}
    directory: ./geoip-data
```

### Docker Multi-Stage Build Integration

Add GeoIP scripts to your existing Docker image:

```dockerfile
# Copy GeoIP scripts from our image
FROM ytzcom/geoip-scripts:latest as geoip
FROM your-base-image

# Copy the scripts
COPY --from=geoip /opt/geoip /opt/geoip

# Set up environment
ENV GEOIP_API_KEY=your-api-key \
    GEOIP_TARGET_DIR=/app/data/geoip \
    GEOIP_DOWNLOAD_ON_START=true

# Use the helper in your entrypoint
ENTRYPOINT ["/bin/sh", "-c", ". /opt/geoip/entrypoint-helper.sh && geoip_init && exec your-app"]
```

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

## 🔑 Authentication & Access

### Direct S3 Downloads (No Authentication Required)
The databases are publicly available on S3. You can download them directly without any API keys using the URLs shown in the Quick Start section.

### Docker Images (API Key Required)
The Docker images use a different approach - they authenticate with the GeoIP API server to download databases:

- **API Endpoint**: `https://geoipdb.net/auth` (or your own API server)
- **Authentication**: Requires `GEOIP_API_KEY` environment variable
- **What it does**: The API server provides download URLs for the databases stored on S3
- **Note**: You do NOT need MaxMind or IP2Location credentials when using Docker images

### GitHub Actions (Provider Credentials Required)
The GitHub Action downloads directly from the providers, so it needs:
- `MAXMIND_ACCOUNT_ID` and `MAXMIND_LICENSE_KEY` for MaxMind databases
- `IP2LOCATION_TOKEN` for IP2Location databases

## 📋 Requirements

To use these databases in your applications, you'll need:

- **MaxMind databases**: `geoip2` Python library or equivalent
- **IP2Location databases**: `IP2Location` Python library or equivalent
- **IP2Proxy databases**: `IP2Proxy` Python library or equivalent

Install Python libraries:

```bash
pip install geoip2 IP2Location IP2Proxy
```

## 🔐 Security

- All databases are validated before upload to ensure integrity
- S3 bucket has public read access for easy distribution
- Original database licenses apply - ensure compliance with MaxMind and IP2Location terms

## 🤝 Contributing

To trigger a manual update:
1. Go to the [Actions tab](https://github.com/ytzcom/geoip/actions)
2. Select "Update GeoIP Databases"
3. Click "Run workflow"

## 📄 License

This repository's code is licensed under the MIT License. The GeoIP databases themselves are subject to their respective licenses:

- MaxMind databases: [MaxMind End User License Agreement](https://www.maxmind.com/en/geolite2/eula)
- IP2Location databases: [IP2Location License Agreement](https://www.ip2location.com/licensing)

## 🔗 Links

- [MaxMind GeoIP2](https://www.maxmind.com/en/geoip2-databases)
- [IP2Location](https://www.ip2location.com/)
- [S3 Bucket](https://ytz-geoip.s3.amazonaws.com/)

---

**Last Update:** 2025-08-11 00:26:03 UTC
