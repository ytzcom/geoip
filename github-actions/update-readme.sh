#!/bin/bash

# Update README.sh - Updates README with latest database status
# Usage: ./update-readme.sh <timestamp> <total_count> <maxmind_count> <ip2location_count> [s3_bucket]

TIMESTAMP="$1"
TOTAL_COUNT="$2"
MAXMIND_COUNT="$3"
IP2LOCATION_COUNT="$4"
S3_BUCKET="${5:-ytz-geoip}"

# Create URL-encoded version of timestamp for badge (replace spaces with %20 and escape dashes)
TIMESTAMP_BADGE=$(echo "$TIMESTAMP" | sed 's/ /%20/g' | sed 's/-/--/g')

# Get file sizes from S3
echo "Fetching file sizes from S3..."

# Function to get human-readable file size
get_file_size() {
    local bucket="$1"
    local key="$2"
    local size_bytes=$(aws s3api head-object --bucket "$bucket" --key "$key" 2>/dev/null | jq -r '.ContentLength // 0')
    
    if [ "$size_bytes" -eq 0 ]; then
        echo "N/A"
    elif [ "$size_bytes" -lt 1024 ]; then
        echo "${size_bytes}B"
    elif [ "$size_bytes" -lt 1048576 ]; then
        echo "$((size_bytes / 1024))KB"
    elif [ "$size_bytes" -lt 1073741824 ]; then
        echo "$((size_bytes / 1048576))MB"
    else
        echo "$((size_bytes / 1073741824))GB"
    fi
}

# Get sizes for each database
CITY_SIZE=$(get_file_size "$S3_BUCKET" "raw/maxmind/GeoIP2-City.mmdb")
COUNTRY_SIZE=$(get_file_size "$S3_BUCKET" "raw/maxmind/GeoIP2-Country.mmdb")
ISP_SIZE=$(get_file_size "$S3_BUCKET" "raw/maxmind/GeoIP2-ISP.mmdb")
CONNECTION_SIZE=$(get_file_size "$S3_BUCKET" "raw/maxmind/GeoIP2-Connection-Type.mmdb")

DB23_BIN_SIZE=$(get_file_size "$S3_BUCKET" "raw/ip2location/IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN")
DB23_BIN6_SIZE=$(get_file_size "$S3_BUCKET" "raw/ip2location/IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN")
PX2_BIN_SIZE=$(get_file_size "$S3_BUCKET" "raw/ip2location/IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN")

# Create README content
cat > README.md << 'EOF'
# GeoIP Database Updater

![Workflow Status](https://github.com/ytzcom/geoip/workflows/Update%20GeoIP%20Databases/badge.svg)
![Last Update](https://img.shields.io/badge/Last%20Update-TIMESTAMP_BADGE_PLACEHOLDER-blue)
![Database Count](https://img.shields.io/badge/Databases-TOTAL_PLACEHOLDER-green)
![MaxMind Databases](https://img.shields.io/badge/MaxMind-MAXMIND_PLACEHOLDER-orange)
![IP2Location Databases](https://img.shields.io/badge/IP2Location-IP2LOCATION_PLACEHOLDER-purple)

Automated GeoIP database updater for MaxMind and IP2Location databases. This repository automatically downloads, validates, and uploads GeoIP databases to S3 for public distribution.

## 📅 Update Schedule

Databases are automatically updated **every Monday at midnight UTC**.

## 🚀 Quick Start

### Direct Download Links

#### MaxMind Databases (MMDB Format)

```bash
# GeoIP2 City Database
curl -O https://S3_BUCKET_PLACEHOLDER.s3.amazonaws.com/raw/maxmind/GeoIP2-City.mmdb

# GeoIP2 Country Database
curl -O https://S3_BUCKET_PLACEHOLDER.s3.amazonaws.com/raw/maxmind/GeoIP2-Country.mmdb

# GeoIP2 ISP Database
curl -O https://S3_BUCKET_PLACEHOLDER.s3.amazonaws.com/raw/maxmind/GeoIP2-ISP.mmdb

# GeoIP2 Connection Type Database
curl -O https://S3_BUCKET_PLACEHOLDER.s3.amazonaws.com/raw/maxmind/GeoIP2-Connection-Type.mmdb
```

#### IP2Location Databases (BIN Format)

```bash
# IP2Location IPv4 Database
curl -O https://S3_BUCKET_PLACEHOLDER.s3.amazonaws.com/raw/ip2location/IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN

# IP2Location IPv6 Database
curl -O https://S3_BUCKET_PLACEHOLDER.s3.amazonaws.com/raw/ip2location/IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN

# IP2Proxy IPv4 Database
curl -O https://S3_BUCKET_PLACEHOLDER.s3.amazonaws.com/raw/ip2location/IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN
```

### Download Compressed Archives

Compressed archives are also available:

- MaxMind: `https://S3_BUCKET_PLACEHOLDER.s3.amazonaws.com/compressed/maxmind/[database-name].tar.gz`
- IP2Location: `https://S3_BUCKET_PLACEHOLDER.s3.amazonaws.com/compressed/ip2location/[database-name].zip`

## 📊 Database Information

| Database | Provider | Format | Size | Description |
|----------|----------|--------|------|-------------|
| GeoIP2-City | MaxMind | MMDB | CITY_SIZE_PLACEHOLDER | City-level IP geolocation data |
| GeoIP2-Country | MaxMind | MMDB | COUNTRY_SIZE_PLACEHOLDER | Country-level IP geolocation data |
| GeoIP2-ISP | MaxMind | MMDB | ISP_SIZE_PLACEHOLDER | ISP and organization data |
| GeoIP2-Connection-Type | MaxMind | MMDB | CONNECTION_SIZE_PLACEHOLDER | Connection type data |
| DB23 IPv4 | IP2Location | BIN | DB23_BIN_SIZE_PLACEHOLDER | Comprehensive IPv4 geolocation data |
| DB23 IPv6 | IP2Location | BIN | DB23_BIN6_SIZE_PLACEHOLDER | Comprehensive IPv6 geolocation data |
| PX2 IPv4 | IP2Location | BIN | PX2_BIN_SIZE_PLACEHOLDER | IPv4 proxy detection data |

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
- [S3 Bucket](https://S3_BUCKET_PLACEHOLDER.s3.amazonaws.com/)

---

**Last Update:** TIMESTAMP_PLACEHOLDER
EOF

# Replace placeholders with actual values
sed -i.bak "s/TIMESTAMP_BADGE_PLACEHOLDER/${TIMESTAMP_BADGE}/g" README.md
sed -i.bak "s/TIMESTAMP_PLACEHOLDER/${TIMESTAMP}/g" README.md
sed -i.bak "s/TOTAL_PLACEHOLDER/${TOTAL_COUNT}/g" README.md
sed -i.bak "s/MAXMIND_PLACEHOLDER/${MAXMIND_COUNT}/g" README.md
sed -i.bak "s/IP2LOCATION_PLACEHOLDER/${IP2LOCATION_COUNT}/g" README.md
sed -i.bak "s/S3_BUCKET_PLACEHOLDER/${S3_BUCKET}/g" README.md

# Replace size placeholders
sed -i.bak "s/CITY_SIZE_PLACEHOLDER/${CITY_SIZE}/g" README.md
sed -i.bak "s/COUNTRY_SIZE_PLACEHOLDER/${COUNTRY_SIZE}/g" README.md
sed -i.bak "s/ISP_SIZE_PLACEHOLDER/${ISP_SIZE}/g" README.md
sed -i.bak "s/CONNECTION_SIZE_PLACEHOLDER/${CONNECTION_SIZE}/g" README.md
sed -i.bak "s/DB23_BIN_SIZE_PLACEHOLDER/${DB23_BIN_SIZE}/g" README.md
sed -i.bak "s/DB23_BIN6_SIZE_PLACEHOLDER/${DB23_BIN6_SIZE}/g" README.md
sed -i.bak "s/PX2_BIN_SIZE_PLACEHOLDER/${PX2_BIN_SIZE}/g" README.md

# Clean up backup file
rm -f README.md.bak

echo "✅ README.md updated successfully"