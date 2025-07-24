#!/bin/bash
set -e

# Default cron schedule (daily at 2 AM)
CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * *}"

# Create cron job
cat > /etc/cron.d/geoip-update << EOF
# GeoIP Database Update Job
SHELL=/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin
GEOIP_API_KEY=${GEOIP_API_KEY}
GEOIP_API_ENDPOINT=${GEOIP_API_ENDPOINT}
GEOIP_TARGET_DIR=${GEOIP_TARGET_DIR}

# Schedule: ${CRON_SCHEDULE}
${CRON_SCHEDULE} geoip cd /app && /usr/local/bin/python geoip-update.py --quiet --log-file /logs/geoip-update.log >> /var/log/cron.log 2>&1
EOF

# Set proper permissions
chmod 0644 /etc/cron.d/geoip-update

# Validate crontab
crontab -u geoip /etc/cron.d/geoip-update

echo "GeoIP update cron job configured with schedule: ${CRON_SCHEDULE}"
echo "Logs will be written to:"
echo "  - Application logs: /logs/geoip-update.log"
echo "  - Cron logs: /var/log/cron.log"

# Start cron in foreground and tail logs
cron && tail -f /var/log/cron.log /logs/geoip-update.log