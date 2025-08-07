#!/bin/bash
# GeoIP API Docker Deployment Script
# Can be run from GitHub Actions or manually

set -e

# Configuration
DEPLOY_DIR="${DEPLOY_DIR:-/data/sites/live_projects/geoip-api}"
REPO_URL="${REPO_URL:-https://github.com/ytzcom/geoip-updater.git}"
BRANCH="${BRANCH:-main}"
COMPOSE_FILE="docker-compose.prod.yml"
DOCKER_IMAGE="${DOCKER_IMAGE:-ytzcom/geoip-api:latest}"
DOTENV_TOKEN="${DOTENV_TOKEN:-}"
DOTENV_API_URL="https://dotenv.ca/api/geoip-api/docker/production"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
log_info() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1"
}

# Main deployment process
echo "🚀 GeoIP API Deployment"
echo "======================="
echo "Deploy directory: $DEPLOY_DIR"
echo "Repository: $REPO_URL"
echo "Branch: $BRANCH"
echo "Docker image: $DOCKER_IMAGE"
if [ -n "$DOTENV_TOKEN" ]; then
    echo "dotenv.ca: Enabled (token provided)"
else
    echo "dotenv.ca: Disabled (manual .env required)"
fi
echo ""

# Create deployment directory if it doesn't exist
if [ ! -d "$DEPLOY_DIR" ]; then
    log_info "Creating deployment directory..."
    mkdir -p "$(dirname "$DEPLOY_DIR")"
    cd "$(dirname "$DEPLOY_DIR")"
    
    log_info "Cloning repository..."
    git clone "$REPO_URL" "$(basename "$DEPLOY_DIR")"
    cd "$DEPLOY_DIR"
else
    log_info "Repository already exists, updating..."
    cd "$DEPLOY_DIR"
    
    # Ensure we're in a git repository
    if [ ! -d .git ]; then
        log_error "Error: $DEPLOY_DIR exists but is not a git repository"
        exit 1
    fi
    
    # Fetch latest changes
    log_info "Fetching latest changes..."
    git fetch origin
    
    # Check current branch
    CURRENT_BRANCH=$(git branch --show-current)
    if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
        log_info "Switching from $CURRENT_BRANCH to $BRANCH branch..."
        git checkout "$BRANCH" || {
            log_error "Failed to checkout $BRANCH branch"
            exit 1
        }
    fi
    
    # Pull latest changes
    log_info "Pulling latest changes..."
    git pull origin "$BRANCH" || {
        log_warn "Pull failed, attempting to reset..."
        git reset --hard "origin/$BRANCH"
    }
fi

# Verify we're on the correct branch
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
    log_error "Not on $BRANCH branch (current: $CURRENT_BRANCH)"
    exit 1
fi

# Show current commit
log_info "Current commit: $(git rev-parse --short HEAD) - $(git log -1 --pretty=%B | head -1)"

# Create secrets directory if it doesn't exist
if [ ! -d "infrastructure/docker-api/secrets" ]; then
    log_info "Creating secrets directory..."
    mkdir -p infrastructure/docker-api/secrets
fi

# Handle .env file
cd infrastructure/docker-api

if [ -n "$DOTENV_TOKEN" ]; then
    # Always try to fetch from dotenv.ca when token is available
    log_info "Fetching .env from dotenv.ca..."
    
    # Save the token for future use
    echo "$DOTENV_TOKEN" > secrets/dotenv-token.txt
    chmod 600 secrets/dotenv-token.txt
    log_info "Saved DOTENV_TOKEN to secrets/dotenv-token.txt for future use"
    
    # Backup existing .env if it exists
    if [ -f "secrets/.env" ]; then
        cp secrets/.env secrets/.env.backup
        log_info "Backed up existing .env to secrets/.env.backup"
    fi
    
    # Use curl with Bearer token to fetch .env
    HTTP_STATUS=$(curl -s -w "%{http_code}" -o secrets/.env.tmp \
        -H "Authorization: Bearer $DOTENV_TOKEN" \
        "$DOTENV_API_URL")
    
    if [ "$HTTP_STATUS" = "200" ]; then
        # Validate the downloaded file
        if [ -f "secrets/.env.tmp" ] && [ -s "secrets/.env.tmp" ]; then
            # Check if file contains expected content
            if grep -q "API_KEYS=" secrets/.env.tmp && grep -q "AWS_ACCESS_KEY_ID=" secrets/.env.tmp; then
                # File looks valid, use it
                mv secrets/.env.tmp secrets/.env
                chmod 600 secrets/.env
                log_info ".env file fetched successfully from dotenv.ca"
                log_info "File size: $(wc -c < secrets/.env) bytes"
            else
                # File doesn't contain expected content
                rm -f secrets/.env.tmp
                log_error "Downloaded .env file appears to be invalid (missing required keys)"
                
                # Restore backup if it exists
                if [ -f "secrets/.env.backup" ]; then
                    mv secrets/.env.backup secrets/.env
                    log_warn "Restored previous .env from backup"
                else
                    log_error "No backup available, manual intervention required"
                    exit 1
                fi
            fi
        else
            # File is empty or doesn't exist
            rm -f secrets/.env.tmp
            log_error "Downloaded .env file is empty or missing"
            
            # Restore backup if it exists
            if [ -f "secrets/.env.backup" ]; then
                mv secrets/.env.backup secrets/.env
                log_warn "Restored previous .env from backup"
            else
                log_error "No backup available, manual intervention required"
                exit 1
            fi
        fi
    else
        # HTTP request failed
        rm -f secrets/.env.tmp
        log_error "Failed to fetch .env from dotenv.ca (HTTP $HTTP_STATUS)"
        
        # Check if we have an existing .env to fall back to
        if [ -f "secrets/.env" ]; then
            log_warn "Using existing .env file as fallback"
        else
            log_error "No existing .env file found"
            log_error "Please check your DOTENV_TOKEN or network connection"
            exit 1
        fi
    fi
    
    # Clean up backup if everything went well
    if [ -f "secrets/.env.backup" ] && [ -f "secrets/.env" ]; then
        rm -f secrets/.env.backup
    fi
else
    # No token provided
    if [ ! -f "secrets/.env" ]; then
        log_error "secrets/.env file not found and no DOTENV_TOKEN provided!"
        echo ""
        echo "You have two options:"
        echo ""
        echo "1. Provide DOTENV_TOKEN to fetch automatically:"
        echo "   export DOTENV_TOKEN='your-token-here'"
        echo "   $0"
        echo ""
        echo "2. Create it manually from the template:"
        echo "   cp .env.example secrets/.env"
        echo "   nano secrets/.env"
        echo ""
        echo "Then fill in all required values"
        exit 1
    else
        log_info "Using existing secrets/.env file (dotenv.ca disabled)"
    fi
fi

# Run deployment setup script
if [ -f "../docker-deploy-setup.sh" ]; then
    log_info "Running deployment setup..."
    if [ "$EUID" -ne 0 ]; then
        # Not running as root, use sudo
        sudo bash ../docker-deploy-setup.sh || {
            log_error "Deployment setup failed"
            exit 1
        }
    else
        # Already root
        bash ../docker-deploy-setup.sh || {
            log_error "Deployment setup failed"
            exit 1
        }
    fi
else
    log_warn "docker-deploy-setup.sh not found, skipping automatic setup"
fi

# Pull latest Docker images
log_info "Pulling Docker images..."
docker compose -f "$COMPOSE_FILE" pull || {
    log_error "Failed to pull Docker images"
    exit 1
}

# Stop existing containers (if any)
if docker compose -f "$COMPOSE_FILE" ps -q | grep -q .; then
    log_info "Stopping existing containers..."
    docker compose -f "$COMPOSE_FILE" down
fi

# Start containers
log_info "Starting containers..."
docker compose -f "$COMPOSE_FILE" --env-file secrets/.env up -d || {
    log_error "Failed to start containers"
    exit 1
}

# Wait for containers to be healthy
log_info "Waiting for containers to be healthy..."
sleep 10

# Check container status
log_info "Checking container status..."
docker compose -f "$COMPOSE_FILE" ps

# Health check
log_info "Performing health check..."
HEALTH_CHECK_URL="http://localhost/health"
MAX_ATTEMPTS=30
ATTEMPT=1

while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    if curl -fs "$HEALTH_CHECK_URL" > /dev/null; then
        log_info "Health check passed!"
        break
    else
        log_warn "Health check attempt $ATTEMPT/$MAX_ATTEMPTS failed, retrying..."
        sleep 2
        ATTEMPT=$((ATTEMPT + 1))
    fi
done

if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
    log_error "Health check failed after $MAX_ATTEMPTS attempts"
    echo ""
    echo "Debug information:"
    docker compose -f "$COMPOSE_FILE" logs --tail=50
    exit 1
fi

# Test API authentication endpoint
log_info "Testing API authentication endpoint..."
if [ -f "secrets/.env" ]; then
    # Extract first API key from .env file
    API_KEY=$(grep "^API_KEYS=" secrets/.env | cut -d'=' -f2 | cut -d',' -f1)
    if [ -n "$API_KEY" ]; then
        AUTH_TEST=$(curl -s -o /dev/null -w "%{http_code}" -H "X-API-Key: $API_KEY" "http://localhost/auth")
        if [ "$AUTH_TEST" = "200" ]; then
            log_info "API authentication test passed!"
        else
            log_warn "API authentication test returned HTTP $AUTH_TEST"
        fi
    else
        log_warn "No API key found in .env file, skipping authentication test"
    fi
fi

# Clean up old images
log_info "Cleaning up old Docker images..."
docker image prune -f || true

# Final status
echo ""
echo "✅ Deployment completed successfully!"
echo ""
echo "🌐 Application URL: ${ENVIRONMENT_URL:-https://geoip.ytrack.io}"
echo "📊 Container status:"
docker compose -f "$COMPOSE_FILE" ps
echo ""
echo "📝 View logs with:"
echo "  docker compose -f $COMPOSE_FILE logs -f"
echo ""
echo "🔑 API endpoints:"
echo "  Health: ${ENVIRONMENT_URL:-https://geoip.ytrack.io}/health"
echo "  Auth: ${ENVIRONMENT_URL:-https://geoip.ytrack.io}/auth"
echo "  Docs: ${ENVIRONMENT_URL:-https://geoip.ytrack.io}/docs"
echo ""