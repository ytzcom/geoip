# GeoIP Database Updater

![Workflow Status](https://github.com/ytzcom/geoip/workflows/Update%20GeoIP%20Databases/badge.svg)
![Last Update](https://img.shields.io/badge/Last%20Update-2026--06--08%2016:50:07%20UTC-blue)
![Database Count](https://img.shields.io/badge/Databases-6-green)
![MaxMind Databases](https://img.shields.io/badge/MaxMind-4-orange)
![IP2Location Databases](https://img.shields.io/badge/IP2Location-2-purple)

Automated GeoIP database updater for MaxMind and IP2Location databases. This repository automatically downloads, validates, and stores GeoIP databases in S3, serving them through an authenticated API.

## 📅 Update Schedule

Databases are automatically updated **every Monday at midnight UTC**.

## 🚀 Quick Start

### Getting the databases

Databases are served through an authenticated API — request a short-lived
download URL with your API key, then fetch it. The simplest way is the bundled
CLI tools, which handle authentication and validation for you:

```bash
# Download all databases (see cli/README.md for options and other languages)
./cli/geoip-update.sh -k YOUR_API_KEY
```

Or call the API directly to obtain presigned download URLs:

```bash
curl -s -X POST https://geoipdb.net/auth \
  -H "X-API-Key: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"databases": "all"}'
```

See **[cli/README.md](cli/README.md)** for the bash, PowerShell, Python and Go
clients and database-selection options.

## 📊 Database Information

| Database | Provider | Format | Size | Description |
|----------|----------|--------|------|-------------|
| GeoIP2-City | MaxMind | MMDB | 120MB | City-level IP geolocation data |
| GeoIP2-Country | MaxMind | MMDB | 8MB | Country-level IP geolocation data |
| GeoIP2-ISP | MaxMind | MMDB | 19MB | ISP and organization data |
| GeoIP2-Connection-Type | MaxMind | MMDB | 12MB | Connection type data |
| DB23 IPv4 | IP2Location | BIN | 638MB | Comprehensive IPv4 geolocation data |
| DB23 IPv6 | IP2Location | BIN | 820MB | Comprehensive IPv6 geolocation data |
| PX2 IPv4 | IP2Location | BIN | 366MB | IPv4 proxy detection data |

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
- Databases are served only through the authenticated API, which issues
  short-lived presigned URLs; the storage bucket is not for direct public access
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

- [CLI Tools](cli/README.md)
- [MaxMind GeoIP2](https://www.maxmind.com/en/geoip2-databases)
- [IP2Location](https://www.ip2location.com/)

---

**Last Update:** 2026-06-08 16:50:07 UTC
