# Multi-stage build for optimal image size
FROM python:3.11-slim as builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements
WORKDIR /build
COPY requirements.txt .

# Install Python dependencies
RUN pip install --user --no-cache-dir -r requirements.txt

# Runtime stage
FROM python:3.11-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -s /bin/bash geoip

# Copy Python dependencies from builder
COPY --from=builder /root/.local /home/geoip/.local

# Copy application
WORKDIR /app
COPY geoip-update.py .

# Create data directory
RUN mkdir -p /data && chown geoip:geoip /data

# Switch to non-root user
USER geoip

# Add local bin to PATH
ENV PATH=/home/geoip/.local/bin:$PATH

# Set default environment variables
ENV GEOIP_TARGET_DIR=/data \
    PYTHONUNBUFFERED=1

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=1 \
    CMD python geoip-update.py --version || exit 1

# Default command (can be overridden)
ENTRYPOINT ["python", "geoip-update.py"]
CMD ["--help"]