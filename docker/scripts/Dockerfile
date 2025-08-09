# Multi-stage build for GeoIP scripts-only image
# Ultra-minimal image containing just the scripts needed for integration

# Stage 1: Build Go binaries for multiple architectures
FROM golang:1.21-alpine AS go-builder

WORKDIR /build

# Copy Go source code
COPY scripts/cli/go/go.mod scripts/cli/go/go.sum* ./
RUN go mod download || true

COPY scripts/cli/go/main.go .

# Build for AMD64
RUN GOOS=linux GOARCH=amd64 go build \
    -ldflags="-s -w -X main.version=1.0.0" \
    -trimpath \
    -o geoip-update-amd64 \
    main.go

# Build for ARM64
RUN GOOS=linux GOARCH=arm64 go build \
    -ldflags="-s -w -X main.version=1.0.0" \
    -trimpath \
    -o geoip-update-arm64 \
    main.go

# Stage 2: Prepare scripts
FROM alpine:3.19 as builder

WORKDIR /opt/geoip

# Copy existing CLI scripts (DRY - reuse these!)
COPY scripts/cli/geoip-update.sh .
COPY scripts/cli/geoip-update-posix.sh .
COPY scripts/cli/geoip-update.py .
COPY scripts/cli/geoip-update.ps1 .
COPY scripts/cli/requirements.txt .

# Add new helper scripts that WRAP the existing ones
COPY docker/scripts/entrypoint-helper.sh .
COPY docker/scripts/setup-cron.sh .
COPY docker/scripts/validate.sh .
COPY docker/scripts/crontab.example .
COPY docker/scripts/README.md .

# Make scripts executable
RUN chmod +x *.sh

# Stage 3: Final minimal image
FROM scratch

# Copy all scripts from builder
COPY --from=builder /opt/geoip /opt/geoip

# Copy both architecture Go binaries
COPY --from=go-builder /build/geoip-update-amd64 /opt/geoip/
COPY --from=go-builder /build/geoip-update-arm64 /opt/geoip/

# This image is meant to be used as a source for COPY --from
# It doesn't have an entrypoint or command