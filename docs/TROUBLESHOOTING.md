# Troubleshooting Guide

Common issues and solutions for the GeoIP Database Updater system across all deployment methods.

## Quick Diagnostics

### Health Check Commands
```bash
# Test API connectivity
curl -I https://geoipdb.net/auth

# Check local database files
ls -la /data/geoip/*.{mmdb,BIN} 2>/dev/null || echo "No databases found"

# Verify environment variables
env | grep -E "GEOIP|API" | sed 's/=.*/=***/'

# Test API authentication
curl -X POST -H "X-API-Key: your-key" \
  -d '{"databases": "all"}' \
  https://geoipdb.net/auth
```

### Log Analysis
```bash
# View recent errors
tail -50 /var/log/geoip-update.log | grep -i error

# Check authentication issues
grep -i "auth" /var/log/geoip-update.log | tail -10

# Monitor download progress
tail -f /var/log/geoip-update.log | grep -E "(download|progress|complete)"
```

## Authentication Issues

### Invalid API Key
**Symptoms**: `401 Unauthorized`, `Invalid API key` errors

**Solutions**:
1. **Verify API Key Format**:
   ```bash
   # Check if key is properly set
   [ -n "$GEOIP_API_KEY" ] && echo "API key is configured (${#GEOIP_API_KEY} chars)" || echo "API key is not set"
   # Should be 32+ characters
   ```

2. **Test API Key**:
   ```bash
   curl -X POST -H "X-API-Key: $GEOIP_API_KEY" \
     -d '{"databases": "all"}' \
     https://geoipdb.net/auth
   ```

3. **Check Environment Variables**:
   ```bash
   # Bash/Linux
   export GEOIP_API_KEY="your-actual-key"
   
   # Windows PowerShell
   $env:GEOIP_API_KEY = "your-actual-key"
   
   # Docker
   docker run -e GEOIP_API_KEY="your-key" ...
   ```

### API Endpoint Issues
**Symptoms**: `Connection refused`, `DNS resolution failed`

**Solutions**:
1. **Verify Endpoint URL**:
   ```bash
   # Default endpoint
   export GEOIP_API_ENDPOINT="https://geoipdb.net/auth"
   
   # Custom endpoint
   export GEOIP_API_ENDPOINT="https://your-api.execute-api.region.amazonaws.com/v1/auth"
   ```

2. **Test Network Connectivity**:
   ```bash
   # Check DNS resolution
   nslookup geoipdb.net
   
   # Test HTTPS connectivity
   curl -I https://geoipdb.net/auth
   
   # Check firewall/proxy
   curl -v https://geoipdb.net/auth
   ```

## Download Problems

### Failed Downloads
**Symptoms**: `Download failed`, `HTTP 403/404 errors`, Zero-byte files

**Solutions**:
1. **Check API Response**:
   ```bash
   # Get download URLs
   curl -X POST -H "X-API-Key: $GEOIP_API_KEY" \
     -d '{"databases": "all"}' \
     https://geoipdb.net/auth | jq .
   ```

2. **Verify S3 Access**:
   ```bash
   # Test S3 URL directly
   curl -I "https://s3-url-from-api-response"
   ```

3. **Check Disk Space**:
   ```bash
   # Check available space
   df -h /data/geoip
   
   # Clean old files if needed
   find /data/geoip -name "*.old" -delete
   ```

### Corrupt Downloads
**Symptoms**: `File validation failed`, `Invalid database format`

**Solutions**:
1. **Re-download with Validation**:
   ```bash
   # Python CLI with validation
   python geoip-update.py --validate --verbose
   
   # Bash script with retry
   ./geoip-update.sh -k $GEOIP_API_KEY --retry 3
   ```

2. **Check File Integrity**:
   ```bash
   # Check file sizes (should be > 1MB for most databases)
   ls -lh /data/geoip/*.mmdb /data/geoip/*.BIN
   
   # Verify MMDB files
   python -c "import geoip2.database; print(geoip2.database.Reader('/data/geoip/GeoIP2-City.mmdb').metadata())"
   ```

## Platform-Specific Issues

### Docker Issues

#### Container Won't Start
**Symptoms**: Container exits immediately, permission errors

**Solutions**:
1. **Check Logs**:
   ```bash
   docker logs container-name
   docker-compose logs geoip-updater
   ```

2. **Volume Permissions**:
   ```bash
   # Create with correct ownership
   mkdir -p data
   chown 1000:1000 data
   
   # Or use named volumes
   docker volume create geoip-data
   ```

3. **Environment Variables**:
   ```bash
   # Verify variables are passed correctly
   docker run --rm alpine env | grep GEOIP
   ```

#### Networking Issues in Container
**Solutions**:
```bash
# Test network from inside container
docker run --rm curlimages/curl curl -I https://geoipdb.net/auth

# Check DNS resolution
docker run --rm alpine nslookup geoipdb.net

# Test with host network
docker run --network host your-image
```

### Kubernetes Issues

#### Pod Fails to Start
**Symptoms**: `ImagePullBackOff`, `CrashLoopBackOff`

**Solutions**:
1. **Check Pod Status**:
   ```bash
   kubectl describe pod geoip-updater-xxx -n geoip-system
   kubectl logs geoip-updater-xxx -n geoip-system
   ```

2. **Verify Secrets**:
   ```bash
   kubectl get secrets -n geoip-system
   kubectl describe secret geoip-api-credentials -n geoip-system
   ```

3. **Resource Constraints**:
   ```bash
   # Check resource usage
   kubectl top pod -n geoip-system
   kubectl describe node
   ```

#### Job Fails Repeatedly
**Solutions**:
```bash
# Check CronJob status
kubectl get cronjobs -n geoip-system
kubectl describe cronjob geoip-updater -n geoip-system

# View failed job logs
kubectl logs -l app=geoip-updater -n geoip-system --previous

# Check job history
kubectl get jobs -n geoip-system --sort-by=.metadata.creationTimestamp
```

### Windows Issues

#### PowerShell Execution Policy
**Symptoms**: `Execution policy restricted`

**Solutions**:
```powershell
# Check current policy
Get-ExecutionPolicy

# Set policy for current user
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Run with bypass (one-time)
powershell -ExecutionPolicy Bypass -File .\geoip-update.ps1
```

#### Credential Manager Issues
**Solutions**:
```powershell
# Install credential manager module
Install-Module CredentialManager -Force

# Store credentials
New-StoredCredential -Target "GeoIP-API" -Username "api-key" -Password "your-key"

# Retrieve credentials
$cred = Get-StoredCredential -Target "GeoIP-API"
```

## API Server Issues

### Query API Problems

#### No Results Returned
**Symptoms**: Empty responses, `Database not found` errors

**Solutions**:
1. **Check Database Status**:
   ```bash
   curl http://localhost:8080/health | jq '.databases_local'
   ```

2. **Verify Database Files**:
   ```bash
   docker exec geoip-api ls -la /data/databases/raw/
   ```

3. **Test with Known IP**:
   ```bash
   curl -H "X-API-Key: your-key" \
     "http://localhost:8080/query?ips=8.8.8.8"
   ```

#### Slow Query Performance
**Solutions**:
1. **Enable Caching**:
   ```env
   CACHE_TYPE=redis
   REDIS_URL=redis://redis:6379
   ```

2. **Increase Workers**:
   ```env
   WORKERS=4
   ```

3. **Monitor Cache Performance**:
   ```bash
   curl -H "X-API-Key: your-key" \
     http://localhost:8080/metrics | jq
   ```

### Database Update Issues
**Symptoms**: Databases not updating automatically

**Solutions**:
1. **Check Scheduler Status**:
   ```bash
   curl -H "X-Admin-Key: admin-key" \
     http://localhost:8080/admin/scheduler/info
   ```

2. **Manual Database Update**:
   ```bash
   curl -X POST -H "X-Admin-Key: admin-key" \
     http://localhost:8080/admin/update-databases
   ```

3. **Verify S3 Configuration**:
   ```bash
   docker exec geoip-api env | grep -E "AWS|S3_BUCKET"
   ```

## Performance Issues

### Slow Downloads
**Symptoms**: Downloads take excessive time, timeouts

**Solutions**:
1. **Increase Timeout Values**:
   ```bash
   # Python CLI
   python geoip-update.py --timeout 300
   
   # Bash script
   export CURL_TIMEOUT=300
   ```

2. **Use Parallel Downloads**:
   ```bash
   # Enable concurrent downloads
   python geoip-update.py --concurrent 4
   ```

3. **Check Network Bandwidth**:
   ```bash
   # Test download speed
   curl -o /dev/null -s -w "%{speed_download}\n" https://example.com/large-file
   ```

### Memory Issues
**Symptoms**: Out of memory errors, system slowdown

**Solutions**:
1. **Monitor Memory Usage**:
   ```bash
   # System memory
   free -h
   
   # Container memory
   docker stats container-name
   
   # Kubernetes pods
   kubectl top pods -n geoip-system
   ```

2. **Optimize Database Loading**:
   ```bash
   # Load only required databases
   export GEOIP_DATABASES="GeoIP2-City.mmdb,GeoIP2-Country.mmdb"
   ```

3. **Increase Resource Limits**:
   ```yaml
   # Kubernetes
   resources:
     limits:
       memory: 2Gi
     requests:
       memory: 512Mi
   ```

## Network and Connectivity

### Proxy Configuration
**Symptoms**: Connection failures in corporate environments

**Solutions**:
1. **Configure HTTP Proxy**:
   ```bash
   export HTTP_PROXY=http://proxy.company.com:8080
   export HTTPS_PROXY=http://proxy.company.com:8080
   export NO_PROXY=localhost,127.0.0.1
   ```

2. **Docker Proxy Configuration**:
   ```json
   // ~/.docker/config.json
   {
     "proxies": {
       "default": {
         "httpProxy": "http://proxy.company.com:8080",
         "httpsProxy": "http://proxy.company.com:8080"
       }
     }
   }
   ```

3. **Kubernetes Proxy**:
   ```yaml
   env:
   - name: HTTP_PROXY
     value: "http://proxy.company.com:8080"
   - name: HTTPS_PROXY
     value: "http://proxy.company.com:8080"
   ```

### SSL/TLS Issues
**Symptoms**: Certificate verification failures

**Solutions**:
1. **Update CA Certificates**:
   ```bash
   # Ubuntu/Debian
   sudo apt-get update && sudo apt-get install ca-certificates
   
   # Alpine (Docker)
   apk add --update ca-certificates
   ```

2. **Corporate Certificate Issues**:
   ```bash
   # Add corporate CA to container
   COPY corporate-ca.crt /usr/local/share/ca-certificates/
   RUN update-ca-certificates
   ```

## Data Validation Issues

### Database Validation Failures
**Symptoms**: `Database validation failed`, `Cannot read database file`

**Solutions**:
1. **Check File Format**:
   ```bash
   # Verify MMDB files
   file /data/geoip/*.mmdb
   
   # Check BIN files
   file /data/geoip/*.BIN
   ```

2. **Test Database Reading**:
   ```bash
   # Python validation
   python -c "
   import geoip2.database
   with geoip2.database.Reader('/data/geoip/GeoIP2-City.mmdb') as reader:
       response = reader.city('8.8.8.8')
       print(f'Country: {response.country.name}')
   "
   ```

3. **Re-download Corrupted Files**:
   ```bash
   # Remove and re-download
   rm /data/geoip/GeoIP2-City.mmdb
   ./geoip-update.sh -k $GEOIP_API_KEY --databases GeoIP2-City.mmdb
   ```

## Scheduling Issues

### Cron Not Running
**Symptoms**: Updates not happening on schedule

**Solutions**:
1. **Check Cron Status**:
   ```bash
   # System cron
   systemctl status cron
   
   # User cron
   crontab -l
   
   # Supercronic (Docker)
   docker logs geoip-cron | grep -i cron
   ```

2. **Verify Cron Syntax**:
   ```bash
   # Test cron expression
   echo "0 2 * * * /path/to/script" | crontab -
   
   # Check cron logs
   grep CRON /var/log/syslog
   ```

3. **Environment Variables in Cron**:
   ```bash
   # Add to crontab
   GEOIP_API_KEY=your-key
   0 2 * * * /path/to/geoip-update.sh
   ```

## Recovery Procedures

### Emergency Recovery
1. **Stop All Services**:
   ```bash
   # Docker
   docker-compose down
   
   # Kubernetes
   kubectl scale deployment geoip-updater --replicas=0
   
   # Systemd
   systemctl stop geoip-updater
   ```

2. **Backup Current State**:
   ```bash
   # Backup databases
   cp -r /data/geoip /data/geoip.backup.$(date +%Y%m%d)
   
   # Backup configuration
   cp /etc/geoip/config.yaml /etc/geoip/config.yaml.backup
   ```

3. **Clean and Restore**:
   ```bash
   # Remove problematic files
   rm -rf /data/geoip/*
   
   # Fresh download
   ./geoip-update.sh -k $GEOIP_API_KEY --force
   ```

### Configuration Reset
```bash
# Reset to default configuration
cp config.yaml.example config.yaml

# Clear cache and temporary files
rm -rf /tmp/geoip-*
rm -rf /var/cache/geoip/*

# Restart with clean state
systemctl restart geoip-updater
```

## Getting Help

### Log Collection
```bash
# Collect system information
echo "System Info:" > debug-info.txt
uname -a >> debug-info.txt
echo -e "\nEnvironment Variables:" >> debug-info.txt
env | grep -E "GEOIP|API" | sed 's/=.*/=***/' >> debug-info.txt

# Collect logs
echo -e "\nRecent Logs:" >> debug-info.txt
tail -50 /var/log/geoip-update.log >> debug-info.txt
```

### Support Information
When reporting issues, include:
- Operating system and version
- Deployment method (Docker, Kubernetes, native)
- Configuration files (sanitized)
- Error messages and logs
- Network environment details
- Recent changes to the system

### Community Resources
- [GitHub Issues](https://github.com/ytzcom/geoip-updater/issues) - Bug reports and feature requests
- [Security Issues](mailto:security@example.com) - Private security vulnerability reports

---

**Note**: Always sanitize logs and configuration files before sharing, removing any API keys, passwords, or sensitive information.