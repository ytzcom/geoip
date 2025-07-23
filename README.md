# GeoIP Database Updater

![Workflow Status](https://github.com/ytzcom/geoip-updater/workflows/Update%20GeoIP%20Databases/badge.svg)
![Last Update](https://img.shields.io/badge/Last%20Update-Not%20Yet%20Run-blue)
![Database Count](https://img.shields.io/badge/Databases-7-green)
![MaxMind Databases](https://img.shields.io/badge/MaxMind-4-orange)
![IP2Location Databases](https://img.shields.io/badge/IP2Location-3-purple)

Automated GeoIP database updater for MaxMind and IP2Location databases. This repository automatically downloads, validates, and uploads GeoIP databases to S3 for public distribution.

## 📅 Update Schedule

Databases are automatically updated **every Monday at midnight UTC**.

## 🚀 Quick Start

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
| GeoIP2-City | MaxMind | MMDB | TBD | City-level IP geolocation data |
| GeoIP2-Country | MaxMind | MMDB | TBD | Country-level IP geolocation data |
| GeoIP2-ISP | MaxMind | MMDB | TBD | ISP and organization data |
| GeoIP2-Connection-Type | MaxMind | MMDB | TBD | Connection type data |
| DB23 IPv4 | IP2Location | BIN | TBD | Comprehensive IPv4 geolocation data |
| DB23 IPv6 | IP2Location | BIN | TBD | Comprehensive IPv6 geolocation data |
| PX2 IPv4 | IP2Location | BIN | TBD | IPv4 proxy detection data |

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

## ⚙️ Configuration

### S3 Bucket Configuration

By default, the workflow uses the `ytz-geoip` S3 bucket. To use a different bucket:

1. Set the `S3_BUCKET` secret in your GitHub repository settings
2. Ensure your AWS credentials have the necessary permissions for the bucket
3. The bucket should allow public read access for distribution

### Environment Variables

See `.env.example` for all available configuration options:
- `S3_BUCKET`: Your S3 bucket name (defaults to `ytz-geoip`)
- `AWS_ACCESS_KEY_ID`: AWS access key with S3 permissions
- `AWS_SECRET_ACCESS_KEY`: AWS secret key
- `MAXMIND_ACCOUNT_ID`: MaxMind account ID
- `MAXMIND_LICENSE_KEY`: MaxMind license key
- `IP2LOCATION_TOKEN`: IP2Location download token

## 🔔 Notifications

The workflow includes automatic failure notifications:
- **GitHub Actions Summary**: Always created on failure with detailed error information
- **Slack Notifications**: Configure via `SLACK_WEBHOOK_URL` secret
- **GitHub Issues**: Enable via `CREATE_ISSUE_ON_FAILURE` variable

See [docs/notifications.md](docs/notifications.md) for setup instructions.

## 🤝 Contributing

To trigger a manual update:
1. Go to the [Actions tab](https://github.com/ytzcom/geoip-updater/actions)
2. Select "Update GeoIP Databases"
3. Click "Run workflow"
4. Optionally configure notification and debug settings

## 📄 License

This repository's code is licensed under the MIT License. The GeoIP databases themselves are subject to their respective licenses:

- MaxMind databases: [MaxMind End User License Agreement](https://www.maxmind.com/en/geolite2/eula)
- IP2Location databases: [IP2Location License Agreement](https://www.ip2location.com/licensing)

## 🔗 Links

- [MaxMind GeoIP2](https://www.maxmind.com/en/geoip2-databases)
- [IP2Location](https://www.ip2location.com/)
- [Default S3 Bucket](https://ytz-geoip.s3.amazonaws.com/)

---

**Last Update:** Not Yet Run