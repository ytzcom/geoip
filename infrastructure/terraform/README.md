# GeoIP Authentication Infrastructure

Terraform configuration for deploying the GeoIP authentication system to AWS.

## Architecture

This infrastructure creates:
- **Lambda Function**: Validates API keys and generates pre-signed S3 URLs
- **API Gateway**: HTTP API endpoint for authentication
- **CloudWatch Logs**: API and Lambda logging

## Prerequisites

- [Terraform](https://www.terraform.io/downloads.html) >= 1.0
- [AWS CLI](https://aws.amazon.com/cli/) configured with appropriate credentials
- An existing S3 bucket with GeoIP database files

## Quick Start

### 1. Deploy Everything with One Command

```bash
cd ../  # Go to infrastructure directory
./deploy.sh
```

The deployment script will:
- Generate or accept API keys
- Package the Lambda function
- Deploy all infrastructure
- Output the API endpoint

### 2. Manual Deployment

If you prefer to deploy manually:

```bash
# Create terraform.tfvars
cat > terraform.tfvars <<EOF
api_keys = "your-key-1,your-key-2,your-key-3"
s3_bucket_name = "your-s3-bucket"  # Replace with your S3 bucket name
aws_region = "us-east-1"
EOF

# Package Lambda
cd ../lambda
zip ../terraform/lambda_deployment.zip auth_handler.py
cd ../terraform

# Deploy
terraform init
terraform plan
terraform apply
```

## Configuration

### Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `api_keys` | Comma-separated list of API keys | "" (set via tfvars) |
| `s3_bucket_name` | S3 bucket containing GeoIP files | "your-s3-bucket" |
| `aws_region` | AWS region for deployment | "us-east-1" |
| `environment` | Environment name for tagging | "production" |

### Setting API Keys

Three ways to set API keys:

1. **terraform.tfvars file** (recommended):
   ```hcl
   api_keys = "key1,key2,key3"
   ```

2. **Environment variable**:
   ```bash
   export TF_VAR_api_keys="key1,key2,key3"
   terraform apply
   ```

3. **Command line**:
   ```bash
   terraform apply -var="api_keys=key1,key2,key3"
   ```

## Outputs

After deployment, Terraform will output:
- `api_gateway_url`: The API endpoint for authentication
- `lambda_function_name`: The Lambda function name
- `lambda_function_arn`: The Lambda function ARN

## Updating API Keys

To update API keys after deployment:

```bash
# Option 1: Use the management script
../manage-api-keys.sh

# Option 2: Update via Terraform
terraform apply -var="api_keys=new-key-1,new-key-2"

# Option 3: Direct AWS CLI
aws lambda update-function-configuration \
  --function-name geoip-auth \
  --environment Variables={ALLOWED_API_KEYS="key1,key2,key3"}
```

## Testing

Test your deployment:

```bash
# Get the API URL
API_URL=$(terraform output -raw api_gateway_url)

# Test with curl
curl -X POST "$API_URL" \
  -H 'X-API-Key: your-key-here' \
  -H 'Content-Type: application/json' \
  -d '{"databases": "all"}'
```

## Monitoring

View Lambda logs:

```bash
# Recent logs
aws logs tail /aws/lambda/geoip-auth

# Follow logs
aws logs tail /aws/lambda/geoip-auth --follow
```

Check metrics in CloudWatch:
- Invocation count
- Error rate
- Duration
- Throttles

## Cost Estimation

Typical monthly costs (low volume):
- Lambda: ~$0.20/month
- API Gateway: ~$3.50/month
- CloudWatch Logs: ~$0.50/month
- **Total**: ~$4.20/month

## Cleanup

To remove all infrastructure:

```bash
terraform destroy
```

This will remove:
- Lambda function
- API Gateway
- IAM roles and policies
- CloudWatch log groups

## Troubleshooting

### Lambda function fails to create
- Check that `lambda_deployment.zip` exists
- Verify IAM permissions for Lambda creation

### API Gateway returns 500 errors
- Check Lambda logs for errors
- Verify S3 bucket name and permissions
- Ensure API keys are set correctly

### Cannot update API keys
- Ensure you have Lambda update permissions
- Check that the function exists: `aws lambda get-function --function-name geoip-auth`

## Security Notes

- API keys are stored as Lambda environment variables
- All API Gateway traffic is HTTPS only
- Lambda has minimal S3 permissions (GetObject only)
- Consider enabling API Gateway throttling for production use