"""
FastAPI server for GeoIP authentication and file serving.
Docker-deployable alternative to AWS Lambda.
"""

import os
import json
import logging
from typing import Dict, List, Optional, Any, Union
from pathlib import Path
from datetime import datetime, timedelta
from contextlib import asynccontextmanager

import boto3
from botocore.exceptions import ClientError
from fastapi import FastAPI, Header, HTTPException, Request, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, FileResponse, PlainTextResponse, Response
from pydantic import BaseModel

from config import Settings, get_settings

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Load settings
settings = get_settings()

# Initialize S3 client if in S3 mode
s3_client = None
if settings.storage_mode in ['s3', 'hybrid']:
    if settings.aws_access_key_id and settings.aws_secret_access_key:
        s3_client = boto3.client(
            's3',
            aws_access_key_id=settings.aws_access_key_id,
            aws_secret_access_key=settings.aws_secret_access_key,
            region_name=settings.aws_region
        )
    else:
        # Use default AWS credentials (IAM role, etc.)
        s3_client = boto3.client('s3', region_name=settings.aws_region)

# Available databases mapping
AVAILABLE_DATABASES = {
    # MaxMind databases
    'GeoIP2-City.mmdb': 'raw/maxmind/GeoIP2-City.mmdb',
    'GeoIP2-Country.mmdb': 'raw/maxmind/GeoIP2-Country.mmdb',
    'GeoIP2-ISP.mmdb': 'raw/maxmind/GeoIP2-ISP.mmdb',
    'GeoIP2-Connection-Type.mmdb': 'raw/maxmind/GeoIP2-Connection-Type.mmdb',
    # IP2Location databases
    'IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN': 
        'raw/ip2location/IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN',
    'IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN': 
        'raw/ip2location/IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN',
    'IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN': 'raw/ip2location/IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN',
}


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup and shutdown events."""
    # Startup
    logger.info(f"Starting GeoIP API Server")
    logger.info(f"Storage Mode: {settings.storage_mode}")
    logger.info(f"API Keys configured: {len(settings.api_keys)}")
    
    if settings.storage_mode in ['local', 'hybrid']:
        # Verify local data path exists
        if not Path(settings.local_data_path).exists():
            logger.warning(f"Local data path does not exist: {settings.local_data_path}")
            Path(settings.local_data_path).mkdir(parents=True, exist_ok=True)
            logger.info(f"Created local data path: {settings.local_data_path}")
    
    yield
    
    # Shutdown
    logger.info("Shutting down GeoIP API Server")


# Create FastAPI app
app = FastAPI(
    title="GeoIP Authentication API",
    description="Docker-deployable GeoIP database authentication and serving",
    version="1.0.0",
    lifespan=lifespan
)

# Configure CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# Request/Response models
class DatabaseRequest(BaseModel):
    databases: Union[str, List[str]] = "all"


class HealthResponse(BaseModel):
    status: str
    timestamp: str
    storage_mode: str
    databases_available: int


class MetricsResponse(BaseModel):
    total_requests: int
    successful_requests: int
    failed_requests: int
    uptime_seconds: float


# Metrics tracking
metrics = {
    "total_requests": 0,
    "successful_requests": 0,
    "failed_requests": 0,
    "start_time": datetime.now()
}


def validate_api_key(api_key: Optional[str]) -> bool:
    """Validate API key against allowed list."""
    if not api_key or not settings.api_keys:
        return False
    
    return api_key in settings.api_keys


def get_local_file_url(database_name: str, request: Request) -> Optional[str]:
    """Generate URL for local file serving."""
    if database_name not in AVAILABLE_DATABASES:
        return None
    
    # Check if file exists locally
    relative_path = AVAILABLE_DATABASES[database_name]
    local_file = Path(settings.local_data_path) / relative_path
    
    if local_file.exists():
        # Generate download URL
        base_url = str(request.base_url).rstrip('/')
        return f"{base_url}/download/{database_name}"
    
    return None


def generate_s3_presigned_url(database_name: str) -> Optional[str]:
    """Generate S3 pre-signed URL for database."""
    if not s3_client or database_name not in AVAILABLE_DATABASES:
        return None
    
    s3_key = AVAILABLE_DATABASES[database_name]
    
    try:
        url = s3_client.generate_presigned_url(
            'get_object',
            Params={
                'Bucket': settings.s3_bucket,
                'Key': s3_key
            },
            ExpiresIn=settings.url_expiry_seconds
        )
        return url
    except Exception as e:
        logger.error(f"Error generating S3 URL for {database_name}: {str(e)}")
        return None


def generate_database_urls(databases: List[str], request: Request) -> Dict[str, str]:
    """Generate URLs for requested databases based on storage mode."""
    urls = {}
    
    for db_name in databases:
        if db_name not in AVAILABLE_DATABASES:
            continue
        
        url = None
        
        if settings.storage_mode == 'local':
            # Local file serving only
            url = get_local_file_url(db_name, request)
        
        elif settings.storage_mode == 's3':
            # S3 pre-signed URLs only
            url = generate_s3_presigned_url(db_name)
        
        elif settings.storage_mode == 'hybrid':
            # Try local first, fallback to S3
            url = get_local_file_url(db_name, request)
            if not url:
                url = generate_s3_presigned_url(db_name)
        
        if url:
            urls[db_name] = url
            logger.debug(f"Generated URL for {db_name}: {url[:50]}...")
    
    return urls


@app.get("/health", response_model=HealthResponse)
async def health_check():
    """Health check endpoint."""
    available_count = 0
    
    if settings.storage_mode in ['local', 'hybrid']:
        # Count available local files
        for db_name, rel_path in AVAILABLE_DATABASES.items():
            local_file = Path(settings.local_data_path) / rel_path
            if local_file.exists():
                available_count += 1
    else:
        # In S3 mode, assume all are available
        available_count = len(AVAILABLE_DATABASES)
    
    return HealthResponse(
        status="healthy",
        timestamp=datetime.now().isoformat(),
        storage_mode=settings.storage_mode,
        databases_available=available_count
    )


@app.get("/metrics", response_model=MetricsResponse)
async def get_metrics(x_api_key: Optional[str] = Header(None)):
    """Metrics endpoint (requires API key)."""
    if not validate_api_key(x_api_key):
        raise HTTPException(status_code=401, detail="Invalid API key")
    
    uptime = (datetime.now() - metrics["start_time"]).total_seconds()
    
    return MetricsResponse(
        total_requests=metrics["total_requests"],
        successful_requests=metrics["successful_requests"],
        failed_requests=metrics["failed_requests"],
        uptime_seconds=uptime
    )


@app.post("/auth")
async def authenticate(
    request: Request,
    body: DatabaseRequest,
    x_api_key: Optional[str] = Header(None)
):
    """Main authentication endpoint - compatible with Lambda version."""
    metrics["total_requests"] += 1
    
    # Validate API key
    if not validate_api_key(x_api_key):
        metrics["failed_requests"] += 1
        logger.warning(f"Invalid API key attempt from {request.client.host}")
        raise HTTPException(status_code=401, detail="Invalid API key")
    
    # Determine which databases to return
    if body.databases == "all":
        databases = list(AVAILABLE_DATABASES.keys())
    elif isinstance(body.databases, list):
        # Validate requested databases exist
        databases = [db for db in body.databases if db in AVAILABLE_DATABASES]
        if not databases and body.databases:
            metrics["failed_requests"] += 1
            raise HTTPException(status_code=400, detail="No valid databases in request")
    else:
        metrics["failed_requests"] += 1
        raise HTTPException(status_code=400, detail='databases parameter must be "all" or an array')
    
    # Generate URLs
    urls = generate_database_urls(databases, request)
    
    if not urls:
        metrics["failed_requests"] += 1
        logger.error("Failed to generate any download URLs")
        raise HTTPException(status_code=500, detail="Failed to generate download URLs")
    
    metrics["successful_requests"] += 1
    logger.info(f"Successful auth request for {len(urls)} databases")
    
    return JSONResponse(content=urls)


@app.get("/download/{database_name}")
async def download_database(
    database_name: str,
    x_api_key: Optional[str] = Header(None)
):
    """Direct file download endpoint for local storage mode."""
    if settings.storage_mode not in ['local', 'hybrid']:
        raise HTTPException(status_code=404, detail="Download endpoint not available in S3 mode")
    
    # Validate API key
    if not validate_api_key(x_api_key):
        logger.warning(f"Invalid API key for download: {database_name}")
        raise HTTPException(status_code=401, detail="Invalid API key")
    
    if database_name not in AVAILABLE_DATABASES:
        raise HTTPException(status_code=404, detail="Database not found")
    
    # Get local file path
    relative_path = AVAILABLE_DATABASES[database_name]
    local_file = Path(settings.local_data_path) / relative_path
    
    if not local_file.exists():
        logger.error(f"File not found: {local_file}")
        raise HTTPException(status_code=404, detail="Database file not found")
    
    logger.info(f"Serving file: {database_name}")
    
    return FileResponse(
        path=local_file,
        filename=database_name,
        media_type='application/octet-stream'
    )


@app.get("/")
async def root():
    """Root endpoint with API information."""
    return {
        "name": "GeoIP Authentication API",
        "version": "1.0.0",
        "storage_mode": settings.storage_mode,
        "endpoints": {
            "auth": "/auth",
            "health": "/health",
            "metrics": "/metrics",
            "download": "/download/{database_name}" if settings.storage_mode in ['local', 'hybrid'] else None,
            "install": "/install"
        }
    }


@app.get("/install", response_class=PlainTextResponse)
async def get_installer(
    request: Request,
    with_cron: bool = Query(False, description="Setup automatic updates via cron"),
    install_dir: str = Query("/opt/geoip", description="Installation directory"),
    api_endpoint: Optional[str] = Query(None, description="API endpoint URL")
):
    """
    One-line installer script for GeoIP tools.
    
    Usage:
        curl -sSL https://your-api.com/install | sh
        
    With options:
        curl -sSL "https://your-api.com/install?with_cron=true&install_dir=/usr/local/geoip" | sh
    """
    
    # Use current server as default endpoint if not specified
    if not api_endpoint:
        api_endpoint = str(request.base_url).rstrip('/')
    
    installer_script = f"""#!/bin/sh
# GeoIP Universal Installer
# Generated by {api_endpoint}/install
# 
# This script installs GeoIP update tools without requiring Docker

set -e

# Configuration
INSTALL_DIR="{install_dir}"
WITH_CRON="{str(with_cron).lower()}"
API_ENDPOINT="{api_endpoint}"

echo "========================================="
echo "     GeoIP Tools Universal Installer     "
echo "========================================="
echo ""
echo "Configuration:"
echo "  Install directory: $INSTALL_DIR"
echo "  API endpoint: $API_ENDPOINT"
echo "  Setup cron: $WITH_CRON"
echo ""

# Check for required tools
check_requirements() {{
    local missing=""
    
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        missing="$missing curl/wget"
    fi
    
    if ! command -v tar >/dev/null 2>&1; then
        missing="$missing tar"
    fi
    
    if [ -n "$missing" ]; then
        echo "ERROR: Missing required tools:$missing"
        echo "Please install them and try again."
        exit 1
    fi
}}

check_requirements

# Create installation directory
echo "Creating installation directory..."
mkdir -p "$INSTALL_DIR"

# Download scripts from Docker image using crane (no Docker daemon needed)
echo "Downloading GeoIP scripts..."
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

# Method 1: Try using crane if available
if command -v crane >/dev/null 2>&1; then
    echo "Using existing crane installation..."
    CRANE_CMD="crane"
else
    echo "Installing crane for extraction..."
    
    # Detect architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            CRANE_ARCH="x86_64"
            ;;
        aarch64|arm64)
            CRANE_ARCH="arm64"
            ;;
        *)
            echo "ERROR: Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
    
    # Download crane
    CRANE_URL="https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_${{CRANE_ARCH}}.tar.gz"
    
    if command -v curl >/dev/null 2>&1; then
        curl -sL "$CRANE_URL" | tar -xz crane
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$CRANE_URL" | tar -xz crane
    fi
    
    chmod +x crane
    CRANE_CMD="./crane"
fi

# Extract scripts from Docker image
echo "Extracting scripts from ytzcom/geoip-scripts:latest..."
if ! "$CRANE_CMD" export ytzcom/geoip-scripts:latest - | tar -x --strip-components=2 -C "$INSTALL_DIR" 2>/dev/null; then
    echo "ERROR: Failed to extract scripts from Docker image"
    echo "This might be because:"
    echo "  1. The Docker image doesn't exist yet"
    echo "  2. Network connectivity issues"
    echo ""
    echo "Alternative: Download scripts directly from GitHub:"
    echo "  git clone https://github.com/yourusername/geoip-updater"
    echo "  cp -r geoip-updater/scripts/cli/* $INSTALL_DIR/"
    echo "  cp -r geoip-updater/docker/scripts/* $INSTALL_DIR/"
    exit 1
fi

# Make scripts executable
chmod +x "$INSTALL_DIR"/*.sh 2>/dev/null || true

# Setup cron if requested
if [ "$WITH_CRON" = "true" ]; then
    echo ""
    echo "Setting up automatic updates..."
    
    # Check if API key is already configured
    if [ -z "$GEOIP_API_KEY" ]; then
        echo "NOTE: GEOIP_API_KEY not set. You'll need to configure it before cron can work."
        echo "Set it in your environment or update the cron command."
    fi
    
    # Run setup-cron script
    if [ -f "$INSTALL_DIR/setup-cron.sh" ]; then
        export GEOIP_API_ENDPOINT="$API_ENDPOINT"
        "$INSTALL_DIR/setup-cron.sh" || echo "WARNING: Cron setup failed, manual configuration required"
    else
        echo "WARNING: setup-cron.sh not found, skipping cron configuration"
    fi
fi

# Cleanup
cd /
rm -rf "$TEMP_DIR"

echo ""
echo "========================================="
echo "✅ GeoIP scripts installed successfully!"
echo "========================================="
echo ""
echo "📁 Installation directory: $INSTALL_DIR"
echo ""
echo "🔧 Next steps:"
echo "   1. Set your API key:"
echo "      export GEOIP_API_KEY=your-api-key"
echo ""
echo "   2. Download databases:"
echo "      $INSTALL_DIR/geoip-update.sh"
echo ""
if [ "$WITH_CRON" = "true" ]; then
    echo "   3. Automatic updates configured (2 AM daily)"
    echo "      Check cron status: crontab -l"
else
    echo "   3. Setup automatic updates (optional):"
    echo "      $INSTALL_DIR/setup-cron.sh"
fi
echo ""
echo "📚 For more options:"
echo "   $INSTALL_DIR/geoip-update.sh --help"
echo ""
echo "🔍 To validate databases:"
echo "   $INSTALL_DIR/validate.sh"
echo ""
"""
    
    return Response(
        content=installer_script,
        media_type="text/plain",
        headers={
            "Content-Disposition": "inline; filename=install-geoip.sh"
        }
    )


# Admin endpoints (optional, can be disabled via environment)
if settings.enable_admin:
    @app.post("/admin/reload-keys")
    async def reload_api_keys(
        x_admin_key: Optional[str] = Header(None)
    ):
        """Reload API keys from environment (requires admin key)."""
        global settings
        
        if x_admin_key != settings.admin_key:
            raise HTTPException(status_code=401, detail="Invalid admin key")
        
        # Reload settings
        settings = get_settings(force_reload=True)
        
        logger.info(f"Reloaded API keys, now have {len(settings.api_keys)} keys")
        
        return {"message": f"Reloaded {len(settings.api_keys)} API keys"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "app:app",
        host="0.0.0.0",
        port=settings.port,
        workers=settings.workers,
        log_level="info",
        reload=settings.debug
    )