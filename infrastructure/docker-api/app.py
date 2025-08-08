"""
FastAPI server for GeoIP authentication and file serving.
Docker-deployable alternative to AWS Lambda.
"""

import os
import json
import logging
import ipaddress
from typing import Dict, List, Optional, Any, Union
from pathlib import Path
from datetime import datetime, timedelta
from contextlib import asynccontextmanager

import boto3
from botocore.exceptions import ClientError
from fastapi import FastAPI, Header, HTTPException, Request, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.responses import JSONResponse, FileResponse, PlainTextResponse, Response, HTMLResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from starlette.middleware.sessions import SessionMiddleware
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from apscheduler.triggers.cron import CronTrigger

from config import Settings, get_settings
from geoip_reader import GeoIPReader
from cache import get_cache
from database_updater import update_databases

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Load settings
settings = get_settings()

# Initialize S3 client if using S3 URLs
s3_client = None
if settings.use_s3_urls:
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

# Initialize GeoIP reader and cache
geoip_reader = None  # Will be initialized in lifespan
cache = get_cache(settings.cache_type)

# Initialize scheduler
scheduler = AsyncIOScheduler()

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
    global geoip_reader
    
    # Startup
    logger.info(f"Starting GeoIP API Server")
    logger.info(f"Download URLs: {'S3 pre-signed' if settings.use_s3_urls else 'Local file serving'}")
    logger.info(f"API Keys configured: {len(settings.api_keys)}")
    logger.info(f"Cache Type: {settings.cache_type}")
    
    # Always verify database path exists (needed for query functionality)
    if not Path(settings.database_path).exists():
        logger.warning(f"Database path does not exist: {settings.database_path}")
        Path(settings.database_path).mkdir(parents=True, exist_ok=True)
        logger.info(f"Created database path: {settings.database_path}")
        
    # Check if databases exist, download if not
    db_path = Path(settings.database_path) / 'raw'
    maxmind_path = db_path / 'maxmind'
    ip2location_path = db_path / 'ip2location'
    
    # Check if any databases are missing
    databases_exist = (
        maxmind_path.exists() and 
        any(maxmind_path.glob('*.mmdb')) and
        ip2location_path.exists() and 
        any(ip2location_path.glob('*.BIN'))
    )
    
    if not databases_exist:
        logger.info("Databases not found, downloading from S3...")
        try:
            import asyncio
            result = await update_databases()
            if result:
                successful = sum(1 for success in result.values() if success)
                logger.info(f"Downloaded {successful}/{len(result)} databases")
            else:
                logger.warning("Database download returned no results")
        except Exception as e:
            logger.error(f"Failed to download databases at startup: {e}")
            logger.warning("Continuing without databases - they will be downloaded on schedule")
    
    # Initialize GeoIP reader
    try:
        geoip_reader = GeoIPReader()
        db_status = geoip_reader.get_database_status()
        logger.info(f"GeoIP databases loaded: {db_status}")
    except Exception as e:
        logger.error(f"Failed to initialize GeoIP reader: {e}")
        logger.warning("GeoIP query functionality will not be available")
    
    # Schedule database updates (always needed since we maintain local copies)
    # Parse cron schedule
    cron_parts = settings.database_update_schedule.split()
    if len(cron_parts) == 5:
        minute, hour, day, month, day_of_week = cron_parts
        scheduler.add_job(
                update_databases,
                CronTrigger(
                    minute=minute,
                    hour=hour,
                    day=day if day != '*' else None,
                    month=month if month != '*' else None,
                    day_of_week=day_of_week if day_of_week != '*' else None
                ),
                id='database_update',
                name='Update GeoIP databases from S3',
                misfire_grace_time=3600  # 1 hour grace time
            )
        scheduler.start()
        logger.info(f"Scheduled database updates: {settings.database_update_schedule}")
    else:
        logger.warning(f"Invalid cron schedule: {settings.database_update_schedule}")
    
    yield
    
    # Shutdown
    logger.info("Shutting down GeoIP API Server")
    
    # Stop scheduler
    if scheduler.running:
        scheduler.shutdown(wait=False)
    
    # Close cache
    await cache.close()


# Create FastAPI app
app = FastAPI(
    title="GeoIP Authentication API",
    description="Docker-deployable GeoIP database authentication and serving",
    version="1.0.0",
    lifespan=lifespan
)

# Configure middleware
app.add_middleware(
    SessionMiddleware,
    secret_key=settings.session_secret_key,
    session_cookie="geoip_session",
    max_age=86400,  # 24 hours
    same_site="lax",
    https_only=False  # Set to True in production with HTTPS
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mount static files
static_path = Path(__file__).parent / "static"
if static_path.exists():
    app.mount("/static", StaticFiles(directory=str(static_path)), name="static")


# Request/Response models
class DatabaseRequest(BaseModel):
    databases: Union[str, List[str]] = "all"


class HealthResponse(BaseModel):
    status: str
    timestamp: str
    use_s3_urls: bool
    databases_available: int
    databases_local: int
    databases_remote: int


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
    local_file = Path(settings.database_path) / relative_path
    
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
    """Generate URLs for requested databases based on configuration."""
    urls = {}
    
    for db_name in databases:
        if db_name not in AVAILABLE_DATABASES:
            continue
        
        url = None
        
        if settings.use_s3_urls:
            # Generate S3 pre-signed URLs for scalability
            url = generate_s3_presigned_url(db_name)
        else:
            # Serve files directly from local storage
            url = get_local_file_url(db_name, request)
        
        if url:
            urls[db_name] = url
            logger.debug(f"Generated URL for {db_name}: {url[:50]}...")
    
    return urls


@app.get("/health", response_model=HealthResponse)
async def health_check():
    """Health check endpoint."""
    local_count = 0
    remote_count = 0
    
    # Always check local database availability
    for db_name, rel_path in AVAILABLE_DATABASES.items():
        local_file = Path(settings.database_path) / rel_path
        if local_file.exists():
            local_count += 1
    
    # Always check remote (S3) database availability
    if s3_client:
        try:
            for db_name, rel_path in AVAILABLE_DATABASES.items():
                try:
                    # Use HEAD request to check if object exists (fast, no data transfer)
                    s3_client.head_object(
                        Bucket=settings.s3_bucket,
                        Key=rel_path
                    )
                    remote_count += 1
                except ClientError as e:
                    # Object doesn't exist or access denied
                    if e.response['Error']['Code'] not in ['404', 'NoSuchKey', 'Forbidden', '403']:
                        logger.debug(f"S3 error checking {db_name}: {e}")
                except Exception as e:
                    logger.debug(f"Error checking S3 database {db_name}: {e}")
        except Exception as e:
            logger.warning(f"Failed to check S3 database availability: {e}")
    
    # Calculate total unique databases available
    # This is the count of databases available from either local OR remote sources
    total_available = 0
    for db_name, rel_path in AVAILABLE_DATABASES.items():
        local_file = Path(settings.database_path) / rel_path
        local_exists = local_file.exists()
        
        remote_exists = False
        if s3_client:
            try:
                s3_client.head_object(Bucket=settings.s3_bucket, Key=rel_path)
                remote_exists = True
            except:
                pass
        
        if local_exists or remote_exists:
            total_available += 1
    
    return HealthResponse(
        status="healthy",
        timestamp=datetime.now().isoformat(),
        use_s3_urls=settings.use_s3_urls,
        databases_available=total_available,
        databases_local=local_count,
        databases_remote=remote_count
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
    """Direct file download endpoint."""
    # Validate API key
    if not validate_api_key(x_api_key):
        logger.warning(f"Invalid API key for download: {database_name}")
        raise HTTPException(status_code=401, detail="Invalid API key")
    
    if database_name not in AVAILABLE_DATABASES:
        raise HTTPException(status_code=404, detail="Database not found")
    
    # Get local file path
    relative_path = AVAILABLE_DATABASES[database_name]
    local_file = Path(settings.database_path) / relative_path
    
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
    """Serve the web UI or API information."""
    # Check if static index.html exists
    index_path = Path(__file__).parent / "static" / "index.html"
    if index_path.exists():
        return FileResponse(index_path, media_type="text/html")
    else:
        # Fallback to API information
        return {
            "name": "GeoIP Authentication API",
            "version": "1.0.0",
            "use_s3_urls": settings.use_s3_urls,
            "endpoints": {
                "auth": "/auth",
                "query": "/query", 
                "health": "/health",
                "metrics": "/metrics",
                "download": "/download/{database_name}",
                "install": "/install",
                "admin": {
                    "databases": "/admin/databases/status",
                    "downloads": "/admin/downloads/status", 
                    "retry": "/admin/downloads/retry",
                    "cleanup": "/admin/downloads/cleanup",
                    "update": "/admin/update-databases"
                } if settings.enable_admin else None
            }
        }


@app.get("/query")
async def query_ips(
    request: Request,
    ips: str = Query(..., description="Comma-separated IP addresses"),
    full_data: bool = Query(False, description="Return all available data"),
    x_api_key: Optional[str] = Header(None),
    api_key: Optional[str] = Query(None)
):
    """
    Query GeoIP data for one or more IP addresses.
    
    Authentication can be provided via:
    1. Session cookie (from web UI)
    2. X-API-Key header
    3. api_key query parameter
    """
    metrics["total_requests"] += 1
    
    # Check authentication (session -> header -> query param)
    session_key = request.session.get("api_key") if hasattr(request.session, "get") else None
    auth_key = session_key or x_api_key or api_key
    
    if not validate_api_key(auth_key):
        metrics["failed_requests"] += 1
        logger.warning(f"Invalid API key attempt for query from {request.client.host}")
        raise HTTPException(status_code=401, detail="Invalid API key")
    
    # Store API key in session for web UI
    if not session_key and auth_key:
        request.session["api_key"] = auth_key
    
    # Check if GeoIP reader is available
    if not geoip_reader:
        raise HTTPException(status_code=503, detail="GeoIP service not available")
    
    # Parse and validate IPs
    ip_list = [ip.strip() for ip in ips.split(',')][:settings.query_rate_limit]
    
    if not ip_list:
        raise HTTPException(status_code=400, detail="No IP addresses provided")
    
    results = {}
    
    for ip in ip_list:
        # Validate IP format
        try:
            ipaddress.ip_address(ip)
        except ValueError:
            results[ip] = {"error": "Invalid IP address"}
            continue
        
        # Check cache
        cache_key = f"{ip}:{full_data}"
        cached = await cache.get(cache_key)
        if cached:
            results[ip] = cached
            continue
        
        # Query databases
        try:
            data = await geoip_reader.query(ip, full_data)
            if data:
                await cache.set(cache_key, data)
                results[ip] = data
            else:
                not_found = {"error": "Not found"}
                await cache.set(cache_key, not_found)
                results[ip] = not_found
        except Exception as e:
            logger.error(f"Error querying {ip}: {e}")
            results[ip] = {"error": "Query failed"}
    
    metrics["successful_requests"] += 1
    logger.info(f"Successful query for {len(ip_list)} IPs")
    
    return JSONResponse(content=results)


@app.post("/login")
async def login(
    request: Request,
    api_key: str = Query(..., description="API key for authentication")
):
    """Login endpoint for session-based authentication."""
    if not validate_api_key(api_key):
        raise HTTPException(status_code=401, detail="Invalid API key")
    
    # Store in session
    request.session["api_key"] = api_key
    
    return {"message": "Authentication successful"}


@app.post("/logout")
async def logout(request: Request):
    """Logout endpoint to clear session."""
    request.session.clear()
    return {"message": "Logged out successfully"}


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

    @app.post("/admin/update-databases")
    async def update_databases_endpoint(
        x_admin_key: Optional[str] = Header(None)
    ):
        """Manually trigger database update from S3 (requires admin key)."""
        if x_admin_key != settings.admin_key:
            raise HTTPException(status_code=401, detail="Invalid admin key")
        
        try:
            logger.info("Admin triggered database update")
            await update_databases()
            logger.info("Admin database update completed successfully")
            return {"message": "Database update completed successfully"}
        except Exception as e:
            logger.error(f"Admin database update failed: {e}")
            raise HTTPException(status_code=500, detail=f"Database update failed: {str(e)}")

    @app.post("/admin/cache/clear")
    async def clear_cache_endpoint(
        x_admin_key: Optional[str] = Header(None)
    ):
        """Clear all cached query results (requires admin key)."""
        if x_admin_key != settings.admin_key:
            raise HTTPException(status_code=401, detail="Invalid admin key")
        
        try:
            cache = get_cache()
            await cache.clear_all()
            logger.info("Admin cleared all cache entries")
            return {"message": "Cache cleared successfully"}
        except Exception as e:
            logger.error(f"Admin cache clear failed: {e}")
            raise HTTPException(status_code=500, detail=f"Cache clear failed: {str(e)}")

    @app.get("/admin/cache/stats")
    async def get_cache_stats_endpoint(
        x_admin_key: Optional[str] = Header(None)
    ):
        """Get cache statistics and configuration (requires admin key)."""
        if x_admin_key != settings.admin_key:
            raise HTTPException(status_code=401, detail="Invalid admin key")
        
        try:
            cache = get_cache()
            cache_type = type(cache).__name__.replace('Cache', '').lower()
            
            # Basic stats available for all cache types
            stats = {
                "cache_type": cache_type,
                "cache_enabled": settings.cache_type != "none"
            }
            
            # Add type-specific stats if available
            if hasattr(cache, 'get_stats'):
                stats.update(await cache.get_stats())
            
            return stats
        except Exception as e:
            logger.error(f"Admin cache stats failed: {e}")
            raise HTTPException(status_code=500, detail=f"Cache stats failed: {str(e)}")

    @app.get("/admin/databases/status")
    async def get_database_status_endpoint(
        x_admin_key: Optional[str] = Header(None)
    ):
        """Get database loading status (requires admin key)."""
        if x_admin_key != settings.admin_key:
            raise HTTPException(status_code=401, detail="Invalid admin key")
        
        try:
            reader = GeoIPReader()
            status = reader.get_database_status()
            
            total_databases = len(status)
            loaded_databases = sum(1 for loaded in status.values() if loaded)
            
            return {
                "databases": status,
                "summary": {
                    "total": total_databases,
                    "loaded": loaded_databases,
                    "failed": total_databases - loaded_databases
                }
            }
        except Exception as e:
            logger.error(f"Admin database status check failed: {e}")
            raise HTTPException(status_code=500, detail=f"Database status check failed: {str(e)}")

    @app.get("/admin/databases/info")
    async def get_database_info_endpoint(
        x_admin_key: Optional[str] = Header(None)
    ):
        """Get database file information (requires admin key)."""
        if x_admin_key != settings.admin_key:
            raise HTTPException(status_code=401, detail="Invalid admin key")
        
        try:
            database_path = Path(settings.database_path)
            info = {}
            
            # Check MaxMind databases
            maxmind_path = database_path / 'raw' / 'maxmind'
            if maxmind_path.exists():
                info['maxmind'] = {}
                for db_file in maxmind_path.glob('*.mmdb'):
                    stat = db_file.stat()
                    info['maxmind'][db_file.name] = {
                        "size_bytes": stat.st_size,
                        "size_mb": round(stat.st_size / (1024 * 1024), 2),
                        "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
                        "path": str(db_file)
                    }
            
            # Check IP2Location databases  
            ip2location_path = database_path / 'raw' / 'ip2location'
            if ip2location_path.exists():
                info['ip2location'] = {}
                for db_file in ip2location_path.glob('*.BIN'):
                    stat = db_file.stat()
                    info['ip2location'][db_file.name] = {
                        "size_bytes": stat.st_size,
                        "size_mb": round(stat.st_size / (1024 * 1024), 2),
                        "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
                        "path": str(db_file)
                    }
            
            return info
        except Exception as e:
            logger.error(f"Admin database info check failed: {e}")
            raise HTTPException(status_code=500, detail=f"Database info check failed: {str(e)}")

    @app.post("/admin/databases/reload")
    async def reload_databases_endpoint(
        x_admin_key: Optional[str] = Header(None)
    ):
        """Reload databases without updating from S3 (requires admin key)."""
        if x_admin_key != settings.admin_key:
            raise HTTPException(status_code=401, detail="Invalid admin key")
        
        try:
            reader = GeoIPReader()
            reader.reload_databases()
            logger.info("Admin triggered database reload")
            
            # Get updated status
            status = reader.get_database_status()
            loaded_count = sum(1 for loaded in status.values() if loaded)
            
            return {
                "message": f"Databases reloaded successfully ({loaded_count} loaded)",
                "databases_loaded": loaded_count,
                "status": status
            }
        except Exception as e:
            logger.error(f"Admin database reload failed: {e}")
            raise HTTPException(status_code=500, detail=f"Database reload failed: {str(e)}")

    @app.get("/admin/scheduler/info")
    async def get_scheduler_info_endpoint(
        x_admin_key: Optional[str] = Header(None)
    ):
        """Get scheduler information and next run times (requires admin key)."""
        if x_admin_key != settings.admin_key:
            raise HTTPException(status_code=401, detail="Invalid admin key")
        
        try:
            info = {
                "scheduler_running": scheduler.running,
                "jobs": []
            }
            
            for job in scheduler.get_jobs():
                next_run = job.next_run_time
                info["jobs"].append({
                    "id": job.id,
                    "name": job.name,
                    "next_run": next_run.isoformat() if next_run else None,
                    "trigger": str(job.trigger)
                })
            
            return info
        except Exception as e:
            logger.error(f"Admin scheduler info check failed: {e}")
            raise HTTPException(status_code=500, detail=f"Scheduler info check failed: {str(e)}")

    @app.post("/admin/scheduler/trigger")
    async def trigger_scheduler_job_endpoint(
        x_admin_key: Optional[str] = Header(None),
        job_id: str = Query("database_update", description="Job ID to trigger")
    ):
        """Manually trigger a scheduled job (requires admin key)."""
        if x_admin_key != settings.admin_key:
            raise HTTPException(status_code=401, detail="Invalid admin key")
        
        try:
            job = scheduler.get_job(job_id)
            if not job:
                raise HTTPException(status_code=404, detail=f"Job '{job_id}' not found")
            
            # Trigger the job
            await job.func()
            logger.info(f"Admin manually triggered job: {job_id}")
            
            return {"message": f"Job '{job_id}' triggered successfully"}
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Admin job trigger failed: {e}")
            raise HTTPException(status_code=500, detail=f"Job trigger failed: {str(e)}")

    @app.get("/admin/downloads/status")
    async def get_download_status_endpoint(
        x_admin_key: Optional[str] = Header(None)
    ):
        """Get detailed download status for all databases (requires admin key)."""
        if x_admin_key != settings.admin_key:
            raise HTTPException(status_code=401, detail="Invalid admin key")
        
        try:
            from database_updater import DatabaseUpdater
            updater = DatabaseUpdater()
            status = updater.get_download_status()
            
            # Add summary statistics
            summary = {
                "total_databases": len(status),
                "downloaded": sum(1 for db in status.values() if db['exists']),
                "missing": sum(1 for db in status.values() if not db['exists']),
                "total_size_mb": sum(db['size_mb'] for db in status.values()),
                "temp_files_count": sum(len(db['temp_files']) for db in status.values())
            }
            
            return {
                "summary": summary,
                "databases": status,
                "timestamp": datetime.now().isoformat()
            }
        except Exception as e:
            logger.error(f"Admin download status check failed: {e}")
            raise HTTPException(status_code=500, detail=f"Download status check failed: {str(e)}")

    @app.post("/admin/downloads/cleanup")
    async def cleanup_downloads_endpoint(
        x_admin_key: Optional[str] = Header(None)
    ):
        """Clean up temporary download files (requires admin key)."""
        if x_admin_key != settings.admin_key:
            raise HTTPException(status_code=401, detail="Invalid admin key")
        
        try:
            from database_updater import DatabaseUpdater
            updater = DatabaseUpdater()
            await updater.cleanup_old_files()
            logger.info("Admin triggered download cleanup")
            
            return {"message": "Download cleanup completed successfully"}
        except Exception as e:
            logger.error(f"Admin download cleanup failed: {e}")
            raise HTTPException(status_code=500, detail=f"Download cleanup failed: {str(e)}")

    @app.post("/admin/downloads/retry")
    async def retry_failed_downloads_endpoint(
        x_admin_key: Optional[str] = Header(None),
        databases: Optional[str] = Query(None, description="Comma-separated list of database names to retry, or 'all' for all missing")
    ):
        """Retry downloading specific databases (requires admin key)."""
        if x_admin_key != settings.admin_key:
            raise HTTPException(status_code=401, detail="Invalid admin key")
        
        try:
            from database_updater import DatabaseUpdater, AVAILABLE_DATABASES
            updater = DatabaseUpdater()
            
            # Determine which databases to retry
            if databases == "all" or not databases:
                # Retry all missing databases
                current_status = updater.get_download_status()
                databases_to_retry = [name for name, status in current_status.items() if not status['exists']]
            else:
                # Retry specific databases
                databases_to_retry = [db.strip() for db in databases.split(',')]
                # Validate database names
                invalid_dbs = [db for db in databases_to_retry if db not in AVAILABLE_DATABASES]
                if invalid_dbs:
                    raise HTTPException(status_code=400, detail=f"Invalid database names: {', '.join(invalid_dbs)}")
            
            if not databases_to_retry:
                return {"message": "No databases need to be downloaded", "databases_checked": []}
            
            logger.info(f"Admin triggered retry for databases: {', '.join(databases_to_retry)}")
            
            # Create a custom updater method for specific databases
            results = {}
            
            import aiohttp
            import asyncio
            
            connector = aiohttp.TCPConnector(
                limit=10,
                limit_per_host=5,
                ttl_dns_cache=300,
                use_dns_cache=True,
            )
            
            timeout = aiohttp.ClientTimeout(
                total=updater.download_timeout,
                connect=updater.connection_timeout
            )
            
            async with aiohttp.ClientSession(connector=connector, timeout=timeout) as session:
                tasks = {}
                for db_name in databases_to_retry:
                    s3_path = AVAILABLE_DATABASES[db_name]
                    task = updater.download_database(session, db_name, s3_path)
                    tasks[db_name] = task
                
                # Execute downloads concurrently
                download_results = await asyncio.gather(
                    *tasks.values(), 
                    return_exceptions=True
                )
                
                # Map results back to database names
                for db_name, result in zip(tasks.keys(), download_results):
                    if isinstance(result, Exception):
                        logger.error(f"Exception retrying {db_name}: {result}")
                        results[db_name] = False
                    else:
                        results[db_name] = result
            
            successful = [name for name, success in results.items() if success]
            failed = [name for name, success in results.items() if not success]
            
            response = {
                "message": f"Retry completed: {len(successful)}/{len(results)} successful",
                "successful_downloads": successful,
                "failed_downloads": failed,
                "results": results
            }
            
            logger.info(f"Admin retry completed: {len(successful)}/{len(results)} successful")
            return response
            
        except HTTPException:
            raise
        except Exception as e:
            logger.error(f"Admin download retry failed: {e}")
            raise HTTPException(status_code=500, detail=f"Download retry failed: {str(e)}")

    @app.get("/admin/status")
    async def get_admin_status_endpoint(
        x_admin_key: Optional[str] = Header(None)
    ):
        """Get comprehensive system status for administrators (requires admin key)."""
        if x_admin_key != settings.admin_key:
            raise HTTPException(status_code=401, detail="Invalid admin key")
        
        try:
            # Get basic health info
            reader = GeoIPReader()
            db_status = reader.get_database_status()
            
            # Get scheduler status
            scheduler_jobs = []
            for job in scheduler.get_jobs():
                next_run = job.next_run_time
                scheduler_jobs.append({
                    "id": job.id,
                    "name": job.name,
                    "next_run": next_run.isoformat() if next_run else None
                })
            
            # Calculate uptime
            uptime_seconds = (datetime.now() - metrics["start_time"]).total_seconds()
            
            return {
                "service": {
                    "status": "healthy",
                    "uptime_seconds": uptime_seconds,
                    "version": "1.0.0",
                    "debug_mode": settings.debug
                },
                "databases": {
                    "total": len(db_status),
                    "loaded": sum(1 for loaded in db_status.values() if loaded),
                    "status": db_status
                },
                "scheduler": {
                    "running": scheduler.running,
                    "jobs": scheduler_jobs
                },
                "cache": {
                    "type": settings.cache_type,
                    "enabled": settings.cache_type != "none"
                },
                "configuration": {
                    "use_s3_urls": settings.use_s3_urls,
                    "database_path": settings.database_path,
                    "workers": settings.workers,
                    "port": settings.port
                },
                "metrics": {
                    "total_requests": metrics["total_requests"],
                    "successful_requests": metrics["successful_requests"],
                    "failed_requests": metrics["failed_requests"]
                }
            }
        except Exception as e:
            logger.error(f"Admin status check failed: {e}")
            raise HTTPException(status_code=500, detail=f"Status check failed: {str(e)}")

    @app.get("/admin/config")
    async def get_admin_config_endpoint(
        x_admin_key: Optional[str] = Header(None)
    ):
        """Get current configuration (sanitized, no secrets) (requires admin key)."""
        if x_admin_key != settings.admin_key:
            raise HTTPException(status_code=401, detail="Invalid admin key")
        
        try:
            config = {
                "api": {
                    "port": settings.port,
                    "workers": settings.workers,
                    "debug": settings.debug,
                    "api_keys_count": len(settings.api_keys)
                },
                "database": {
                    "path": settings.database_path,
                    "update_schedule": settings.database_update_schedule
                },
                "s3": {
                    "use_s3_urls": settings.use_s3_urls,
                    "bucket": settings.s3_bucket if settings.use_s3_urls else None,
                    "region": settings.aws_region if settings.use_s3_urls else None,
                    "url_expiry_seconds": settings.url_expiry_seconds if settings.use_s3_urls else None
                },
                "cache": {
                    "type": settings.cache_type,
                    "enabled": settings.cache_type != "none"
                },
                "admin": {
                    "enabled": settings.enable_admin,
                    "key_configured": bool(settings.admin_key)
                },
                "logging": {
                    "level": settings.log_level
                }
            }
            
            # Add Redis config if using Redis cache
            if settings.cache_type == "redis" and hasattr(settings, 'redis_url'):
                config["cache"]["redis_url"] = "***configured***"
            
            return config
        except Exception as e:
            logger.error(f"Admin config check failed: {e}")
            raise HTTPException(status_code=500, detail=f"Config check failed: {str(e)}")


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