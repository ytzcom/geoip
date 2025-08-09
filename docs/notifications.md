# Notifications Setup Guide

This document explains how to configure notifications for the GeoIP Update system across different deployment methods including GitHub Actions workflows and CLI operations.

## Overview

The GeoIP Update system provides multiple notification methods to alert you when database updates fail. This is especially important for scheduled runs (GitHub Actions every Monday at midnight UTC) and automated CLI deployments that might fail silently without proper alerting.

## Notification Methods

### 1. GitHub Actions Summary

**Always enabled**. When a workflow fails, a detailed summary is automatically created in the GitHub Actions run summary, including:
- Error details
- Troubleshooting steps
- Links to relevant logs
- Timestamp and trigger information

### 2. Slack Notifications

To enable Slack notifications:

1. Create a Slack Webhook URL:
   - Go to your Slack workspace
   - Navigate to Apps → Incoming Webhooks
   - Create a new webhook for your desired channel
   - Copy the webhook URL

2. Add the webhook URL to GitHub Secrets:
   - Go to Settings → Secrets and variables → Actions
   - Create a new secret named `SLACK_WEBHOOK_URL`
   - Paste your Slack webhook URL

When configured, failures will send a formatted message to your Slack channel with:
- Failure alert header
- Repository and workflow run links
- Trigger information
- Direct link to view logs

### 3. GitHub Issues

To enable automatic issue creation on failure:

1. Go to Settings → Secrets and variables → Actions → Variables
2. Create a new repository variable named `CREATE_ISSUE_ON_FAILURE`
3. Set the value to `true`

When enabled, the workflow will:
- Create a GitHub issue on failure
- Include error details and troubleshooting checklist
- Add labels: `geoip-update-failure` and `automated`
- Avoid creating duplicate issues if one already exists

## Controlling Notifications

### For Manual Runs

When triggering the workflow manually, you can control notifications:

```yaml
notify_on_failure: true  # Send all configured notifications (default)
notify_on_failure: false # Disable notifications for this run
```

### For Scheduled Runs

Notifications are always enabled for scheduled runs to ensure you're alerted to failures.

## Notification Content

All notifications include:
- Workflow run number and link
- Trigger type (schedule or manual)
- Actor who triggered the workflow
- Timestamp of failure
- Quick access links to logs

## Best Practices

1. **Slack Notifications**: Recommended for immediate alerts, especially for production environments
2. **GitHub Issues**: Useful for tracking recurring issues and maintaining a history
3. **Both Methods**: Can be used together for comprehensive coverage

### 4. CLI Tool Notifications

For CLI deployments, configure system-level notifications:

#### Email Notifications (Linux/macOS)
```bash
# Add to your cron job or script
if ! ./geoip-update.sh -q; then
    echo "GeoIP update failed on $(hostname)" | mail -s "GeoIP Update Failure" admin@company.com
fi
```

#### System Logging
```bash
# Log to syslog
logger -t geoip-update "Database update completed successfully"
logger -p user.error -t geoip-update "Database update failed"
```

#### Docker Container Notifications
```yaml
# docker-compose.yml with health checks
services:
  geoip-updater:
    image: ytzcom/geoip-updater-cron:latest
    healthcheck:
      test: ["CMD", "test", "-f", "/data/GeoIP2-City.mmdb"]
      interval: 1h
      timeout: 10s
      retries: 3
```

## CLI Integration with External Systems

### Webhook Notifications
```bash
# Add webhook call to your script
if ! ./geoip-update.sh; then
    curl -X POST https://hooks.slack.com/your-webhook \
      -H "Content-Type: application/json" \
      -d '{"text": "GeoIP update failed on production server"}'
fi
```

### Monitoring System Integration
```bash
# Send metrics to monitoring system
if ./geoip-update.sh; then
    curl -X POST http://prometheus-pushgateway:9091/metrics/job/geoip_update \
      -d 'geoip_update_success 1'
else
    curl -X POST http://prometheus-pushgateway:9091/metrics/job/geoip_update \
      -d 'geoip_update_success 0'
fi
```

## Troubleshooting Common Failures

When you receive a failure notification, check:

1. **Authentication Failures**
   - API key expired or invalid (https://geoipdb.net/auth)
   - Network connectivity to authentication endpoint
   - Firewall or proxy blocking HTTPS requests

2. **Network Issues**
   - S3 service availability
   - Rate limiting from API endpoint
   - Connection timeouts or DNS resolution

3. **Storage Issues**
   - Disk space availability
   - File permissions for target directory
   - Volume mount issues (Docker/Kubernetes)

4. **Data Issues**
   - Database file corruption during download
   - Validation failures
   - Unsupported database formats

## Testing Notifications

To test your notification configuration:

1. Temporarily modify a script to fail
2. Run the workflow manually
3. Verify notifications are received
4. Restore the script

## Security Notes

- Slack webhook URLs should be kept secret
- Use GitHub Secrets for sensitive data
- Avoid exposing internal details in public notifications
- Regularly rotate credentials and webhooks