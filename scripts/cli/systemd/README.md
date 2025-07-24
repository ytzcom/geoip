# GeoIP Update Systemd Service

Systemd service and timer units for automated GeoIP database updates on modern Linux systems.

## Features

- **Automated Updates**: Daily updates via systemd timer
- **Security Hardened**: Runs with minimal privileges and strict sandboxing
- **Resource Limited**: CPU and memory quotas prevent resource exhaustion
- **Persistent**: Catches up on missed updates after system downtime
- **Multiple Script Support**: Works with Bash, Python, or Go implementations

## Quick Installation

### Automated Installation

```bash
# Make install script executable
chmod +x install.sh

# Run installer (requires root)
sudo ./install.sh
```

The installer will:
1. Create a dedicated system user (`geoip`)
2. Set up necessary directories
3. Install your chosen script (Bash/Python/Go)
4. Configure systemd service and timer
5. Help you set up the configuration

### Manual Installation

```bash
# Create user and directories
sudo useradd --system --home-dir /var/lib/geoip --shell /bin/false geoip
sudo mkdir -p /var/lib/geoip /var/log/geoip /etc/geoip-update
sudo chown geoip:geoip /var/lib/geoip /var/log/geoip

# Install script (choose one)
sudo cp ../geoip-update.sh /usr/local/bin/
sudo chmod 755 /usr/local/bin/geoip-update.sh

# Install systemd units
sudo cp geoip-update.service geoip-update.timer /etc/systemd/system/
sudo cp config.example /etc/geoip-update/config
sudo chmod 600 /etc/geoip-update/config

# Edit configuration
sudo nano /etc/geoip-update/config

# Enable and start timer
sudo systemctl daemon-reload
sudo systemctl enable geoip-update.timer
sudo systemctl start geoip-update.timer
```

## Configuration

### Environment File

Edit `/etc/geoip-update/config`:

```bash
# Required
GEOIP_API_KEY=your_api_key_here
GEOIP_API_ENDPOINT=https://your-api.execute-api.region.amazonaws.com/v1/auth

# Optional
GEOIP_TARGET_DIR=/var/lib/geoip
GEOIP_LOG_FILE=/var/log/geoip/update.log
#GEOIP_DATABASES=GeoIP2-City.mmdb,GeoIP2-Country.mmdb
```

### Timer Schedule

The default schedule runs daily at 2 AM. To modify:

1. Edit `/etc/systemd/system/geoip-update.timer`
2. Change the `OnCalendar` value:
   ```ini
   # Every 6 hours
   OnCalendar=*-*-* 00,06,12,18:00:00
   
   # Weekly on Monday at 3 AM
   OnCalendar=Mon *-*-* 03:00:00
   
   # Twice daily
   OnCalendar=*-*-* 02,14:00:00
   ```
3. Reload: `sudo systemctl daemon-reload`

## Service Management

### Basic Commands

```bash
# Check timer status
systemctl status geoip-update.timer

# See next scheduled run
systemctl list-timers geoip-update

# Run update manually
sudo systemctl start geoip-update.service

# Stop timer
sudo systemctl stop geoip-update.timer

# Disable timer
sudo systemctl disable geoip-update.timer
```

### Monitoring

```bash
# View service logs
journalctl -u geoip-update.service

# Follow logs in real-time
journalctl -u geoip-update.service -f

# View last run
journalctl -u geoip-update.service -n 50

# Check for errors
journalctl -u geoip-update.service -p err
```

## Security Features

The service runs with strict security hardening:

### Sandboxing
- **NoNewPrivileges**: Prevents privilege escalation
- **PrivateTmp**: Isolated temporary filesystem
- **ProtectSystem**: Read-only system directories
- **ProtectHome**: No access to user home directories

### Resource Limits
- **CPUQuota**: Limited to 50% of one CPU core
- **MemoryLimit**: Maximum 512MB RAM
- **TasksMax**: Maximum 16 processes/threads

### Network Restrictions
- **RestrictAddressFamilies**: Only IPv4/IPv6 allowed
- **RestrictNamespaces**: Namespace creation blocked

### Additional Hardening
- **MemoryDenyWriteExecute**: No writable+executable memory
- **RestrictRealtime**: No realtime scheduling
- **RemoveIPC**: Isolated IPC namespace

## File Locations

| File/Directory | Purpose |
|----------------|---------|
| `/etc/systemd/system/geoip-update.service` | Service unit file |
| `/etc/systemd/system/geoip-update.timer` | Timer unit file |
| `/etc/geoip-update/config` | Environment configuration |
| `/var/lib/geoip/` | Downloaded database files |
| `/var/log/geoip/` | Log files |
| `/usr/local/bin/geoip-update.*` | Update script |

## Troubleshooting

### Common Issues

1. **"Failed to start geoip-update.service"**
   ```bash
   # Check logs for details
   journalctl -xe -u geoip-update.service
   
   # Verify configuration
   sudo cat /etc/geoip-update/config
   ```

2. **"Permission denied"**
   ```bash
   # Fix directory ownership
   sudo chown -R geoip:geoip /var/lib/geoip /var/log/geoip
   ```

3. **"Timer not running"**
   ```bash
   # Check timer status
   systemctl is-enabled geoip-update.timer
   systemctl is-active geoip-update.timer
   
   # Re-enable if needed
   sudo systemctl enable --now geoip-update.timer
   ```

4. **"API authentication failed"**
   ```bash
   # Test configuration
   sudo -u geoip /usr/local/bin/geoip-update.sh -v
   ```

### Manual Testing

Test the service without the timer:

```bash
# Run as the service user
sudo -u geoip /usr/local/bin/geoip-update.sh -v

# Or use systemd
sudo systemctl start geoip-update.service
```

### Reset Everything

```bash
# Stop and disable
sudo systemctl stop geoip-update.timer
sudo systemctl disable geoip-update.timer

# Remove files
sudo rm -f /etc/systemd/system/geoip-update.{service,timer}
sudo rm -rf /etc/geoip-update
sudo systemctl daemon-reload

# Remove user (careful - this deletes data!)
sudo userdel -r geoip
```

## Integration with Applications

### Nginx

```nginx
http {
    geoip2 /var/lib/geoip/GeoIP2-Country.mmdb {
        auto_reload 60m;
        $geoip2_data_country_code default=US source=$remote_addr country iso_code;
    }
}
```

### Apache

```apache
<IfModule mod_geoip.c>
    GeoIPEnable On
    GeoIPDBFile /var/lib/geoip/GeoIP2-Country.mmdb
</IfModule>
```

### Application Access

Grant read access to application users:

```bash
# Add application user to geoip group
sudo usermod -a -G geoip www-data

# Or set specific permissions
sudo setfacl -m u:www-data:rx /var/lib/geoip
sudo setfacl -d -m u:www-data:rx /var/lib/geoip
```

## Monitoring and Alerting

### Prometheus Node Exporter

Monitor file age:

```yaml
# /etc/prometheus/file_sd/geoip.yml
- targets: ['localhost:9100']
  labels:
    job: 'node'
    geoip_path: '/var/lib/geoip'
```

Alert on stale databases:

```yaml
groups:
- name: geoip
  rules:
  - alert: GeoIPDatabaseStale
    expr: time() - node_file_mtime{path="/var/lib/geoip/GeoIP2-City.mmdb"} > 86400 * 7
    for: 1h
    annotations:
      summary: "GeoIP database is older than 7 days"
```

### Custom Monitoring Script

```bash
#!/bin/bash
# Check database freshness
DB_AGE=$(find /var/lib/geoip -name "*.mmdb" -mtime +7 | wc -l)
if [[ $DB_AGE -gt 0 ]]; then
    echo "WARNING: GeoIP databases are older than 7 days"
    exit 1
fi
```

## Best Practices

1. **Regular Updates**: Keep systemd and scripts updated
2. **Log Rotation**: Configure logrotate for `/var/log/geoip/`
3. **Monitoring**: Set up alerts for failed updates
4. **Backup**: Consider backing up databases before updates
5. **Testing**: Test updates in staging before production

## License

See the main project LICENSE file.