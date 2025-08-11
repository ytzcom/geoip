# Unified Release Workflow

This document describes the release process for GeoIP Updater, which includes both Docker images and Go binaries in a single unified workflow.

## Overview

The `release.yml` workflow automatically builds and publishes all release artifacts whenever a new version tag is pushed or manually triggered. This unified approach ensures consistency across Docker images and Go binaries.

## Release Artifacts

### Docker Images (8 total)

All images are multi-platform (linux/amd64, linux/arm64):

1. **Scripts Integration**: `ytzcom/geoip-scripts`
2. **CLI Clients**:
   - `ytzcom/geoip-updater` - Python CLI
   - `ytzcom/geoip-updater-cron` - Cron with supercronic
   - `ytzcom/geoip-updater-k8s` - Kubernetes optimized
   - `ytzcom/geoip-updater-go` - Go binary Docker
3. **API Servers**:
   - `ytzcom/geoip-api` - FastAPI server
   - `ytzcom/geoip-api-nginx` - Production with Nginx
   - `ytzcom/geoip-api-dev` - Development server

### Go Binaries (9 platforms)

- **Linux**: amd64, arm64, arm/v7
- **macOS**: amd64 (Intel), arm64 (Apple Silicon)
- **Windows**: amd64, arm64
- **FreeBSD**: amd64

## Release Process

### Method 1: Automatic Release (Recommended)

1. Tag your release:
```bash
git tag v1.0.1
git push origin v1.0.1
```

2. The workflow will automatically:
   - Build all 8 Docker images for multiple platforms
   - Sign Docker images with Cosign (keyless OIDC)
   - Generate SBOMs for all Docker images
   - Run vulnerability scans with Trivy
   - Build Go binaries for all 9 platforms
   - Create compressed versions (.gz and .tar.gz)
   - Generate checksums (SHA256 and MD5)
   - Create/update GitHub release with all artifacts
   - Test binaries on major platforms
   - Update Docker Hub descriptions

### Method 2: Manual Release via GitHub UI

1. Go to GitHub Releases → "Draft a new release"
2. Create tag: `v1.0.1`
3. Add your release notes
4. Publish release

The workflow will:
- Detect the existing release
- Preserve your manual release notes
- Add all build artifacts without overwriting

### Method 3: Manual Workflow Dispatch

1. Go to Actions → "Unified Release"
2. Click "Run workflow"
3. Enter the version (e.g., `v1.0.1`)
4. Click "Run workflow"

## Naming Conventions

### Docker Images
All images use consistent version tagging:
```
ytzcom/{image-name}:v1.0.1
ytzcom/{image-name}:latest
ytzcom/{image-name}:1.0
ytzcom/{image-name}:1
```

### Go Binaries
Binaries follow this pattern:
```
geoip-updater-{os}-{arch}[.exe]
```

Examples:
- `geoip-updater-linux-amd64`
- `geoip-updater-darwin-arm64`
- `geoip-updater-windows-amd64.exe`

## Download URLs

### Docker Images
```bash
# Pull specific version
docker pull ytzcom/geoip-updater:v1.0.1

# Pull latest
docker pull ytzcom/geoip-updater:latest
```

### Go Binaries
Once released, binaries are available at:
```
https://github.com/ytzcom/geoip/releases/download/v1.0.1/{binary-name}
```

## Verification

### Docker Images
All images are signed with Cosign using keyless signing:
```bash
# Verify image signature
cosign verify \
  --certificate-identity "https://github.com/ytzcom/geoip/.github/workflows/release.yml@refs/tags/v1.0.1" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ytzcom/geoip-updater:v1.0.1
```

### Go Binaries
Each release includes checksums:
```bash
# Verify SHA256
sha256sum -c checksums-sha256.txt

# Verify MD5
md5sum -c checksums-md5.txt
```

### SBOMs
Software Bill of Materials for all Docker images:
- Format: SPDX JSON
- Files: `{image-name}-sbom.spdx.json`
- Generated using Syft

## Version Management

- Version format: `v1.2.3` (semantic versioning with v prefix)
- Version is embedded in:
  - Docker image labels
  - Go binary during compilation
  - GitHub release tags

Check versions:
```bash
# Go binary
./geoip-updater --version

# Docker image
docker inspect ytzcom/geoip-updater:v1.0.1 | grep version
```

## Testing

After release, the workflow automatically tests:
- Docker image vulnerability scanning
- Go binaries on:
  - Ubuntu (linux/amd64)
  - macOS (darwin/amd64)
  - Windows (windows/amd64)

## Permissions Required

The workflow needs these GitHub permissions:
- `contents: write` - Create releases
- `packages: write` - Push to GitHub Container Registry
- `id-token: write` - OIDC for Cosign signing
- `security-events: write` - Upload vulnerability scans

## Troubleshooting

### Release Already Exists
The workflow intelligently handles existing releases:
- Preserves manual release notes
- Adds artifacts without overwriting
- Appends automated content to description

### Asset Upload Fails (422 Error)
Fixed by using specific glob patterns to avoid duplicate matches:
- Platform-specific patterns for binaries
- Separate pattern for SBOMs
- No overlapping file patterns

### Trivy Scan Upload Fails
Ensure workflow has `security-events: write` permission for uploading SARIF files to GitHub code scanning.

### Missing Go Binaries
If binaries are missing from a release:
1. Check workflow logs for build failures
2. Re-run the failed job
3. Verify all matrix jobs completed

### Docker Build Failures
Common causes:
- Docker Hub rate limits (retry with backoff)
- Base image unavailable
- BuildKit cache issues

## Maintenance

### Adding New Docker Images
Edit `.github/workflows/release.yml` matrix:
```yaml
matrix:
  include:
    - name: new-image-name
      context: ./path/to/context
      dockerfile: Dockerfile
      description: "Image description"
      category: category-name
```

### Adding New Binary Platforms
Edit `.github/workflows/release.yml` Go matrix:
```yaml
matrix:
  include:
    - os: new-os
      arch: new-arch
      output: geoip-updater-new-os-new-arch
```

### Build Configuration

Docker build args:
```yaml
VERSION: ${{ needs.setup.outputs.version }}
BUILD_DATE: ${{ timestamp }}
VCS_REF: ${{ github.sha }}
```

Go build flags:
```bash
-ldflags="-s -w -X main.version=$VERSION"
-trimpath
```

## Best Practices

1. **Version Tags**: Always use `v` prefix (e.g., `v1.0.1`)
2. **Semantic Versioning**: Follow major.minor.patch format
3. **Release Notes**: Update CHANGELOG.md before tagging
4. **Testing**: Verify in development before production release
5. **Monitoring**: Check release page after workflow completes

## Integration with GitHub Actions

The main `action.yml` automatically downloads these binaries with fallback options:
1. **Primary**: Download from GitHub releases
2. **Fallback 1**: Build from source if Go is available
3. **Fallback 2**: Use Docker image as last resort

## Security Considerations

- All Docker images are scanned for vulnerabilities
- Binaries are built in GitHub-hosted runners
- Checksums provided for integrity verification
- Keyless signing prevents key management issues
- SBOMs provide supply chain transparency