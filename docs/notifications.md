# Workflow Failure Notifications

This document explains how to configure notifications for the GeoIP Update workflow failures.

## Overview

The GeoIP Update workflow includes built-in failure notifications that can alert you when database updates fail. This is especially important for scheduled runs that might fail silently without notifications.

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

## Troubleshooting Common Failures

When you receive a failure notification, check:

1. **Authentication Failures**
   - MaxMind credentials expired
   - IP2Location token invalid
   - AWS credentials misconfigured

2. **Network Issues**
   - Provider services down
   - Rate limiting
   - Connection timeouts

3. **Storage Issues**
   - S3 permissions
   - Bucket accessibility
   - Storage quotas

4. **Data Issues**
   - Invalid database formats
   - Corrupted downloads
   - Validation failures

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