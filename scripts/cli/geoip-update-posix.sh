#!/bin/sh
# POSIX-compliant GeoIP Database Update Script
# Compatible with Alpine Linux and other minimal shells (ash, dash, busybox)
#
# This script downloads GeoIP databases from an authenticated API endpoint.
# It maintains feature parity with the bash version while using only POSIX shell features.
#
# Usage:
#   ./geoip-update-posix.sh --api-key YOUR_KEY [OPTIONS]
#
# Options:
#   --api-key KEY        API key for authentication (or use GEOIP_API_KEY env var)
#   --endpoint URL       API endpoint URL (default: https://geoipdb.net/auth)
#   --directory DIR      Target directory for databases (default: current directory)
#   --databases LIST     Comma-separated list of databases or "all" (default: all)
#   --config FILE        Read configuration from YAML file
#   --max-retries N      Maximum retry attempts (default: 3)
#   --timeout SECONDS    Request timeout in seconds (default: 300)
#   --quiet              Suppress output
#   --verbose            Enable verbose output
#   --log-file FILE      Log output to file
#   --validate           Only validate existing databases
#   --help               Show this help message

set -eu

# Version
VERSION="2.0.0-posix"

# Default values
API_KEY="${GEOIP_API_KEY:-}"
API_ENDPOINT="${GEOIP_API_ENDPOINT:-https://geoipdb.net/auth}"
DEFAULT_ENDPOINT="https://geoipdb.net/auth"
TARGET_DIR="${GEOIP_TARGET_DIR:-.}"
DATABASES="${GEOIP_DATABASES:-all}"
CONFIG_FILE=""
MAX_RETRIES=3
TIMEOUT=300
QUIET_MODE=false
VERBOSE_MODE=false
LOG_FILE=""
VALIDATE_ONLY=false

# Parallel download settings
MAX_PARALLEL=4
TEMP_DIR=""

# Color codes (disabled if not interactive or quiet)
if [ -t 1 ] && [ "$QUIET_MODE" = "false" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    NC=''
fi

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Log to file if specified
    if [ -n "$LOG_FILE" ]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
    
    # Log to console unless quiet
    if [ "$QUIET_MODE" = "false" ]; then
        case "$level" in
            ERROR)
                printf "${RED}[ERROR]${NC} %s\n" "$message" >&2
                ;;
            SUCCESS)
                printf "${GREEN}[SUCCESS]${NC} %s\n" "$message"
                ;;
            WARNING)
                printf "${YELLOW}[WARNING]${NC} %s\n" "$message"
                ;;
            INFO)
                if [ "$VERBOSE_MODE" = "true" ]; then
                    printf "[INFO] %s\n" "$message"
                fi
                ;;
            *)
                printf "[%s] %s\n" "$level" "$message"
                ;;
        esac
    elif [ "$level" = "ERROR" ]; then
        # Always show errors to stderr even in quiet mode
        printf "%s\n" "$message" >&2
    fi
}

# Show usage
show_usage() {
    cat << EOF
GeoIP Database Update Script (POSIX-compliant) v$VERSION

Usage: $0 --api-key YOUR_KEY [OPTIONS]

Options:
    --api-key KEY        API key for authentication (or use GEOIP_API_KEY env var)
    --endpoint URL       API endpoint URL (default: $DEFAULT_ENDPOINT)
    --directory DIR      Target directory for databases (default: current directory)
    --databases LIST     Comma-separated list of databases or "all" (default: all)
    --config FILE        Read configuration from YAML file
    --max-retries N      Maximum retry attempts (default: 3)
    --timeout SECONDS    Request timeout in seconds (default: 300)
    --quiet              Suppress output
    --verbose            Enable verbose output
    --log-file FILE      Log output to file
    --validate           Only validate existing databases
    --help               Show this help message
    --version            Show version information

Environment Variables:
    GEOIP_API_KEY        API key for authentication
    GEOIP_API_ENDPOINT   API endpoint URL
    GEOIP_TARGET_DIR     Target directory for databases
    GEOIP_DATABASES      Databases to download

Examples:
    # Download all databases
    $0 --api-key your-key

    # Download specific databases to custom directory
    $0 --api-key your-key --directory /opt/geoip --databases "GeoIP2-City.mmdb,GeoIP2-Country.mmdb"

    # Use configuration file
    $0 --config config.yaml

    # Validate existing databases
    $0 --validate --directory /opt/geoip

EOF
}

# Parse command line arguments
parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --api-key)
                API_KEY="$2"
                shift 2
                ;;
            --endpoint)
                API_ENDPOINT="$2"
                shift 2
                ;;
            --directory|--target-dir)
                TARGET_DIR="$2"
                shift 2
                ;;
            --databases)
                DATABASES="$2"
                shift 2
                ;;
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --max-retries)
                MAX_RETRIES="$2"
                shift 2
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --quiet)
                QUIET_MODE=true
                shift
                ;;
            --verbose)
                VERBOSE_MODE=true
                shift
                ;;
            --log-file)
                LOG_FILE="$2"
                shift 2
                ;;
            --validate)
                VALIDATE_ONLY=true
                shift
                ;;
            --version)
                echo "GeoIP Update Script (POSIX) v$VERSION"
                exit 0
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                log ERROR "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Load configuration from YAML file
load_config() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        log ERROR "Configuration file not found: $config_file"
        return 1
    fi
    
    log INFO "Loading configuration from: $config_file"
    
    # Simple YAML parser for key-value pairs
    while IFS=': ' read -r key value; do
        # Skip comments and empty lines
        case "$key" in
            ""|\#*) continue ;;
        esac
        
        # Remove leading/trailing whitespace and quotes
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^["'\'']//;s/["'\'']$//')
        
        case "$key" in
            api_key)
                [ -z "$API_KEY" ] && API_KEY="$value"
                ;;
            api_endpoint|endpoint)
                [ "$API_ENDPOINT" = "$DEFAULT_ENDPOINT" ] && API_ENDPOINT="$value"
                ;;
            target_dir|directory)
                [ "$TARGET_DIR" = "." ] && TARGET_DIR="$value"
                ;;
            databases)
                [ "$DATABASES" = "all" ] && DATABASES="$value"
                ;;
            max_retries)
                MAX_RETRIES="$value"
                ;;
            timeout)
                TIMEOUT="$value"
                ;;
            quiet)
                [ "$value" = "true" ] && QUIET_MODE=true
                ;;
            verbose)
                [ "$value" = "true" ] && VERBOSE_MODE=true
                ;;
            log_file)
                [ -z "$LOG_FILE" ] && LOG_FILE="$value"
                ;;
        esac
    done < "$config_file"
}

# Validate configuration
validate_config() {
    if [ -z "$API_KEY" ]; then
        log ERROR "API key is required. Use --api-key or set GEOIP_API_KEY environment variable."
        return 1
    fi
    
    if [ -z "$API_ENDPOINT" ]; then
        log ERROR "API endpoint is required."
        return 1
    fi
    
    # Check if endpoint is localhost (for testing)
    case "$API_ENDPOINT" in
        http://localhost*|http://127.0.0.1*)
            log WARNING "Using local API endpoint (testing mode): $API_ENDPOINT"
            ;;
        "$DEFAULT_ENDPOINT")
            log INFO "Using production API endpoint"
            ;;
        *)
            log INFO "Using custom API endpoint: $API_ENDPOINT"
            ;;
    esac
    
    return 0
}

# Create target directory if it doesn't exist
create_target_dir() {
    if [ ! -d "$TARGET_DIR" ]; then
        log INFO "Creating target directory: $TARGET_DIR"
        if ! mkdir -p "$TARGET_DIR"; then
            log ERROR "Failed to create target directory: $TARGET_DIR"
            return 1
        fi
    fi
    
    # Check write permissions
    if [ ! -w "$TARGET_DIR" ]; then
        log ERROR "No write permission for target directory: $TARGET_DIR"
        return 1
    fi
    
    return 0
}

# Make HTTP request with retry logic
http_request() {
    local url="$1"
    local method="${2:-GET}"
    local output_file="${3:-}"
    local retry_count=0
    local curl_exit=0
    
    while [ $retry_count -lt $MAX_RETRIES ]; do
        log INFO "HTTP $method request to: $url (attempt $((retry_count + 1))/$MAX_RETRIES)"
        
        # Build curl command
        local curl_cmd="curl --silent --show-error --location"
        curl_cmd="$curl_cmd --max-time $TIMEOUT --connect-timeout 30"
        curl_cmd="$curl_cmd --retry 0 --fail"
        
        if [ "$VERBOSE_MODE" = "true" ] && [ -n "$output_file" ]; then
            curl_cmd="$curl_cmd --verbose"
        fi
        
        if [ "$method" = "POST" ]; then
            curl_cmd="$curl_cmd --request POST"
            curl_cmd="$curl_cmd --header 'Content-Type: application/json'"
            curl_cmd="$curl_cmd --header 'X-API-Key: $API_KEY'"
            
            # Format databases parameter
            if [ "$DATABASES" = "all" ]; then
                curl_cmd="$curl_cmd --data '{\"databases\": \"all\"}'"
            else
                # Convert comma-separated list to JSON array
                local db_array=""
                local saved_ifs="$IFS"
                IFS=','
                for db in $DATABASES; do
                    # Trim whitespace
                    db=$(echo "$db" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    if [ -n "$db" ]; then
                        if [ -n "$db_array" ]; then
                            db_array="$db_array, "
                        fi
                        db_array="$db_array\"$db\""
                    fi
                done
                IFS="$saved_ifs"
                curl_cmd="$curl_cmd --data '{\"databases\": [$db_array]}'"
            fi
        fi
        
        if [ -n "$output_file" ]; then
            curl_cmd="$curl_cmd --output '$output_file'"
        else
            curl_cmd="$curl_cmd --output -"
        fi
        
        # Execute curl command
        local http_code
        local response
        
        if [ -n "$output_file" ]; then
            http_code=$(eval "$curl_cmd --write-out '%{http_code}' '$url'" 2>&1)
            curl_exit=$?
        else
            response=$(eval "$curl_cmd --write-out '\n%{http_code}' '$url'" 2>&1)
            curl_exit=$?
            http_code=$(echo "$response" | tail -n1)
            response=$(echo "$response" | sed '$d')
        fi
        
        # Check for success
        if [ $curl_exit -eq 0 ] && [ "$http_code" = "200" ]; then
            log SUCCESS "Request successful (HTTP $http_code)"
            if [ -z "$output_file" ]; then
                echo "$response"
            fi
            return 0
        fi
        
        # Handle errors
        log ERROR "Request failed (curl exit: $curl_exit, HTTP: $http_code)"
        
        # Clean up failed download
        if [ -n "$output_file" ] && [ -f "$output_file" ]; then
            rm -f "$output_file"
        fi
        
        retry_count=$((retry_count + 1))
        
        if [ $retry_count -lt $MAX_RETRIES ]; then
            local wait_time=$((retry_count * 2))
            log INFO "Waiting ${wait_time} seconds before retry..."
            sleep $wait_time
        fi
    done
    
    log ERROR "Failed after $MAX_RETRIES attempts"
    return 1
}

# Get list of available databases from API
get_database_list() {
    log INFO "Fetching available databases from API..."
    
    local response
    response=$(http_request "$API_ENDPOINT/databases" "POST") || return 1
    
    # Parse JSON response to extract database URLs
    # This is a simple parser that works with the expected format
    echo "$response" | grep -o '"[^"]*":"[^"]*"' | while IFS='"' read -r _ name _ url _; do
        if [ -n "$name" ] && [ -n "$url" ]; then
            echo "${name}|${url}"
        fi
    done
}

# Download a single database
download_database() {
    local db_name="$1"
    local url="$2"
    local output_file="$TARGET_DIR/$db_name"
    
    log INFO "Downloading: $db_name"
    
    if http_request "$url" "GET" "$output_file"; then
        # Verify file was downloaded
        if [ -f "$output_file" ]; then
            local size=$(wc -c < "$output_file" 2>/dev/null || echo 0)
            
            # Check for error pages (usually small HTML files)
            if [ "$size" -lt 1000 ]; then
                log ERROR "Downloaded file too small ($size bytes), likely an error page: $db_name"
                rm -f "$output_file"
                return 1
            fi
            
            log SUCCESS "Downloaded: $db_name ($(( size / 1024 / 1024 ))MB)"
            return 0
        else
            log ERROR "Failed to save file: $db_name"
            return 1
        fi
    else
        log ERROR "Failed to download: $db_name"
        return 1
    fi
}

# Download databases with parallel support
download_databases() {
    log INFO "Starting database download process..."
    
    # Get list of databases to download
    local urls
    urls=$(get_database_list) || {
        log ERROR "Failed to get database list from API"
        return 1
    }
    
    if [ -z "$urls" ]; then
        log ERROR "No databases available from API"
        return 1
    fi
    
    # Filter databases if specific ones requested
    if [ "$DATABASES" != "all" ]; then
        local filtered_urls=""
        local saved_ifs="$IFS"
        IFS=','
        for requested_db in $DATABASES; do
            requested_db=$(echo "$requested_db" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # Check if this database is in the list
            local found=false
            echo "$urls" | while IFS='|' read -r db_name url; do
                if [ "$db_name" = "$requested_db" ]; then
                    if [ -n "$filtered_urls" ]; then
                        filtered_urls="$filtered_urls\n"
                    fi
                    filtered_urls="$filtered_urls${db_name}|${url}"
                    found=true
                    break
                fi
            done
            
            if [ "$found" = "false" ]; then
                log WARNING "Requested database not available: $requested_db"
            fi
        done
        IFS="$saved_ifs"
        
        urls="$filtered_urls"
        
        if [ -z "$urls" ]; then
            log ERROR "None of the requested databases are available"
            return 1
        fi
    fi
    
    # Create temp directory for tracking parallel downloads
    TEMP_DIR=$(mktemp -d) || {
        log ERROR "Failed to create temp directory"
        return 1
    }
    
    # Download databases in parallel
    local download_count=0
    local failed_count=0
    local pids=""
    local active_count=0
    
    echo "$urls" | while IFS='|' read -r db_name url; do
        # Wait if we have too many parallel downloads
        while [ $active_count -ge $MAX_PARALLEL ]; do
            # Check for completed downloads
            local new_pids=""
            active_count=0
            for pid in $pids; do
                if kill -0 "$pid" 2>/dev/null; then
                    new_pids="$new_pids $pid"
                    active_count=$((active_count + 1))
                else
                    wait "$pid"
                    local exit_code=$?
                    if [ $exit_code -ne 0 ]; then
                        failed_count=$((failed_count + 1))
                    else
                        download_count=$((download_count + 1))
                    fi
                fi
            done
            pids="$new_pids"
            
            if [ $active_count -ge $MAX_PARALLEL ]; then
                sleep 0.1
            fi
        done
        
        # Start download in background
        download_database "$db_name" "$url" &
        local new_pid=$!
        pids="$pids $new_pid"
        active_count=$((active_count + 1))
    done
    
    # Wait for remaining downloads
    for pid in $pids; do
        wait "$pid"
        local exit_code=$?
        if [ $exit_code -ne 0 ]; then
            failed_count=$((failed_count + 1))
        else
            download_count=$((download_count + 1))
        fi
    done
    
    # Clean up temp directory
    rm -rf "$TEMP_DIR"
    
    # Report results
    log INFO "Download complete: $download_count successful, $failed_count failed"
    
    if [ $failed_count -gt 0 ]; then
        log WARNING "Some databases failed to download"
        return 1
    fi
    
    return 0
}

# Validate database file
validate_database() {
    local db_file="$1"
    local db_name=$(basename "$db_file")
    
    if [ ! -f "$db_file" ]; then
        log ERROR "Database file not found: $db_name"
        return 1
    fi
    
    # Check file size
    local size=$(wc -c < "$db_file" 2>/dev/null || echo 0)
    if [ "$size" -lt 1000 ]; then
        log ERROR "Database file too small: $db_name (${size} bytes)"
        return 1
    fi
    
    # Check for MMDB format (basic check)
    case "$db_name" in
        *.mmdb|*.MMDB)
            # Check for MMDB magic bytes (simplified check)
            if command -v od >/dev/null 2>&1; then
                local magic=$(od -N 16 -t x1 "$db_file" 2>/dev/null | head -n1)
                case "$magic" in
                    *"ab cd ef"*)
                        log SUCCESS "Valid MMDB format: $db_name"
                        return 0
                        ;;
                esac
            fi
            ;;
        *.BIN|*.bin)
            # IP2Location BIN format (basic size check)
            if [ "$size" -gt 100000 ]; then
                log SUCCESS "Valid BIN format: $db_name ($(( size / 1024 / 1024 ))MB)"
                return 0
            fi
            ;;
    esac
    
    # If we can't validate format, just check size
    if [ "$size" -gt 100000 ]; then
        log INFO "Database file exists: $db_name ($(( size / 1024 / 1024 ))MB)"
        return 0
    else
        log ERROR "Invalid database file: $db_name"
        return 1
    fi
}

# Validate all databases in target directory
validate_databases() {
    log INFO "Validating databases in: $TARGET_DIR"
    
    local total=0
    local valid=0
    local invalid=0
    
    # Check for any database files
    local found_files=false
    for pattern in "*.mmdb" "*.MMDB" "*.BIN" "*.bin"; do
        for db_file in "$TARGET_DIR"/$pattern; do
            if [ -f "$db_file" ]; then
                found_files=true
                total=$((total + 1))
                
                if validate_database "$db_file"; then
                    valid=$((valid + 1))
                else
                    invalid=$((invalid + 1))
                fi
            fi
        done
    done
    
    if [ "$found_files" = "false" ]; then
        log ERROR "No database files found in: $TARGET_DIR"
        return 1
    fi
    
    log INFO "Validation complete: $valid valid, $invalid invalid out of $total total"
    
    if [ $invalid -gt 0 ]; then
        return 1
    fi
    
    return 0
}

# Main function
main() {
    # Parse arguments
    parse_arguments "$@"
    
    # Load config file if specified
    if [ -n "$CONFIG_FILE" ]; then
        load_config "$CONFIG_FILE" || exit 1
    fi
    
    # Initialize log file if specified
    if [ -n "$LOG_FILE" ]; then
        # Create log directory if needed
        log_dir=$(dirname "$LOG_FILE")
        if [ ! -d "$log_dir" ]; then
            mkdir -p "$log_dir" || {
                echo "Failed to create log directory: $log_dir" >&2
                exit 1
            }
        fi
        
        # Initialize log file
        echo "=== GeoIP Update Log - $(date) ===" >> "$LOG_FILE"
    fi
    
    log INFO "GeoIP Update Script (POSIX) v$VERSION"
    
    # Validate only mode
    if [ "$VALIDATE_ONLY" = "true" ]; then
        validate_databases
        exit $?
    fi
    
    # Validate configuration
    validate_config || exit 1
    
    # Create target directory
    create_target_dir || exit 1
    
    # Download databases
    if download_databases; then
        log SUCCESS "All databases downloaded successfully!"
        
        # Validate downloaded databases
        if validate_databases; then
            log SUCCESS "All databases validated successfully!"
            exit 0
        else
            log ERROR "Database validation failed"
            exit 1
        fi
    else
        log ERROR "Database download failed"
        exit 1
    fi
}

# Run main function
main "$@"