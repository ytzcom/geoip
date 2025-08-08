# GeoIP Docker API

A containerized version of the GeoIP authentication API that can be deployed anywhere with Docker. This provides a flexible alternative to the AWS Lambda deployment.

## 🚀 Features

- **Flexible Download Options**:
  - **S3 URLs**: Generate pre-signed URLs for scalability
  - **Direct Serving**: Serve files directly from local storage
  - **Always Local Query**: Fast GeoIP queries using local databases

- **Production Ready**:
  - Health checks and metrics endpoints
  - Multi-worker support with uvicorn
  - Non-root container execution
  - Comprehensive logging
  - CORS support

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

### 3. Test the API

```bash
# Health check
curl http://localhost:8080/health

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
| `API_KEYS` | Comma-separated list of allowed API keys | *Required* |
| `USE_S3_URLS` | Use S3 pre-signed URLs for downloads | `true` |
| `S3_BUCKET` | S3 bucket name (required when USE_S3_URLS=true) | `your-s3-bucket` |
| `AWS_ACCESS_KEY_ID` | AWS credentials (optional, uses IAM role if not set) | - |
| `AWS_SECRET_ACCESS_KEY` | AWS credentials (optional, uses IAM role if not set) | - |
| `AWS_REGION` | AWS region | `us-east-1` |
| `URL_EXPIRY_SECONDS` | Pre-signed URL expiry time | `3600` |
| `DATABASE_PATH` | Path to GeoIP database files in container | `/data/databases` |
| `PORT` | Server port | `8080` |
| `WORKERS` | Number of worker processes | `1` |
| `DEBUG` | Enable debug mode | `false` |
| `ENABLE_ADMIN` | Enable admin endpoints | `false` |
| `ADMIN_KEY` | Admin API key (required if admin enabled) | - |
| `LOG_LEVEL` | Logging level | `INFO` |

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

### Authentication Endpoint
`POST /auth`

Request:
```json
{
  "databases": "all"  // or ["GeoIP2-City.mmdb", "GeoIP2-Country.mmdb"]
}
```

Response:
```json
{
  "GeoIP2-City.mmdb": "https://...",
  "GeoIP2-Country.mmdb": "https://..."
}
```

### Health Check
`GET /health`

Response:
```json
{
  "status": "healthy",
  "timestamp": "2024-01-01T00:00:00",
  "use_s3_urls": true,
  "databases_available": 7
}
```

### Metrics
`GET /metrics` (requires API key)

Response:
```json
{
  "total_requests": 1000,
  "successful_requests": 950,
  "failed_requests": 50,
  "uptime_seconds": 3600
}
```

### Direct Download (when USE_S3_URLS=false)
`GET /download/{database_name}` (requires API key)

Downloads the database file directly.

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
```

### Authentication failures

```bash
# Verify API keys are set correctly
docker exec geoip-api env | grep API_KEYS

# Test with curl
curl -v -X POST http://localhost:8080/auth \
  -H "X-API-Key: your-key" \
  -H "Content-Type: application/json" \
  -d '{"databases": "all"}'
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
```

## 📈 Performance Tuning

### Optimize for High Traffic

```env
# .env configuration for high traffic
WORKERS=8  # Set to number of CPU cores
USE_S3_URLS=true  # Use S3 URLs for scalability
URL_EXPIRY_SECONDS=7200  # Longer expiry for less S3 calls
```

### Memory Optimization

```yaml
# docker-compose.yml
services:
  geoip-api:
    deploy:
      resources:
        limits:
          memory: 1G
        reservations:
          memory: 512M
```

## 🔄 Migration from Lambda

To migrate from the Lambda deployment:

1. **Same API Interface**: The Docker API is compatible with the Lambda version
2. **Update Endpoints**: Change your CLI scripts to point to your Docker deployment
3. **Copy API Keys**: Use the same API keys from your Lambda environment variables

```bash
# Update CLI scripts to use Docker endpoint
export GEOIP_API_ENDPOINT="http://your-server.com/auth"
./geoip-update.sh -k your-api-key
```

## 📝 License

Same as the main project - see LICENSE file.