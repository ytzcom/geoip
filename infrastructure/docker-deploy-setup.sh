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

# Set ownership for Docker user (typically UID 1000 for non-root containers)
# Only do this if we have permission (running as root)
if [ "$EUID" -eq 0 ]; then
    echo "👤 Setting ownership for container user..."
    chown -R 1000:1000 secrets ssl nginx-cache
    
    # Set permissions
    echo "🔧 Setting directory permissions..."
    chmod 755 secrets ssl nginx-cache
    chmod 600 secrets/.env
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