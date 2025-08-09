# Go Binary Release Workflow

This document describes the release process for the GeoIP updater Go binaries.

## Overview

The `release-go-binaries.yml` workflow automatically builds and publishes Go binaries for multiple platforms whenever a new version tag is pushed or manually triggered.

## Supported Platforms

The workflow builds binaries for:

- **Linux**: amd64, arm64, arm/v7
- **macOS**: amd64 (Intel), arm64 (Apple Silicon)
- **Windows**: amd64, arm64
- **FreeBSD**: amd64

## Release Process

### Automatic Release (Recommended)

1. Tag your release:
```bash
git tag v1.0.1
git push origin v1.0.1
```

2. The workflow will automatically:
   - Build binaries for all platforms
   - Create compressed versions (.gz and .tar.gz)
   - Generate checksums (SHA256 and MD5)
   - Create a GitHub release with all assets
   - Test the binaries on major platforms

### Manual Release

1. Go to Actions → Release Go Binaries
2. Click "Run workflow"
3. Enter the version (e.g., `v1.0.1`)
4. Click "Run workflow"

## Binary Naming Convention

Binaries follow this naming pattern:
```
geoip-updater-{os}-{arch}[.exe]
```

Examples:
- `geoip-updater-linux-amd64`
- `geoip-updater-darwin-arm64`
- `geoip-updater-windows-amd64.exe`

## Download URLs

Once released, binaries are available at:
```
https://github.com/ytzcom/geoip/releases/latest/download/{binary-name}
```

## Verification

Each release includes:
- `checksums-sha256.txt` - SHA256 checksums for all binaries
- `checksums-md5.txt` - MD5 checksums for all binaries

To verify a download:
```bash
# SHA256
sha256sum -c checksums-sha256.txt

# MD5
md5sum -c checksums-md5.txt
```

## GitHub Action Integration

The main `action.yml` automatically downloads these binaries with fallback options:

1. **Primary**: Download from GitHub releases
2. **Fallback 1**: Build from source if Go is available
3. **Fallback 2**: Fail gracefully with helpful error message

## Version Management

- Version is set in the Git tag (e.g., `v1.0.1`)
- The version is embedded in the binary during build
- Users can check version with: `./geoip-updater --version`

## Testing

After release, the workflow automatically tests binaries on:
- Ubuntu (linux/amd64)
- macOS (darwin/amd64)
- Windows (windows/amd64)

## Troubleshooting

### Binary Not Found in Action

If the GitHub Action can't find binaries:

1. Check if a release exists:
   - Visit: https://github.com/ytzcom/geoip/releases
   - Look for the latest release with binaries

2. Create a new release:
   - Run the workflow manually (see Manual Release above)
   - Or push a new version tag

3. The action will fall back to building from source if Go is installed

### Build Failures

If builds fail:
1. Check Go version compatibility (requires Go 1.21+)
2. Review build logs in the Actions tab
3. Ensure all dependencies are available

## Maintenance

### Updating Supported Platforms

To add new platforms, edit `.github/workflows/release-go-binaries.yml`:

```yaml
matrix:
  include:
    - os: new-os
      arch: new-arch
      output: geoip-updater-new-os-new-arch
```

### Changing Build Flags

Build flags are set in the workflow:
```yaml
BUILD_FLAGS="-ldflags=\"-s -w -X main.version=$VERSION\" -trimpath"
```

- `-s -w`: Strip debug information (smaller binaries)
- `-X main.version=`: Embed version string
- `-trimpath`: Remove file system paths from binary