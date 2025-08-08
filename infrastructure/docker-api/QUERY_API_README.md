# GeoIP Query API Documentation

## Overview

The GeoIP API now includes a powerful query endpoint that allows you to look up geographic and network information for IP addresses. The API maintains local copies of all GeoIP databases (MaxMind and IP2Location) and provides both a web UI and programmatic API access.

## Features

- **Query Endpoint**: Look up data for up to 50 IP addresses per request
- **Web UI**: Clean, modern interface using Tailwind CSS and Alpine.js
- **Multiple Auth Methods**: API key via header, query param, or session
- **Caching**: Configurable caching with memory, Redis, or SQLite backends
- **Automatic Updates**: Databases update from S3 every Monday at 4am
- **Full or Partial Data**: Choose between essential fields or complete data

## Quick Start

### Using Docker Compose

1. Create a `.env` file with your configuration:

```bash
# Required
API_KEYS=your-api-key-1,your-api-key-2

# AWS credentials for downloading from S3
AWS_ACCESS_KEY_ID=your-aws-key
AWS_SECRET_ACCESS_KEY=your-aws-secret

# Optional cache configuration
CACHE_TYPE=memory  # or redis, sqlite, none
# REDIS_URL=redis://localhost:6379  # if using Redis

# Session secret (generate a secure random key)
SESSION_SECRET_KEY=your-secure-random-key
```

2. Start the service:

```bash
docker-compose up -d
```

3. Access the web UI at `http://localhost:8080`

## API Usage

### Query Endpoint

**Endpoint**: `GET /query`

**Authentication** (use one of):
- Header: `X-API-Key: your-api-key`
- Query param: `?api_key=your-api-key`
- Session cookie (set via web UI or `/login`)

**Parameters**:
- `ips` (required): Comma-separated IP addresses (max 50)
- `full_data` (optional): `true` for all fields, `false` for essential only (default: false)

**Example Request**:

```bash
curl -H "X-API-Key: your-api-key" \
  "http://localhost:8080/query?ips=8.8.8.8,1.1.1.1&full_data=false"
```

**Example Response**:

```json
{
  "8.8.8.8": {
    "country": "United States",
    "country_code": "US",
    "city": "Mountain View",
    "region": "California",
    "postal_code": "94035",
    "isp": "Google LLC",
    "organization": "Google Public DNS",
    "timezone": "America/Los_Angeles",
    "is_proxy": false,
    "is_vpn": false,
    "usage_type": "DCH"
  },
  "1.1.1.1": {
    "country": "United States",
    "country_code": "US",
    "city": "Los Angeles",
    "isp": "Cloudflare",
    "organization": "Cloudflare Inc",
    "is_proxy": false,
    "is_vpn": false
  }
}
```

## Web UI

Access the web interface at `http://localhost:8080`

Features:
- Enter IPs in a textarea (one per line or comma-separated)
- Toggle between essential and full data
- View results in a clean table format
- Click "Details" for complete information
- Copy results as JSON
- URL parameters support: `http://localhost:8080?ips=8.8.8.8,1.1.1.1`

## Caching

The API caches query results to improve performance. Cache is automatically cleared every Monday at 4am when databases update.

### Cache Types

1. **Memory** (default): Fast in-memory cache
2. **Redis**: Distributed cache for multi-instance deployments
3. **SQLite**: Persistent cache that survives restarts
4. **None**: Disable caching

### Configure Redis Cache

1. Uncomment Redis service in `docker-compose.yml`
2. Set environment variables:
```bash
CACHE_TYPE=redis
REDIS_URL=redis://redis:6379
```

## Database Updates

The API automatically downloads fresh databases from S3 every Monday at 4am. This ensures:
- Always up-to-date GeoIP data
- Consistency with GitHub Actions updates
- No direct provider API calls needed

Manual update trigger (if admin endpoints enabled):
```bash
curl -X POST -H "X-Admin-Key: your-admin-key" \
  http://localhost:8080/admin/update-databases
```

## Available Databases

The API queries all available databases:

**MaxMind**:
- GeoIP2-City (country, city, location data)
- GeoIP2-Country (country information)
- GeoIP2-ISP (ISP and organization data)
- GeoIP2-Connection-Type (connection type info)

**IP2Location**:
- DB23 IPv4 (comprehensive location and ISP data)
- DB23 IPv6 (IPv6 location and ISP data)
- IP2Proxy (proxy, VPN, TOR detection)

## Response Fields

### Essential Fields (default)
- `country`, `country_code`: Country name and ISO code
- `city`: City name
- `region`: State/province/region
- `postal_code`: Postal/ZIP code
- `isp`: Internet Service Provider
- `organization`: Organization name
- `timezone`: Timezone identifier
- `is_proxy`, `is_vpn`: Proxy/VPN detection
- `usage_type`: Usage classification (ISP, DCH, etc.)
- `latitude`, `longitude`: Geographic coordinates

### Additional Fields (with full_data=true)
- `accuracy_radius`: Location accuracy in km
- `autonomous_system_number`: ASN
- `autonomous_system_organization`: AS organization
- `connection_type`: Connection type
- `domain`: Associated domain
- `mobile_brand`: Mobile carrier info
- `is_tor`, `is_datacenter`: Additional proxy types
- `proxy_type`: Detailed proxy classification

## Error Handling

The API returns specific error messages for each IP:

```json
{
  "invalid.ip": {
    "error": "Invalid IP address"
  },
  "192.168.1.1": {
    "error": "Not found"
  }
}
```

## Performance

- Query up to 50 IPs per request
- Cached results return in <10ms
- Fresh queries typically complete in 50-200ms
- Automatic rate limiting at 50 IPs per query

## Security

- All endpoints require API key authentication
- Session cookies are signed and secure
- Input validation prevents injection attacks
- URL length limited to 2083 characters for compatibility

## Monitoring

Check service health:
```bash
curl http://localhost:8080/health
```

View metrics (requires API key):
```bash
curl -H "X-API-Key: your-api-key" http://localhost:8080/metrics
```

## Troubleshooting

### Databases not loading
- Check Docker logs: `docker logs geoip-api`
- Verify S3 credentials are correct
- Ensure databases exist in S3 bucket
- Check database path permissions

### Cache not working
- Verify cache type in environment
- For Redis: ensure Redis is running
- Check cache-related logs

### Authentication issues
- Verify API_KEYS environment variable is set
- Check API key format (no spaces)
- Clear browser cookies if session issues

## Development

### Build the Docker image
```bash
docker build -t geoip-api ./infrastructure/docker-api
```

### Run with Redis caching
```bash
docker-compose --profile with-redis up
```

### Test the query endpoint
```bash
# Single IP
curl -H "X-API-Key: test-key" "http://localhost:8080/query?ips=8.8.8.8"

# Multiple IPs with full data
curl -H "X-API-Key: test-key" \
  "http://localhost:8080/query?ips=8.8.8.8,1.1.1.1,208.67.222.222&full_data=true"
```

## License

See main project LICENSE file.