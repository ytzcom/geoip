# GitHub Actions Workflows

This directory contains GitHub Actions workflows for automated tasks.

## Workflows

### update-geoip.yml
Main workflow for downloading and updating GeoIP databases from MaxMind and IP2Location.

**Triggers:**
- Manual dispatch (workflow_dispatch)
- Weekly schedule (Mondays at midnight UTC)

**Features:**
- Parallel downloads from MaxMind and IP2Location
- S3 upload for both compressed and raw files
- Database validation
- README auto-update with latest status
- Failure notifications (Slack, GitHub Issues)

### docker-build.yml
Automated Docker image building and publishing to Docker Hub.

**Triggers:**
- Push to main branch
- Git tags (v*)
- Pull requests (build only, no push)
- Manual dispatch
- Weekly schedule for security updates

**Images Built:**
1. `ytzcom/geoip-updater` - Python CLI version
2. `ytzcom/geoip-updater-cron` - Secure cron with supercronic
3. `ytzcom/geoip-updater-k8s` - Kubernetes optimized
4. `ytzcom/geoip-updater-go` - Minimal Go binary

**Features:**
- Multi-platform builds (linux/amd64, linux/arm64)
- Vulnerability scanning with Trivy
- Image signing with Cosign
- SBOM generation
- Automated Docker Hub description updates
- Build caching for faster builds

## Required Secrets

### For update-geoip.yml:
- `AWS_ACCESS_KEY_ID` - AWS access key for S3
- `AWS_SECRET_ACCESS_KEY` - AWS secret key for S3
- `MAXMIND_LICENSE_KEY` - MaxMind license key
- `IP2LOCATION_TOKEN` - IP2Location download token
- `SLACK_WEBHOOK_URL` - (Optional) Slack webhook for notifications

### For docker-build.yml:
- `DOCKERHUB_USERNAME` - Docker Hub username
- `DOCKERHUB_PASSWORD` - Docker Hub access token (not password)

## Required Variables

### For update-geoip.yml:
- `S3_BUCKET` - S3 bucket name (default: your-s3-bucket)
- `AWS_REGION` - AWS region (default: us-east-1)
- `MAXMIND_ACCOUNT_ID` - MaxMind account ID
- `CREATE_ISSUE_ON_FAILURE` - Create GitHub issue on failure (true/false)

## Setup Instructions

### 1. Configure AWS Credentials
```bash
# Add to repository secrets
AWS_ACCESS_KEY_ID=your-access-key
AWS_SECRET_ACCESS_KEY=your-secret-key
```

### 2. Configure Docker Hub
```bash
# Create access token at https://hub.docker.com/settings/security
# Add to repository secrets
DOCKERHUB_USERNAME=your-username
DOCKERHUB_PASSWORD=your-access-token
```

### 3. Configure Database Providers
```bash
# MaxMind - Get from https://www.maxmind.com/en/my_license_key
MAXMIND_LICENSE_KEY=your-license-key

# IP2Location - Get from https://www.ip2location.com/web-service
IP2LOCATION_TOKEN=your-token
```

### 4. Optional Notifications
```bash
# Slack webhook for failure notifications
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL
```

## Manual Workflow Runs

### Update GeoIP Databases
1. Go to Actions tab
2. Select "Update GeoIP Databases"
3. Click "Run workflow"
4. Configure options:
   - Send notifications on failure: Yes/No
   - Enable debug logging: Yes/No
5. Click "Run workflow"

### Build Docker Images
1. Go to Actions tab
2. Select "Build and Push Docker Images"
3. Click "Run workflow"
4. Configure options:
   - Force rebuild without cache: Yes/No
5. Click "Run workflow"

## Monitoring

### Workflow Status
- Check Actions tab for workflow runs
- Enable notifications for failed workflows
- Review job summaries for detailed information

### Docker Image Status
- Check Docker Hub for latest images
- Review vulnerability scan results in Security tab
- Monitor Dependabot for base image updates

## Troubleshooting

### Common Issues

#### 1. AWS S3 Upload Fails
- **Check AWS credentials are valid**
  ```bash
  aws sts get-caller-identity
  ```
- **Verify S3 bucket permissions**: Ensure the IAM user has `s3:PutObject` and `s3:PutObjectAcl` permissions
- **Check AWS region configuration**: Confirm the region matches your bucket location

#### 2. Docker Build Fails
- **Check Docker Hub credentials**
  - Ensure you're using an access token, not a password
  - Verify token has `write` permissions
  - Test locally: `docker login -u USERNAME`
- **Verify Dockerfile syntax**
  ```bash
  docker build --check .
  ```
- **Review build logs for errors**
  - Check for base image pull failures
  - Look for missing files in COPY commands
  - Verify build context includes all required files

#### 3. Database Download Fails
- **Verify API credentials are valid**
  - Check MaxMind license key hasn't expired
  - Ensure IP2Location token is active
- **Check if providers are having issues**
  - Visit MaxMind status page
  - Check IP2Location service status
- **Review rate limits**
  - MaxMind: 2000 requests per day
  - IP2Location: Based on subscription

#### 4. Docker Hub Push Fails
- **Rate limits**: Docker Hub has push rate limits
  - Free tier: 100 pushes per 6 hours
  - Pro tier: 5000 pushes per day
- **Image size limits**: Maximum 10GB compressed
- **Network issues**: Retry with exponential backoff

#### 5. Cosign Signing Fails
- **OIDC token issues**: Ensure workflow has `id-token: write` permission
- **Network access**: Cosign needs access to Sigstore infrastructure
- **Only works on**: Push events and releases, not PRs

### Debug Mode

Enable debug logging in workflows:

1. **For update-geoip.yml**: Use debug_mode input
   ```yaml
   workflow_dispatch:
     inputs:
       debug_mode: 'true'
   ```

2. **For docker-build.yml**: 
   - Check build logs in Actions tab
   - Enable BuildKit debug output:
     ```yaml
     env:
       BUILDKIT_PROGRESS: plain
       DOCKER_BUILDKIT: 1
     ```

3. **Global debug logging**: Add `ACTIONS_STEP_DEBUG=true` as a repository secret

4. **Docker build debugging**:
   - Add `--progress=plain` to see detailed output
   - Use `docker build --no-cache` to bypass cache issues
   - Test builds locally first

### Performance Optimization

1. **Slow builds**:
   - Enable registry caching
   - Use `--cache-from` with previous builds
   - Optimize Dockerfile layer ordering

2. **Workflow timeouts**:
   - Default timeout: 6 hours
   - Adjust in workflow: `timeout-minutes: 30`
   - Use job-level timeouts for granular control

3. **Parallel execution**:
   - Matrix builds run in parallel
   - Default limit: 256 concurrent jobs
   - Adjust with `max-parallel` in strategy

## Best Practices

1. **Security**
   - Use access tokens, not passwords
   - Rotate credentials regularly
   - Review security alerts

2. **Performance**
   - Use build caching
   - Optimize Dockerfiles
   - Monitor workflow duration

3. **Reliability**
   - Set up notifications
   - Monitor failure rates
   - Test changes in PRs first