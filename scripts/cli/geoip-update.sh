#!/usr/bin/env bash
# Note: This script requires bash for advanced features like arrays and [[ ]] tests
# For broader compatibility, ensure bash is available or use the Python version
#
# GeoIP Database Update Script
# Downloads GeoIP databases from authenticated API
#
# Usage:
#   ./geoip-update.sh [OPTIONS]
#
# Options:
#   -k, --api-key KEY        API key (or use GEOIP_API_KEY env var)
#   -e, --endpoint URL       API endpoint (default: from env or predefined)
#   -d, --directory DIR      Target directory (default: ./geoip)
#   -b, --databases LIST     Comma-separated database list or "all" (default: all)
#   -q, --quiet             Quiet mode for cron (no output unless error)
#   -v, --verbose           Verbose output
#   -l, --log-file FILE     Log to file
#   -n, --no-lock           Don't use lock file
#   -r, --retries NUM       Max retries (default: 3)
#   -t, --timeout SEC       Download timeout in seconds (default: 300)
#   -L, --list-databases    List all available databases and aliases
#   -E, --show-examples     Show usage examples for database selection
#   -V, --validate-only     Validate database names without downloading
#   -h, --help              Show this help message
#
# Environment Variables:
#   GEOIP_API_KEY           API key for authentication
#   GEOIP_API_ENDPOINT      API endpoint URL
#   GEOIP_TARGET_DIR        Default target directory
#   GEOIP_LOG_FILE          Default log file
#
# Examples:
#   # Download all databases (production endpoint)
#   ./geoip-update.sh --api-key your-key
#
#   # Local testing with Docker API
#   ./geoip-update.sh --api-key test-key-1 --endpoint http://localhost:8080/auth
#
#   # Using environment variables
#   export GEOIP_API_ENDPOINT=http://localhost:8080/auth
#   ./geoip-update.sh --api-key test-key-1
#
#   # Download specific databases quietly for cron
#   ./geoip-update.sh -q -b "GeoIP2-City.mmdb,GeoIP2-Country.mmdb"
#
#   # With logging
#   ./geoip-update.sh -l /var/log/geoip-update.log
#

set -euo pipefail

# Default values
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
readonly DEFAULT_ENDPOINT="https://geoipdb.net/auth"
readonly DEFAULT_TARGET_DIR="./geoip"
readonly DEFAULT_RETRIES=3
readonly DEFAULT_TIMEOUT=300
readonly LOCK_FILE="/tmp/geoip-update.lock"
readonly TEMP_DIR_PREFIX="/tmp/geoip-update"

# Configuration variables
API_KEY="${GEOIP_API_KEY:-}"
API_ENDPOINT="${GEOIP_API_ENDPOINT:-$DEFAULT_ENDPOINT}"
TARGET_DIR="${GEOIP_TARGET_DIR:-$DEFAULT_TARGET_DIR}"
DATABASES="all"
QUIET_MODE=false
VERBOSE_MODE=false
LOG_FILE="${GEOIP_LOG_FILE:-}"
USE_LOCK=true
MAX_RETRIES=$DEFAULT_RETRIES
TIMEOUT=$DEFAULT_TIMEOUT
TEMP_DIR=""

# Color codes for output (disabled in quiet mode)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Log to file if specified
    if [[ -n "$LOG_FILE" ]]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
    
    # Output to console based on mode
    if [[ "$QUIET_MODE" == "false" ]]; then
        case "$level" in
            ERROR)
                echo -e "${RED}[$level]${NC} $message" >&2
                ;;
            WARN)
                echo -e "${YELLOW}[$level]${NC} $message" >&2
                ;;
            INFO)
                if [[ "$VERBOSE_MODE" == "true" ]]; then
                    echo -e "${BLUE}[$level]${NC} $message" >&2
                fi
                ;;
            SUCCESS)
                echo -e "${GREEN}[$level]${NC} $message" >&2
                ;;
            *)
                echo "[$level] $message" >&2
                ;;
        esac
    elif [[ "$level" == "ERROR" ]]; then
        # Always output errors, even in quiet mode
        echo "[$timestamp] $message" >&2
    fi
}

error() {
    log ERROR "$@"
    exit 1
}

# Help function
show_help() {
    sed -n '3,/^$/p' "$0" | grep '^#' | cut -c3-
    exit 0
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -k|--api-key)
                API_KEY="$2"
                shift 2
                ;;
            -e|--endpoint)
                API_ENDPOINT="$2"
                shift 2
                ;;
            -d|--directory)
                TARGET_DIR="$2"
                shift 2
                ;;
            -b|--databases)
                DATABASES="$2"
                shift 2
                ;;
            -q|--quiet)
                QUIET_MODE=true
                shift
                ;;
            -v|--verbose)
                VERBOSE_MODE=true
                shift
                ;;
            -l|--log-file)
                LOG_FILE="$2"
                shift 2
                ;;
            -n|--no-lock)
                USE_LOCK=false
                shift
                ;;
            -r|--retries)
                MAX_RETRIES="$2"
                shift 2
                ;;
            -t|--timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            -L|--list-databases)
                list_databases
                exit 0
                ;;
            -E|--show-examples)
                show_examples
                exit 0
                ;;
            -V|--validate-only)
                validate_database_names
                exit 0
                ;;
            -h|--help)
                show_help
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done
}

# Validate configuration
validate_config() {
    if [[ -z "$API_KEY" ]]; then
        error "API key not provided. Use -k option or set GEOIP_API_KEY environment variable"
    fi
    
    if [[ -z "$API_ENDPOINT" ]]; then
        error "API endpoint not configured"
    fi
    
    # Clean and normalize the endpoint
    # Remove trailing slashes and whitespace
    API_ENDPOINT=$(echo "$API_ENDPOINT" | sed 's|/*$||' | sed 's/[[:space:]]*$//')
    
    # Auto-append /auth if it's the base geoipdb.net domain without path
    case "$API_ENDPOINT" in
        */auth)
            # Already has /auth, keep as is
            ;;
        https://geoipdb.net|http://geoipdb.net)
            # Base domain without /auth, append it
            API_ENDPOINT="${API_ENDPOINT}/auth"
            log INFO "Appended /auth to endpoint: $API_ENDPOINT"
            ;;
        *)
            # Custom endpoint or already has a different path, keep as is
            ;;
    esac
    
    # Log endpoint being used (helpful for debugging)
    if [[ "$API_ENDPOINT" =~ ^http://localhost|^http://127\.0\.0\.1 ]]; then
        log INFO "Using local API endpoint: $API_ENDPOINT"
    elif [[ "$API_ENDPOINT" == "$DEFAULT_ENDPOINT" ]]; then
        log INFO "Using production API endpoint: $API_ENDPOINT"
    else
        log INFO "Using custom API endpoint: $API_ENDPOINT"
    fi
    
    # Validate API key format (basic check) - allow shorter keys for testing
    if [[ ! "$API_KEY" =~ ^[a-zA-Z0-9_-]{8,64}$ ]]; then
        error "Invalid API key format"
    fi
    
    # Create target directory if it doesn't exist
    if [[ ! -d "$TARGET_DIR" ]]; then
        log INFO "Creating target directory: $TARGET_DIR"
        mkdir -p "$TARGET_DIR" || error "Failed to create target directory"
    fi
    
    # Check if target directory is writable
    if [[ ! -w "$TARGET_DIR" ]]; then
        error "Target directory is not writable: $TARGET_DIR"
    fi
    
    # Create log directory if log file is specified
    if [[ -n "$LOG_FILE" ]]; then
        local log_dir=$(dirname "$LOG_FILE")
        if [[ ! -d "$log_dir" ]]; then
            mkdir -p "$log_dir" || error "Failed to create log directory"
        fi
    fi
}

# Lock file management
acquire_lock() {
    if [[ "$USE_LOCK" == "false" ]]; then
        return 0
    fi
    
    local lock_pid
    
    if [[ -f "$LOCK_FILE" ]]; then
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
        
        # Check if the process is still running
        if kill -0 "$lock_pid" 2>/dev/null; then
            error "Another instance is already running (PID: $lock_pid)"
        else
            log WARN "Removing stale lock file (PID: $lock_pid)"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    echo $$ > "$LOCK_FILE" || error "Failed to create lock file"
    log INFO "Acquired lock (PID: $$)"
}

release_lock() {
    if [[ "$USE_LOCK" == "false" ]]; then
        return 0
    fi
    
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
        if [[ "$lock_pid" == "$$" ]]; then
            rm -f "$LOCK_FILE"
            log INFO "Released lock"
        fi
    fi
}

# Cleanup function
cleanup() {
    local exit_code=$?
    
    # Release lock
    release_lock
    
    # Clean up temporary directory
    if [[ -d "$TEMP_DIR" ]]; then
        log INFO "Cleaning up temporary files"
        rm -rf "$TEMP_DIR"
    fi
    
    if [[ $exit_code -eq 0 ]]; then
        log SUCCESS "GeoIP update completed successfully"
    else
        log ERROR "GeoIP update failed with exit code: $exit_code"
    fi
    
    exit $exit_code
}

# Setup signal handlers
trap cleanup EXIT
trap 'error "Interrupted by signal"' INT TERM

# Make HTTP request with retry logic
http_request() {
    local method="$1"
    local url="$2"
    local output_file="${3:-}"
    local retry_count=0
    local retry_delay=1
    
    while [[ $retry_count -lt $MAX_RETRIES ]]; do
        log INFO "HTTP $method request to: $url (attempt $((retry_count + 1))/$MAX_RETRIES)"
        
        local curl_opts=(
            --silent
            --show-error
            --location
            --max-time "$TIMEOUT"
            --connect-timeout 30
            --retry 0  # We handle retries ourselves
            --fail
        )
        
        # Note: We avoid using curl's --verbose flag when capturing response
        # as it interferes with JSON parsing by mixing debug output with response
        if [[ "$VERBOSE_MODE" == "true" ]] && [[ -n "$output_file" ]]; then
            curl_opts+=(--verbose)
        elif [[ "$VERBOSE_MODE" == "true" ]]; then
            # For verbose mode without output file, log curl command details
            log INFO "Curl command details: ${curl_opts[*]} $url"
        fi
        
        if [[ "$method" == "POST" ]]; then
            # Format databases parameter correctly for API
            if [[ "$DATABASES" == "all" ]]; then
                curl_opts+=(
                    --request POST
                    --header "Content-Type: application/json"
                    --header "X-API-Key: $API_KEY"
                    --data '{"databases": "all"}'
                )
            else
                # Convert comma-separated list to JSON array - use portable approach
                db_array=""
                saved_ifs="$IFS"
                IFS=','
                for db in $DATABASES; do
                    # Trim whitespace
                    db=$(echo "$db" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    if [[ -n "$db" ]]; then
                        if [[ -n "$db_array" ]]; then
                            db_array+=", "
                        fi
                        db_array+="\"$db\""
                    fi
                done
                IFS="$saved_ifs"
                curl_opts+=(
                    --request POST
                    --header "Content-Type: application/json"
                    --header "X-API-Key: $API_KEY"
                    --data "{\"databases\": [$db_array]}"
                )
            fi
        fi
        
        if [[ -n "$output_file" ]]; then
            curl_opts+=(--output "$output_file")
        else
            curl_opts+=(--output -)
        fi
        
        local http_code
        local response
        
        if [[ -n "$output_file" ]]; then
            http_code=$(curl --write-out "%{http_code}" "${curl_opts[@]}" "$url" 2>&1)
            curl_exit=$?
        else
            response=$(curl --write-out "\n%{http_code}" "${curl_opts[@]}" "$url" 2>&1)
            curl_exit=$?
            http_code=$(echo "$response" | tail -n1)
            response=$(echo "$response" | sed '$d')
            
            # Debug output for verbose mode
            if [[ "$VERBOSE_MODE" == "true" ]]; then
                log INFO "Raw response length: ${#response}"
                log INFO "HTTP code: $http_code"
                log INFO "First 200 chars of response: ${response:0:200}"
            fi
        fi
        
        if [[ $curl_exit -eq 0 ]] && [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            log INFO "HTTP request successful (HTTP $http_code)"
            if [[ -z "$output_file" ]]; then
                echo "$response"
            fi
            return 0
        elif [[ "$http_code" == "429" ]]; then
            log WARN "Rate limit exceeded (HTTP 429)"
            retry_delay=60  # Wait longer for rate limit
        elif [[ "$http_code" == "401" ]]; then
            error "Authentication failed (HTTP 401) - check your API key"
        elif [[ "$http_code" == "403" ]]; then
            error "Access forbidden (HTTP 403) - check your permissions"
        elif [[ "$http_code" =~ ^5[0-9][0-9]$ ]]; then
            log WARN "Server error (HTTP $http_code)"
        else
            log WARN "Request failed (HTTP $http_code, curl exit: $curl_exit)"
        fi
        
        retry_count=$((retry_count + 1))
        if [[ $retry_count -lt $MAX_RETRIES ]]; then
            log INFO "Retrying in $retry_delay seconds..."
            sleep $retry_delay
            retry_delay=$((retry_delay * 2))  # Exponential backoff
            if [[ $retry_delay -gt 60 ]]; then
                retry_delay=60  # Cap at 60 seconds
            fi
        fi
    done
    
    error "Failed after $MAX_RETRIES attempts"
}

# Download a single database file
download_database() {
    local db_name="$1"
    local url="$2"
    local target_file="$TARGET_DIR/$db_name"
    local temp_file="$TEMP_DIR/$db_name"
    
    log INFO "Downloading: $db_name"
    
    # Download to temporary file
    if http_request GET "$url" "$temp_file"; then
        # Verify file was downloaded and has content
        if [[ -f "$temp_file" ]] && [[ -s "$temp_file" ]]; then
            # Get file size in a cross-platform way
            local file_size
            if command -v stat >/dev/null 2>&1; then
                # Try GNU stat first (Linux), then BSD stat (macOS)
                file_size=$(stat -c%s "$temp_file" 2>/dev/null || stat -f%z "$temp_file" 2>/dev/null || echo 0)
            else
                # Fallback to ls if stat is not available
                file_size=$(ls -l "$temp_file" 2>/dev/null | awk '{print $5}' || echo 0)
            fi
            log INFO "Downloaded $db_name ($file_size bytes)"
            
            # Basic file validation
            if [[ "$db_name" == *.mmdb ]]; then
                # Check if it's a valid MMDB file by looking for MaxMind metadata marker at the end
                # MMDB files have metadata at the end with marker \xab\xcd\xef followed by MaxMind.com
                if ! tail -c 100000 "$temp_file" 2>/dev/null | grep -a -q $'\xab\xcd\xef'MaxMind.com 2>/dev/null; then
                    log WARN "MMDB file $db_name may be invalid: missing MaxMind metadata marker"
                fi
            elif [[ "$db_name" == *.BIN ]]; then
                # Basic check for BIN files
                if [[ $file_size -lt 1000 ]]; then
                    log ERROR "BIN file $db_name is too small to be valid"
                    return 1
                fi
            fi
            
            # Move to target location (atomic operation)
            mv "$temp_file" "$target_file" || {
                log ERROR "Failed to move $db_name to target directory"
                return 1
            }
            
            log SUCCESS "Successfully updated: $db_name"
            return 0
        else
            log ERROR "Downloaded file is empty or missing: $db_name"
            return 1
        fi
    else
        log ERROR "Failed to download: $db_name"
        return 1
    fi
}

# Main update function
update_databases() {
    log INFO "Starting GeoIP database update"
    log INFO "Target directory: $TARGET_DIR"
    
    # Create temporary directory
    TEMP_DIR=$(mktemp -d "$TEMP_DIR_PREFIX.XXXXXX") || error "Failed to create temporary directory"
    log INFO "Temporary directory: $TEMP_DIR"
    
    # Get pre-signed URLs from API
    log INFO "Authenticating with API endpoint"
    local response
    response=$(http_request POST "$API_ENDPOINT") || error "Failed to authenticate with API"
    
    # Parse JSON response to get URLs
    # Check if jq is available for JSON parsing
    if ! command -v jq >/dev/null 2>&1; then
        error "jq is required for JSON parsing but not found. Please install jq:
  - Ubuntu/Debian: sudo apt-get install jq
  - CentOS/RHEL: sudo yum install jq
  - macOS: brew install jq
  - Or download from: https://stedolan.github.io/jq/"
    fi
    
    # Parse URLs using jq
    local urls
    urls=$(echo "$response" | jq -r 'to_entries | .[] | "\(.key)|\(.value)"' 2>/dev/null) || {
        error "Failed to parse API response. The response may be malformed or empty."
    }
    
    if [[ -z "$urls" ]]; then
        error "No download URLs received from API"
    fi
        
        # Count total databases
        local total_count=$(echo "$urls" | wc -l | tr -d ' ')
        log INFO "Received URLs for $total_count databases"
        
        # Download databases in parallel (up to 4 at a time)
        local download_count=0
        local failed_count=0
        local pids=()
        local max_parallel=4
        
        while IFS='|' read -r db_name url; do
            # Wait if we have too many parallel downloads
            while [[ ${#pids[@]} -ge $max_parallel ]]; do
                for i in "${!pids[@]}"; do
                    if ! kill -0 "${pids[$i]}" 2>/dev/null; then
                        wait "${pids[$i]}"
                        local exit_code=$?
                        if [[ $exit_code -ne 0 ]]; then
                            failed_count=$((failed_count + 1))
                        else
                            download_count=$((download_count + 1))
                        fi
                        unset "pids[$i]"
                    fi
                done
                pids=("${pids[@]}")  # Reindex array
                sleep 0.1
            done
            
            # Start download in background
            download_database "$db_name" "$url" &
            pids+=($!)
            
        done <<< "$urls"
        
        # Wait for remaining downloads
        for pid in "${pids[@]}"; do
            wait "$pid"
            local exit_code=$?
            if [[ $exit_code -ne 0 ]]; then
                failed_count=$((failed_count + 1))
            else
                download_count=$((download_count + 1))
            fi
        done
        
        log INFO "Download summary: $download_count successful, $failed_count failed"
        
        if [[ $failed_count -gt 0 ]]; then
            error "Failed to download $failed_count databases"
        fi
}

# Database discovery functions
get_databases_endpoint() {
    # Convert /auth endpoint to /databases endpoint
    local databases_endpoint="${API_ENDPOINT%/auth}/databases"
    echo "$databases_endpoint"
}

fetch_databases_info() {
    local databases_endpoint=$(get_databases_endpoint)
    local response
    
    log INFO "Fetching database information from: $databases_endpoint"
    
    response=$(curl -s --max-time 10 "$databases_endpoint" 2>/dev/null)
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]] && [[ -n "$response" ]] && echo "$response" | grep -q '"total"'; then
        echo "$response"
        return 0
    else
        log WARN "Database discovery not available, using fallback mode"
        return 1
    fi
}

list_databases() {
    if [[ -z "$API_ENDPOINT" ]]; then
        # Set default endpoint if not provided
        API_ENDPOINT="$DEFAULT_ENDPOINT"
    fi
    
    # Normalize endpoint
    API_ENDPOINT=$(echo "$API_ENDPOINT" | sed 's|/*$||' | sed 's/[[:space:]]*$//')
    
    local db_info
    if db_info=$(fetch_databases_info); then
        echo "Available GeoIP Databases:"
        echo "========================="
        echo
        
        # Parse and display database information
        echo "$db_info" | jq -r '
            "Total databases: " + (.total | tostring) + "\n",
            "MaxMind databases (" + (.providers.maxmind.count | tostring) + "):",
            (.providers.maxmind.databases[] | "  • " + .name + " (aliases: " + (.aliases | join(", ")) + ")"),
            "\nIP2Location databases (" + (.providers.ip2location.count | tostring) + "):",
            (.providers.ip2location.databases[] | "  • " + .name + " (aliases: " + (.aliases | join(", ")) + ")"),
            "\nBulk Selection Options:",
            "  • all - All databases",
            "  • maxmind/all - All MaxMind databases", 
            "  • ip2location/all - All IP2Location databases",
            "\nUsage Notes:",
            "  • Database names are case-insensitive",
            "  • File extensions are optional in most cases",
            "  • Use short aliases for easier selection"
        ' 2>/dev/null || {
            # Fallback if jq is not available
            echo "Database discovery available but jq not installed."
            echo "Install jq for formatted output or use the API directly:"
            echo "  curl $(get_databases_endpoint)"
        }
    else
        echo "Database discovery not available."
        echo "Using legacy database list:"
        echo "  • GeoIP2-City.mmdb"
        echo "  • GeoIP2-Country.mmdb"  
        echo "  • GeoIP2-ISP.mmdb"
        echo "  • GeoIP2-Connection-Type.mmdb"
        echo "  • IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN"
        echo "  • IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN"
        echo "  • IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN"
    fi
}

show_examples() {
    if [[ -z "$API_ENDPOINT" ]]; then
        API_ENDPOINT="$DEFAULT_ENDPOINT"
    fi
    
    API_ENDPOINT=$(echo "$API_ENDPOINT" | sed 's|/*$||' | sed 's/[[:space:]]*$//')
    
    local db_info
    if db_info=$(fetch_databases_info); then
        echo "Database Selection Examples:"
        echo "===========================" 
        echo
        
        echo "$db_info" | jq -r '
            "Single Database Selection:",
            (.examples.single_database[] | "  $0 --api-key YOUR_KEY --databases \"" + . + "\""),
            "\nMultiple Database Selection:",
            (.examples.multiple_databases[] | "  $0 --api-key YOUR_KEY --databases \"" + (. | join(",")) + "\""),
            "\nBulk Selection:",
            (.examples.bulk_selection[] | "  $0 --api-key YOUR_KEY --databases \"" + . + "\"")
        ' 2>/dev/null || {
            echo "Database discovery available but jq not installed for formatted examples."
        }
    else
        echo "Database Selection Examples (Legacy Mode):"
        echo "=========================================="
    fi
    
    echo
    echo "Common Examples:"
    echo "  # Download all databases"
    echo "  $SCRIPT_NAME --api-key YOUR_KEY"
    echo
    echo "  # Download specific databases using aliases"
    echo "  $SCRIPT_NAME --api-key YOUR_KEY --databases \"city,country\""
    echo
    echo "  # Download all MaxMind databases"
    echo "  $SCRIPT_NAME --api-key YOUR_KEY --databases \"maxmind/all\""
    echo
    echo "  # Case insensitive selection"
    echo "  $SCRIPT_NAME --api-key YOUR_KEY --databases \"CITY,ISP\""
    echo
    echo "  # Local testing with Docker API"
    echo "  $SCRIPT_NAME --api-key test-key-1 --endpoint http://localhost:8080/auth --databases \"city\""
}

validate_database_names() {
    if [[ -z "$API_KEY" ]]; then
        error "API key required for validation. Use -k option or set GEOIP_API_KEY environment variable"
    fi
    
    if [[ -z "$API_ENDPOINT" ]]; then
        API_ENDPOINT="$DEFAULT_ENDPOINT"
    fi
    
    # Normalize endpoint  
    API_ENDPOINT=$(echo "$API_ENDPOINT" | sed 's|/*$||' | sed 's/[[:space:]]*$//')
    
    if [[ "$API_ENDPOINT" =~ geoipdb\.net$ ]]; then
        API_ENDPOINT="${API_ENDPOINT}/auth"
    fi
    
    if [[ "$DATABASES" == "all" ]]; then
        echo "✓ Database selection 'all' is valid"
        return 0
    fi
    
    # Convert comma-separated list to JSON array
    local db_array=""
    IFS=',' read -ra db_names <<< "$DATABASES"
    for db in "${db_names[@]}"; do
        db=$(echo "$db" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -z "$db_array" ]]; then
            db_array="\"$db\""
        else
            db_array="$db_array,\"$db\""
        fi
    done
    
    local json_payload="{\"databases\":[${db_array}]}"
    local response
    
    log INFO "Validating database names: $DATABASES"
    
    response=$(curl -s --max-time 10 \
        -X POST \
        -H "X-API-Key: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$json_payload" \
        "$API_ENDPOINT" 2>/dev/null)
    
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]] && [[ -n "$response" ]]; then
        if echo "$response" | grep -q '"detail"'; then
            # Error response
            local error_msg=$(echo "$response" | sed -n 's/.*"detail":"\([^"]*\)".*/\1/p')
            echo "✗ Validation failed: $error_msg"
            return 1
        else
            # Success response with download URLs
            local db_count=$(echo "$response" | grep -o '\.mmdb\|\.BIN' | wc -l)
            echo "✓ All database names are valid"
            echo "✓ Resolved to $db_count database(s)"
            
            # Show resolved databases
            echo "$response" | sed 's/,/\n/g' | grep -o '"[^"]*\.mmdb\|[^"]*\.BIN' | sed 's/"//g' | sort | while read -r db; do
                echo "  → $db"
            done
        fi
    else
        echo "✗ Validation failed: Unable to connect to API"
        return 1
    fi
}

# Main execution
main() {
    parse_args "$@"
    
    # Set quiet mode for logging
    if [[ "$QUIET_MODE" == "true" ]]; then
        VERBOSE_MODE=false
    fi
    
    log INFO "GeoIP Update Script starting"
    
    validate_config
    acquire_lock
    update_databases
}

# Run main function
main "$@"