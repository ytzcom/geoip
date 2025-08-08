# GeoIP Docker API

A containerized version of the GeoIP authentication API that can be deployed anywhere with Docker. This provides a flexible alternative to the AWS Lambda deployment.

## 🚀 Features

- **GeoIP Query API**:
  - Query up to 50 IP addresses per request
  - Returns geographic and network information
  - Support for both IPv4 and IPv6
  - Essential or full data modes
  - Sub-50ms response time with caching

- **Web User Interface**:
  - Clean, modern UI with Tailwind CSS
  - Batch IP lookup with instant results
  - JSON export functionality
  - URL parameter support for automation

- **Flexible Download Options**:
  - **S3 URLs**: Generate pre-signed URLs for scalability
  - **Direct Serving**: Serve files directly from local storage
  - **Always Local Query**: Fast GeoIP queries using local databases

- **Intelligent Caching**:
  - Multiple cache backends (Memory, Redis, SQLite)
  - Automatic cache invalidation on updates
  - Configurable TTL settings
  - Session-based authentication caching

- **Automatic Database Updates**:
  - Scheduled updates every Monday at 4am
  - Downloads fresh databases from S3
  - Zero-downtime updates
  - Manual trigger via admin endpoints

- **Production Ready**:
  - Health checks and metrics endpoints
  - Multi-worker support with uvicorn
  - Non-root container execution
  - Comprehensive logging
  - CORS support
  - Rate limiting (50 IPs per query)

- **Easy Deployment**:
  - Single command with Docker
  - Docker Compose orchestration
  - Kubernetes compatible
  - Environment-based configuration

## 📋 Quick Start

### 1. Clone and Configure

```bash
# Copy environment template
cp .env.example .env

# Edit .env with your configuration
nano .env
```

### 2. Run with Docker

```bash
# Build and run with docker-compose
docker-compose up -d

# Or run directly with Docker
docker build -t geoip-api .
docker run -p 8080:8080 \
  -e API_KEYS="key1,key2,key3" \
  -e USE_S3_URLS="true" \
  -e S3_BUCKET="your-s3-bucket" \
  -v geoip-databases:/data/databases \
  geoip-api
```

### 3. Access the Services

```bash
# Access the Web UI
open http://localhost:8080

# Health check
curl http://localhost:8080/health

# Query IP addresses
curl -H "X-API-Key: your-api-key" \
  "http://localhost:8080/query?ips=8.8.8.8,1.1.1.1"

# Authenticate and get download URLs
curl -X POST http://localhost:8080/auth \
  -H "X-API-Key: your-api-key" \
  -H "Content-Type: application/json" \
  -d '{"databases": "all"}'
```

## 🔧 Configuration Options

### Download Configuration

The API always maintains local copies of databases for query functionality. The `USE_S3_URLS` flag controls how database downloads are served:

#### Using S3 URLs (Recommended for Production)
Generates pre-signed URLs for scalable database distribution:

```bash
docker run -p 8080:8080 \
  -e API_KEYS="key1,key2" \
  -e USE_S3_URLS="true" \
  -e S3_BUCKET="your-s3-bucket" \
  -e AWS_ACCESS_KEY_ID="your-key" \
  -e AWS_SECRET_ACCESS_KEY="your-secret" \
  -v geoip-databases:/data/databases \
  geoip-api
```

#### Direct File Serving (Local Development)
Serves files directly from local storage:

```bash
docker run -p 8080:8080 \
  -e API_KEYS="key1,key2" \
  -e USE_S3_URLS="false" \
  -v /path/to/geoip/databases:/data/databases:ro \
  geoip-api
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| **Core Configuration** | | |
| `API_KEYS` | Comma-separated list of allowed API keys | *Required* |
| `SESSION_SECRET_KEY` | Secret key for signing session cookies | *Required* |
| **Download Configuration** | | |
| `USE_S3_URLS` | Use S3 pre-signed URLs for downloads | `true` |
| `S3_BUCKET` | S3 bucket name (required when USE_S3_URLS=true) | `ytz-geoip` |
| `AWS_ACCESS_KEY_ID` | AWS credentials (optional, uses IAM role if not set) | - |
| `AWS_SECRET_ACCESS_KEY` | AWS credentials (optional, uses IAM role if not set) | - |
| `AWS_REGION` | AWS region | `us-east-1` |
| `URL_EXPIRY_SECONDS` | Pre-signed URL expiry time | `3600` |
| **Database Configuration** | | |
| `DATABASE_PATH` | Path to GeoIP database files in container | `/data/databases` |
| `DATABASE_UPDATE_SCHEDULE` | Cron schedule for automatic updates | `0 4 * * 1` |
| **Cache Configuration** | | |
| `CACHE_TYPE` | Cache backend: memory, redis, sqlite, none | `memory` |
| `REDIS_URL` | Redis connection URL (if using Redis cache) | - |
| `CACHE_TTL` | Cache TTL in seconds (optional) | Until next update |
| **Query Configuration** | | |
| `QUERY_RATE_LIMIT` | Maximum IPs per query request | `50` |
| **Server Configuration** | | |
| `PORT` | Server port | `8080` |
| `WORKERS` | Number of worker processes | `1` |
| `DEBUG` | Enable debug mode | `false` |
| **Admin Configuration** | | |
| `ENABLE_ADMIN` | Enable admin endpoints | `false` |
| `ADMIN_KEY` | Admin API key (required if admin enabled) | - |
| **Logging** | | |
| `LOG_LEVEL` | Logging level (DEBUG, INFO, WARNING, ERROR) | `INFO` |

## 🐳 Docker Compose Deployments

### Development Setup

```bash
# Use local file serving for development
docker-compose -f docker-compose.local.yml up
```

Features:
- Local file serving
- Hot reload enabled
- Debug logging
- Dev API keys

### Production Setup

```bash
# Production with nginx reverse proxy
docker-compose -f docker-compose.prod.yml up -d
```

Features:
- Nginx reverse proxy
- Rate limiting
- SSL support (configure certificates)
- Multi-worker processes
- Production logging

### Basic Setup

```bash
# Standard deployment
docker-compose up -d
```

## 📁 File Structure

When using the API, organize your GeoIP databases like this:

```
/data/databases/
├── raw/
│   ├── maxmind/
│   │   ├── GeoIP2-City.mmdb
│   │   ├── GeoIP2-Country.mmdb
│   │   ├── GeoIP2-ISP.mmdb
│   │   └── GeoIP2-Connection-Type.mmdb
│   └── ip2location/
│       ├── IP-COUNTRY-REGION-CITY-*.BIN
│       ├── IPV6-COUNTRY-REGION-CITY-*.BIN
│       └── IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN
```

## 🔐 API Endpoints

### GeoIP Query
`GET /query`

Query geographic and network information for IP addresses.

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
    "latitude": 37.386,
    "longitude": -122.0838,
    "is_proxy": false,
    "is_vpn": false,
    "usage_type": "DCH"
  },
  "1.1.1.1": {
    "country": "United States",
    "country_code": "US",
    "city": "Los Angeles",
    "region": "California",
    "isp": "Cloudflare",
    "organization": "Cloudflare Inc",
    "is_proxy": false,
    "is_vpn": false
  }
}
```

### Authentication Endpoint
`POST /auth`

Get download URLs for GeoIP database files.

**Request**:
```json
{
  "databases": "all"  // or ["GeoIP2-City.mmdb", "GeoIP2-Country.mmdb"]
}
```

**Response**:
```json
{
  "GeoIP2-City.mmdb": "https://...",
  "GeoIP2-Country.mmdb": "https://..."
}
```

### Session Management
`POST /login` - Login with API key for session-based auth
```bash
curl -X POST "http://localhost:8080/login?api_key=your-api-key"
```

`POST /logout` - Clear session
```bash
curl -X POST "http://localhost:8080/logout"
```

### Health Check
`GET /health`

**Response**:
```json
{
  "status": "healthy",
  "timestamp": "2024-01-01T00:00:00",
  "use_s3_urls": true,
  "databases_available": 7,
  "databases_local": 7,
  "databases_remote": 7
}
```

### Metrics
`GET /metrics` (requires API key)

**Response**:
```json
{
  "total_requests": 1000,
  "successful_requests": 950,
  "failed_requests": 50,
  "uptime_seconds": 3600
}
```

### Admin Endpoints
Admin endpoints provide operational control and system management capabilities. All admin endpoints require the `X-Admin-Key` header with a valid admin key.

**Prerequisites**: Set `ENABLE_ADMIN=true` and configure `ADMIN_KEY` in your environment.

#### API Key Management
`POST /admin/reload-keys` - Reload API keys from environment
```bash
curl -X POST -H "X-Admin-Key: your-admin-key" \
  http://localhost:8080/admin/reload-keys
```

#### Database Management  
`POST /admin/update-databases` - Trigger manual database update from S3
```bash
curl -X POST -H "X-Admin-Key: your-admin-key" \
  http://localhost:8080/admin/update-databases
```

`GET /admin/databases/status` - Get database loading status
```bash
curl -H "X-Admin-Key: your-admin-key" \
  http://localhost:8080/admin/databases/status
```

`GET /admin/databases/info` - Get database file information (sizes, dates, paths)
```bash
curl -H "X-Admin-Key: your-admin-key" \
  http://localhost:8080/admin/databases/info
```

`POST /admin/databases/reload` - Reload databases without S3 update
```bash
curl -X POST -H "X-Admin-Key: your-admin-key" \
  http://localhost:8080/admin/databases/reload
```

#### Cache Management
`POST /admin/cache/clear` - Clear all cached query results
```bash
curl -X POST -H "X-Admin-Key: your-admin-key" \
  http://localhost:8080/admin/cache/clear
```

`GET /admin/cache/stats` - Get cache statistics and configuration
```bash
curl -H "X-Admin-Key: your-admin-key" \
  http://localhost:8080/admin/cache/stats
```

#### Scheduler Management
`GET /admin/scheduler/info` - Get scheduler information and next run times
```bash
curl -H "X-Admin-Key: your-admin-key" \
  http://localhost:8080/admin/scheduler/info
```

`POST /admin/scheduler/trigger` - Manually trigger scheduled jobs
```bash
curl -X POST -H "X-Admin-Key: your-admin-key" \
  http://localhost:8080/admin/scheduler/trigger?job_id=database_update
```

#### System Status & Configuration
`GET /admin/status` - Get comprehensive system status
```bash
curl -H "X-Admin-Key: your-admin-key" \
  http://localhost:8080/admin/status
```

`GET /admin/config` - Get current configuration (sanitized, no secrets)
```bash
curl -H "X-Admin-Key: your-admin-key" \
  http://localhost:8080/admin/config
```

**Response Example** (admin/status):
```json
{
  "service": {
    "status": "healthy",
    "uptime_seconds": 3600,
    "version": "1.0.0",
    "debug_mode": false
  },
  "databases": {
    "total": 7,
    "loaded": 7,
    "status": {
      "maxmind_city": true,
      "maxmind_country": true,
      "ip2location_v4": true
    }
  },
  "scheduler": {
    "running": true,
    "jobs": [
      {
        "id": "database_update",
        "name": "Update GeoIP databases from S3",
        "next_run": "2024-01-08T04:00:00"
      }
    ]
  },
  "cache": {
    "type": "memory",
    "enabled": true
  }
}
```

### Installation Script
`GET /install`

Get a one-line installer script for GeoIP tools.

**Parameters**:
- `with_cron` (optional): Setup automatic updates via cron
- `install_dir` (optional): Installation directory (default: /opt/geoip)

**Example**:
```bash
curl -sSL "http://localhost:8080/install?with_cron=true" | sh
```

### Direct Download
`GET /download/{database_name}` (requires API key)

Downloads database files directly when `USE_S3_URLS=false`.

## 🌐 Web User Interface

Access the modern web interface at `http://localhost:8080`

### Features
- **Batch IP Lookup**: Enter multiple IPs (one per line or comma-separated)
- **Data Mode Toggle**: Switch between essential and full data display
- **Interactive Results**: Clean table format with expandable details
- **JSON Export**: Copy results as JSON for further processing
- **URL Parameters**: Direct query support via `?ips=8.8.8.8,1.1.1.1`
- **Session Authentication**: Login once, query multiple times

### Usage
1. Open browser to `http://localhost:8080`
2. Enter your API key and click "Authenticate"
3. Input IP addresses in the text area
4. Toggle "Full Data" if needed
5. Click "Query IPs" to get results
6. Click "Details" on any result for complete information
7. Use "Copy as JSON" to export results

## 💾 Caching Configuration

The API includes intelligent caching to improve performance and reduce database load.

### Cache Types

| Type | Description | Use Case |
|------|-------------|----------|
| **memory** | In-memory cache (default) | Single instance, fast responses |
| **redis** | Distributed Redis cache | Multi-instance deployments |
| **sqlite** | Persistent SQLite cache | Survives restarts, single instance |
| **none** | Disable caching | Development/debugging |

### Redis Cache Setup

1. Enable Redis service in docker-compose:
```yaml
services:
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
```

2. Configure environment:
```env
CACHE_TYPE=redis
REDIS_URL=redis://redis:6379
CACHE_TTL=3600  # Optional: override default TTL
```

### Cache Behavior
- Cached results return in <10ms
- Cache automatically clears on database updates (Monday 4am)
- Per-IP caching with full_data flag consideration
- Session-based authentication caching

## 🔄 Database Updates

The API automatically maintains up-to-date GeoIP databases through scheduled downloads from S3.

### Automatic Updates
- **Schedule**: Every Monday at 4am (configurable via `DATABASE_UPDATE_SCHEDULE`)
- **Source**: Downloads from S3 bucket (no direct MaxMind/IP2Location API calls)
- **Zero Downtime**: Updates happen in background without service interruption
- **Cache Invalidation**: Automatically clears cache after updates

### Manual Updates
If admin endpoints are enabled, trigger manual updates:
```bash
curl -X POST -H "X-Admin-Key: your-admin-key" \
  http://localhost:8080/admin/update-databases
```

### Update Configuration
```env
# Cron format: minute hour day month day_of_week
DATABASE_UPDATE_SCHEDULE=0 4 * * 1  # Monday 4am
```

## 📚 Available Databases

The API queries multiple GeoIP databases for comprehensive data:

### MaxMind Databases
- **GeoIP2-City.mmdb**: Country, city, postal code, coordinates
- **GeoIP2-Country.mmdb**: Country-level information
- **GeoIP2-ISP.mmdb**: ISP and organization data
- **GeoIP2-Connection-Type.mmdb**: Connection type (DSL, Cable, etc.)

### IP2Location Databases
- **IP-COUNTRY-REGION-CITY-*.BIN**: Comprehensive IPv4 location data
- **IPV6-COUNTRY-REGION-CITY-*.BIN**: IPv6 location and ISP data
- **IP2PROXY-*.BIN**: Proxy, VPN, TOR detection

## 📊 Response Fields

### Essential Fields (default)
| Field | Description | Example |
|-------|-------------|---------|
| `country` | Country name | "United States" |
| `country_code` | ISO country code | "US" |
| `city` | City name | "Mountain View" |
| `region` | State/province | "California" |
| `postal_code` | ZIP/postal code | "94035" |
| `isp` | Internet Service Provider | "Google LLC" |
| `organization` | Organization name | "Google Public DNS" |
| `timezone` | Timezone identifier | "America/Los_Angeles" |
| `latitude` | Geographic latitude | 37.386 |
| `longitude` | Geographic longitude | -122.0838 |
| `is_proxy` | Proxy detection | false |
| `is_vpn` | VPN detection | false |
| `usage_type` | Usage classification | "DCH" |

### Additional Fields (with full_data=true)
| Field | Description | Example |
|-------|-------------|---------|
| `accuracy_radius` | Location accuracy in km | 5 |
| `autonomous_system_number` | ASN | 15169 |
| `autonomous_system_organization` | AS organization | "Google LLC" |
| `connection_type` | Connection type | "Corporate" |
| `domain` | Associated domain | "google.com" |
| `mobile_brand` | Mobile carrier | "Verizon" |
| `is_tor` | TOR exit node | false |
| `is_datacenter` | Datacenter IP | true |
| `proxy_type` | Proxy classification | "DCH" |
| `threat_types` | Security threats | [] |

### Error Responses
```json
{
  "invalid.ip": {
    "error": "Invalid IP address"
  },
  "192.168.1.1": {
    "error": "Not found"  // Private IP
  }
}
```

## 🚀 Deployment Examples

### Deploy to VPS

```bash
# SSH to your server
ssh user@your-server.com

# Clone the repository
git clone https://github.com/ytzcom/geoip.git
cd geoip-updater/infrastructure/docker-api

# Configure environment
cp .env.example .env
vim .env  # Add your API keys and configuration

# Run with Docker Compose
docker-compose -f docker-compose.prod.yml up -d
```

### Deploy to Kubernetes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: geoip-api
spec:
  replicas: 3
  selector:
    matchLabels:
      app: geoip-api
  template:
    metadata:
      labels:
        app: geoip-api
    spec:
      containers:
      - name: geoip-api
        image: geoip-api:latest
        ports:
        - containerPort: 8080
        env:
        - name: API_KEYS
          valueFrom:
            secretKeyRef:
              name: geoip-secrets
              key: api-keys
        - name: USE_S3_URLS
          value: "true"
        - name: S3_BUCKET
          value: "your-s3-bucket"
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 30
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
```

### Deploy with Docker Swarm

```bash
# Initialize swarm
docker swarm init

# Create secrets
echo "key1,key2,key3" | docker secret create api_keys -

# Deploy stack
docker stack deploy -c docker-compose.prod.yml geoip
```

## 📊 Monitoring

### View Logs

```bash
# View logs
docker-compose logs -f geoip-api

# View last 100 lines
docker-compose logs --tail=100 geoip-api
```

### Health Monitoring

```bash
# Simple health check
watch -n 5 'curl -s http://localhost:8080/health | jq'

# Monitor metrics
watch -n 10 'curl -s -H "X-API-Key: your-key" http://localhost:8080/metrics | jq'
```

## 🧪 Testing

### Automated Test Suite

The project includes a comprehensive test suite (`test.sh`) that validates all API functionality.

#### Running Tests

```bash
# Run all tests with default configuration
./test.sh

# Run with custom API endpoint
API_ENDPOINT=http://your-server:8080 ./test.sh

# Run with custom API key
./test.sh your-api-key

# Run with both custom endpoint and key
API_ENDPOINT=http://your-server:8080 ./test.sh your-api-key
```

#### Test Categories

The test suite covers 40+ test cases across multiple categories:

| Category | Tests | Coverage |
|----------|-------|----------|
| **Health & Status** | 5 | Health check, root endpoint, API info |
| **Authentication** | 8 | API key validation, session management, invalid keys |
| **Query API** | 15 | Single/batch queries, error handling, data modes |
| **Downloads** | 7 | S3 URLs, direct downloads, database availability |
| **Metrics & Admin** | 5 | Usage metrics, admin endpoints (if enabled) |
| **Edge Cases** | 10+ | Rate limits, invalid IPs, timeout handling |

#### Test Configuration

The test script uses these environment variables:
- `API_ENDPOINT`: API base URL (default: `http://localhost:8080`)
- `API_KEY`: Test API key (default: `test-key-1`)
- `DEBUG`: Enable verbose output (set to any value)

#### Example Test Output

```bash
$ ./test.sh
================================
GeoIP API Test Suite
================================
API Endpoint: http://localhost:8080
Using API Key: test-key-1
================================

Running Health Check Tests...
✅ Health check endpoint
✅ Health check returns valid JSON
✅ Health check includes database status

Running Authentication Tests...
✅ Valid API key authentication
✅ Invalid API key rejection
✅ Session-based authentication
✅ Session logout
✅ Query param authentication

Running Query API Tests...
✅ Single IP query
✅ Multiple IP query (batch)
✅ Full data mode
✅ Essential data mode
✅ Invalid IP handling
✅ Private IP handling
✅ IPv6 query support
✅ Mixed IPv4/IPv6 batch

[... more tests ...]

================================
Test Summary
================================
Total Tests: 42
Passed: 42
Failed: 0
Success Rate: 100%
================================
```

#### CI/CD Integration

Include the test suite in your CI/CD pipeline:

```yaml
# GitHub Actions example
- name: Start API
  run: docker-compose up -d
  
- name: Wait for API
  run: |
    for i in {1..30}; do
      if curl -f http://localhost:8080/health; then
        break
      fi
      sleep 2
    done

- name: Run Tests
  run: ./test.sh
  
- name: Check Test Results
  run: |
    if [ $? -ne 0 ]; then
      echo "Tests failed"
      exit 1
    fi
```

#### Docker Test Environment

Run tests in an isolated Docker environment:

```bash
# Build test image
docker build -f Dockerfile.dev -t geoip-api-test .

# Run container with test configuration
docker run -d --name geoip-test \
  -p 8080:8080 \
  -e API_KEYS="test-key-1,test-key-2" \
  -e DEBUG=true \
  geoip-api-test

# Execute tests
./test.sh

# Cleanup
docker stop geoip-test && docker rm geoip-test
```

#### Local Development Testing

For development, use the test environment configuration:

```bash
# Copy test environment
cp .env.test .env

# Start with docker-compose
docker-compose -f docker-compose.local.yml up -d

# Run tests with debug output
DEBUG=1 ./test.sh

# View detailed logs during tests
docker-compose logs -f geoip-api
```

#### Testing Specific Features

Test individual components:

```bash
# Test only health endpoints
./test.sh | grep -A3 "Health Check"

# Test only query API
curl -X GET "http://localhost:8080/query?ips=8.8.8.8" \
  -H "X-API-Key: test-key-1" | jq

# Test caching performance
time curl -H "X-API-Key: test-key-1" \
  "http://localhost:8080/query?ips=1.1.1.1"
  
# Test rate limiting
for i in {1..60}; do
  curl -H "X-API-Key: test-key-1" \
    "http://localhost:8080/query?ips=8.8.8.$i"
done
```

#### Troubleshooting Test Failures

Common test failure causes and solutions:

| Issue | Solution |
|-------|----------|
| Connection refused | Ensure API is running: `docker-compose ps` |
| Authentication failures | Check API_KEYS in .env file |
| Database not found | Wait for database download or check S3 access |
| Timeout errors | Increase health check timeout or wait longer |
| S3 test failures | Verify AWS credentials and bucket permissions |

## 🔧 Advanced Configuration

### Using with External Load Balancer

If you're using an external load balancer (AWS ALB, GCP LB, etc.), you can run multiple containers:

```bash
# Run multiple instances
docker-compose up -d --scale geoip-api=4
```

### Custom Database Paths

To use custom database paths, modify the `AVAILABLE_DATABASES` dictionary in `app.py`:

```python
AVAILABLE_DATABASES = {
    'custom-db.mmdb': 'path/to/custom-db.mmdb',
    # ... your databases
}
```

### SSL/TLS Configuration

For production with SSL:

1. Place certificates in `./ssl/` directory
2. Uncomment HTTPS section in `nginx.conf`
3. Update docker-compose.prod.yml to mount certificates

## 🐛 Troubleshooting

### Container won't start

```bash
# Check logs
docker-compose logs geoip-api

# Verify environment variables
docker-compose config

# Check if port is already in use
lsof -i :8080
```

### Query API Issues

#### No results returned
```bash
# Check if databases are loaded
curl http://localhost:8080/health | jq '.databases_local'

# Verify GeoIP reader status
docker logs geoip-api | grep "GeoIP databases loaded"

# Test with known public IP
curl -H "X-API-Key: your-key" \
  "http://localhost:8080/query?ips=8.8.8.8"
```

#### Databases not loading
```bash
# Check database directory
docker exec geoip-api ls -la /data/databases/raw/

# Verify S3 credentials and bucket
docker exec geoip-api env | grep -E "AWS|S3_BUCKET"

# Manually trigger database update (if admin enabled)
curl -X POST -H "X-Admin-Key: admin-key" \
  http://localhost:8080/admin/update-databases
```

### Caching Issues

#### Redis cache not working
```bash
# Check Redis connectivity
docker exec geoip-api python -c "
import redis
r = redis.from_url('redis://redis:6379')
print(r.ping())
"

# Verify Redis is running
docker-compose ps redis

# Check cache configuration
docker exec geoip-api env | grep -E "CACHE_TYPE|REDIS_URL"
```

#### Cache not clearing after updates
```bash
# Manually clear cache (restart for memory cache)
docker-compose restart geoip-api

# For Redis cache
docker exec redis redis-cli FLUSHALL
```

### Authentication failures

```bash
# Verify API keys are set correctly
docker exec geoip-api env | grep API_KEYS

# Test authentication methods
# Header auth
curl -H "X-API-Key: your-key" \
  "http://localhost:8080/query?ips=8.8.8.8"

# Query param auth
curl "http://localhost:8080/query?ips=8.8.8.8&api_key=your-key"

# Session auth
curl -X POST "http://localhost:8080/login?api_key=your-key" -c cookies.txt
curl -b cookies.txt "http://localhost:8080/query?ips=8.8.8.8"
```

### Web UI Issues

#### Can't access Web UI
```bash
# Check if static files are mounted
docker exec geoip-api ls -la /app/static/

# Verify index.html exists
docker exec geoip-api ls -la /app/static/index.html

# Check for JavaScript errors in browser console
# Open Developer Tools (F12) and check Console tab
```

### S3 access issues

```bash
# Check AWS credentials
docker exec geoip-api env | grep AWS

# Test S3 access
docker exec geoip-api python -c "
import boto3
s3 = boto3.client('s3')
print(s3.list_objects_v2(Bucket='your-s3-bucket', MaxKeys=1))
"

# Check S3 bucket permissions
aws s3 ls s3://your-s3-bucket/raw/ --profile your-profile
```

### Performance Issues

#### Slow query responses
```bash
# Check cache status
curl -H "X-API-Key: your-key" \
  http://localhost:8080/metrics | jq

# Monitor response times
time curl -H "X-API-Key: your-key" \
  "http://localhost:8080/query?ips=8.8.8.8"

# Increase workers for better concurrency
# Edit docker-compose.yml: WORKERS=4
docker-compose up -d
```

## 📈 Performance Tuning

### Optimize for High Traffic

```env
# .env configuration for high traffic
WORKERS=8  # Set to number of CPU cores
USE_S3_URLS=true  # Use S3 URLs for scalability
URL_EXPIRY_SECONDS=7200  # Longer expiry for less S3 calls

# Query API optimization
CACHE_TYPE=redis  # Use Redis for distributed caching
CACHE_TTL=3600  # Cache for 1 hour
QUERY_RATE_LIMIT=50  # Adjust based on needs
```

### Query Performance Optimization

#### Enable Redis Caching
```yaml
# docker-compose.yml
services:
  geoip-api:
    environment:
      - CACHE_TYPE=redis
      - REDIS_URL=redis://redis:6379
    depends_on:
      - redis
  
  redis:
    image: redis:7-alpine
    command: redis-server --maxmemory 512mb --maxmemory-policy allkeys-lru
```

#### Performance Metrics
- **Cached queries**: <10ms response time
- **Fresh queries**: 50-200ms for up to 50 IPs
- **Database load**: ~30 seconds on cold start
- **Memory usage**: ~300MB with all databases loaded

### Memory Optimization

```yaml
# docker-compose.yml
services:
  geoip-api:
    deploy:
      resources:
        limits:
          memory: 1G  # Adjust based on database size
        reservations:
          memory: 512M  # Minimum required
```

### Database Loading Optimization

For faster startup times:
1. Pre-download databases to a volume
2. Mount as read-only for multiple instances
3. Use persistent volumes to avoid re-downloads

```yaml
volumes:
  geoip-databases:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /path/to/pre-downloaded/databases
```

## 🔄 Migration from Lambda

To migrate from the Lambda deployment:

1. **Same API Interface**: The Docker API is compatible with the Lambda version
2. **Update Endpoints**: Change your CLI scripts to point to your Docker deployment
3. **Copy API Keys**: Use the same API keys from your Lambda environment variables

```bash
# Update CLI scripts to use Docker endpoint
export GEOIP_API_ENDPOINT="https://your-server.com/auth"
./geoip-update.sh -k your-api-key
```

## 📝 License

Same as the main project - see LICENSE file.