#!/usr/bin/env bash
#
# Update all CLI scripts with the actual API Gateway URL
# Usage: ./update-api-endpoint.sh <API_GATEWAY_URL>
#
# Example:
#   ./update-api-endpoint.sh https://abc123.execute-api.us-east-1.amazonaws.com/v1

set -euo pipefail

# Check arguments
if [ $# -ne 1 ]; then
    echo "Usage: $0 <API_GATEWAY_URL>"
    echo "Example: $0 https://abc123.execute-api.us-east-1.amazonaws.com/v1"
    echo ""
    echo "You can get the API Gateway URL from Terraform output:"
    echo "  cd infrastructure/terraform"
    echo "  terraform output api_gateway_url"
    exit 1
fi

API_URL="$1"
API_URL_WITH_AUTH="${API_URL}/auth"

# Validate URL format
if [[ ! "$API_URL" =~ ^https://[a-z0-9]+\.execute-api\.[a-z0-9-]+\.amazonaws\.com/v[0-9]$ ]]; then
    echo "Warning: URL doesn't match expected AWS API Gateway format"
    echo "Expected format: https://xxx.execute-api.region.amazonaws.com/vN"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

echo "Updating CLI scripts with API endpoint: $API_URL_WITH_AUTH"

# Update Bash script
echo "Updating geoip-update.sh..."
sed -i.bak "s|REPLACE_WITH_DEPLOYED_API_GATEWAY_URL/auth|${API_URL_WITH_AUTH}|g" geoip-update.sh
echo "✓ Updated geoip-update.sh"

# Update PowerShell script
echo "Updating geoip-update.ps1..."
sed -i.bak "s|REPLACE_WITH_DEPLOYED_API_GATEWAY_URL/auth|${API_URL_WITH_AUTH}|g" geoip-update.ps1
echo "✓ Updated geoip-update.ps1"

# Update Python script
echo "Updating geoip-update.py..."
sed -i.bak "s|REPLACE_WITH_DEPLOYED_API_GATEWAY_URL/auth|${API_URL_WITH_AUTH}|g" geoip-update.py
echo "✓ Updated geoip-update.py"

# Clean up backup files
rm -f *.bak

echo ""
echo "All scripts have been updated successfully!"
echo ""
echo "You can now use the scripts with:"
echo "  - Bash: ./geoip-update.sh -k YOUR_API_KEY"
echo "  - PowerShell: .\\geoip-update.ps1 -ApiKey YOUR_API_KEY"
echo "  - Python: python geoip-update.py --api-key YOUR_API_KEY"
echo ""
echo "Or set the environment variable:"
echo "  export GEOIP_API_ENDPOINT='$API_URL_WITH_AUTH'"