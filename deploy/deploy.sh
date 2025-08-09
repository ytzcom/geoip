#!/bin/bash
set -euo pipefail

# Deployment script for the GeoIP Lambda authentication system
# Usage: ./deploy.sh [api-keys]
# Example: ./deploy.sh "key1,key2,key3"

echo "🚀 GeoIP Authentication Deployment"
echo "=========================================="

# Check if we're in the right directory
if [ ! -f "terraform/main.tf" ]; then
    echo "❌ Error: Please run this script from the infrastructure directory"
    exit 1
fi

# Parse arguments
API_KEYS="${1:-}"

# Function to generate a secure API key
generate_api_key() {
    # Generate a secure random key (32 bytes, base64 encoded)
    if command -v openssl &> /dev/null; then
        echo "geoip_$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)"
    else
        # Fallback to using /dev/urandom
        echo "geoip_$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)"
    fi
}

# If no API keys provided, offer to generate them
if [ -z "$API_KEYS" ]; then
    echo ""
    echo "No API keys provided. Would you like to:"
    echo "1) Generate new API keys"
    echo "2) Enter your own API keys"
    echo "3) Use existing terraform.tfvars"
    echo ""
    read -p "Choose an option (1-3): " choice
    
    case $choice in
        1)
            echo ""
            read -p "How many API keys to generate? (1-10): " num_keys
            if [[ "$num_keys" =~ ^[1-9]$|^10$ ]]; then
                KEYS_ARRAY=()
                echo ""
                echo "Generated API Keys:"
                echo "==================="
                for i in $(seq 1 $num_keys); do
                    KEY=$(generate_api_key)
                    KEYS_ARRAY+=("$KEY")
                    echo "Key $i: $KEY"
                done
                API_KEYS=$(IFS=','; echo "${KEYS_ARRAY[*]}")
                echo ""
                echo "⚠️  IMPORTANT: Save these keys securely! They cannot be retrieved after deployment."
                echo ""
            else
                echo "❌ Invalid number. Please run the script again."
                exit 1
            fi
            ;;
        2)
            echo ""
            echo "Enter your API keys (comma-separated):"
            read -p "> " API_KEYS
            ;;
        3)
            if [ -f "terraform/terraform.tfvars" ]; then
                echo "Using existing terraform.tfvars"
            else
                echo "❌ terraform.tfvars not found"
                exit 1
            fi
            ;;
        *)
            echo "❌ Invalid option"
            exit 1
            ;;
    esac
fi

# Change to terraform directory
cd terraform

# Create terraform.tfvars if API keys were provided
if [ -n "$API_KEYS" ]; then
    echo "📝 Creating terraform.tfvars..."
    cat > terraform.tfvars <<EOF
# API Keys for GeoIP authentication
api_keys = "$API_KEYS"

# Customize these if needed
# aws_region = "us-east-1"
# s3_bucket_name = "ytz-geoip"
EOF
    echo "✅ terraform.tfvars created"
fi

# Package the Lambda function
echo ""
echo "📦 Packaging Lambda function..."
if [ -f "../lambda/auth_handler.py" ]; then
    cd ../lambda
    zip -q ../terraform/lambda_deployment.zip auth_handler.py
    cd ../terraform
    echo "✅ Lambda package created"
else
    echo "❌ Lambda function not found at ../lambda/auth_handler.py"
    exit 1
fi

# Initialize Terraform
echo ""
echo "🔧 Initializing Terraform..."
terraform init -input=false

# Plan the deployment
echo ""
echo "📋 Planning deployment..."
terraform plan -input=false -var-file=terraform.tfvars

# Ask for confirmation
echo ""
echo "=========================================="
read -p "Do you want to apply these changes? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "❌ Deployment cancelled"
    exit 0
fi

# Apply the configuration
echo ""
echo "🚀 Deploying infrastructure..."
terraform apply -auto-approve -input=false -var-file=terraform.tfvars

# Get the outputs
echo ""
echo "=========================================="
echo "✅ Deployment Complete!"
echo "=========================================="
echo ""
API_URL=$(terraform output -raw api_gateway_url)
LAMBDA_NAME=$(terraform output -raw lambda_function_name)

echo "📌 API Endpoint: $API_URL"
echo "📌 Lambda Function: $LAMBDA_NAME"
echo ""

# Update the CLI scripts with the new endpoint
echo "Would you like to update the CLI scripts with the new endpoint?"
read -p "(yes/no): " update_scripts

if [ "$update_scripts" = "yes" ]; then
    echo ""
    echo "🔄 Updating CLI scripts..."
    
    # Update the Python script
    if [ -f "../../scripts/cli/geoip-update.py" ]; then
        sed -i.bak "s|DEFAULT_ENDPOINT = .*|DEFAULT_ENDPOINT = \"$API_URL\"|" ../../scripts/cli/geoip-update.py
        echo "✅ Updated Python script"
    fi
    
    # Update the Bash script
    if [ -f "../../scripts/cli/geoip-update.sh" ]; then
        sed -i.bak "s|DEFAULT_ENDPOINT=.*|DEFAULT_ENDPOINT=\"$API_URL\"|" ../../scripts/cli/geoip-update.sh
        echo "✅ Updated Bash script"
    fi
    
    # Update the PowerShell script
    if [ -f "../../scripts/cli/geoip-update.ps1" ]; then
        sed -i.bak "s|\$DefaultEndpoint = .*|\$DefaultEndpoint = \"$API_URL\"|" ../../scripts/cli/geoip-update.ps1
        echo "✅ Updated PowerShell script"
    fi
    
    # Update the Go script
    if [ -f "../../scripts/cli/go/main.go" ]; then
        sed -i.bak "s|defaultEndpoint.*=.*|defaultEndpoint   = \"$API_URL\"|" ../../scripts/cli/go/main.go
        echo "✅ Updated Go script"
    fi
    
    echo ""
    echo "✅ All CLI scripts updated with new endpoint"
fi

echo ""
echo "=========================================="
echo "📚 Next Steps:"
echo "=========================================="
echo ""
echo "1. Test the API with one of your keys:"
echo "   curl -X POST $API_URL \\"
echo "     -H 'X-API-Key: <your-api-key>' \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"databases\": \"all\"}'"
echo ""
echo "2. Update API keys anytime:"
echo "   terraform apply -var=\"api_keys=new-key-1,new-key-2\""
echo ""
echo "3. Use the CLI scripts to download databases:"
echo "   ./scripts/cli/geoip-update.sh -k <your-api-key>"
echo ""
echo "=========================================="