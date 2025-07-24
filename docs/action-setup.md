# GeoIP Cache GitHub Action Setup Guide

This guide explains how to use the GeoIP Cache GitHub Action in your projects to automatically download and cache GeoIP databases.

## Overview

The GeoIP Cache Action provides:
- 🚀 Automatic downloading of GeoIP databases from S3
- 💾 Intelligent caching to reduce download time and bandwidth
- 🔐 API key authentication for controlled access
- ✅ Built-in validation of database files
- 📊 Support for both MaxMind and IP2Location databases

## Prerequisites

1. **API Key**: You need a valid GeoIP API key. Contact the repository maintainer to request one.
2. **GitHub Repository**: The action can be used in any GitHub repository
3. **Runner**: Works on `ubuntu-latest`, `macos-latest`, and `windows-latest` runners

## Quick Start

### 1. Store Your API Key

Add your API key as a GitHub secret:

1. Go to your repository's Settings → Secrets and variables → Actions
2. Click "New repository secret"
3. Name: `GEOIP_API_KEY`
4. Value: Your API key (format: `geoip_xxxxxxxxxxxxx`)

### 2. Add to Your Workflow

Add the action to your workflow file (`.github/workflows/your-workflow.yml`):

```yaml
name: My Workflow
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup GeoIP databases
        uses: ytzcom/geoip@v1
        with:
          api-key: ${{ secrets.GEOIP_API_KEY }}
      
      - name: Run tests
        run: |
          # GeoIP databases are now available at ./geoip/
          python test_geoip.py
```

## Configuration Options

### Basic Configuration

```yaml
- uses: ytzcom/geoip@v1
  with:
    api-key: ${{ secrets.GEOIP_API_KEY }}  # Required
    path: ./geoip                          # Optional (default: ./geoip)
    databases: all                         # Optional (default: all)
    cache-refresh: weekly                  # Optional (default: weekly)
    validate: true                         # Optional (default: true)
```

### Input Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `api-key` | Yes | - | Your GeoIP API key |
| `path` | No | `./geoip` | Directory to store databases |
| `databases` | No | `all` | Databases to download (see list below) |
| `cache-key-prefix` | No | `geoip` | Prefix for cache key |
| `cache-refresh` | No | `weekly` | Cache refresh period: `daily`, `weekly`, `monthly` |
| `validate` | No | `true` | Validate downloaded files |
| `fail-on-error` | No | `true` | Fail the action on download/validation errors |

### Available Databases

You can specify individual databases or use `all` to download everything:

**MaxMind Databases (MMDB format):**
- `GeoIP2-City.mmdb` - City-level geolocation (115MB)
- `GeoIP2-Country.mmdb` - Country-level geolocation (9MB)
- `GeoIP2-ISP.mmdb` - ISP information (17MB)
- `GeoIP2-Connection-Type.mmdb` - Connection type data (11MB)

**IP2Location Databases (BIN format):**
- `IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN` - IPv4 comprehensive (633MB)
- `IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN` - IPv6 comprehensive (805MB)
- `IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN` - Proxy detection (193MB)

### Outputs

The action provides these outputs:

| Output | Description |
|--------|-------------|
| `cache-hit` | Whether cache was hit (`true` or `false`) |
| `path` | Path where databases are stored |
| `databases-downloaded` | Comma-separated list of downloaded databases |

## Usage Examples

### Download Specific Databases

```yaml
- name: Setup GeoIP databases
  uses: ytzcom/geoip@v1
  with:
    api-key: ${{ secrets.GEOIP_API_KEY }}
    databases: GeoIP2-City.mmdb,GeoIP2-Country.mmdb
```

### Custom Path and Daily Cache

```yaml
- name: Setup GeoIP databases
  uses: ytzcom/geoip@v1
  with:
    api-key: ${{ secrets.GEOIP_API_KEY }}
    path: ./resources/geoip
    cache-refresh: daily
```

### Use Action Outputs

```yaml
- name: Setup GeoIP databases
  id: geoip
  uses: ytzcom/geoip@v1
  with:
    api-key: ${{ secrets.GEOIP_API_KEY }}

- name: Display results
  run: |
    echo "Cache hit: ${{ steps.geoip.outputs.cache-hit }}"
    echo "Path: ${{ steps.geoip.outputs.path }}"
    echo "Databases: ${{ steps.geoip.outputs.databases-downloaded }}"
```

### Matrix Strategy with Different Databases

```yaml
strategy:
  matrix:
    database-set:
      - name: "MaxMind Only"
        databases: "GeoIP2-City.mmdb,GeoIP2-Country.mmdb"
      - name: "IP2Location Only"
        databases: "IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN"

steps:
  - uses: ytzcom/geoip@v1
    with:
      api-key: ${{ secrets.GEOIP_API_KEY }}
      databases: ${{ matrix.database-set.databases }}
```

## Cache Behavior

The action uses GitHub's cache action internally with intelligent cache keys:

- **Daily**: New cache every day (for frequently updated data)
- **Weekly**: New cache every week (recommended for most use cases)
- **Monthly**: New cache every month (for stable data)

Cache keys include the OS to ensure compatibility:
- `geoip-ubuntu-latest-2024-W15` (weekly, week 15)
- `geoip-macos-latest-2024-03` (monthly, March)
- `geoip-windows-latest-2024-103` (daily, day 103)

## Python Usage Example

```python
import geoip2.database
import IP2Location

# MaxMind database
with geoip2.database.Reader('./geoip/GeoIP2-City.mmdb') as reader:
    response = reader.city('8.8.8.8')
    print(f"Location: {response.city.name}, {response.country.name}")

# IP2Location database
db = IP2Location.IP2Location('./geoip/IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN')
result = db.get_all('8.8.8.8')
print(f"ISP: {result.isp}")
```

## Troubleshooting

### Authentication Failed

```
❌ Authentication failed with status code: 401
```

**Solution**: Check that your API key is valid and properly stored as a secret.

### Rate Limit Exceeded

```
❌ Authentication failed with status code: 429
```

**Solution**: You've exceeded the rate limit (default: 100 requests/hour). Wait and try again.

### Download Failed

```
❌ Failed to download GeoIP2-City.mmdb
```

**Possible causes**:
1. Network connectivity issues
2. S3 bucket temporarily unavailable
3. Invalid database name

### Validation Failed

```
❌ Invalid MaxMind database file: Error opening database
```

**Solution**: The downloaded file may be corrupted. Clear cache and retry.

## Best Practices

1. **Use Secrets**: Always store your API key as a GitHub secret
2. **Choose Appropriate Cache**: Use `weekly` for most cases, `daily` only if needed
3. **Download Only What You Need**: Specify databases to reduce download time
4. **Handle Failures Gracefully**: Set `fail-on-error: false` for non-critical workflows
5. **Monitor Usage**: Check your API key statistics regularly

## API Key Management

To request an API key:
1. Contact the repository maintainer
2. Provide your use case and expected usage
3. You'll receive an API key via secure channel

To check your usage:
- Contact the maintainer for usage statistics
- Monitor rate limit headers in responses

## Security

- API keys are transmitted over HTTPS only
- Pre-signed URLs expire after 1 hour
- All requests are logged for security audit
- Database files are validated before use

## Support

For issues or questions:
1. Check the [troubleshooting section](#troubleshooting)
2. Open an issue in the [GitHub repository](https://github.com/ytzcom/geoip/issues)
3. Contact the maintainer for API key issues

## License

The action code is MIT licensed. The GeoIP databases are subject to their respective licenses:
- [MaxMind EULA](https://www.maxmind.com/en/geolite2/eula)
- [IP2Location License](https://www.ip2location.com/licensing)