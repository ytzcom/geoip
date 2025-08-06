# GeoIP Database Updater

![Workflow Status](https://github.com/ytzcom/geoip/workflows/Update%20GeoIP%20Databases/badge.svg)
![Last Update](https://img.shields.io/badge/Last%20Update-2025--07--28%2000:28:14%20UTC-blue)
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
| GeoIP2-City | MaxMind | MMDB | 115MB | City-level IP geolocation data |
| GeoIP2-Country | MaxMind | MMDB | 9MB | Country-level IP geolocation data |
| GeoIP2-ISP | MaxMind | MMDB | 17MB | ISP and organization data |
| GeoIP2-Connection-Type | MaxMind | MMDB | 11MB | Connection type data |
| DB23 IPv4 | IP2Location | BIN | 633MB | Comprehensive IPv4 geolocation data |
| DB23 IPv6 | IP2Location | BIN | 805MB | Comprehensive IPv6 geolocation data |
| PX2 IPv4 | IP2Location | BIN | 192MB | IPv4 proxy detection data |

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

## 🛠️ CLI Tools

For automated downloading with authentication, use the included CLI tools:

```bash
# Install CLI script
cd scripts/cli

# Download with API key
./geoip-update.sh -k YOUR_API_KEY

# Or use Docker
docker run --rm \
  -e GEOIP_API_KEY=your-api-key \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater:latest
```

**Available Scripts:**
- **Bash** (`geoip-update.sh`) - Linux, macOS, BSD
- **PowerShell** (`geoip-update.ps1`) - Windows
- **Python** (`geoip-update.py`) - Cross-platform
- **Go** (`main.go`) - Compiled binary

See [CLI Documentation](scripts/cli/README.md) for detailed usage instructions.

## 🔐 Security

- All databases are validated before upload to ensure integrity
- CLI tools use API key authentication for secure access
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

**Last Update:** 2025-07-28 00:28:14 UTC
