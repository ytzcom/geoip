# GeoIP Updater Docker Setup

Containerized GeoIP database updater with automated scheduling support.

## Quick Start

### 1. Configure Environment

```bash
cd scripts/cli/docker
cp .env.example .env
# Edit .env with your API key and endpoint
```

### 2. Build Images

```bash
docker-compose build
```

### 3. Run One-Time Update

```bash
# Download all databases
docker-compose run --rm geoip-updater

# Download specific databases
docker-compose run --rm geoip-updater --databases GeoIP2-City.mmdb --databases GeoIP2-Country.mmdb
```

### 4. Run Scheduled Updates

```bash
# Start the cron container for automated updates
docker-compose up -d geoip-cron

# View logs
docker-compose logs -f geoip-cron
```

## Docker Images

### Base Image (`geoip-updater`)
- **Purpose**: One-time or manual database updates
- **Size**: ~150MB
- **User**: Runs as non-root user (UID 1000)
- **Python**: 3.11-slim base

### Cron Image (`geoip-updater-cron`)
- **Purpose**: Scheduled automatic updates
- **Size**: ~160MB
- **Schedule**: Configurable via CRON_SCHEDULE env var
- **Default**: Daily at 2 AM

## Volume Management

### Data Volume
Stores downloaded GeoIP databases:
```bash
# List databases
docker volume ls | grep geoip-data

# Inspect volume
docker volume inspect docker_geoip-data

# Access databases from host
docker run --rm -v docker_geoip-data:/data alpine ls -la /data
```

### Logs Volume
Stores update logs:
```bash
# View logs
docker run --rm -v docker_geoip-logs:/logs alpine cat /logs/geoip-update.log

# Clear old logs
docker run --rm -v docker_geoip-logs:/logs alpine rm -f /logs/*.log.old
```

## Configuration Options

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| GEOIP_API_KEY | API key for authentication | Required |
| GEOIP_API_ENDPOINT | API Gateway URL | Required |
| CRON_SCHEDULE | Cron expression for updates | `0 2 * * *` |
| GEOIP_DATABASES | Specific databases (comma-separated) | `all` |

### Using Config File

Create `config.yaml`:
```yaml
api_key: "your_api_key_here"
target_dir: "/data"
databases:
  - "GeoIP2-City.mmdb"
  - "GeoIP2-Country.mmdb"
max_retries: 5
timeout: 600
```

Mount in docker-compose.yml (already configured).

## Advanced Usage

### Custom Build Args

```bash
# Build with specific Python version
docker build --build-arg PYTHON_VERSION=3.10 -f docker/Dockerfile -t geoip-updater:py310 .
```

### Running with Host Network

```bash
# Use host network (for proxy environments)
docker run --rm --network host \
  -e GEOIP_API_KEY="$GEOIP_API_KEY" \
  -v geoip-data:/data \
  geoip-updater:latest
```

### Multi-Architecture Build

```bash
# Build for multiple platforms
docker buildx build --platform linux/amd64,linux/arm64 \
  -f docker/Dockerfile \
  -t geoip-updater:multiarch .
```

## Integration Examples

### Kubernetes

See the `k8s/` directory for Kubernetes manifests.

### Docker Swarm

Deploy as a service:
```bash
docker service create \
  --name geoip-updater \
  --replicas 1 \
  --mount type=volume,source=geoip-data,target=/data \
  --env GEOIP_API_KEY="$GEOIP_API_KEY" \
  --restart-delay 24h \
  geoip-updater:latest --quiet
```

### Portainer Stack

Use the provided `docker-compose.yml` as a Portainer stack template.

## Monitoring

### Health Checks

The container includes a health check:
```bash
# Check container health
docker inspect geoip-updater | jq '.[0].State.Health'
```

### Prometheus Metrics

Add a sidecar for metrics:
```yaml
services:
  metrics-exporter:
    image: prom/node-exporter:latest
    volumes:
      - geoip-data:/data:ro
    command:
      - '--path.rootfs=/data'
      - '--collector.filesystem'
```

## Troubleshooting

### Common Issues

1. **Permission Denied**
   ```bash
   # Fix volume permissions
   docker run --rm -v docker_geoip-data:/data alpine chown -R 1000:1000 /data
   ```

2. **Cron Not Running**
   ```bash
   # Check cron logs
   docker-compose exec geoip-cron tail -f /var/log/cron.log
   
   # Verify crontab
   docker-compose exec geoip-cron crontab -l
   ```

3. **API Connection Failed**
   ```bash
   # Test connectivity
   docker-compose run --rm geoip-updater python -c \
     "import requests; print(requests.get('https://api.ipify.org').text)"
   ```

### Debug Mode

```bash
# Run with verbose output
docker-compose run --rm geoip-updater --verbose

# Interactive shell
docker-compose run --rm --entrypoint /bin/bash geoip-updater
```

### Clean Up

```bash
# Stop all containers
docker-compose down

# Remove volumes (WARNING: deletes downloaded databases)
docker-compose down -v

# Remove images
docker rmi geoip-updater:latest geoip-updater-cron:latest
```

## Security Considerations

1. **Non-Root User**: Containers run as UID 1000
2. **Read-Only Root**: Filesystem is read-only except for specific volumes
3. **No New Privileges**: Security option prevents privilege escalation
4. **Resource Limits**: CPU and memory limits prevent resource exhaustion
5. **Network Isolation**: Containers use isolated network by default

## Best Practices

1. **Regular Updates**: Keep base images updated
   ```bash
   docker-compose build --pull
   ```

2. **Volume Backups**: Backup data volumes regularly
   ```bash
   docker run --rm -v docker_geoip-data:/data \
     -v $(pwd):/backup alpine \
     tar czf /backup/geoip-backup.tar.gz /data
   ```

3. **Log Rotation**: Implement log rotation
   ```yaml
   logging:
     driver: "json-file"
     options:
       max-size: "10m"
       max-file: "3"
   ```

4. **Secrets Management**: Use Docker secrets for API keys in production
   ```bash
   echo "$GEOIP_API_KEY" | docker secret create geoip_api_key -
   ```