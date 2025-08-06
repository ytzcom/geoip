# GeoIP Authentication System

Flexible authentication system for GeoIP database downloads with multiple deployment options:
- **AWS Lambda** - Serverless deployment with CloudFront custom domain
- **Docker API** - Containerized deployment for any infrastructure
- **Environment-based** - API keys in environment variables (no database)

## 🎯 Overview

Choose your deployment method based on your infrastructure:

### Option 1: AWS Lambda (Serverless)
- **API keys stored in Lambda environment variables** (no database needed)
- **Clean, maintainable code** (~50 lines)
- **Single Terraform configuration**
- **One-command deployment**
- **Custom domain support** via CloudFront (geoip.ytrack.io)
- **Perfect for AWS environments**

### Option 2: Docker API (Container)
- **Run anywhere** - VPS, Kubernetes, Docker Swarm, etc.
- **Multiple storage backends** - S3, local files, or hybrid
- **Production ready** - Health checks, metrics, multi-worker
- **Same API interface** - Compatible with Lambda version
- **Perfect for non-AWS environments**

## 🚦 Deployment Options

### Comparison Table

| Feature | AWS Lambda | Docker API |
|---------|------------|------------|
| **Infrastructure** | AWS only | Any (VPS, K8s, local) |
| **Scaling** | Automatic | Manual/Orchestrator |
| **Cold Start** | ~1-2s first request | None |
| **Maintenance** | AWS managed | Self-managed |
| **Storage Options** | S3 only | S3, Local, Hybrid |
| **Custom Domain** | CloudFront | Any proxy/LB |
| **Cost Model** | Pay per request | Fixed server cost |
| **Setup Time** | 5 minutes | 10 minutes |

## 🚀 Quick Start

### AWS Lambda Deployment

```bash
cd infrastructure
./deploy.sh
```

The script will:
- Generate secure API keys for you (or let you provide your own)
- Package and deploy the Lambda function
- Create the API Gateway endpoint
- Update all CLI scripts with the new endpoint

### Docker Deployment

```bash
cd infrastructure/docker-api
cp .env.example .env
# Edit .env with your API keys
docker-compose up -d
```

This will:
- Build the Docker image
- Start the API server on port 8080
- Use S3 backend by default (configurable)

### 2. Manage API Keys

```bash
# Interactive management
./manage-api-keys.sh

# Options:
# - List current keys
# - Add/remove keys
# - Generate new keys
# - Test keys
```

## 📁 Files Structure

```
infrastructure/
├── lambda/
│   └── auth_handler.py          # Lambda function (50 lines)
├── terraform/
│   └── main.tf                  # Terraform configuration
├── docker-api/                  # Docker deployment option
│   ├── app.py                   # FastAPI server
│   ├── config.py                # Configuration management
│   ├── Dockerfile               # Container image
│   ├── docker-compose.yml       # Standard deployment
│   ├── docker-compose.prod.yml  # Production with nginx
│   └── docker-compose.local.yml # Local development
├── deploy.sh                    # Lambda deployment script
└── manage-api-keys.sh           # Key management script
```

## 🔑 API Key Management

### Option 1: During Deployment
```bash
# Let the script generate keys
./deploy.sh

# Or provide your own
./deploy.sh "key1,key2,key3"
```

### Option 2: After Deployment
```bash
# Use the management script
./manage-api-keys.sh

# Or update via Terraform
cd terraform
terraform apply -var="api_keys=new-key-1,new-key-2"
```

### Option 3: Direct AWS CLI
```bash
# Update Lambda environment directly
aws lambda update-function-configuration \
  --function-name geoip-auth \
  --environment Variables={ALLOWED_API_KEYS="key1,key2,key3"}
```

## 🏗️ Architecture

### Request Flow
```
Client Request → CloudFront (geoip.ytrack.io) → API Gateway → Lambda → Validate Key → Generate S3 URLs
                                                                ↑
                                                         Environment Variables
                                                          (API Keys stored here)
```

### Components
- **CloudFront**: Custom domain distribution (geoip.ytrack.io)
- **Lambda Function**: Simple Python function (50 lines)
- **API Gateway**: HTTP API with CORS
- **S3 Bucket**: Your existing GeoIP files
- **No Database**: Keys in environment variables

## 💰 Cost Breakdown

### AWS Lambda Option
| Component | Monthly Cost |
|-----------|-------------|
| Lambda | ~$0.20/month |
| API Gateway | ~$3.50/month |
| CloudFront | ~$0.50/month |
| **Total** | **~$4.20/month** |

### Docker Option
| Component | Monthly Cost |
|-----------|-------------|
| VPS (1GB RAM) | ~$5-10/month |
| Or Kubernetes Pod | ~$0.05/hour |
| Or Local Server | $0 |

*Choose based on your existing infrastructure*

## 🔧 Configuration

### Environment Variables
Set in `terraform.tfvars` or during deployment:

```hcl
# terraform.tfvars
api_keys = "key1,key2,key3"
s3_bucket_name = "ytz-geoip"  # Optional, defaults to ytz-geoip
aws_region = "us-east-1"       # Optional, defaults to us-east-1
```

### Lambda Settings
- **Runtime**: Python 3.11
- **Memory**: 256 MB (plenty for this use case)
- **Timeout**: 30 seconds
- **Environment Variables**:
  - `ALLOWED_API_KEYS`: Comma-separated list of valid keys
  - `S3_BUCKET`: Bucket containing GeoIP files
  - `URL_EXPIRY_SECONDS`: Pre-signed URL expiry (default: 3600)

## 🌐 Custom Domain Setup

### CloudFront Configuration
The API is accessible via CloudFront at `https://geoip.ytrack.io/auth`.

After deployment, configure DNS in Cloudflare:

1. **Get CloudFront domain from Terraform output:**
   ```bash
   cd terraform
   terraform output cloudfront_domain_name
   ```

2. **Add CNAME record in Cloudflare:**
   - **Type**: CNAME
   - **Name**: geoip
   - **Target**: [CloudFront domain from output]
   - **Proxy**: DNS only (gray cloud) ⚠️ **IMPORTANT**

   The proxy MUST be disabled for CloudFront to handle SSL termination.

3. **Wait for propagation** (15-20 minutes for initial deployment)

## 📝 API Usage

### Request
```bash
curl -X POST https://geoip.ytrack.io/auth \
  -H 'X-API-Key: your-api-key' \
  -H 'Content-Type: application/json' \
  -d '{"databases": "all"}'
```

### Response
```json
{
  "GeoIP2-City.mmdb": "https://s3.amazonaws.com/...",
  "GeoIP2-Country.mmdb": "https://s3.amazonaws.com/...",
  "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN": "https://s3.amazonaws.com/..."
}
```

### Specific Databases
```bash
curl -X POST https://your-api-gateway-url/auth \
  -H 'X-API-Key: your-api-key' \
  -H 'Content-Type: application/json' \
  -d '{"databases": ["GeoIP2-City.mmdb", "GeoIP2-Country.mmdb"]}'
```


## 🔒 Security Considerations

### Security Features
- ✅ Keys stored in environment variables (never in code)
- ✅ Easy key rotation
- ✅ Minimal attack surface
- ✅ HTTPS-only via API Gateway

### Limitations
- ⚠️ No rate limiting (use API Gateway throttling if needed)
- ⚠️ No usage tracking (use CloudWatch Logs if needed)
- ⚠️ No per-key permissions (all keys have same access)
- ⚠️ Limited to ~4KB of keys (environment variable limit)

### Best Practices
1. **Generate strong keys**: Use the provided scripts
2. **Rotate regularly**: Update keys monthly
3. **Monitor usage**: Check CloudWatch Logs
4. **Use HTTPS only**: API Gateway enforces this
5. **Limit key distribution**: Only share with trusted systems

## 🚨 Troubleshooting

### Common Issues

**1. Lambda not found**
```bash
# Check Lambda exists
aws lambda get-function --function-name geoip-auth

# If not, deploy it
./deploy.sh
```

**2. Invalid API key error**
```bash
# Check current keys
./manage-api-keys.sh

# Option 1: List keys to verify
# Option 6: Test your key
```

**3. API Gateway timeout**
```bash
# Check Lambda logs
aws logs tail /aws/lambda/geoip-auth --follow
```

**4. S3 access denied**
```bash
# Check Lambda IAM role has S3 permissions
aws iam get-role-policy --role-name geoip-auth-lambda-role \
  --policy-name geoip-auth-lambda-policy
```

## 📊 Monitoring

### CloudWatch Metrics
- **Invocations**: API usage frequency
- **Errors**: Authentication failures
- **Duration**: Response times
- **Throttles**: Rate limit hits (if configured)

### View Logs
```bash
# Recent logs
aws logs tail /aws/lambda/geoip-auth

# Follow logs
aws logs tail /aws/lambda/geoip-auth --follow

# Search logs
aws logs filter-log-events --log-group-name /aws/lambda/geoip-auth \
  --filter-pattern "ERROR"
```

## 🎯 Use Cases

### Perfect For:
- ✅ Internal projects
- ✅ Small teams (2-10 API keys)
- ✅ Simple authentication needs
- ✅ Minimal infrastructure requirements
- ✅ Multi-cloud or hybrid deployments

### Choose Lambda When:
- ✅ Already using AWS infrastructure
- ✅ Want serverless with no server management
- ✅ Need auto-scaling without configuration
- ✅ Prefer pay-per-request pricing

### Choose Docker When:
- ✅ Have existing Docker/Kubernetes infrastructure
- ✅ Need to run on-premises or private cloud
- ✅ Want to serve files locally (no S3 costs)
- ✅ Require custom modifications or extensions

### Consider Alternatives When:
- ❌ Public API service needed
- ❌ Rate limiting per key required
- ❌ Usage tracking/billing needed
- ❌ 100+ API keys
- ❌ Complex key metadata required

## 📚 Additional Resources

- [Lambda Environment Variables Documentation](https://docs.aws.amazon.com/lambda/latest/dg/configuration-envvars.html)
- [API Gateway Throttling](https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-request-throttling.html)
- [S3 Pre-signed URLs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/PresignedUrlUploadObject.html)

## 📝 License

Same as the main project - see LICENSE file.