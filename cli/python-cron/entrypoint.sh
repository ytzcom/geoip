#!/bin/bash
set -e

# Default cron schedule (daily at 2 AM)
CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * *}"

# Validate environment variables
if [ -z "$GEOIP_API_KEY" ]; then
    echo "ERROR: GEOIP_API_KEY environment variable is not set"
    exit 1
fi

# Create crontab file for supercronic
# Note: supercronic reads environment variables from the runtime environment,
# so we don't need to write them to the crontab file
cat > /tmp/crontab << EOF
# GeoIP Database Update Job
# Schedule: ${CRON_SCHEDULE}
${CRON_SCHEDULE} cd /app && python geoip-update.py --quiet --log-file /logs/geoip-update.log
EOF

echo "GeoIP update cron job configured with schedule: ${CRON_SCHEDULE}"
echo "Logs will be written to: /logs/geoip-update.log"
echo "Starting supercronic..."

# Run supercronic in foreground as non-root user
# Supercronic inherits environment variables, so API key is never written to disk
exec /usr/local/bin/supercronic -prometheus-listen-address :9090 /tmp/crontab