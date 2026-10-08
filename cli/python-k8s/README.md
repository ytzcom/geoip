# Kubernetes-Optimized Python CLI

Production-ready Kubernetes container optimized for CronJobs and deployments with enhanced monitoring and cloud-native features.

## ✨ Key Features

- 🎯 **K8s Optimized**: Designed specifically for Kubernetes environments
- 🔒 **OpenShift Compatible**: Runs as non-root user (UID 1000, GID 0)
- 📊 **Cloud Native**: Structured logging, metrics, health checks
- 🚀 **Resource Efficient**: Optimized for cluster resource constraints  
- 🔄 **Job Ready**: Perfect for CronJobs and one-off tasks
- 🌐 **Multi-Platform**: linux/amd64, linux/arm64 support

## 🚀 Quick Start

### Kubernetes CronJob
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: geoip-updater
spec:
  schedule: "0 2 * * *"  # Daily at 2 AM
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: geoip-updater
            image: ytzcom/geoip-updater-k8s:latest
            env:
            - name: GEOIP_API_KEY
              valueFrom:
                secretKeyRef:
                  name: geoip-secret
                  key: api-key
            - name: GEOIP_DATABASES
              value: "city,country,isp"
            volumeMounts:
            - name: geoip-data
              mountPath: /data
            resources:
              requests:
                memory: "128Mi"
                cpu: "100m"
              limits:
                memory: "512Mi"
                cpu: "500m"
          volumes:
          - name: geoip-data
            persistentVolumeClaim:
              claimName: geoip-pvc
```

### Kubernetes Job (One-time)
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: geoip-initial-download
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: geoip-updater
        image: ytzcom/geoip-updater-k8s:latest
        env:
        - name: GEOIP_API_KEY
          valueFrom:
            secretKeyRef:
              name: geoip-secret
              key: api-key
        volumeMounts:
        - name: geoip-data
          mountPath: /data
      volumes:
      - name: geoip-data
        persistentVolumeClaim:
          claimName: geoip-pvc
```

## 🔧 Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GEOIP_API_KEY` | *(required)* | Your authentication API key |
| `GEOIP_API_ENDPOINT` | `https://geoipdb.net/auth` | API endpoint URL |
| `GEOIP_TARGET_DIR` | `/data` | Database storage directory |
| `GEOIP_DATABASES` | `all` | Databases to download |
| `GEOIP_TIMEOUT` | `1800` | Download timeout in seconds |
| `GEOIP_MAX_RETRIES` | `3` | Maximum retry attempts |
| `GEOIP_CONCURRENT` | `2` | Max concurrent downloads |
| `GEOIP_LOG_FILE` | - | Log file path |
| `GEOIP_ONLY_CHANGED` | - | Download only changed databases (`true`, `1`, `yes`) |
| `GEOIP_LOCK_FILE` | - | Exclusive lock on a shared path |
| `GEOIP_LOCK_TIMEOUT` | `1800` | Seconds to wait for `GEOIP_LOCK_FILE` |

Command-line arguments (`args:`) win over environment variables.

### Change Detection and Shared-Path Locking

The image runs the [Python CLI](../python/README.md). Recommended for CronJobs and for a volume shared between pods (`ReadWriteMany`):

```yaml
            args: ["--only-changed", "--lock-file", "/data/.geoip-update.lock"]
            # or, through the environment:
            env:
            - name: GEOIP_ONLY_CHANGED
              value: "true"
            - name: GEOIP_LOCK_FILE
              value: /data/.geoip-update.lock
```

`--force` downloads everything even with `--only-changed`, and `--lock-timeout SECONDS` (`GEOIP_LOCK_TIMEOUT`) sets the lock wait limit.

- **Manifest.** With change detection on, the client keeps `<target>/.geoip-update.json` with each database's ETag, `Last-Modified` and size, in the same layout every client writes. A database is skipped with `Unchanged: <name>` when the server answers its conditional request (`If-None-Match`) with `304`. It downloads when the file is missing, the manifest has no entry, or the size on disk differs. The manifest is written once at the end of the run; an unreadable manifest is treated as absent. A run where everything is unchanged exits `0`.
- **Lock.** A lock file takes an exclusive kernel lock that the operating system releases on any exit, including `kill -9`, so a crashed run never blocks the next one. A second run waits up to the lock timeout (default `1800` s), then logs `Timed out after N s waiting for lock PATH` and exits `1`. Setting `GEOIP_LOCK_FILE` together with `--no-lock` exits `1` with `--lock-file and --no-lock cannot be combined`.
- **Staging.** Downloads go to `<target>/<name>.part` and are renamed into place, so a pod or container reading the volume never sees a partial file. A failed download removes its `.part`.
- **`GEOIP_TIMEOUT` / `--timeout`** does not abort a stalled transfer.

Details for every client: [CLI Overview](../README.md#-change-detection-shared-path-locking-and-staging).

### Kubernetes Secrets

Create secrets for sensitive configuration:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: geoip-secret
type: Opaque
stringData:
  api-key: "your-api-key-here"
  endpoint: "https://geoipdb.net/auth"
```

### ConfigMaps

Store non-sensitive configuration:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: geoip-config
data:
  databases: "city,country,isp"
  timeout: "300"
  log-level: "INFO"
  max-retries: "3"
```

Use in deployment:
```yaml
envFrom:
- configMapRef:
    name: geoip-config
- secretRef:
    name: geoip-secret
```

## 📦 Storage Configuration

### Persistent Volume Claim

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: geoip-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: fast-ssd  # Use appropriate storage class
  resources:
    requests:
      storage: 5Gi  # Enough for all databases
```

### Shared Storage (Multi-Pod Access)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: geoip-shared-pvc
spec:
  accessModes:
    - ReadWriteMany  # Multiple pods can access
  storageClassName: nfs-client
  resources:
    requests:
      storage: 5Gi
```

## 🎯 Resource Management

### Resource Requests and Limits

```yaml
resources:
  requests:
    memory: "128Mi"    # Minimum memory
    cpu: "100m"        # 0.1 CPU cores
  limits:
    memory: "512Mi"    # Maximum memory
    cpu: "500m"        # 0.5 CPU cores
```

### Recommended Configurations

| Scenario | Memory Request | Memory Limit | CPU Request | CPU Limit |
|----------|----------------|--------------|-------------|-----------|
| **Light Usage** | 64Mi | 256Mi | 50m | 200m |
| **Standard** | 128Mi | 512Mi | 100m | 500m |
| **Heavy Usage** | 256Mi | 1Gi | 200m | 1000m |

### Node Affinity

```yaml
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      preference:
        matchExpressions:
        - key: node-type
          operator: In
          values:
          - worker
```

## 📊 Monitoring & Observability

### Health Checks

Built-in health check endpoint:

```yaml
livenessProbe:
  exec:
    command:
    - /bin/sh
    - -c
    - "pgrep -f geoip-update.py"
  initialDelaySeconds: 10
  periodSeconds: 30

readinessProbe:
  exec:
    command:
    - /bin/sh  
    - -c
    - "ls /data/*.mmdb >/dev/null 2>&1"
  initialDelaySeconds: 5
  periodSeconds: 10
```

### Structured Logging

Logs are output in JSON format for easy parsing:

```json
{
  "timestamp": "2025-08-09T10:30:00Z",
  "level": "INFO",
  "message": "Download completed",
  "database": "GeoIP2-City.mmdb",
  "size": "115MB",
  "duration": "45.2s"
}
```

### Metrics Collection

Compatible with Prometheus monitoring:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: geoip-metrics
  labels:
    app: geoip-updater
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
spec:
  ports:
  - port: 8080
    targetPort: metrics
  selector:
    app: geoip-updater
```

## 🔐 Security Considerations

### Pod Security Context

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 0          # OpenShift compatibility
  fsGroup: 1000
  allowPrivilegeEscalation: false
  capabilities:
    drop:
    - ALL
```

### Security Policies

Pod Security Policy example:

```yaml
apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  name: geoip-psp
spec:
  privileged: false
  allowPrivilegeEscalation: false
  requiredDropCapabilities:
    - ALL
  volumes:
    - 'persistentVolumeClaim'
    - 'secret'
    - 'configMap'
  runAsUser:
    rule: 'MustRunAsNonRoot'
  seLinux:
    rule: 'RunAsAny'
  fsGroup:
    rule: 'RunAsAny'
```

### Network Policies

Restrict network access:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: geoip-netpol
spec:
  podSelector:
    matchLabels:
      app: geoip-updater
  policyTypes:
  - Egress
  egress:
  - to: []
    ports:
    - protocol: TCP
      port: 443  # HTTPS only
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53   # DNS
```

## 🚨 Error Handling & Recovery

### Restart Policies

```yaml
# For CronJobs
restartPolicy: OnFailure

# For regular Jobs  
restartPolicy: Never

# For Deployments
restartPolicy: Always
```

### Failure Handling

```yaml
# CronJob failure handling
failedJobsHistoryLimit: 3
successfulJobsHistoryLimit: 1
concurrencyPolicy: Forbid  # Prevent overlapping jobs

# Job failure handling  
backoffLimit: 3           # Retry up to 3 times
activeDeadlineSeconds: 600 # Kill job after 10 minutes
```

### Alerting

Example Prometheus alert:

```yaml
groups:
- name: geoip-updater
  rules:
  - alert: GeoIPUpdateFailed
    expr: increase(kubernetes_job_status_failed[5m]) > 0
    for: 0m
    labels:
      severity: warning
    annotations:
      summary: "GeoIP update job failed"
      description: "GeoIP updater job failed in namespace {{ $labels.namespace }}"
```

## 🔄 Deployment Patterns

### Blue-Green Deployment

```yaml
# Blue deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: geoip-blue
spec:
  selector:
    matchLabels:
      app: geoip-updater
      version: blue
  template:
    metadata:
      labels:
        app: geoip-updater
        version: blue
    spec:
      containers:
      - name: geoip-updater
        image: ytzcom/geoip-updater-k8s:v1.0
        # ... configuration
```

### Canary Deployment

Using Argo Rollouts:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: geoip-rollout
spec:
  replicas: 3
  strategy:
    canary:
      steps:
      - setWeight: 33
      - pause: {}
      - setWeight: 67
      - pause: {duration: 10m}
  selector:
    matchLabels:
      app: geoip-updater
  template:
    # ... pod template
```

## 🏗️ Technical Details

### Architecture

- **Base Image**: Python 3.11-slim for security and size
- **User**: Non-root execution (UID 1000, GID 0)
- **Platform**: Multi-architecture (amd64, arm64)
- **Size**: ~150MB compressed

### File Structure

```
Container Layout:
/app/
├── geoip-update.py     # Main Python script
└── entrypoint.sh       # Container entrypoint

/data/                  # Database storage (volume)
├── GeoIP2-City.mmdb
├── GeoIP2-Country.mmdb
└── ...

/tmp/                   # Temporary files
└── geoip-*.tmp
```

### Optimization Features

- **Async downloads**: Concurrent database downloads
- **Smart caching**: Only downloads if files changed
- **Resource limits**: Memory and CPU usage monitoring
- **Graceful shutdown**: Handles SIGTERM properly

## 🔗 Related Documentation

- **[Kubernetes Deployment Guide](../../k8s/README.md)** - Complete K8s setup
- **[Python CLI](../python/README.md)** - Base Python implementation
- **[Docker Cron](../python-cron/README.md)** - Cron scheduling version
- **[Security Guide](../../docs/SECURITY.md)** - Security best practices

## 🤝 Contributing

To modify this Kubernetes image:

1. **Test locally**:
   ```bash
   docker build -t test-k8s .
   docker run --rm -e GEOIP_API_KEY=test test-k8s
   ```

2. **Test in cluster**:
   ```bash
   kubectl create job test-job --image=test-k8s
   kubectl logs job/test-job
   ```

3. **Submit pull request**: Include K8s manifests and documentation updates