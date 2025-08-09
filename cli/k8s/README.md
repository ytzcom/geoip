# GeoIP Updater - Kubernetes Deployment

Kubernetes CronJob manifests for running GeoIP database updates in a cluster.

## Features

- **CronJob Scheduling**: Automated updates on a configurable schedule
- **Security Hardened**: Runs with minimal privileges, NetworkPolicies, and RBAC
- **Multi-Environment**: Dev/staging/prod configurations with Kustomize
- **Monitoring Ready**: Prometheus alerts and metrics
- **Flexible Storage**: Supports various storage classes and access modes
- **Multiple Implementations**: Python, Go, or containerized versions

## Quick Start

### Prerequisites

- Kubernetes cluster (1.19+)
- kubectl configured
- Storage provisioner that supports RWX (for shared access)

### Basic Deployment

```bash
# Deploy using kubectl
kubectl apply -k .

# Or deploy individual resources
kubectl apply -f namespace.yaml
kubectl apply -f secret.yaml  # Edit with your API credentials first!
kubectl apply -f configmap.yaml
kubectl apply -f pvc.yaml
kubectl apply -f rbac.yaml
kubectl apply -f cronjob.yaml
```

### Using Kustomize for Different Environments

```bash
# Deploy to development
kubectl apply -k overlays/dev

# Deploy to production
kubectl apply -k overlays/prod

# Preview changes without applying
kubectl kustomize overlays/prod
```

## Configuration

### 1. API Credentials

Edit `secret.yaml` or use a secret management tool:

```yaml
stringData:
  api-key: "your_actual_api_key"
  api-endpoint: "https://xxx.execute-api.region.amazonaws.com/v1/auth"
```

**Better approach**: Use Sealed Secrets or External Secrets Operator:

```bash
# Using sealed-secrets
echo -n "your_api_key" | kubectl create secret generic geoip-api-credentials \
  --dry-run=client \
  --from-file=api-key=/dev/stdin \
  -o yaml | kubeseal -o yaml > sealed-secret.yaml

# Using external-secrets with AWS Secrets Manager
kubectl apply -f external-secret.yaml
```

### 2. Schedule Configuration

Modify the CronJob schedule in `cronjob.yaml`:

```yaml
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM UTC
  # Examples:
  # "0 */6 * * *"    - Every 6 hours
  # "0 2 * * MON"    - Weekly on Monday at 2 AM
  # "*/30 * * * *"   - Every 30 minutes (testing)
```

### 3. Storage Configuration

Adjust PVC size and storage class:

```yaml
spec:
  storageClassName: fast-ssd  # Your storage class
  accessModes:
    - ReadWriteMany  # RWX for shared access
  resources:
    requests:
      storage: 1Gi
```

### 4. Resource Limits

Configure CPU/memory in `cronjob.yaml`:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

## Deployment Options

### Option 1: Python Script in Generic Image

Uses python:3.11-slim and installs dependencies at runtime:

```yaml
containers:
- name: geoip-updater
  image: python:3.11-slim
  command: ["/bin/sh", "-c"]
  args:
    - |
      pip install --no-cache-dir aiohttp pyyaml click
      python /scripts/geoip-update.py --quiet
```

### Option 2: Pre-built Docker Image

Build and push your image:

```bash
# Build image
cd scripts/cli/docker
docker build -t your-registry/geoip-updater:v1.0.0 .
docker push your-registry/geoip-updater:v1.0.0

# Update cronjob.yaml
image: your-registry/geoip-updater:v1.0.0
```

### Option 3: Go Binary in Minimal Image

For smallest footprint:

```dockerfile
FROM scratch
COPY geoip-update /
ENTRYPOINT ["/geoip-update"]
```

## Monitoring

### View CronJob Status

```bash
# List cronjobs
kubectl get cronjobs -n geoip-system

# View last runs
kubectl get jobs -n geoip-system

# Check logs from last job
kubectl logs -n geoip-system job/geoip-updater-xxxxx
```

### Prometheus Alerts

Deploy the alerts ConfigMap:

```bash
kubectl apply -f monitoring.yaml
```

Available alerts:
- `GeoIPUpdateFailed`: No successful update in 48 hours
- `GeoIPUpdateFailureRate`: High failure rate (>50%)
- `GeoIPStorageSpaceLow`: Less than 10% storage remaining

### Manual Trigger

```bash
# Create a job from the cronjob
kubectl create job --from=cronjob/geoip-updater manual-update-$(date +%s) -n geoip-system

# Watch the job
kubectl logs -f job/manual-update-xxxxx -n geoip-system
```

## Accessing Databases

### From Other Pods

Mount the PVC in your application:

```yaml
spec:
  volumes:
  - name: geoip-data
    persistentVolumeClaim:
      claimName: geoip-data
      readOnly: true
  containers:
  - name: app
    volumeMounts:
    - name: geoip-data
      mountPath: /geoip
      readOnly: true
```

### Using InitContainer

Copy databases to local storage:

```yaml
initContainers:
- name: copy-geoip
  image: busybox
  command: ['sh', '-c', 'cp /source/* /target/']
  volumeMounts:
  - name: geoip-data
    mountPath: /source
    readOnly: true
  - name: local-data
    mountPath: /target
```

### ConfigMap for Small Databases

For small databases, store in ConfigMap:

```bash
# Create ConfigMap from database files
kubectl create configmap geoip-databases \
  --from-file=GeoIP2-Country.mmdb \
  -n geoip-system
```

## Advanced Configuration

### Multi-Region Deployment

Deploy to multiple regions with different schedules:

```yaml
# Region-specific overlay
patches:
  - target:
      kind: CronJob
    patch: |-
      - op: add
        path: /spec/jobTemplate/spec/template/spec/nodeSelector
        value:
          topology.kubernetes.io/region: us-east-1
```

### High Availability

Use multiple replicas with different schedules:

```bash
# Deploy multiple CronJobs with staggered schedules
for i in 0 6 12 18; do
  cat cronjob.yaml | \
    sed "s/name: geoip-updater/name: geoip-updater-$i/" | \
    sed "s/schedule: .*/schedule: \"0 $i * * *\"/" | \
    kubectl apply -f -
done
```

### Database Validation Job

Run validation after updates:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: geoip-validator
spec:
  template:
    spec:
      containers:
      - name: validator
        image: maxmind/geoipupdate:latest
        command: ["sh", "-c"]
        args:
          - |
            for db in /data/*.mmdb; do
              if [ -f "$db" ]; then
                echo "Validating $db..."
                # Add validation logic
              fi
            done
```

## Troubleshooting

### Common Issues

1. **CronJob Not Running**
   ```bash
   # Check if CronJob is suspended
   kubectl get cronjob geoip-updater -n geoip-system -o yaml | grep suspend
   
   # Check for schedule issues
   kubectl describe cronjob geoip-updater -n geoip-system
   ```

2. **Job Failures**
   ```bash
   # View failed jobs
   kubectl get jobs -n geoip-system | grep Failed
   
   # Check logs
   kubectl logs job/geoip-updater-xxxxx -n geoip-system
   
   # Describe job for events
   kubectl describe job geoip-updater-xxxxx -n geoip-system
   ```

3. **Storage Issues**
   ```bash
   # Check PVC status
   kubectl get pvc -n geoip-system
   
   # Check available space
   kubectl exec -n geoip-system job/geoip-updater-xxxxx -- df -h /data
   ```

4. **Permission Denied**
   ```bash
   # Check security context
   kubectl get pod -n geoip-system -o yaml | grep -A5 securityContext
   
   # Verify ServiceAccount
   kubectl get sa geoip-updater -n geoip-system
   ```

### Debug Mode

Create a debug pod:

```bash
kubectl run debug-geoip \
  --image=python:3.11-slim \
  --namespace=geoip-system \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "debug",
        "image": "python:3.11-slim",
        "command": ["sleep", "3600"],
        "volumeMounts": [{
          "name": "geoip-data",
          "mountPath": "/data"
        }],
        "env": [{
          "name": "GEOIP_API_KEY",
          "valueFrom": {
            "secretKeyRef": {
              "name": "geoip-api-credentials",
              "key": "api-key"
            }
          }
        }]
      }],
      "volumes": [{
        "name": "geoip-data",
        "persistentVolumeClaim": {
          "claimName": "geoip-data"
        }
      }]
    }
  }' \
  -it -- /bin/bash
```

## Cleanup

Remove all resources:

```bash
# Using kustomize
kubectl delete -k .

# Or manually
kubectl delete namespace geoip-system

# Remove PVs if not automatically cleaned
kubectl delete pv -l app.kubernetes.io/name=geoip-updater
```

## Security Considerations

1. **Secret Management**: Use Sealed Secrets, External Secrets, or Vault
2. **Network Policies**: Restrict egress to API endpoints only
3. **RBAC**: Minimal permissions, dedicated ServiceAccount
4. **Pod Security**: Non-root user, read-only root filesystem
5. **Resource Limits**: Prevent resource exhaustion

## Best Practices

1. **Monitoring**: Set up alerts for failed updates
2. **Backup**: Consider backing up databases before updates
3. **Testing**: Test in dev/staging before production
4. **Versioning**: Tag images with specific versions
5. **Documentation**: Document your specific configuration

## License

See the main project LICENSE file.