# Docker Hub Cleanup Configuration

This document explains how to configure automated Docker Hub cleanup to prevent storage bloat and keep repositories organized.

## Overview

The Docker Hub cleanup workflow automatically removes old and unused image tags on a weekly schedule while preserving important releases and current development tags.

## Required Secrets

Add these secrets to your GitHub repository settings (`Settings > Secrets and variables > Actions`):

### DOCKERHUB_CLEANUP_USERNAME
- **Value**: Your Docker Hub username (same as `DOCKERHUB_USERNAME`)
- **Purpose**: Authentication for Docker Hub API access during cleanup operations

### DOCKERHUB_CLEANUP_TOKEN
- **Value**: A Docker Hub Personal Access Token (PAT) with `Public Repo Write` permissions
- **Purpose**: Secure authentication for tag deletion operations

⚠️ **Important**: Use a Personal Access Token, not a password. Regular passwords may not work with the cleanup API.

### How to Create a Docker Hub Personal Access Token

1. Log in to [Docker Hub](https://hub.docker.com)
2. Go to **Account Settings** > **Security** > **Personal Access Tokens**
3. Click **Generate New Token**
4. Set these options:
   - **Token Description**: `GitHub Actions Docker Cleanup`
   - **Permissions**: Select `Public Repo Write` (or `Public Repo Read, Write, Delete` if available)
5. Click **Generate** and copy the token immediately
6. Add the token as `DOCKERHUB_CLEANUP_TOKEN` secret in GitHub

## Cleanup Rules

### Protected Tags (Never Deleted)
- ✅ `latest` - Always preserved
- ✅ Current branch tags (`main`, `develop`, `master`)
- ✅ Semantic version tags (`v1.0.0`, `1.0`, `1`)

### Cleanup Targets
- 🗑️ **PR tags** (`pr-123`, `pr-456`) - Deleted after 30 days
- 🗑️ **Branch SHA tags** (`main-abc123f`, `develop-xyz789a`) - Deleted after 14 days
- 🗑️ **Untagged manifests** - Cleaned up automatically

## Schedule and Operation

### Automatic Schedule
- **Frequency**: Every Sunday at 2:00 AM UTC
- **Mode**: Live deletion (not dry-run)
- **Scope**: All 8 Docker images in the project

### Manual Triggers
You can manually trigger cleanup with custom parameters:

1. Go to **Actions** > **Docker Hub Cleanup**
2. Click **Run workflow**
3. Configure options:
   - **Dry run**: `true` to preview, `false` to actually delete
   - **PR tag retention**: Days to keep PR tags (default: 30)
   - **SHA tag retention**: Days to keep branch SHA tags (default: 14)

## Monitoring

### Workflow Results
- Check the **Actions** tab for cleanup results
- Each run includes a summary of what was deleted
- Failed cleanups are highlighted in red

### What Gets Logged
- Number of tags identified for deletion
- Actual tags deleted (with timestamps)
- Any errors or API issues
- Summary of protected tags preserved

## Troubleshooting

### Common Issues

**Error: "Unauthorized" or "403 Forbidden"**
- Verify `DOCKERHUB_CLEANUP_TOKEN` is a valid Personal Access Token
- Ensure token has `Public Repo Write` permissions
- Check that `DOCKERHUB_CLEANUP_USERNAME` matches your Docker Hub username

**Error: "Repository not found"**
- Verify repository names in the workflow match your Docker Hub repositories
- Ensure repositories exist and are accessible with the provided credentials

**No tags deleted**
- Check if tags actually meet the deletion criteria (age and pattern)
- Review the cleanup configuration in the workflow logs
- Verify you're not running in dry-run mode when expecting actual deletion

### Testing the Setup

1. **First run**: Always use dry-run mode (`dry_run: true`)
2. **Review logs**: Check what would be deleted before proceeding
3. **Test cleanup**: Run with a short retention period on a test tag
4. **Monitor results**: Verify the cleanup worked as expected

## Security Considerations

- Personal Access Tokens are more secure than passwords
- Tokens can be revoked immediately if compromised
- GitHub Secrets are encrypted and only accessible during workflow execution
- Cleanup operations are logged for audit purposes

## Customization

### Adjust Retention Periods
Edit the default values in `.github/workflows/docker-cleanup.yml`:

```yaml
retention_days_pr:
  default: '30'  # Change to desired days
retention_days_branch_sha:
  default: '14'  # Change to desired days
```

### Add/Remove Images
Update the matrix in the cleanup workflow:

```yaml
matrix:
  image:
    - geoip-scripts
    - geoip-updater
    # Add or remove images as needed
```

### Change Schedule
Modify the cron expression:

```yaml
schedule:
  - cron: '0 2 * * 0'  # Sunday 2 AM UTC
  # Change to desired schedule
```

## Benefits

- **Cost Control**: Prevents accumulation of unused tags that may incur storage fees
- **Organization**: Keeps repositories clean and easy to navigate  
- **Automation**: No manual maintenance required
- **Flexibility**: Configurable retention policies and manual override options
- **Safety**: Dry-run mode and protected tag preservation prevent accidental deletion