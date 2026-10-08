# Python CLI with Cron Scheduling

Docker image with automated GeoIP database updates using **supercronic** for secure, non-root cron execution.

## ✨ Key Features

- 🔐 **Secure**: Runs as non-root user (UID 1000)
- 📅 **Automated**: Built-in cron scheduling with supercronic
- 📊 **Monitored**: Prometheus metrics endpoint
- 🚀 **Production-ready**: Multi-platform support (amd64, arm64)
- 🔄 **Reliable**: Retry logic with exponential backoff

## 🚀 Quick Start

### Docker Run
```bash
# Run with daily updates at 2 AM UTC
docker run -d \
  --name geoip-cron \
  -e GEOIP_API_KEY=your-api-key \
  -e GEOIP_API_ENDPOINT=https://geoipdb.net/auth \
  -v geoip-data:/data \
  ytzcom/geoip-updater-cron:latest
```

### Docker Compose
```yaml
version: '3.8'
services:
  geoip-cron:
    image: ytzcom/geoip-updater-cron:latest
    environment:
      GEOIP_API_KEY: ${GEOIP_API_KEY}
      GEOIP_API_ENDPOINT: https://geoipdb.net/auth
      CRON_SCHEDULE: "0 2 * * *"  # Daily at 2 AM UTC
      GEOIP_DATABASES: "all"
    volumes:
      - geoip-data:/data
      - geoip-logs:/logs
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "pgrep", "supercronic"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  geoip-data:
  geoip-logs:
```

## 🔧 Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GEOIP_API_KEY` | *(required)* | Your authentication API key |
| `GEOIP_API_ENDPOINT` | *(required)* | API endpoint URL |
| `GEOIP_TARGET_DIR` | `/data` | Database storage directory |
| `CRON_SCHEDULE` | `0 2 * * *` | Cron schedule (daily at 2 AM) |
| `GEOIP_DATABASES` | `all` | Databases to download |
| `GEOIP_LOG_FILE` | `/logs/geoip-update.log` | Log file path (the crontab passes `--log-file /logs/geoip-update.log`, which wins) |
| `GEOIP_CONCURRENT` | `2` | Max concurrent downloads |
| `GEOIP_TIMEOUT` | `1800` | Download timeout in seconds |
| `GEOIP_MAX_RETRIES` | `3` | Maximum retry attempts |
| `GEOIP_ONLY_CHANGED` | - | Download only changed databases (`true`, `1`, `yes`) |
| `GEOIP_LOCK_FILE` | - | Exclusive lock on a shared path |
| `GEOIP_LOCK_TIMEOUT` | `1800` | Seconds to wait for `GEOIP_LOCK_FILE` |

### Change Detection and Shared-Path Locking

The scheduled job runs the [Python CLI](../python/README.md), so set these through the environment. Recommended for daily runs and for a volume shared with other updaters:

```yaml
    environment:
      GEOIP_ONLY_CHANGED: "true"
      GEOIP_LOCK_FILE: /data/.geoip-update.lock
```

- **Manifest.** With change detection on, the client keeps `<target>/.geoip-update.json` with each database's ETag, `Last-Modified` and size, in the same layout every client writes. A database is skipped with `Unchanged: <name>` when the server answers its conditional request (`If-None-Match`) with `304`. It downloads when the file is missing, the manifest has no entry, or the size on disk differs. The manifest is written once at the end of the run; an unreadable manifest is treated as absent. A run where everything is unchanged exits `0`.
- **Lock.** A lock file takes an exclusive kernel lock that the operating system releases on any exit, including `kill -9`, so a crashed run never blocks the next one. A second run waits up to the lock timeout (default `1800` s), then logs `Timed out after N s waiting for lock PATH` and exits `1`. Setting `GEOIP_LOCK_FILE` together with `--no-lock` exits `1` with `--lock-file and --no-lock cannot be combined`.
- **Staging.** Downloads go to `<target>/<name>.part` and are renamed into place, so a pod or container reading the volume never sees a partial file. A failed download removes its `.part`.
- **`GEOIP_TIMEOUT` / `--timeout`** does not abort a stalled transfer.

Details for every client: [CLI Overview](../README.md#-change-detection-shared-path-locking-and-staging).

### Cron Schedule Examples

```bash
# Every hour
CRON_SCHEDULE="0 * * * *"

# Every 6 hours
CRON_SCHEDULE="0 */6 * * *"

# Daily at 3 AM UTC
CRON_SCHEDULE="0 3 * * *"

# Weekly on Sunday at 2 AM
CRON_SCHEDULE="0 2 * * 0"

# Multiple times per day
CRON_SCHEDULE="0 2,14 * * *"  # 2 AM and 2 PM
```

## 📊 Monitoring

### Health Checks

Built-in health check monitors supercronic process:
```bash
# Check container health
docker inspect --format='{{.State.Health.Status}}' geoip-cron

# Manual health check
docker exec geoip-cron pgrep supercronic
```

### Prometheus Metrics

Supercronic exposes metrics on port 9090:
```bash
# Access metrics endpoint
curl http://localhost:9090/metrics

# Sample metrics
supercronic_job_duration_seconds{job="geoip-update"} 45.2
supercronic_job_success_total{job="geoip-update"} 142
supercronic_job_failure_total{job="geoip-update"} 2
```

### Log Monitoring

```bash
# View logs
docker logs geoip-cron

# Follow logs
docker logs -f geoip-cron

# Check log files in volume
docker exec geoip-cron cat /logs/geoip-update.log
```

## 🏗️ Technical Details

### Security Features

- **Non-root execution**: Runs as user `geoip` (UID 1000)
- **No privilege escalation**: Container security hardening
- **Read-only filesystem**: Immutable container filesystem
- **Minimal attack surface**: Only essential packages installed

### Architecture

- **Base**: Python 3.11-slim for security and performance
- **Scheduler**: supercronic for reliable cron replacement
- **Multi-stage build**: Optimized for size and security
- **Platform**: linux/amd64, linux/arm64

### Directory Structure

```
Container Layout:
/app/
├── geoip-update.py     # Main Python script
└── entrypoint.sh       # Container entrypoint

/data/                  # Database storage (volume)
├── GeoIP2-City.mmdb
├── GeoIP2-Country.mmdb
└── ...

/logs/                  # Log files (volume)
└── geoip-update.log
```

## 🔄 Deployment Scenarios

### Development

```bash
# Quick test with one-time execution
docker run --rm \
  -e GEOIP_API_KEY=your-key \
  -e CRON_SCHEDULE="* * * * *" \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater-cron:latest
```

### Production with Docker Compose

```yaml
version: '3.8'
services:
  geoip-cron:
    image: ytzcom/geoip-updater-cron:latest
    environment:
      GEOIP_API_KEY: ${GEOIP_API_KEY}
      CRON_SCHEDULE: "0 2 * * *"
    volumes:
      - geoip-data:/data
      - geoip-logs:/logs
    networks:
      - internal
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: '0.5'
        reservations:
          memory: 128M
          cpus: '0.1'

  # Your application using GeoIP data
  app:
    image: your-app:latest
    volumes:
      - geoip-data:/app/geoip:ro  # Read-only access
    depends_on:
      - geoip-cron

volumes:
  geoip-data:
  geoip-logs:

networks:
  internal:
```

### Production with Docker Swarm

```bash
# Deploy as stack
docker stack deploy -c docker-compose.yml geoip-stack

# Scale if needed (though typically you only need one instance)
docker service scale geoip-stack_geoip-cron=1
```

## 🚨 Troubleshooting

### Common Issues

**Container Won't Start**
```bash
# Check logs
docker logs geoip-cron

# Common causes:
# - Missing GEOIP_API_KEY
# - Invalid cron schedule format
# - Volume permission issues
```

**Cron Jobs Not Running**
```bash
# Check supercronic process
docker exec geoip-cron pgrep -a supercronic

# Validate cron schedule
echo "0 2 * * *" | docker run --rm -i ytzcom/geoip-updater-cron:latest supercronic -test -

# Check metrics for job execution
curl http://localhost:9090/metrics | grep supercronic_job
```

**Database Downloads Failing**
```bash
# Test API connectivity
docker exec geoip-cron python geoip-update.py --api-key="$GEOIP_API_KEY" --test-connection

# Run manual update
docker exec geoip-cron python geoip-update.py --api-key="$GEOIP_API_KEY" --verbose
```

**Volume Permission Issues**
```bash
# Fix volume permissions
docker run --rm -v geoip-data:/data alpine chown -R 1000:1000 /data
docker run --rm -v geoip-logs:/logs alpine chown -R 1000:1000 /logs
```

### Debug Mode

Run with verbose logging:
```bash
docker run --rm \
  -e GEOIP_API_KEY=your-key \
  -e CRON_SCHEDULE="* * * * *" \
  ytzcom/geoip-updater-cron:latest \
  python geoip-update.py --verbose
```

## 🔗 Related Documentation

- **[Python CLI](../python/README.md)** - Base Python implementation
- **[Security Guide](../../docs/SECURITY.md)** - Security best practices
- **[Docker Integration](../../docker-scripts/README.md)** - Integration helpers
- **[Kubernetes](../../k8s/README.md)** - K8s deployment alternative

## 🤝 Contributing

To modify this Docker image:

1. **Edit Dockerfile**: Make changes to `Dockerfile`
2. **Test locally**:
   ```bash
   docker build -t test-cron .
   docker run --rm -e GEOIP_API_KEY=test test-cron
   ```
3. **Submit pull request**: Include tests and documentation updates