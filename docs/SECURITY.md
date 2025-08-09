# Security Guide

This document outlines security best practices, configurations, and considerations for deploying the GeoIP Database Updater system securely across all implementations.

## Overview

The GeoIP Database Updater system implements defense-in-depth security principles across all deployment options, from simple CLI scripts to enterprise Kubernetes deployments.

## Authentication & API Security

### API Key Management
- **Storage**: Use environment variables, never hardcode in scripts
- **Rotation**: Implement regular API key rotation policies
- **Scope**: Use different keys for different environments (dev/staging/prod)
- **Monitoring**: Monitor API key usage and detect anomalies

### Secure Storage Options
| Platform | Recommended Storage | Implementation |
|----------|-------------------|----------------|
| **Linux/macOS** | Environment variables | `export GEOIP_API_KEY=key` |
| **Windows** | Credential Manager | PowerShell `Get-StoredCredential` |
| **Docker** | Docker secrets | `docker secret create api_key` |
| **Kubernetes** | K8s Secrets | `kubectl create secret generic` |
| **AWS** | Systems Manager | Parameter Store with encryption |

### Network Security
- **HTTPS Only**: All API communications use TLS 1.2+
- **Firewall Rules**: Restrict outbound access to required endpoints only
- **VPN**: Consider VPN for sensitive environments
- **Proxy Support**: Configure corporate proxy settings when required

## Docker Security

### Container Hardening
- **Non-Root Execution**: All containers run as UID 1000 (non-root user)
- **Read-Only Root Filesystem**: Prevents runtime modifications
- **No New Privileges**: Security flag prevents privilege escalation
- **Resource Limits**: CPU and memory limits prevent resource exhaustion
- **Health Checks**: Automated monitoring for container health

### Secure Cron Implementation
Using **supercronic** instead of traditional cron for enhanced security:

```dockerfile
# Secure cron container example
FROM alpine:latest
RUN addgroup -g 1000 geoip && adduser -u 1000 -G geoip -s /bin/sh -D geoip
USER 1000:1000
COPY --from=supercronic /usr/local/bin/supercronic /usr/local/bin/
```

**Security Benefits**:
- Runs as non-root user
- No sensitive data written to disk
- Environment variable inheritance (no API keys in cron files)
- Prometheus metrics for monitoring
- Lightweight and container-optimized

### Docker Compose Security
```yaml
services:
  geoip-updater:
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp:noexec,nosuid,size=100m
    cap_drop:
      - ALL
    networks:
      - internal
networks:
  internal:
    driver: bridge
    internal: true
```

## Kubernetes Security

### Pod Security Standards
All Kubernetes deployments implement **restricted** security standards:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 0  # OpenShift compatibility
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  seccompProfile:
    type: RuntimeDefault
  capabilities:
    drop:
    - ALL
```

### Network Policies
Egress-only network policy for database downloads:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: geoip-updater-netpol
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: geoip-updater
  policyTypes:
  - Egress
  egress:
  - to: []
    ports:
    - protocol: TCP
      port: 53  # DNS
    - protocol: UDP
      port: 53  # DNS
    - protocol: TCP
      port: 443  # HTTPS
```

### Secret Management
```yaml
# Create secrets securely
kubectl create secret generic geoip-api-credentials \
  --from-literal=api-key=your-actual-api-key \
  --from-literal=api-endpoint=https://your-api-endpoint \
  -n geoip-system

# Use in deployment
env:
- name: GEOIP_API_KEY
  valueFrom:
    secretKeyRef:
      name: geoip-api-credentials
      key: api-key
      optional: false
```

### RBAC (Role-Based Access Control)
Minimal permissions for service accounts:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: geoip-updater-role
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create"]
```

## API Server Security

### Authentication
- **API Key Authentication**: Header, query parameter, or session-based
- **Rate Limiting**: 50 IPs per query to prevent abuse
- **Session Management**: Secure cookie-based sessions with CSRF protection

### CORS Configuration
```python
# Secure CORS settings
CORS_ALLOW_CREDENTIALS = True
CORS_ALLOW_ORIGINS = [
    "https://your-domain.com",
    "https://your-app.com"
]
CORS_ALLOW_HEADERS = ["X-API-Key", "Content-Type"]
```

### Production Deployment
```yaml
# Nginx reverse proxy with security headers
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

# Security headers
add_header X-Frame-Options DENY;
add_header X-Content-Type-Options nosniff;
add_header X-XSS-Protection "1; mode=block";
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";
```

## Cloud Platform Security

### AWS Security
- **IAM Roles**: Use IAM roles instead of access keys when possible
- **S3 Bucket Policies**: Restrict S3 access to specific resources
- **VPC**: Deploy Lambda functions in VPC for network isolation
- **CloudTrail**: Enable API logging for audit trails

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::your-geoip-bucket/raw/*"
    }
  ]
}
```

### Multi-Cloud Considerations
- Use cloud-native secret management (AWS Secrets Manager, GCP Secret Manager)
- Implement least-privilege access policies
- Enable audit logging and monitoring
- Use managed identity services when available

## Security Monitoring

### Log Security
```bash
# Secure log file permissions
chmod 640 /var/log/geoip-update.log
chown geoip:adm /var/log/geoip-update.log

# Logrotate configuration
/var/log/geoip-update.log {
    weekly
    rotate 52
    compress
    delaycompress
    create 640 geoip adm
}
```

### Audit Events
Monitor these security-relevant events:
- API key authentication failures
- Unusual download patterns
- File permission changes
- Network connection anomalies
- Container restart patterns

### Health Monitoring
```bash
# Monitor for security issues
# Failed authentication attempts
grep "authentication failed" /var/log/geoip-update.log | wc -l

# File integrity monitoring
find /opt/geoip -type f -name "*.sh" -exec md5sum {} \; > checksums.txt
```

## Compliance Considerations

### Data Protection
- **Transit Encryption**: All data transfers use TLS 1.2+
- **At-Rest Encryption**: Use encrypted storage volumes
- **Data Residency**: Configure storage locations per requirements
- **Retention Policies**: Implement log and data retention policies

### Security Standards Alignment
The implementations follow security best practices from:
- **CIS Docker Benchmark**: Container security hardening
- **CIS Kubernetes Benchmark**: K8s cluster security
- **NIST Container Security Guidelines**: Federal security standards
- **OWASP Container Security Top 10**: Application security

### Audit Requirements
```bash
# Generate security audit report
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  -v /tmp:/tmp \
  aquasec/trivy image geoip-updater:latest

# Kubernetes security scanning
kubectl run kube-hunter --image=aquasec/kube-hunter --restart=Never -- --report json
```

## Incident Response

### Security Incident Checklist
1. **Immediate Response**
   - Isolate affected systems
   - Preserve logs and evidence
   - Assess scope of compromise

2. **Investigation**
   - Review audit logs
   - Check file integrity
   - Analyze network traffic

3. **Recovery**
   - Rotate compromised credentials
   - Update and patch systems
   - Validate system integrity

4. **Prevention**
   - Update security policies
   - Improve monitoring
   - Conduct lessons learned

### Emergency Procedures
```bash
# Emergency API key rotation
# 1. Generate new API key from provider
# 2. Update secrets in all deployments
kubectl patch secret geoip-api-credentials -p='{"data":{"api-key":"<base64-new-key>"}}'

# 3. Restart all pods to use new key
kubectl rollout restart deployment/geoip-updater -n geoip-system

# 4. Verify new key works
kubectl logs -l app=geoip-updater -n geoip-system --tail=10
```

## Security Checklist

### Pre-Deployment
- [ ] API keys stored securely (not in code)
- [ ] Network access restricted to required endpoints
- [ ] Container runs as non-root user
- [ ] File permissions properly configured
- [ ] Security scanning completed
- [ ] Secrets encrypted at rest and in transit

### Runtime Security
- [ ] Monitor authentication failures
- [ ] Track unusual access patterns
- [ ] Validate file integrity regularly
- [ ] Update dependencies regularly
- [ ] Review logs for anomalies
- [ ] Test incident response procedures

### Compliance
- [ ] Document security configurations
- [ ] Maintain audit trails
- [ ] Implement retention policies
- [ ] Regular security assessments
- [ ] Staff security training
- [ ] Vendor security validation

## Security Resources

### Documentation References
- [Docker Security Best Practices](https://docs.docker.com/engine/security/)
- [Kubernetes Security Concepts](https://kubernetes.io/docs/concepts/security/)
- [OWASP Container Security](https://owasp.org/www-project-container-security/)
- [CIS Benchmarks](https://www.cisecurity.org/cis-benchmarks/)

### Security Tools
- **Container Scanning**: Trivy, Grype, Docker Scout
- **Kubernetes Security**: Falco, OPA Gatekeeper, Polaris
- **Secrets Management**: HashiCorp Vault, AWS Secrets Manager
- **Network Security**: Istio, Linkerd, Cilium

---

**Important**: Security is a shared responsibility. Regular security assessments, monitoring, and updates are essential for maintaining a secure GeoIP database infrastructure.