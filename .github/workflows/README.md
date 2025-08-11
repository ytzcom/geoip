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
CI/CD workflow for Docker images (development and continuous integration).

**Triggers:**
- Push to main branch
- Pull requests (build only, no push)
- Manual dispatch
- Weekly schedule for security updates

**Images Built:**
1. `ytzcom/geoip-scripts` - Scripts-only image for Docker integration
2. `ytzcom/geoip-updater` - Python CLI version
3. `ytzcom/geoip-updater-cron` - Secure cron with supercronic
4. `ytzcom/geoip-updater-k8s` - Kubernetes optimized
5. `ytzcom/geoip-updater-go` - Minimal Go binary
6. `ytzcom/geoip-api` - FastAPI server with S3 backend
7. `ytzcom/geoip-api-nginx` - Production server with Nginx
8. `ytzcom/geoip-api-dev` - Development server with debug features

**Features:**
- Multi-platform builds (linux/amd64, linux/arm64)
- Vulnerability scanning with Trivy
- SBOM generation
- Automated Docker Hub description updates
- Build caching for faster builds
- Development tags (latest, pr-*, weekly)

### release.yml
Unified release workflow for production releases with both Docker images and Go binaries.

**Triggers:**
- Git tags (v*)
- Manual dispatch with version input

**Docker Images:**
All 8 Docker images are built, signed, and pushed with version tags:
- Keyless signing with Cosign (GitHub OIDC)
- SBOM generation for supply chain security
- Vulnerability scanning with Trivy
- Multi-platform support (linux/amd64, linux/arm64)

**Go Binaries:**
Cross-platform compilation for 9 targets:
- Linux (amd64, arm64, arm/v7)
- macOS (amd64, arm64)
- Windows (amd64, arm64)
- FreeBSD (amd64)

**Features:**
- Unified release with all artifacts
- Automatic GitHub release creation
- Checksum generation (SHA256, MD5)
- Binary compression (.gz, .tar.gz)
- Post-release testing on major platforms
- Smart release detection (preserves manual release notes)

See [docs/RELEASE_PROCESS.md](../../docs/RELEASE_PROCESS.md) for detailed release process.

### deploy.yml
Unified deployment workflow supporting both manual triggers and workflow calls.

**Triggers:**
- Manual dispatch (GitHub UI)
- Workflow call (from other workflows)

**Features:**
- Deploy to single or multiple hosts
- SSH-based deployment with key authentication
- Environment management (production, staging, manual)
- Health check validation after deployment
- Support for both direct invocation and reuse by other workflows

**Parameters:**
- `deploy_host/deploy_hosts`: Target server(s) for deployment
- `deploy_user`: SSH username (defaults to repository variable)
- `deploy_port`: SSH port (defaults to repository variable)
- `deploy_branch`: Branch to deploy (defaults to current/main)
- `environment_name`: GitHub environment (manual-deployment/production)
- `environment_url`: URL for health checks

### docker-cleanup.yml
Automated cleanup of old Docker Hub tags.

**Triggers:**
- Weekly schedule (Sundays at 2 AM UTC)
- Manual dispatch

**Features:**
- Removes PR tags older than 30 days
- Cleans up SHA tags from old builds
- Preserves version tags and important branches
- Dry-run mode for safety

## Required Secrets

### For update-geoip.yml:
- `AWS_ACCESS_KEY_ID` - AWS access key for S3
- `AWS_SECRET_ACCESS_KEY` - AWS secret key for S3
- `MAXMIND_LICENSE_KEY` - MaxMind license key
- `IP2LOCATION_TOKEN` - IP2Location download token
- `SLACK_WEBHOOK_URL` - (Optional) Slack webhook for notifications

### For docker-build.yml and release.yml:
- `DOCKERHUB_USERNAME` - Docker Hub username
- `DOCKERHUB_PASSWORD` - Docker Hub access token (not password)

### For deploy.yml:
- `DEPLOY_KEY` - SSH private key for deployment
- `DOTENV_TOKEN` - (Optional) Token for environment configuration

## Required Variables

### For update-geoip.yml:
- `S3_BUCKET` - S3 bucket name (default: your-s3-bucket)
- `AWS_REGION` - AWS region (default: us-east-1)
- `MAXMIND_ACCOUNT_ID` - MaxMind account ID
- `CREATE_ISSUE_ON_FAILURE` - Create GitHub issue on failure (true/false)

### For deploy.yml:
- `DEPLOY_USER` - Default SSH username for deployments
- `DEPLOY_PORT` - Default SSH port for deployments

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

### 4. Configure Deployment
```bash
# Generate SSH key pair for deployment
ssh-keygen -t ed25519 -f deploy_key -N ""

# Add private key to GitHub secrets as DEPLOY_KEY
# Add public key to authorized_keys on target servers
```

### 5. Optional Notifications
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

### Build Docker Images (CI/CD)
1. Go to Actions tab
2. Select "Docker CI/CD"
3. Click "Run workflow"
4. Configure options:
   - Force rebuild without cache: Yes/No
5. Click "Run workflow"

### Create Release
1. **Method 1: Tag Push**
   ```bash
   git tag v1.2.3
   git push origin v1.2.3
   ```

2. **Method 2: Manual Dispatch**
   - Go to Actions → "Unified Release"
   - Click "Run workflow"
   - Enter version (e.g., v1.2.3)
   - Run workflow

### Deploy to Production
1. Go to Actions tab
2. Select "Deploy Workflow"
3. Click "Run workflow"
4. Configure:
   - Target host(s): server.example.com
   - SSH user: deploy
   - SSH port: 22
   - Branch to deploy: main
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

### Release Status
- Check Releases page for all artifacts
- Verify checksums for Go binaries
- Confirm Docker image signatures with Cosign

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

#### 6. Release Asset Upload Fails (422 Error)
- **Duplicate assets**: Asset with same name already exists
  - Solution: Fixed by using specific glob patterns to avoid duplicates
- **Re-running workflows**: May encounter conflicts with existing assets
- **File patterns**: Ensure no overlapping glob patterns in release configuration

#### 7. Trivy Scan Upload Fails
- **Missing permissions**: Ensure workflow has `security-events: write` permission
- **SARIF upload**: Required for GitHub code scanning integration
- **Token access**: Verify GITHUB_TOKEN has appropriate permissions

#### 8. Deployment Fails
- **SSH key issues**:
  - Verify DEPLOY_KEY secret is correctly formatted
  - Ensure public key is in authorized_keys on target server
- **Port access**: Confirm SSH port is accessible from GitHub Actions
- **Directory permissions**: Deploy user needs write access to deployment directory

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
   - Keep permissions minimal (principle of least privilege)

2. **Performance**
   - Use build caching
   - Optimize Dockerfiles
   - Monitor workflow duration
   - Leverage parallel matrix builds

3. **Reliability**
   - Set up notifications
   - Monitor failure rates
   - Test changes in PRs first
   - Use retry logic for network operations

4. **Releases**
   - Follow semantic versioning (v1.2.3)
   - Document changes in CHANGELOG
   - Test releases in staging first
   - Verify all artifacts post-release