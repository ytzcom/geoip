# Docker Hub Images

Official Docker images for the GeoIP Updater are available on Docker Hub under the `ytzcom` namespace.

## Available Images

### 1. Python CLI Image
**Image:** `ytzcom/geoip-updater:latest`

The main Python-based GeoIP updater with full feature support.

```bash
# Pull the latest version
docker pull ytzcom/geoip-updater:latest

# Run with API key
docker run --rm \
  -e GEOIP_API_KEY=your-api-key \
  -e GEOIP_API_ENDPOINT=https://your-api.execute-api.region.amazonaws.com/v1/auth \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater:latest

# Run with config file
docker run --rm \
  -v $(pwd)/config.yaml:/app/config.yaml:ro \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater:latest \
  --config /app/config.yaml
```

### 2. Secure Cron Image
**Image:** `ytzcom/geoip-updater-cron:latest`

Non-root cron container using supercronic for scheduled updates.

```bash
# Pull the latest version
docker pull ytzcom/geoip-updater-cron:latest

# Run with daily schedule (2 AM UTC)
docker run -d \
  --name geoip-cron \
  -e GEOIP_API_KEY=your-api-key \
  -e GEOIP_API_ENDPOINT=https://your-api.execute-api.region.amazonaws.com/v1/auth \
  -e CRON_SCHEDULE="0 2 * * *" \
  -v geoip-data:/data \
  -v geoip-logs:/logs \
  ytzcom/geoip-updater-cron:latest

# View Prometheus metrics
docker run -d \
  --name geoip-cron \
  -p 9090:9090 \
  -e GEOIP_API_KEY=your-api-key \
  -e GEOIP_API_ENDPOINT=https://your-api.execute-api.region.amazonaws.com/v1/auth \
  -v geoip-data:/data \
  ytzcom/geoip-updater-cron:latest
```

### 3. Kubernetes Optimized Image
**Image:** `ytzcom/geoip-updater-k8s:latest`

Optimized for Kubernetes deployments with minimal attack surface.

```bash
# Pull the latest version
docker pull ytzcom/geoip-updater-k8s:latest

# Use in Kubernetes (see k8s/cronjob-secure.yaml)
# Update the image in your manifests:
# image: ytzcom/geoip-updater-k8s:latest
```

### 4. Go Binary Image
**Image:** `ytzcom/geoip-updater-go:latest`

Minimal Go binary image built from scratch for smallest size and attack surface.

```bash
# Pull the latest version
docker pull ytzcom/geoip-updater-go:latest

# Run the Go version
docker run --rm \
  -e GEOIP_API_KEY=your-api-key \
  -e GEOIP_API_ENDPOINT=https://your-api.execute-api.region.amazonaws.com/v1/auth \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater-go:latest \
  -quiet \
  -directory /data
```

## Image Tags

All images support the following tagging scheme:

- `latest` - Latest stable release from main branch
- `v1.0.0` - Specific version tags
- `1.0.0` - Version without 'v' prefix
- `1.0` - Major.minor version
- `1` - Major version only
- `main-abc1234` - Branch name with short commit SHA
- `pr-123` - Pull request builds (not pushed to registry)

## Multi-Platform Support

All images are built for multiple platforms:
- `linux/amd64` - Standard x86_64 architecture
- `linux/arm64` - ARM64 architecture (Apple Silicon, AWS Graviton)

Docker will automatically pull the correct image for your platform.

## Security

### Image Signing
All tagged releases are signed with Cosign for supply chain security. We use keyless signing through Sigstore, which provides a transparent and auditable signing process.

#### Verifying Image Signatures

```bash
# Verify image signature (keyless signing via Sigstore)
# This will verify the signature was created by our GitHub Actions workflow
cosign verify ytzcom/geoip-updater:v1.0.0 \
  --certificate-identity-regexp "https://github.com/ytzcom/geoip-updater/.github/workflows/docker-build.yml@refs/tags/v.*" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"

# Verify a specific image with more details
cosign verify ytzcom/geoip-updater:v1.0.0 --output text

# Verify all images for a release
for image in geoip-updater geoip-updater-cron geoip-updater-k8s geoip-updater-go; do
  echo "Verifying $image..."
  cosign verify ytzcom/$image:v1.0.0 \
    --certificate-identity-regexp "https://github.com/ytzcom/geoip-updater/.github/workflows/docker-build.yml@refs/tags/v.*" \
    --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
done
```

#### Understanding Keyless Signing
- **No long-lived keys**: Signatures are created using short-lived certificates from Sigstore
- **Transparency**: All signatures are logged in a public transparency log (Rekor)
- **GitHub Actions integration**: Signatures are tied to the specific workflow that built the image
- **OIDC verification**: Ensures the signature came from our official GitHub repository

#### Troubleshooting Verification

If verification fails, check:
1. **Cosign version**: Ensure you have cosign v2.0+ installed
   ```bash
   cosign version
   ```
2. **Image tag**: Only tagged releases (v*) are signed, not 'latest' or branch builds
3. **Network access**: Cosign needs to access Sigstore's public infrastructure
4. **Certificate details**: View the certificate used for signing
   ```bash
   cosign verify ytzcom/geoip-updater:v1.0.0 --output json | jq -r '.[0].optional.Bundle.Payload.body' | base64 -d | jq
   ```

### Vulnerability Scanning
All images are scanned for vulnerabilities using:
- Trivy - Results available in GitHub Security tab
- Docker Scout - Results available in Docker Hub

### SBOM (Software Bill of Materials)
SBOMs are generated for each image and attached to GitHub releases:

```bash
# Download SBOM from GitHub release
curl -LO https://github.com/ytzcom/geoip-updater/releases/download/v1.0.0/geoip-updater-sbom.spdx.json

# Inspect SBOM
cat geoip-updater-sbom.spdx.json | jq .
```

## Docker Compose

Use the provided Docker Compose files for easy deployment:

```bash
# Using secure compose file
cd scripts/cli
docker-compose -f docker/docker-compose-secure.yml up -d

# View logs
docker-compose -f docker/docker-compose-secure.yml logs -f

# Stop services
docker-compose -f docker/docker-compose-secure.yml down
```

## Environment Variables

All images support the following environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `GEOIP_API_KEY` | API key for authentication | Required |
| `GEOIP_API_ENDPOINT` | API endpoint URL | Required |
| `GEOIP_TARGET_DIR` | Directory to save databases | `/data` |
| `GEOIP_LOG_FILE` | Log file path | `/logs/geoip-update.log` |
| `CRON_SCHEDULE` | Cron schedule (cron image only) | `0 2 * * *` |

## Volume Mounts

Recommended volume mounts:

| Path | Purpose | Mode |
|------|---------|------|
| `/data` | Database storage | Read/Write |
| `/logs` | Log files | Read/Write |
| `/app/config.yaml` | Configuration file | Read-only |

## Resource Limits

Recommended resource limits for container orchestration:

### Python Images
- CPU: 100m-500m
- Memory: 128Mi-512Mi
- Ephemeral Storage: 100Mi-1Gi

### Go Binary Image
- CPU: 50m-200m
- Memory: 64Mi-256Mi
- Ephemeral Storage: 50Mi-500Mi

## Health Checks

All images include health checks:

```bash
# Check if container is healthy
docker inspect --format='{{.State.Health.Status}}' container-name

# Manual health check
docker exec container-name python geoip-update.py --version
```

## Troubleshooting

### Permission Issues
If you encounter permission issues with volumes:

```bash
# Create volumes with correct permissions
docker volume create geoip-data
docker volume create geoip-logs

# Or use bind mounts with correct ownership
mkdir -p data logs
chown 1000:1000 data logs
```

### API Connection Issues
Test API connectivity:

```bash
# Test from within container
docker run --rm \
  -e GEOIP_API_KEY=your-api-key \
  -e GEOIP_API_ENDPOINT=https://your-api.execute-api.region.amazonaws.com/v1/auth \
  ytzcom/geoip-updater:latest \
  --test-connection
```

### Debug Mode
Enable verbose logging:

```bash
# Python version
docker run --rm \
  -e GEOIP_API_KEY=your-api-key \
  -e GEOIP_API_ENDPOINT=https://your-api.execute-api.region.amazonaws.com/v1/auth \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater:latest \
  --verbose

# Go version
docker run --rm \
  -e GEOIP_API_KEY=your-api-key \
  -e GEOIP_API_ENDPOINT=https://your-api.execute-api.region.amazonaws.com/v1/auth \
  -v $(pwd)/data:/data \
  ytzcom/geoip-updater-go:latest \
  -verbose
```

## CI/CD Integration

The Docker images are automatically built and pushed by GitHub Actions on:
- Push to main branch
- Git tags (v*)
- Weekly schedule for security updates

See `.github/workflows/docker-build.yml` for the complete workflow.

## Contributing

When contributing changes that affect Docker images:

1. Update relevant Dockerfiles
2. Test builds locally:
   ```bash
   docker build -f docker/Dockerfile -t test-image .
   ```
3. Ensure multi-platform compatibility
4. Update this documentation if needed

## License

The Docker images are distributed under the same license as the main project. See the LICENSE file for details.