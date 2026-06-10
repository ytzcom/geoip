#!/bin/bash

# Update README.sh - Updates README with latest database status
# Usage: ./update-readme.sh <timestamp> <total_count> <maxmind_count> <ip2location_count> [s3_bucket]

TIMESTAMP="$1"
TOTAL_COUNT="$2"
MAXMIND_COUNT="$3"
IP2LOCATION_COUNT="$4"
S3_BUCKET="${5:-your-geoip-bucket}"

# Create URL-encoded version of timestamp for badge (replace spaces with %20 and escape dashes)
TIMESTAMP_BADGE=$(echo "$TIMESTAMP" | sed 's/ /%20/g' | sed 's/-/--/g')

# Get file sizes from S3
echo "Fetching file sizes from S3..."

# Function to get human-readable file size
get_file_size() {
    local bucket="$1"
    local key="$2"
    local size_bytes=$(aws s3api head-object --bucket "$bucket" --key "$key" 2>/dev/null | jq -r '.ContentLength // 0')
    
    if [ "$size_bytes" -eq 0 ]; then
        echo "N/A"
    elif [ "$size_bytes" -lt 1024 ]; then
        echo "${size_bytes}B"
    elif [ "$size_bytes" -lt 1048576 ]; then
        echo "$((size_bytes / 1024))KB"
    elif [ "$size_bytes" -lt 1073741824 ]; then
        echo "$((size_bytes / 1048576))MB"
    else
        echo "$((size_bytes / 1073741824))GB"
    fi
}

# Get sizes for each database
CITY_SIZE=$(get_file_size "$S3_BUCKET" "raw/maxmind/GeoIP2-City.mmdb")
COUNTRY_SIZE=$(get_file_size "$S3_BUCKET" "raw/maxmind/GeoIP2-Country.mmdb")
ISP_SIZE=$(get_file_size "$S3_BUCKET" "raw/maxmind/GeoIP2-ISP.mmdb")
CONNECTION_SIZE=$(get_file_size "$S3_BUCKET" "raw/maxmind/GeoIP2-Connection-Type.mmdb")

DB23_BIN_SIZE=$(get_file_size "$S3_BUCKET" "raw/ip2location/IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN")
DB23_BIN6_SIZE=$(get_file_size "$S3_BUCKET" "raw/ip2location/IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN")
PX2_BIN_SIZE=$(get_file_size "$S3_BUCKET" "raw/ip2location/IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN")

# Create README content
cat > README.md << 'EOF'
# GeoIP Database Updater

![Workflow Status](https://github.com/ytzcom/geoip/workflows/Update%20GeoIP%20Databases/badge.svg)
![Last Update](https://img.shields.io/badge/Last%20Update-TIMESTAMP_BADGE_PLACEHOLDER-blue)
![Database Count](https://img.shields.io/badge/Databases-TOTAL_PLACEHOLDER-green)
![MaxMind Databases](https://img.shields.io/badge/MaxMind-MAXMIND_PLACEHOLDER-orange)
![IP2Location Databases](https://img.shields.io/badge/IP2Location-IP2LOCATION_PLACEHOLDER-purple)

A self-hostable pipeline that keeps **MaxMind** and **IP2Location** GeoIP databases up to date. A scheduled GitHub Actions workflow downloads the databases using *your own* provider credentials, validates them, and stores them in *your own* private S3 bucket. An optional authenticated API hands out short-lived presigned download URLs, and CLI clients (Bash, PowerShell, Python, Go) fetch and verify them.

> The maintainers run a reference deployment at `https://geoipdb.net`. Access to it needs an API key we issue — to use this project freely, **run your own instance** with your own credentials (see below).

## 🧭 How it works

```
MaxMind / IP2Location          <- your provider accounts
       |  download + validate     (GitHub Actions, weekly: Mondays 00:00 UTC)
       v
   Your private S3 bucket
       |  presigned URL on request
       v
   Auth API (optional)           (Lambda or Docker/K8s - validates API keys)
       |
       v
   CLI clients / GitHub Action <- fetch + verify databases
```

## 🧩 Repository structure

| Path | What it is |
|------|------------|
| [`.github/workflows/`](.github/workflows/README.md) | The scheduled pipeline (`update-geoip.yml`) plus build, release and deploy workflows |
| [`github-actions/`](github-actions/) | Scripts the workflow runs: download, extract, validate, upload to S3, README update |
| [`action.yml`](docs/GITHUB_ACTION.md) | Reusable composite GitHub Action to download & cache databases in your own CI |
| [`cli/`](cli/README.md) | Download clients: [Bash](cli/README.md), [Python](cli/python/README.md), [Go](cli/go/README.md), [cron](cli/python-cron/README.md), [Kubernetes](cli/python-k8s/README.md), [systemd](cli/systemd/README.md) |
| [`api-server/`](api-server/README.md) | FastAPI auth/query server that issues presigned S3 URLs (Docker-deployable) |
| [`deploy/`](deploy/README.md) | Deploy the auth API — [Terraform/Lambda](deploy/terraform/README.md) or Docker |
| [`k8s/`](k8s/README.md) | Kubernetes CronJob manifests for running updates in-cluster |
| [`docker-scripts/`](docker-scripts/README.md) | Minimal Docker image bundling the clients and validators |
| [`docs/`](docs/) | Guides: [GitHub Action](docs/GITHUB_ACTION.md) · [notifications](docs/NOTIFICATIONS.md) · [releases](docs/RELEASE_PROCESS.md) · [troubleshooting](docs/TROUBLESHOOTING.md) · [security](docs/SECURITY.md) · [Docker cleanup](docs/DOCKER_CLEANUP.md) |

## 📥 Using the databases

**Existing geoipdb.net users** — if the maintainers have issued you an API key for the hosted service, the bundled CLI handles auth, download and validation. It targets `https://geoipdb.net/auth` by default, so you only need your key:

```bash
# Bash - see cli/README.md for PowerShell, Python, Go and selection options
./cli/geoip-update.sh -k YOUR_API_KEY
```

In CI, use the reusable GitHub Action:

```yaml
- uses: ytzcom/geoip@main
  with:
    api-key: ${{ secrets.GEOIP_API_KEY }}
    databases: all
    # auth-endpoint defaults to https://geoipdb.net/auth
```

Or call the API directly for presigned URLs:

```bash
curl -s -X POST https://geoipdb.net/auth \
  -H "X-API-Key: YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"databases": "all"}'
```

**Self-hosting your own deployment?** Point the same clients at your endpoint with `GEOIP_API_ENDPOINT` (or the Action's `auth-endpoint`) — see **Running your own instance** below.

See **[cli/README.md](cli/README.md)** and **[docs/GITHUB_ACTION.md](docs/GITHUB_ACTION.md)** for every option.

## 🏗️ Running your own instance

The project is free to use with **your own credentials**. Self-hosting has two parts: the database **pipeline** (required) and the download **API** (optional).

### 1. Run the database pipeline

You need accounts of your own:

| Credential | Used for | Where to get it |
|-----------|----------|-----------------|
| MaxMind account ID + license key | Downloading MaxMind databases | <https://www.maxmind.com/en/my_license_key> |
| IP2Location download token | Downloading IP2Location databases | <https://www.ip2location.com/web-service> |
| AWS access key + secret | Uploading to S3 | Your AWS IAM user |
| A private S3 bucket | Storing the databases | Your AWS account |

1. **Fork** this repository.
2. Add repository **secrets** (Settings → Secrets and variables → Actions → *Secrets*): `MAXMIND_LICENSE_KEY`, `IP2LOCATION_TOKEN`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` _(optional: `SLACK_WEBHOOK_URL`)_.
3. Add repository **variables** (same screen → *Variables*): `MAXMIND_ACCOUNT_ID`, `S3_BUCKET` (your bucket name), `AWS_REGION` _(optional: `CREATE_ISSUE_ON_FAILURE`)_.
4. Run **Update GeoIP Databases** (Actions tab → Run workflow), or wait for the weekly schedule.

Your databases now land in your S3 bucket. Full secret/variable reference: **[.github/workflows/README.md](.github/workflows/README.md)**; stuck? see **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**.

> ⚠️ **Keep your S3 bucket private.** These databases are paid/licensed; public access can leak them and run up your costs.

### 2. (Optional) Deploy the download API

Deploy the authenticated API so clients can fetch databases with an API key. Clone your fork and pick a target:

```bash
git clone https://github.com/YOUR_ORG/geoip.git
cd geoip

# AWS Lambda (serverless) - provisions API Gateway + Lambda
./deploy/deploy.sh

# ...or Docker on your own host
./deploy/docker-deploy.sh
```

The API loads its settings from an `.env` file. Provide it manually (`secrets/.env`), or let the Docker deploy pull it automatically from **[dotenv.ca](https://dotenv.ca)** (optional) by setting `DOTENV_TOKEN`. Full options — API-key management, custom domains and dotenv.ca setup — are in **[deploy/README.md](deploy/README.md)**.

## 📊 Database Information

| Database | Provider | Format | Size | Description |
|----------|----------|--------|------|-------------|
| GeoIP2-City | MaxMind | MMDB | CITY_SIZE_PLACEHOLDER | City-level IP geolocation data |
| GeoIP2-Country | MaxMind | MMDB | COUNTRY_SIZE_PLACEHOLDER | Country-level IP geolocation data |
| GeoIP2-ISP | MaxMind | MMDB | ISP_SIZE_PLACEHOLDER | ISP and organization data |
| GeoIP2-Connection-Type | MaxMind | MMDB | CONNECTION_SIZE_PLACEHOLDER | Connection type data |
| DB23 IPv4 | IP2Location | BIN | DB23_BIN_SIZE_PLACEHOLDER | Comprehensive IPv4 geolocation data |
| DB23 IPv6 | IP2Location | BIN | DB23_BIN6_SIZE_PLACEHOLDER | Comprehensive IPv6 geolocation data |
| PX2 IPv4 | IP2Location | BIN | PX2_BIN_SIZE_PLACEHOLDER | IPv4 proxy detection data |

## 🔧 Usage Examples

### Python (with geoip2)

```python
import geoip2.database

# Load the database
reader = geoip2.database.Reader('GeoIP2-City.mmdb')

# Lookup an IP
response = reader.city('8.8.8.8')
print(f"Country: {response.country.name}")
print(f"City: {response.city.name}")
print(f"Latitude: {response.location.latitude}")
print(f"Longitude: {response.location.longitude}")

reader.close()
```

### Python (with IP2Location)

```python
import IP2Location

# Load the database
db = IP2Location.IP2Location('IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN')

# Lookup an IP
result = db.get_all('8.8.8.8')
print(f"Country: {result.country_long}")
print(f"City: {result.city}")
print(f"ISP: {result.isp}")
```

### Python (with IP2Proxy)

```python
import IP2Proxy

# Load the database
db = IP2Proxy.IP2Proxy('IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN')

# Check if IP is a proxy
result = db.get_all('8.8.8.8')
print(f"Is Proxy: {result.is_proxy}")
print(f"Proxy Type: {result.proxy_type}")
print(f"Country: {result.country_long}")
```

## 🛠️ Integration

### CDN/CloudFront Integration

```javascript
// Example CloudFront function
const geoip = require('geoip-lite');

exports.handler = async (event) => {
    const request = event.Records[0].cf.request;
    const clientIp = request.clientIp;
    
    const geo = geoip.lookup(clientIp);
    if (geo) {
        request.headers['cloudfront-viewer-country'] = [{
            key: 'CloudFront-Viewer-Country',
            value: geo.country
        }];
    }
    
    return request;
};
```

### Nginx Integration

```nginx
# Load MaxMind module
load_module modules/ngx_http_geoip2_module.so;

http {
    # Define GeoIP2 databases
    geoip2 /path/to/GeoIP2-City.mmdb {
        auto_reload 60m;
        $geoip2_city_country_code country iso_code;
        $geoip2_city_name city names en;
    }
    
    # Use in server block
    server {
        location / {
            add_header X-Country-Code $geoip2_city_country_code;
            add_header X-City $geoip2_city_name;
        }
    }
}
```

## 📋 Requirements

**To run the pipeline (operator):** a GitHub account (to fork and run Actions), MaxMind and IP2Location accounts, and an AWS account with a private S3 bucket. See **Running your own instance** above for the exact secrets and variables.

**To read the databases in your application:** the matching reader library —

```bash
pip install geoip2 IP2Location IP2Proxy
```

- MaxMind `.mmdb` → `geoip2`
- IP2Location `.BIN` → `IP2Location`
- IP2Proxy `.BIN` → `IP2Proxy`

## 🔐 Security

- All databases are validated before upload to ensure integrity.
- They are served only through the authenticated API, which issues short-lived presigned URLs; the storage bucket is **private**, not for direct public access.
- The original provider licenses apply — comply with MaxMind and IP2Location terms.
- Hardening guidance and how to report a vulnerability: **[docs/SECURITY.md](docs/SECURITY.md)**.

## 🤝 Contributing

Contributions are welcome! In short:

1. **Fork** the repo and create a branch (`fix/…`, `feat/…`, `docs/…`).
2. Make a focused change that matches the existing style.
3. Use [Conventional Commits](https://www.conventionalcommits.org/) for messages (e.g. `fix(cli): handle empty response`).
4. Open a pull request describing the change, and make sure CI passes.

See **[CONTRIBUTING.md](CONTRIBUTING.md)** for the full guide. For security issues, **do not** open a public issue — follow **[docs/SECURITY.md](docs/SECURITY.md)**.

## 📄 License

This repository's **code** is licensed under the [MIT License](LICENSE). The GeoIP **databases** are *not* covered by it — they remain subject to their providers' licenses:

- MaxMind: [End User License Agreement](https://www.maxmind.com/en/geolite2/eula)
- IP2Location: [License Agreement](https://www.ip2location.com/licensing)

## 🔗 Links

- [CLI tools](cli/README.md) · [GitHub Action](docs/GITHUB_ACTION.md) · [Deployment](deploy/README.md) · [Contributing](CONTRIBUTING.md)
- [MaxMind GeoIP2](https://www.maxmind.com/en/geoip2-databases) · [IP2Location](https://www.ip2location.com/)

---

**Last Update:** TIMESTAMP_PLACEHOLDER
EOF

# Replace placeholders with actual values
sed -i.bak "s/TIMESTAMP_BADGE_PLACEHOLDER/${TIMESTAMP_BADGE}/g" README.md
sed -i.bak "s/TIMESTAMP_PLACEHOLDER/${TIMESTAMP}/g" README.md
sed -i.bak "s/TOTAL_PLACEHOLDER/${TOTAL_COUNT}/g" README.md
sed -i.bak "s/MAXMIND_PLACEHOLDER/${MAXMIND_COUNT}/g" README.md
sed -i.bak "s/IP2LOCATION_PLACEHOLDER/${IP2LOCATION_COUNT}/g" README.md

# Replace size placeholders
sed -i.bak "s/CITY_SIZE_PLACEHOLDER/${CITY_SIZE}/g" README.md
sed -i.bak "s/COUNTRY_SIZE_PLACEHOLDER/${COUNTRY_SIZE}/g" README.md
sed -i.bak "s/ISP_SIZE_PLACEHOLDER/${ISP_SIZE}/g" README.md
sed -i.bak "s/CONNECTION_SIZE_PLACEHOLDER/${CONNECTION_SIZE}/g" README.md
sed -i.bak "s/DB23_BIN_SIZE_PLACEHOLDER/${DB23_BIN_SIZE}/g" README.md
sed -i.bak "s/DB23_BIN6_SIZE_PLACEHOLDER/${DB23_BIN6_SIZE}/g" README.md
sed -i.bak "s/PX2_BIN_SIZE_PLACEHOLDER/${PX2_BIN_SIZE}/g" README.md

# Clean up backup file
rm -f README.md.bak

echo "✅ README.md updated successfully"