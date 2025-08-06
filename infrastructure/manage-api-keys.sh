#!/bin/bash
set -euo pipefail

# API key management script for Lambda environment variables
# Updates Lambda environment variables directly - no database required

echo "🔑 GeoIP API Key Manager"
echo "=========================================="

# Check dependencies
if ! command -v aws &> /dev/null; then
    echo "❌ Error: AWS CLI is not installed"
    echo "Install it from: https://aws.amazon.com/cli/"
    exit 1
fi

# Configuration
LAMBDA_FUNCTION="${LAMBDA_FUNCTION:-geoip-auth}"
REGION="${AWS_REGION:-us-east-1}"

# Function to generate a secure API key
generate_api_key() {
    if command -v openssl &> /dev/null; then
        echo "geoip_$(openssl rand -base64 32 | tr -d '/+=' | cut -c1-32)"
    else
        echo "geoip_$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)"
    fi
}

# Function to get current API keys from Lambda
get_current_keys() {
    aws lambda get-function-configuration \
        --function-name "$LAMBDA_FUNCTION" \
        --region "$REGION" \
        --query 'Environment.Variables.ALLOWED_API_KEYS' \
        --output text 2>/dev/null || echo ""
}

# Function to update API keys in Lambda
update_keys() {
    local keys="$1"
    echo "🔄 Updating Lambda environment variables..."
    
    # Get current environment variables
    ENV_VARS=$(aws lambda get-function-configuration \
        --function-name "$LAMBDA_FUNCTION" \
        --region "$REGION" \
        --query 'Environment.Variables' \
        --output json 2>/dev/null || echo "{}")
    
    # Update with new keys
    echo "$ENV_VARS" | jq --arg keys "$keys" '.ALLOWED_API_KEYS = $keys' > /tmp/env_vars.json
    
    # Apply the update
    aws lambda update-function-configuration \
        --function-name "$LAMBDA_FUNCTION" \
        --region "$REGION" \
        --environment "Variables=$(cat /tmp/env_vars.json)" \
        --output text > /dev/null
    
    rm -f /tmp/env_vars.json
    echo "✅ API keys updated successfully"
}

# Main menu
show_menu() {
    echo ""
    echo "What would you like to do?"
    echo "1) List current API keys"
    echo "2) Add a new API key"
    echo "3) Generate and add new API keys"
    echo "4) Remove an API key"
    echo "5) Replace all API keys"
    echo "6) Test an API key"
    echo "7) Exit"
    echo ""
    read -p "Choose an option (1-7): " choice
    
    case $choice in
        1) list_keys ;;
        2) add_key ;;
        3) generate_keys ;;
        4) remove_key ;;
        5) replace_keys ;;
        6) test_key ;;
        7) echo "👋 Goodbye!"; exit 0 ;;
        *) echo "❌ Invalid option"; show_menu ;;
    esac
}

# List current API keys
list_keys() {
    echo ""
    echo "📋 Current API Keys:"
    echo "===================="
    
    KEYS=$(get_current_keys)
    if [ -z "$KEYS" ]; then
        echo "No API keys configured"
    else
        IFS=',' read -ra KEY_ARRAY <<< "$KEYS"
        INDEX=1
        for key in "${KEY_ARRAY[@]}"; do
            # Show only first and last 4 characters for security
            if [ ${#key} -gt 8 ]; then
                MASKED="${key:0:8}...${key: -4}"
            else
                MASKED="$key"
            fi
            echo "$INDEX. $MASKED"
            ((INDEX++))
        done
    fi
    
    show_menu
}

# Add a new API key
add_key() {
    echo ""
    echo "➕ Add New API Key"
    echo "=================="
    
    echo "Enter the new API key (or press Enter to generate one):"
    read -p "> " NEW_KEY
    
    if [ -z "$NEW_KEY" ]; then
        NEW_KEY=$(generate_api_key)
        echo "Generated: $NEW_KEY"
        echo ""
        echo "⚠️  IMPORTANT: Save this key securely! It cannot be retrieved later."
    fi
    
    # Get current keys
    CURRENT_KEYS=$(get_current_keys)
    if [ -z "$CURRENT_KEYS" ]; then
        UPDATED_KEYS="$NEW_KEY"
    else
        UPDATED_KEYS="$CURRENT_KEYS,$NEW_KEY"
    fi
    
    # Update Lambda
    update_keys "$UPDATED_KEYS"
    
    show_menu
}

# Generate and add new API keys
generate_keys() {
    echo ""
    echo "🔐 Generate New API Keys"
    echo "========================"
    
    read -p "How many keys to generate? (1-10): " num_keys
    
    if ! [[ "$num_keys" =~ ^[1-9]$|^10$ ]]; then
        echo "❌ Invalid number"
        show_menu
        return
    fi
    
    # Get current keys
    CURRENT_KEYS=$(get_current_keys)
    NEW_KEYS=""
    
    echo ""
    echo "Generated Keys:"
    echo "==============="
    
    for i in $(seq 1 $num_keys); do
        KEY=$(generate_api_key)
        echo "$i. $KEY"
        
        if [ -z "$NEW_KEYS" ]; then
            NEW_KEYS="$KEY"
        else
            NEW_KEYS="$NEW_KEYS,$KEY"
        fi
    done
    
    echo ""
    echo "⚠️  IMPORTANT: Save these keys securely! They cannot be retrieved later."
    
    # Combine with current keys
    if [ -z "$CURRENT_KEYS" ]; then
        UPDATED_KEYS="$NEW_KEYS"
    else
        UPDATED_KEYS="$CURRENT_KEYS,$NEW_KEYS"
    fi
    
    # Update Lambda
    update_keys "$UPDATED_KEYS"
    
    show_menu
}

# Remove an API key
remove_key() {
    echo ""
    echo "➖ Remove API Key"
    echo "================="
    
    KEYS=$(get_current_keys)
    if [ -z "$KEYS" ]; then
        echo "No API keys to remove"
        show_menu
        return
    fi
    
    # Display keys with numbers
    IFS=',' read -ra KEY_ARRAY <<< "$KEYS"
    INDEX=1
    for key in "${KEY_ARRAY[@]}"; do
        if [ ${#key} -gt 8 ]; then
            MASKED="${key:0:8}...${key: -4}"
        else
            MASKED="$key"
        fi
        echo "$INDEX. $MASKED"
        ((INDEX++))
    done
    
    echo ""
    read -p "Enter the number of the key to remove (or 0 to cancel): " key_num
    
    if [ "$key_num" = "0" ]; then
        show_menu
        return
    fi
    
    # Validate input
    if ! [[ "$key_num" =~ ^[0-9]+$ ]] || [ "$key_num" -lt 1 ] || [ "$key_num" -gt ${#KEY_ARRAY[@]} ]; then
        echo "❌ Invalid selection"
        show_menu
        return
    fi
    
    # Remove the key
    UPDATED_KEYS=""
    INDEX=1
    for key in "${KEY_ARRAY[@]}"; do
        if [ "$INDEX" -ne "$key_num" ]; then
            if [ -z "$UPDATED_KEYS" ]; then
                UPDATED_KEYS="$key"
            else
                UPDATED_KEYS="$UPDATED_KEYS,$key"
            fi
        fi
        ((INDEX++))
    done
    
    # Update Lambda
    update_keys "$UPDATED_KEYS"
    
    show_menu
}

# Replace all API keys
replace_keys() {
    echo ""
    echo "🔄 Replace All API Keys"
    echo "======================="
    
    echo "⚠️  WARNING: This will remove all existing keys!"
    read -p "Are you sure? (yes/no): " confirm
    
    if [ "$confirm" != "yes" ]; then
        show_menu
        return
    fi
    
    echo ""
    echo "Enter new API keys (comma-separated) or press Enter to generate:"
    read -p "> " NEW_KEYS
    
    if [ -z "$NEW_KEYS" ]; then
        read -p "How many keys to generate? (1-10): " num_keys
        
        if ! [[ "$num_keys" =~ ^[1-9]$|^10$ ]]; then
            echo "❌ Invalid number"
            show_menu
            return
        fi
        
        NEW_KEYS=""
        echo ""
        echo "Generated Keys:"
        echo "==============="
        
        for i in $(seq 1 $num_keys); do
            KEY=$(generate_api_key)
            echo "$i. $KEY"
            
            if [ -z "$NEW_KEYS" ]; then
                NEW_KEYS="$KEY"
            else
                NEW_KEYS="$NEW_KEYS,$KEY"
            fi
        done
        
        echo ""
        echo "⚠️  IMPORTANT: Save these keys securely! They cannot be retrieved later."
    fi
    
    # Update Lambda
    update_keys "$NEW_KEYS"
    
    show_menu
}

# Test an API key
test_key() {
    echo ""
    echo "🧪 Test API Key"
    echo "==============="
    
    # Get API endpoint
    API_URL=$(aws lambda get-function-configuration \
        --function-name "$LAMBDA_FUNCTION" \
        --region "$REGION" \
        --query 'Environment.Variables.API_ENDPOINT' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$API_URL" ]; then
        echo "Enter the API endpoint URL:"
        read -p "> " API_URL
    fi
    
    echo "Enter the API key to test:"
    read -p "> " TEST_KEY
    
    if [ -z "$TEST_KEY" ] || [ -z "$API_URL" ]; then
        echo "❌ API key and endpoint are required"
        show_menu
        return
    fi
    
    echo ""
    echo "🔍 Testing API key..."
    
    # Make test request
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
        -H "X-API-Key: $TEST_KEY" \
        -H "Content-Type: application/json" \
        -d '{"databases": "all"}' 2>/dev/null || echo -e "\n000")
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | head -n-1)
    
    if [ "$HTTP_CODE" = "200" ]; then
        echo "✅ API key is valid!"
        echo ""
        echo "Available databases:"
        echo "$BODY" | jq -r 'keys[]' 2>/dev/null || echo "$BODY"
    elif [ "$HTTP_CODE" = "401" ]; then
        echo "❌ Invalid API key"
    elif [ "$HTTP_CODE" = "000" ]; then
        echo "❌ Failed to connect to API"
    else
        echo "❌ API returned error code: $HTTP_CODE"
        echo "$BODY"
    fi
    
    show_menu
}

# Check if Lambda function exists
echo "🔍 Checking Lambda function: $LAMBDA_FUNCTION"
if aws lambda get-function --function-name "$LAMBDA_FUNCTION" --region "$REGION" &> /dev/null; then
    echo "✅ Lambda function found"
else
    echo "❌ Lambda function '$LAMBDA_FUNCTION' not found in region $REGION"
    echo ""
    echo "Please deploy the infrastructure first using:"
    echo "  cd infrastructure && ./deploy.sh"
    exit 1
fi

# Start the menu
show_menu