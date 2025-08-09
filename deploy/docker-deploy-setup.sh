#!/bin/bash
# Deployment setup script for GeoIP API - run before docker-compose up
# This script ensures all required files and directories exist before starting containers

set -e

echo "🚀 GeoIP API Deployment Setup"
echo "=============================="

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$SCRIPT_DIR/docker-api"

cd "$PROJECT_DIR"

# Ensure secrets directory exists
echo "📁 Creating secrets directory..."
mkdir -p secrets

# Check if .env file exists
if [ ! -f secrets/.env ]; then
    echo "⚠️  WARNING: secrets/.env file not found!"
    echo "The docker-deploy.sh script should have created this file."
    echo "If running this script directly, please ensure .env exists first."
    
    # Create from example if it exists
    if [ -f .env.example ]; then
        echo "Creating .env from example..."
        cp .env.example secrets/.env
        echo "✅ Created secrets/.env from example - PLEASE EDIT WITH REAL VALUES!"
    else
        exit 1
    fi
else
    echo "✅ Found secrets/.env"
fi

# Ensure proper permissions
echo "🔒 Setting file permissions..."
chmod 600 secrets/.env
if [ -f secrets/dotenv-token.txt ]; then
    chmod 600 secrets/dotenv-token.txt
fi

# Create required directories for volumes
echo "📁 Creating required directories..."

# SSL directory for certificates (if using HTTPS)
mkdir -p ssl
echo "   Created ssl/ directory for certificates"

# Nginx cache directory
mkdir -p nginx-cache
echo "   Created nginx-cache/ directory"

# Set ownership for the appropriate user
# Only do this if we have permission (running as root)
if [ "$EUID" -eq 0 ]; then
    echo "👤 Setting ownership for container user..."
    
    # Detect the owner of the parent directory (should be the deployment user)
    PARENT_DIR="$(dirname "$(pwd)")"
    if [ -d "$PARENT_DIR" ]; then
        # Use stat to get numeric UID/GID, compatible with both Linux and macOS
        DIR_OWNER=$(stat -c '%u' "$PARENT_DIR" 2>/dev/null || stat -f '%u' "$PARENT_DIR" 2>/dev/null)
        DIR_GROUP=$(stat -c '%g' "$PARENT_DIR" 2>/dev/null || stat -f '%g' "$PARENT_DIR" 2>/dev/null)
    fi
    
    # If we couldn't detect from parent, try current directory
    if [ -z "$DIR_OWNER" ] || [ -z "$DIR_GROUP" ]; then
        DIR_OWNER=$(stat -c '%u' "." 2>/dev/null || stat -f '%u' "." 2>/dev/null)
        DIR_GROUP=$(stat -c '%g' "." 2>/dev/null || stat -f '%g' "." 2>/dev/null)
    fi
    
    # If still no detection, check for SUDO_USER
    if [ -z "$DIR_OWNER" ] || [ -z "$DIR_GROUP" ]; then
        if [ -n "$SUDO_USER" ]; then
            DIR_OWNER=$(id -u "$SUDO_USER")
            DIR_GROUP=$(id -g "$SUDO_USER")
            echo "   Using SUDO_USER ($SUDO_USER) for ownership: $DIR_OWNER:$DIR_GROUP"
        else
            # Default fallback - don't use hardcoded 1000
            echo "⚠️  Could not detect appropriate user/group"
            echo "   Skipping ownership changes to avoid permission issues"
            DIR_OWNER=""
            DIR_GROUP=""
        fi
    else
        echo "   Detected directory owner: UID=$DIR_OWNER GID=$DIR_GROUP"
    fi
    
    # Set ownership if we have valid user/group
    if [ -n "$DIR_OWNER" ] && [ -n "$DIR_GROUP" ]; then
        chown -R "$DIR_OWNER:$DIR_GROUP" secrets ssl nginx-cache
        echo "✅ Set ownership to $DIR_OWNER:$DIR_GROUP"
    fi
    
    # Set permissions
    echo "🔧 Setting directory permissions..."
    chmod 755 secrets ssl nginx-cache
    if [ -f secrets/.env ]; then
        chmod 600 secrets/.env
    fi
else
    echo "⚠️  Not running as root, skipping ownership changes"
    echo "   Containers will use current user permissions"
fi

# Check for SSL certificates
if [ -d "ssl" ]; then
    if [ -f "ssl/cert.pem" ] && [ -f "ssl/key.pem" ]; then
        echo "✅ Found SSL certificates"
    else
        echo "⚠️  No SSL certificates found in ssl/ directory"
        echo "   To enable HTTPS, add:"
        echo "   - ssl/cert.pem (certificate)"
        echo "   - ssl/key.pem (private key)"
    fi
fi

# Validate environment variables in .env
echo ""
echo "🔍 Validating environment configuration..."
if [ -f "secrets/.env" ]; then
    MISSING_VARS=()
    
    # Check required variables
    if ! grep -q "^API_KEYS=" secrets/.env; then
        MISSING_VARS+=("API_KEYS")
    fi
    if ! grep -q "^AWS_ACCESS_KEY_ID=" secrets/.env; then
        MISSING_VARS+=("AWS_ACCESS_KEY_ID")
    fi
    if ! grep -q "^AWS_SECRET_ACCESS_KEY=" secrets/.env; then
        MISSING_VARS+=("AWS_SECRET_ACCESS_KEY")
    fi
    if ! grep -q "^S3_BUCKET=" secrets/.env; then
        MISSING_VARS+=("S3_BUCKET")
    fi
    if ! grep -q "^ADMIN_KEY=" secrets/.env; then
        MISSING_VARS+=("ADMIN_KEY")
    fi
    
    if [ ${#MISSING_VARS[@]} -gt 0 ]; then
        echo "⚠️  Missing required environment variables:"
        for var in "${MISSING_VARS[@]}"; do
            echo "   - $var"
        done
        echo ""
        echo "Please edit secrets/.env and add the missing variables"
    else
        echo "✅ All required environment variables are set"
    fi
fi

echo ""
echo "✅ Deployment setup complete!"
echo ""
echo "You can now run:"
echo "  docker compose -f docker-compose.prod.yml --env-file secrets/.env up -d"
echo ""