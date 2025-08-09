# GeoIP Database Updater

![Workflow Status](https://github.com/ytzcom/geoip/workflows/Update%20GeoIP%20Databases/badge.svg)
![Last Update](https://img.shields.io/badge/Last%20Update-2025--08--04%2000:27:15%20UTC-blue)
![Database Count](https://img.shields.io/badge/Databases-7-green)
![MaxMind Databases](https://img.shields.io/badge/MaxMind-4-orange)
![IP2Location Databases](https://img.shields.io/badge/IP2Location-3-purple)

**Automated GeoIP database management with multiple deployment options.** Download and automatically update MaxMind and IP2Location databases through a secure API with built-in authentication, retry logic, and validation.

> **⚠️ Important Usage Notice:** This repository is publicly shared for educational and internal deployment purposes only. It was originally built for our internal infrastructure needs. Please ensure compliance with MaxMind and IP2Location's terms of service - this service is designed to facilitate deployment of databases you are already licensed to use. Commercial redistribution or sharing of the actual database files is prohibited and violates provider terms.

## 🚀 Quick Start

### Option 1: Docker Integration (2 Lines!)

Add to ANY Dockerfile:
```dockerfile
FROM ytzcom/geoip-scripts:latest as geoip
COPY --from=geoip /opt/geoip /opt/geoip
```

Then in your entrypoint:
```bash
. /opt/geoip/entrypoint-helper.sh && geoip_init && exec your-app
```

**What happens automatically:**
- ✅ Downloads databases on first run (if missing)
- ✅ Validates databases are working  
- ✅ Sets up daily auto-updates via cron
- ✅ Databases persist across container restarts

### Option 2: One-Line Linux Installer

```bash
curl -sSL https://geoipdb.net/install | sh
```

### Option 3: Direct Download

```bash
# Python
docker run --rm -e GEOIP_API_KEY=your-key -v $(pwd)/data:/data ytzcom/geoip-updater:latest

# Go binary (smallest)
docker run --rm -e GEOIP_API_KEY=your-key -v $(pwd)/data:/data ytzcom/geoip-updater-go:latest

# Native scripts
git clone https://github.com/ytzcom/geoip-updater.git
cd geoip-updater/cli
./geoip-update.sh -k YOUR_API_KEY
```

## 📊 Available Databases

| Database | Provider | Format | Size | Description |
|----------|----------|--------|------|-------------|
| GeoIP2-City | MaxMind | MMDB | 115MB | City-level IP geolocation |
| GeoIP2-Country | MaxMind | MMDB | 9MB | Country-level geolocation |
| GeoIP2-ISP | MaxMind | MMDB | 17MB | ISP and organization data |
| GeoIP2-Connection-Type | MaxMind | MMDB | 11MB | Connection type information |
| DB23 IPv4 | IP2Location | BIN | 633MB | Comprehensive IPv4 data |
| DB23 IPv6 | IP2Location | BIN | 805MB | Comprehensive IPv6 data |
| PX2 IPv4 | IP2Location | BIN | 192MB | IPv4 proxy detection |

**Updates:** Databases are automatically updated every Monday at midnight UTC.

## 🛠️ Choose Your Implementation

### For Docker Projects
- **[Docker Integration](docker-scripts/README.md)** - 2-line integration for any Dockerfile
- **[Python CLI](cli/python/README.md)** - Full-featured Python client
- **[Python + Cron](cli/python-cron/README.md)** - Automated scheduling with supercronic
- **[Kubernetes-optimized](cli/python-k8s/README.md)** - Production K8s deployments
- **[Go Binary](cli/go/README.md)** - Single binary, minimal footprint (~8MB)

### For Native Deployment  
- **[Bash Script](cli/README.md)** - Linux/macOS with cron scheduling
- **[PowerShell Script](cli/README.md)** - Windows with Task Scheduler
- **[Python Script](cli/python/README.md)** - Cross-platform with advanced features

### For Self-Hosted API & Query Service
- **[API Server](api-server/README.md)** - FastAPI server with GeoIP query API, web UI, and database downloads

### For CI/CD Integration
- **[GitHub Action](docs/GITHUB_ACTION.md)** - Use as GitHub Action in CI/CD pipelines

### For Cloud Deployment
- **[Kubernetes](k8s/README.md)** - Production CronJobs with monitoring
- **[Infrastructure](deploy/README.md)** - Terraform deployment to AWS Lambda

## 🔧 Configuration

All implementations use the same environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `GEOIP_API_KEY` | *(required)* | Your authentication key |
| `GEOIP_API_ENDPOINT` | `https://geoipdb.net/auth` | API endpoint URL |
| `GEOIP_TARGET_DIR` | `/data` | Database storage directory |
| `GEOIP_DATABASES` | `all` | Comma-separated list or `all` |

## 💡 Usage Examples

### Docker Compose
```yaml
services:
  app:
    build: .
    environment:
      - GEOIP_API_KEY=${GEOIP_API_KEY}
    volumes:
      - geoip-data:/app/geoip
volumes:
  geoip-data:
```

### Laravel/PHP
```dockerfile
FROM ytzcom/geoip-scripts:latest as geoip
FROM php:8.3-fpm

COPY --from=geoip /opt/geoip /opt/geoip
ENV GEOIP_API_KEY=${GEOIP_API_KEY}
ENV GEOIP_TARGET_DIR=/var/www/html/resources/geoip

CMD sh -c '. /opt/geoip/entrypoint-helper.sh && geoip_init && php-fpm'
```

### Node.js
```dockerfile
FROM ytzcom/geoip-scripts:latest as geoip
FROM node:20-alpine

COPY --from=geoip /opt/geoip /opt/geoip
ENV GEOIP_API_KEY=${GEOIP_API_KEY}

CMD sh -c '. /opt/geoip/entrypoint-helper.sh && geoip_init && node server.js'
```

## 🎯 Decision Matrix

| Need | Recommendation | Why |
|------|----------------|-----|
| **Docker integration** | [Docker Scripts](docker-scripts/README.md) | 2-line setup, automatic everything |
| **CI/CD pipelines** | [GitHub Action](docs/GITHUB_ACTION.md) | Cache databases in workflows, Docker builds |
| **GeoIP Query API** | [API Server](api-server/README.md) | Query databases + web UI + downloads |
| **Kubernetes** | [K8s CronJob](k8s/README.md) | Production-ready, monitoring included |
| **Minimal footprint** | [Go Binary](cli/go/README.md) | Single executable, ~8MB |
| **Advanced features** | [Python CLI](cli/python/README.md) | Async, config files, extensive options |
| **Windows** | [PowerShell](cli/README.md) | Native Windows integration |
| **Simple Linux** | [Bash Script](cli/README.md) | Works everywhere, minimal dependencies |

## 🔐 Authentication

1. **Get API Key**: Contact the service provider for authentication credentials
2. **Set Environment**: `export GEOIP_API_KEY=your-key`
3. **Test Connection**: Most tools include a `--test` or `--version` flag

## 📖 Documentation

- **[CLI Tools](cli/README.md)** - All command-line implementations
- **[Docker Integration](docker-scripts/README.md)** - Container integration helpers
- **[GitHub Action](docs/GITHUB_ACTION.md)** - CI/CD pipeline integration
- **[Kubernetes](k8s/README.md)** - Production deployment guide
- **[API Server](api-server/README.md)** - Self-hosted authentication server
- **[Usage Examples](USAGE_EXAMPLES.md)** - Code samples for multiple languages
- **[Security Guide](docs/SECURITY.md)** - Security best practices
- **[Troubleshooting](docs/TROUBLESHOOTING.md)** - Common issues and solutions
- **[Notifications](docs/NOTIFICATIONS.md)** - Alerts and monitoring setup
- **[Docker Hub Cleanup](docs/DOCKER_CLEANUP.md)** - Automated image cleanup and retention

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Submit a pull request

For bug reports or feature requests, use the [Issues tab](https://github.com/ytzcom/geoip-updater/issues).

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

**Database Licenses:** GeoIP databases are subject to their respective licenses from MaxMind and IP2Location.

---

**Need help?** Check the [troubleshooting guide](docs/TROUBLESHOOTING.md) or [open an issue](https://github.com/ytzcom/geoip-updater/issues).