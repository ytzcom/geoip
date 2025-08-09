# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an automated GeoIP database updater that downloads MaxMind and IP2Location databases, validates them, and uploads them to S3 for public distribution. The system runs automatically every Monday at midnight UTC via GitHub Actions.

## Key Commands

### Testing Database Downloads Locally

```bash
# Test MaxMind download (requires MAXMIND_ACCOUNT_ID and MAXMIND_LICENSE_KEY)
./github-actions/download-maxmind.sh temp/compressed/maxmind <account_id> <license_key>

# Test IP2Location download (requires IP2LOCATION_TOKEN)
./github-actions/download-ip2location.sh temp/compressed/ip2location <token>

# Extract databases
./github-actions/extract-databases.sh

# Validate databases
python github-actions/validate-databases.py temp/raw/
```

### Testing S3 Uploads

```bash
# Test upload (requires AWS credentials configured)
./github-actions/upload-to-s3.sh temp/raw/maxmind <bucket> raw/maxmind "*.mmdb" "application/octet-stream"

# Check database status on S3
./github-actions/check-database-status.sh <bucket-name>
```

### Running the Workflow Locally

```bash
# Install dependencies
pip install -r requirements.txt

# Set required environment variables
export MAXMIND_ACCOUNT_ID=your-account-id
export MAXMIND_LICENSE_KEY=your-license-key
export IP2LOCATION_TOKEN=your-token
export S3_BUCKET=your-bucket-name
```

## Architecture Overview

### Workflow Pipeline

1. **Download Phase**: Parallel downloads from MaxMind and IP2Location using retry logic
2. **Extraction Phase**: Unpack compressed archives to get raw database files
3. **Validation Phase**: Python script validates each database can be opened and queried
4. **Upload Phase**: Upload both compressed and raw files to S3 with proper content types
5. **Documentation Phase**: Auto-update README with file sizes and timestamps

### Key Design Decisions

- **Parallel Downloads**: Both MaxMind and IP2Location downloads run concurrently to reduce total execution time
- **Cross-Platform Compatibility**: Uses `wc -c` instead of `stat` for file size checks to work on both Linux and macOS
- **Configurable S3 Bucket**: The S3 bucket name can be customized via the `S3_BUCKET` secret (defaults to 'ytz-geoip')
- **CIDR Databases Excluded**: Only BIN and MMDB formats are supported; CSV/CIDR databases were removed as they're not needed

### Script Dependencies

- **download-*.sh**: First scripts in pipeline, require authentication credentials
- **extract-databases.sh**: Depends on successful downloads, expects files in temp/compressed/
- **validate-databases.py**: Requires Python libraries (geoip2, IP2Location, IP2Proxy) and extracted files in temp/raw/
- **upload-to-s3.sh**: Generic uploader used 4 times in workflow for different file types
- **update-readme.sh**: Depends on S3 uploads being complete to fetch file sizes

### Error Handling Strategy

- Download scripts use 3 retry attempts with 5-second delays
- File size validation catches error pages masquerading as database files
- Workflow creates GitHub issues on failure if CREATE_ISSUE_ON_FAILURE is set
- Each script uses `set -euo pipefail` for strict error handling

## Required Configuration

### Secrets (sensitive values)
GitHub repository must have these secrets configured:
- `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`: AWS credentials for S3 uploads
- `MAXMIND_LICENSE_KEY`: MaxMind API authentication key
- `IP2LOCATION_TOKEN`: IP2Location API token
- `SLACK_WEBHOOK_URL` (optional): Slack webhook for failure notifications

### Variables (non-sensitive configuration)
GitHub repository can have these variables configured:
- `S3_BUCKET`: Custom S3 bucket name (defaults to 'ytz-geoip')
- `AWS_REGION`: AWS region (defaults to 'us-east-1')
- `MAXMIND_ACCOUNT_ID`: MaxMind account identifier
- `CREATE_ISSUE_ON_FAILURE`: Set to 'true' to create GitHub issues on failure