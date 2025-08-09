# Kubernetes-optimized Docker image for GeoIP updater
# Multi-stage build for minimal final image size

# Builder stage
FROM python:3.11-slim as builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy and install Python dependencies
WORKDIR /build
COPY requirements.txt .
RUN pip install --user --no-cache-dir -r requirements.txt

# Runtime stage
FROM python:3.11-slim

# Install only essential runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -g 0 -s /bin/bash geoip \
    && mkdir -p /data /logs /app \
    && chown -R geoip:0 /data /logs /app \
    && chmod -R g=u /data /logs /app

# Copy Python dependencies from builder
COPY --from=builder /root/.local /home/geoip/.local

# Copy application
WORKDIR /app
COPY --chown=geoip:0 geoip-update.py .

# Switch to non-root user
USER 1000

# Add local bin to PATH
ENV PATH=/home/geoip/.local/bin:$PATH

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    GEOIP_TARGET_DIR=/data

# Validate installation
RUN python geoip-update.py --version

# Default entrypoint
ENTRYPOINT ["python", "/app/geoip-update.py"]

# Default arguments
CMD ["--help"]