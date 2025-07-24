# Multi-stage build for minimal Go binary image
# Build stage
FROM golang:1.21-alpine AS builder

# Install build dependencies
RUN apk add --no-cache git ca-certificates tzdata

# Create non-root user for runtime
RUN adduser -D -g '' -u 1000 geoip

# Set working directory
WORKDIR /build

# Copy go mod files
COPY go/go.mod go/go.sum* ./

# Download dependencies
RUN go mod download

# Copy source code
COPY go/ ./

# Build the binary with all optimizations
# CGO_ENABLED=0 for static binary
# -ldflags for smaller binary size and version injection
ARG VERSION=dev
ARG BUILD_DATE
ARG VCS_REF
RUN CGO_ENABLED=0 GOOS=linux go build \
    -a -installsuffix cgo \
    -ldflags "-s -w \
        -X main.version=${VERSION} \
        -X main.buildDate=${BUILD_DATE} \
        -X main.gitCommit=${VCS_REF}" \
    -o geoip-updater \
    main.go

# Create minimal runtime image
FROM scratch

# Copy timezone data for time operations
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo

# Copy SSL certificates for HTTPS
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy passwd file for user
COPY --from=builder /etc/passwd /etc/passwd

# Copy the binary
COPY --from=builder /build/geoip-updater /geoip-updater

# Create necessary directories
# Note: We can't create directories in scratch, so we'll handle this in the app
# or use a minimal base image like alpine:latest if directories are required

# Use non-root user
USER 1000

# Set environment variables
ENV GEOIP_TARGET_DIR=/data

# Labels
LABEL org.opencontainers.image.title="geoip-updater-go" \
      org.opencontainers.image.description="GeoIP database updater - Minimal Go binary" \
      org.opencontainers.image.vendor="YTZ" \
      org.opencontainers.image.authors="YTZ" \
      org.opencontainers.image.source="https://github.com/ytzcom/geoip-updater"

# Entrypoint
ENTRYPOINT ["/geoip-updater"]

# Default command
CMD ["--help"]

# Alternative: Using distroless for better debugging support
# FROM gcr.io/distroless/static-debian12:nonroot
# COPY --from=builder /build/geoip-updater /geoip-updater
# USER nonroot:nonroot
# ENTRYPOINT ["/geoip-updater"]
# CMD ["--help"]

# Alternative: Using Alpine for shell access and volume support
# FROM alpine:3.19
# RUN apk add --no-cache ca-certificates tzdata && \
#     adduser -D -g '' -u 1000 geoip && \
#     mkdir -p /data /logs && \
#     chown -R geoip:geoip /data /logs
# COPY --from=builder /build/geoip-updater /usr/local/bin/geoip-updater
# USER 1000
# VOLUME ["/data", "/logs"]
# ENTRYPOINT ["geoip-updater"]
# CMD ["--help"]