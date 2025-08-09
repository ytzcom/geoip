#!/bin/sh
# GeoIP Docker Entrypoint Helper Functions
# Provides complete Docker integration while using existing CLI scripts
#
# Usage:
#   Source this file in your entrypoint:
#   . /opt/geoip/entrypoint-helper.sh
#
# Then call functions as needed:
#   geoip_init              - Complete initialization
#   geoip_check_databases   - Check if databases exist
#   geoip_download_databases - Download databases
#   geoip_validate_databases - Validate databases
#   geoip_health_check      - Health check for monitoring

# Configuration with sensible defaults
GEOIP_ENABLED="${GEOIP_ENABLED:-true}"
GEOIP_TARGET_DIR="${GEOIP_TARGET_DIR:-/app/resources/geoip}"
GEOIP_DOWNLOAD_ON_START="${GEOIP_DOWNLOAD_ON_START:-true}"
GEOIP_VALIDATE_ON_START="${GEOIP_VALIDATE_ON_START:-true}"
GEOIP_FAIL_ON_ERROR="${GEOIP_FAIL_ON_ERROR:-false}"
GEOIP_SETUP_CRON="${GEOIP_SETUP_CRON:-true}"
GEOIP_API_KEY="${GEOIP_API_KEY:-}"
GEOIP_API_ENDPOINT="${GEOIP_API_ENDPOINT:-https://geoipdb.net/auth}"
GEOIP_DATABASES="${GEOIP_DATABASES:-all}"
GEOIP_LOG_FILE="${GEOIP_LOG_FILE:-}"
GEOIP_QUIET_MODE="${GEOIP_QUIET_MODE:-false}"

# Logging functions with consistent format
geoip_log_info() {
    echo "[GeoIP] INFO: $1"
}

geoip_log_error() {
    echo "[GeoIP] ERROR: $1" >&2
}

geoip_log_warning() {
    echo "[GeoIP] WARNING: $1"
}

geoip_log_success() {
    echo "[GeoIP] SUCCESS: $1"
}

# Check if GeoIP databases need to be downloaded
geoip_check_databases() {
    local need_download=false
    
    if [ ! -d "$GEOIP_TARGET_DIR" ]; then
        geoip_log_info "GeoIP directory does not exist: $GEOIP_TARGET_DIR"
        need_download=true
    else
        # Check for key database files
        local missing_count=0
        for db in "GeoIP2-City.mmdb" "GeoIP2-Country.mmdb"; do
            if [ ! -f "$GEOIP_TARGET_DIR/$db" ]; then
                geoip_log_info "Missing database: $db"
                missing_count=$((missing_count + 1))
            fi
        done
        
        if [ $missing_count -gt 0 ]; then
            need_download=true
        fi
    fi
    
    if [ "$need_download" = true ]; then
        return 1  # Databases needed
    else
        return 0  # Databases present
    fi
}

# Download GeoIP databases using existing CLI script
geoip_download_databases() {
    geoip_log_info "Downloading GeoIP databases..."
    
    # Check if API key is configured
    if [ -z "$GEOIP_API_KEY" ]; then
        geoip_log_error "GEOIP_API_KEY not configured!"
        geoip_log_error "Please set: export GEOIP_API_KEY=your-api-key"
        return 1
    fi
    
    # Ensure target directory exists
    mkdir -p "$GEOIP_TARGET_DIR" 2>/dev/null || true
    
    # Build command arguments (clean trailing whitespace from endpoint)
    local clean_endpoint=$(echo "$GEOIP_API_ENDPOINT" | sed 's/[[:space:]]*$//')
    local cmd_args="--api-key '$GEOIP_API_KEY' --directory '$GEOIP_TARGET_DIR' --endpoint '$clean_endpoint'"
    
    if [ "$GEOIP_QUIET_MODE" = "true" ]; then
        cmd_args="$cmd_args --quiet"
    fi
    
    if [ -n "$GEOIP_LOG_FILE" ]; then
        cmd_args="$cmd_args --log-file '$GEOIP_LOG_FILE'"
    fi
    
    if [ "$GEOIP_DATABASES" != "all" ]; then
        cmd_args="$cmd_args --databases '$GEOIP_DATABASES'"
    fi
    
    # Use POSIX-compliant script for better compatibility (works on Alpine)
    # Falls back to bash version if POSIX version not available
    local script_to_use="/opt/geoip/geoip-update.sh"
    if [ -f /opt/geoip/geoip-update-posix.sh ]; then
        script_to_use="/opt/geoip/geoip-update-posix.sh"
        geoip_log_info "Using POSIX-compliant script for better compatibility"
    fi
    
    if sh -c "$script_to_use $cmd_args"; then
        geoip_log_success "GeoIP databases downloaded successfully!"
        return 0
    else
        geoip_log_error "Failed to download GeoIP databases!"
        return 1
    fi
}

# Validate GeoIP databases
geoip_validate_databases() {
    geoip_log_info "Validating GeoIP databases..."
    
    # Try Python validation if available
    if command -v python3 >/dev/null 2>&1 && [ -f /opt/geoip/geoip-update.py ]; then
        geoip_log_info "Using Python validation..."
        if python3 /opt/geoip/geoip-update.py --validate --directory "$GEOIP_TARGET_DIR" 2>/dev/null; then
            geoip_log_success "Database validation passed (Python)"
            return 0
        else
            geoip_log_warning "Python validation failed, trying basic validation..."
        fi
    fi
    
    # Fallback to basic validation
    if [ -f /opt/geoip/validate.sh ]; then
        geoip_log_info "Using basic validation..."
        if /opt/geoip/validate.sh "$GEOIP_TARGET_DIR"; then
            geoip_log_success "Database validation passed (basic)"
            return 0
        else
            geoip_log_error "Database validation failed!"
            return 1
        fi
    fi
    
    # If no validation available, just check files exist
    geoip_log_warning "No validation script available, checking file existence only"
    if geoip_check_databases; then
        geoip_log_success "Databases exist"
        return 0
    else
        geoip_log_error "Databases missing!"
        return 1
    fi
}

# Setup cron for automatic updates
geoip_setup_cron() {
    if [ -f /opt/geoip/setup-cron.sh ]; then
        geoip_log_info "Setting up automatic GeoIP updates..."
        if /opt/geoip/setup-cron.sh; then
            geoip_log_success "Automatic updates configured"
            return 0
        else
            geoip_log_warning "Failed to setup automatic updates"
            return 1
        fi
    else
        geoip_log_warning "Cron setup script not found"
        return 1
    fi
}

# Main initialization function
geoip_init() {
    if [ "$GEOIP_ENABLED" != "true" ]; then
        geoip_log_info "GeoIP functionality is disabled (GEOIP_ENABLED=$GEOIP_ENABLED)"
        return 0
    fi
    
    geoip_log_info "Initializing GeoIP databases..."
    geoip_log_info "Configuration:"
    geoip_log_info "  Target directory: $GEOIP_TARGET_DIR"
    geoip_log_info "  API endpoint: $GEOIP_API_ENDPOINT"
    geoip_log_info "  Download on start: $GEOIP_DOWNLOAD_ON_START"
    geoip_log_info "  Validate on start: $GEOIP_VALIDATE_ON_START"
    geoip_log_info "  Setup cron: $GEOIP_SETUP_CRON"
    geoip_log_info "  Fail on error: $GEOIP_FAIL_ON_ERROR"
    
    local init_failed=false
    
    # Check and download if needed
    if ! geoip_check_databases; then
        geoip_log_info "Databases are missing or incomplete"
        if [ "$GEOIP_DOWNLOAD_ON_START" = "true" ]; then
            if ! geoip_download_databases; then
                geoip_log_error "Database download failed!"
                init_failed=true
            fi
        else
            geoip_log_warning "Skipping download (GEOIP_DOWNLOAD_ON_START=false)"
        fi
    else
        geoip_log_info "All required databases are present"
    fi
    
    # Validate if requested
    if [ "$GEOIP_VALIDATE_ON_START" = "true" ] && [ "$init_failed" = "false" ]; then
        if ! geoip_validate_databases; then
            geoip_log_error "Database validation failed!"
            init_failed=true
        fi
    fi
    
    # Setup cron if requested
    if [ "$GEOIP_SETUP_CRON" = "true" ] && [ "$init_failed" = "false" ]; then
        if ! geoip_setup_cron; then
            geoip_log_warning "Cron setup failed, manual updates will be required"
            # Don't fail init for cron setup failure
        fi
    fi
    
    # Handle initialization result
    if [ "$init_failed" = "true" ]; then
        if [ "$GEOIP_FAIL_ON_ERROR" = "true" ]; then
            geoip_log_error "GeoIP initialization failed! (GEOIP_FAIL_ON_ERROR=true)"
            return 1
        else
            geoip_log_warning "GeoIP initialization had errors but continuing (GEOIP_FAIL_ON_ERROR=false)"
            return 0
        fi
    else
        geoip_log_success "GeoIP initialization completed successfully!"
        return 0
    fi
}

# Health check function for monitoring
geoip_health_check() {
    if geoip_check_databases; then
        echo "HEALTHY: GeoIP databases present"
        
        # Additional checks if databases exist
        local db_count=0
        local total_size=0
        
        for db_file in "$GEOIP_TARGET_DIR"/*.mmdb "$GEOIP_TARGET_DIR"/*.BIN; do
            if [ -f "$db_file" ]; then
                db_count=$((db_count + 1))
                if command -v stat >/dev/null 2>&1; then
                    size=$(stat -c%s "$db_file" 2>/dev/null || stat -f%z "$db_file" 2>/dev/null || echo 0)
                    total_size=$((total_size + size))
                fi
            fi
        done
        
        echo "  Databases: $db_count files"
        if [ $total_size -gt 0 ]; then
            echo "  Total size: $((total_size / 1024 / 1024))MB"
        fi
        
        return 0
    else
        echo "UNHEALTHY: GeoIP databases missing or incomplete"
        return 1
    fi
}
