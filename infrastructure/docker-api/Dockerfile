# Multi-stage build for minimal production image
FROM python:3.11-slim as builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Create virtual environment
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copy and install requirements
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Production stage
FROM python:3.11-slim

# Create non-root user
RUN useradd -m -u 1000 -s /bin/bash geoip && \
    mkdir -p /data /app && \
    chown -R geoip:geoip /data /app

# Copy virtual environment from builder
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Set working directory
WORKDIR /app

# Copy application files
COPY --chown=geoip:geoip app.py config.py ./

# Switch to non-root user
USER geoip

# Environment variables (defaults)
ENV STORAGE_MODE=s3 \
    PORT=8080 \
    WORKERS=1 \
    LOCAL_DATA_PATH=/data \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import requests; requests.get('http://localhost:${PORT}/health').raise_for_status()" || exit 1

# Expose port
EXPOSE 8080

# Labels
LABEL org.opencontainers.image.title="geoip-api" \
      org.opencontainers.image.description="GeoIP Authentication API Server" \
      org.opencontainers.image.vendor="YTZ" \
      org.opencontainers.image.authors="YTZ" \
      org.opencontainers.image.source="https://github.com/ytzcom/geoip-updater"

# Run the application
CMD ["python", "-m", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]