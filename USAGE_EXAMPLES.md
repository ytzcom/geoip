# GeoIP Database Usage Examples

This document shows how to use the downloaded GeoIP databases in various programming languages and frameworks.

## 📋 Requirements

To use these databases in your applications, you'll need:

- **MaxMind databases**: `geoip2` Python library or equivalent
- **IP2Location databases**: `IP2Location` Python library or equivalent
- **IP2Proxy databases**: `IP2Proxy` Python library or equivalent

Install Python libraries:

```bash
pip install geoip2 IP2Location IP2Proxy
```

## Python Examples

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

## PHP Examples

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

## Integration Examples

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

## Node.js Examples

### Using node-geoip

```javascript
const geoip = require('geoip-lite');

// Lookup an IP
const geo = geoip.lookup('8.8.8.8');

if (geo) {
    console.log('Country:', geo.country);
    console.log('Region:', geo.region);
    console.log('City:', geo.city);
    console.log('Coordinates:', geo.ll);
    console.log('Timezone:', geo.timezone);
}
```

### Using maxmind

```javascript
const maxmind = require('maxmind');

// Open the database
const lookup = await maxmind.open('GeoIP2-City.mmdb');

// Lookup an IP
const result = lookup.get('8.8.8.8');

console.log('Country:', result.country.names.en);
console.log('City:', result.city.names.en);
console.log('Location:', result.location);
```

## Go Examples

```go
package main

import (
    "fmt"
    "log"
    "net"
    
    "github.com/oschwald/geoip2-golang"
)

func main() {
    // Open the database
    db, err := geoip2.Open("GeoIP2-City.mmdb")
    if err != nil {
        log.Fatal(err)
    }
    defer db.Close()
    
    // Parse IP
    ip := net.ParseIP("8.8.8.8")
    
    // Lookup
    record, err := db.City(ip)
    if err != nil {
        log.Fatal(err)
    }
    
    fmt.Printf("Country: %v\n", record.Country.Names["en"])
    fmt.Printf("City: %v\n", record.City.Names["en"])
    fmt.Printf("Latitude: %v\n", record.Location.Latitude)
    fmt.Printf("Longitude: %v\n", record.Location.Longitude)
}
```

## Ruby Examples

```ruby
require 'maxmind/geoip2'

# Open the database
reader = MaxMind::GeoIP2::Reader.new('GeoIP2-City.mmdb')

# Lookup an IP
record = reader.city('8.8.8.8')

puts "Country: #{record.country.name}"
puts "City: #{record.city.name}"
puts "Latitude: #{record.location.latitude}"
puts "Longitude: #{record.location.longitude}"

reader.close
```

## Java Examples

```java
import com.maxmind.geoip2.DatabaseReader;
import com.maxmind.geoip2.model.CityResponse;
import java.io.File;
import java.net.InetAddress;

public class GeoIPExample {
    public static void main(String[] args) throws Exception {
        // Open the database
        File database = new File("GeoIP2-City.mmdb");
        DatabaseReader reader = new DatabaseReader.Builder(database).build();
        
        // Lookup an IP
        InetAddress ip = InetAddress.getByName("8.8.8.8");
        CityResponse response = reader.city(ip);
        
        System.out.println("Country: " + response.getCountry().getName());
        System.out.println("City: " + response.getCity().getName());
        System.out.println("Latitude: " + response.getLocation().getLatitude());
        System.out.println("Longitude: " + response.getLocation().getLongitude());
        
        reader.close();
    }
}
```

## C# Examples

```csharp
using MaxMind.GeoIP2;
using System;
using System.Net;

class Program
{
    static void Main()
    {
        // Open the database
        using (var reader = new DatabaseReader("GeoIP2-City.mmdb"))
        {
            // Lookup an IP
            var ip = IPAddress.Parse("8.8.8.8");
            var response = reader.City(ip);
            
            Console.WriteLine($"Country: {response.Country.Name}");
            Console.WriteLine($"City: {response.City.Name}");
            Console.WriteLine($"Latitude: {response.Location.Latitude}");
            Console.WriteLine($"Longitude: {response.Location.Longitude}");
        }
    }
}
```

## Additional Resources

- [MaxMind GeoIP2 Documentation](https://dev.maxmind.com/geoip/)
- [IP2Location Documentation](https://www.ip2location.com/development-libraries)
- [IP2Proxy Documentation](https://www.ip2proxy.com/development-libraries)

## License Notes

Remember that the databases themselves are subject to their respective licenses:

- **MaxMind databases**: [MaxMind End User License Agreement](https://www.maxmind.com/en/geolite2/eula)
- **IP2Location databases**: [IP2Location License Agreement](https://www.ip2location.com/licensing)