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
GEOIP_SCRIPT_TYPE="${GEOIP_SCRIPT_TYPE:-auto}"  # auto, bash, posix, python, powershell, go

# Environment detection variables
HAVE_BASH=false
HAVE_PYTHON_FULL=false
HAVE_POWERSHELL=false
HAVE_GO_BINARY=false
SELECTED_SCRIPT=""
DETECTED_ARCH=""
GO_BINARY_PATH=""

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

# Detect system architecture
geoip_detect_architecture() {
    local arch_raw
    arch_raw=$(uname -m 2>/dev/null || echo "unknown")
    
    case "$arch_raw" in
        x86_64|amd64)
            DETECTED_ARCH="amd64"
            ;;
        aarch64|arm64)
            DETECTED_ARCH="arm64"
            ;;
        armv7l|armhf|arm)
            DETECTED_ARCH="arm"
            ;;
        i386|i686)
            DETECTED_ARCH="386"
            ;;
        *)
            DETECTED_ARCH="unknown"
            geoip_log_warning "Unknown architecture: $arch_raw"
            ;;
    esac
    
    geoip_log_info "Detected architecture: $DETECTED_ARCH"
}

# Detect available runtimes and shells in the environment
geoip_detect_environment() {
    geoip_log_info "Detecting environment capabilities..."
    
    # First detect architecture
    geoip_detect_architecture
    
    # Check for Bash
    if command -v bash >/dev/null 2>&1; then
        HAVE_BASH=true
    fi
    
    # Check for Python with required dependencies
    if command -v python3 >/dev/null 2>&1; then
        # Check if aiohttp is available for async functionality
        if python3 -c "import aiohttp" 2>/dev/null; then
            HAVE_PYTHON_FULL=true
        elif [ -f /opt/geoip/geoip-update.py ]; then
            # Python is available but might work without aiohttp in basic mode
            geoip_log_warning "Python found but aiohttp not available - Python script may have limited functionality"
        fi
    fi
    
    # Check for PowerShell Core
    if command -v pwsh >/dev/null 2>&1; then
        HAVE_POWERSHELL=true
    fi
    
    # Check for architecture-specific Go binary
    if [ "$DETECTED_ARCH" = "amd64" ] && [ -f /opt/geoip/geoip-update-amd64 ] && [ -x /opt/geoip/geoip-update-amd64 ]; then
        HAVE_GO_BINARY=true
        GO_BINARY_PATH="/opt/geoip/geoip-update-amd64"
        geoip_log_info "Found Go binary for AMD64 architecture"
    elif [ "$DETECTED_ARCH" = "arm64" ] && [ -f /opt/geoip/geoip-update-arm64 ] && [ -x /opt/geoip/geoip-update-arm64 ]; then
        HAVE_GO_BINARY=true
        GO_BINARY_PATH="/opt/geoip/geoip-update-arm64"
        geoip_log_info "Found Go binary for ARM64 architecture"
    elif [ -f /opt/geoip/geoip-update ] && [ -x /opt/geoip/geoip-update ]; then
        # Fallback to generic binary if it exists (backwards compatibility)
        HAVE_GO_BINARY=true
        GO_BINARY_PATH="/opt/geoip/geoip-update"
        geoip_log_info "Found generic Go binary"
    else
        geoip_log_info "No Go binary available for architecture: $DETECTED_ARCH"
    fi
    
    # Log detected capabilities
    geoip_log_info "Environment: Bash=$HAVE_BASH Python=$HAVE_PYTHON_FULL PowerShell=$HAVE_POWERSHELL Go=$HAVE_GO_BINARY"
}

# Select the best available script based on environment and user preference
geoip_select_best_script() {
    # If user specified a script type, try to use it
    case "$GEOIP_SCRIPT_TYPE" in
        bash)
            if [ "$HAVE_BASH" = true ] && [ -f /opt/geoip/geoip-update.sh ]; then
                SELECTED_SCRIPT="/opt/geoip/geoip-update.sh"
                geoip_log_info "Using Bash script (user specified)"
            else
                geoip_log_warning "Bash script requested but not available"
            fi
            ;;
        posix)
            if [ -f /opt/geoip/geoip-update-posix.sh ]; then
                SELECTED_SCRIPT="/opt/geoip/geoip-update-posix.sh"
                geoip_log_info "Using POSIX script (user specified)"
            else
                geoip_log_warning "POSIX script requested but not available"
            fi
            ;;
        python)
            if [ "$HAVE_PYTHON_FULL" = true ] && [ -f /opt/geoip/geoip-update.py ]; then
                SELECTED_SCRIPT="python3 /opt/geoip/geoip-update.py"
                geoip_log_info "Using Python script (user specified)"
            else
                geoip_log_warning "Python script requested but not available or missing dependencies"
            fi
            ;;
        powershell)
            if [ "$HAVE_POWERSHELL" = true ] && [ -f /opt/geoip/geoip-update.ps1 ]; then
                SELECTED_SCRIPT="pwsh /opt/geoip/geoip-update.ps1"
                geoip_log_info "Using PowerShell script (user specified)"
            else
                geoip_log_warning "PowerShell script requested but not available"
            fi
            ;;
        go)
            if [ "$HAVE_GO_BINARY" = true ] && [ -n "$GO_BINARY_PATH" ]; then
                SELECTED_SCRIPT="$GO_BINARY_PATH"
                geoip_log_info "Using Go binary (user specified): $GO_BINARY_PATH"
            else
                geoip_log_warning "Go binary requested but not available for architecture: $DETECTED_ARCH"
            fi
            ;;
        auto|*)
            # Auto-detect best option
            ;;
    esac
    
    # If no script selected yet, auto-detect based on priority
    if [ -z "$SELECTED_SCRIPT" ]; then
        # Priority order:
        # 1. Go binary (fastest, self-contained)
        # 2. Python (async, parallel downloads)
        # 3. Bash (full features, widely available)
        # 4. PowerShell (for Windows containers)
        # 5. POSIX (maximum compatibility, works everywhere)
        
        if [ "$HAVE_GO_BINARY" = true ] && [ -n "$GO_BINARY_PATH" ]; then
            SELECTED_SCRIPT="$GO_BINARY_PATH"
            geoip_log_info "Auto-selected Go binary (fastest): $GO_BINARY_PATH"
        elif [ "$HAVE_PYTHON_FULL" = true ] && [ -f /opt/geoip/geoip-update.py ]; then
            SELECTED_SCRIPT="python3 /opt/geoip/geoip-update.py"
            geoip_log_info "Auto-selected Python script (async downloads)"
        elif [ "$HAVE_BASH" = true ] && [ -f /opt/geoip/geoip-update.sh ]; then
            SELECTED_SCRIPT="/opt/geoip/geoip-update.sh"
            geoip_log_info "Auto-selected Bash script (full features)"
        elif [ "$HAVE_POWERSHELL" = true ] && [ -f /opt/geoip/geoip-update.ps1 ]; then
            SELECTED_SCRIPT="pwsh /opt/geoip/geoip-update.ps1"
            geoip_log_info "Auto-selected PowerShell script"
        elif [ -f /opt/geoip/geoip-update-posix.sh ]; then
            SELECTED_SCRIPT="/opt/geoip/geoip-update-posix.sh"
            geoip_log_info "Auto-selected POSIX script (maximum compatibility)"
        else
            geoip_log_error "No suitable GeoIP update script found!"
            return 1
        fi
    fi
    
    geoip_log_info "Selected script: $SELECTED_SCRIPT"
    return 0
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
    
    # Detect environment and select best script if not done yet
    if [ -z "$SELECTED_SCRIPT" ]; then
        geoip_detect_environment
        geoip_select_best_script || return 1
    fi
    
    # Execute the selected script with arguments
    if sh -c "$SELECTED_SCRIPT $cmd_args"; then
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
    
    # Detect environment and select best script if not done yet
    if [ -z "$SELECTED_SCRIPT" ]; then
        geoip_detect_environment
        geoip_select_best_script || {
            geoip_log_error "No suitable script found for validation"
            return 1
        }
    fi
    
    # Use the same selected script for validation
    # Build validation command
    local validation_cmd="$SELECTED_SCRIPT --validate-only --directory '$GEOIP_TARGET_DIR'"
    
    if [ "$GEOIP_QUIET_MODE" = "true" ]; then
        validation_cmd="$validation_cmd --quiet"
    fi
    
    geoip_log_info "Using selected script for validation: $SELECTED_SCRIPT"
    
    # Execute validation
    if sh -c "$validation_cmd" 2>/dev/null; then
        geoip_log_success "Database validation passed"
        return 0
    else
        # If selected script doesn't support --validate-only, try validate.sh
        geoip_log_warning "Selected script validation failed, trying fallback validation..."
        
        if [ -f /opt/geoip/validate.sh ]; then
            geoip_log_info "Using validate.sh fallback..."
            if /opt/geoip/validate.sh --directory "$GEOIP_TARGET_DIR"; then
                geoip_log_success "Database validation passed (validate.sh)"
                return 0
            else
                geoip_log_error "Database validation failed!"
                return 1
            fi
        fi
        
        # Last resort: just check files exist
        geoip_log_warning "No validation available, checking file existence only"
        if geoip_check_databases; then
            geoip_log_success "Databases exist"
            return 0
        else
            geoip_log_error "Databases missing!"
            return 1
        fi
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
