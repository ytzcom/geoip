# Multi-stage build for GeoIP scripts-only image
# Ultra-minimal image containing just the scripts needed for integration
FROM alpine:3.19 as builder

WORKDIR /opt/geoip

# Copy existing CLI scripts (DRY - reuse these!)
COPY scripts/cli/geoip-update.sh .
COPY scripts/cli/geoip-update.py .
COPY scripts/cli/requirements.txt .

# Add new helper scripts that WRAP the existing ones
COPY docker/scripts/entrypoint-helper.sh .
COPY docker/scripts/setup-cron.sh .
COPY docker/scripts/validate.sh .
COPY docker/scripts/crontab.example .
COPY docker/scripts/README.md .

# Make scripts executable
RUN chmod +x *.sh

# Ultra-minimal final stage using scratch
FROM scratch

# Copy all scripts from builder
COPY --from=builder /opt/geoip /opt/geoip

# This image is meant to be used as a source for COPY --from
# It doesn't have an entrypoint or command