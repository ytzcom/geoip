# GeoIP Authentication Infrastructure

This directory contains the Terraform configuration for setting up the GeoIP authentication infrastructure on AWS.

## Architecture

The infrastructure consists of:
- **API Gateway**: REST API endpoint for authentication
- **Lambda Function**: Validates API keys and generates pre-signed S3 URLs
- **DynamoDB Table**: Stores API keys and usage data
- **CloudWatch Logs**: API and Lambda logging

## Prerequisites

1. AWS CLI configured with appropriate credentials
2. Terraform installed (>= 1.0)
3. Python 3.11+ for Lambda function
4. Existing S3 bucket with GeoIP databases

## Setup Instructions

### 1. Package Lambda Function

First, package the Lambda function code:

```bash
cd ../lambda
pip install -r requirements.txt -t package/
cp auth_handler.py package/
cd package
zip -r ../lambda_function.zip .
cd ..
mv lambda_function.zip ../terraform/
cd ../terraform
```

### 2. Initialize Terraform

```bash
terraform init
```

### 3. Configure Variables

Create a `terraform.tfvars` file:

```hcl
aws_region     = "us-east-1"
environment    = "production"
s3_bucket_name = "ytz-geoip"
```

### 4. Deploy Infrastructure

```bash
# Review the plan
terraform plan

# Apply the configuration
terraform apply
```

### 5. Note the Outputs

After deployment, Terraform will output:
- `api_endpoint`: The API Gateway URL for authentication
- `dynamodb_table`: The DynamoDB table name
- `lambda_function`: The Lambda function name

## Managing API Keys

Use the provided Python script to manage API keys:

### Create a New API Key

```bash
# Basic usage
python manage_api_keys.py create --name "John Doe" --email "john@example.com"

# With expiration
python manage_api_keys.py create --name "Jane Doe" --email "jane@example.com" --expires-days 365

# With specific database access
python manage_api_keys.py create --name "Limited User" --email "limited@example.com" \
  --databases GeoIP2-City.mmdb GeoIP2-Country.mmdb
```

### List All API Keys

```bash
python manage_api_keys.py list
```

### Revoke an API Key

```bash
python manage_api_keys.py revoke --key "geoip_xxxxxxxxxxxxx"
```

### Get API Key Statistics

```bash
python manage_api_keys.py stats --key "geoip_xxxxxxxxxxxxx"
```

## API Usage

Once deployed, users can authenticate and get download URLs:

```bash
curl -X POST https://your-api-endpoint/v1/auth \
  -H "X-API-Key: geoip_xxxxxxxxxxxxx" \
  -H "Content-Type: application/json" \
  -d '{"databases": ["GeoIP2-City.mmdb", "GeoIP2-Country.mmdb"]}'
```

Response:
```json
{
  "GeoIP2-City.mmdb": "https://s3.amazonaws.com/...",
  "GeoIP2-Country.mmdb": "https://s3.amazonaws.com/..."
}
```

## Rate Limiting

The API enforces rate limiting:
- Default: 100 requests per hour per API key
- Configurable via environment variables

## Monitoring

- API Gateway logs: `/aws/apigateway/geoip-auth`
- Lambda logs: `/aws/lambda/geoip-auth`

## Security Considerations

1. API keys are hashed before storage
2. Pre-signed URLs expire after 1 hour
3. Rate limiting prevents abuse
4. All requests are logged for audit
5. HTTPS only for API endpoints

## Cleanup

To destroy the infrastructure:

```bash
terraform destroy
```

## Cost Estimates

With moderate usage (1000 requests/day):
- API Gateway: ~$3.50/month
- Lambda: ~$0.20/month
- DynamoDB: ~$0.25/month
- CloudWatch Logs: ~$0.50/month
- **Total**: ~$4.45/month

Note: S3 costs for database storage and data transfer are separate.