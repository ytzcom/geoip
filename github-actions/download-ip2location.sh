#!/bin/bash
set -euo pipefail

# Enable debug mode if requested
if [ "${DEBUG_MODE:-false}" = "true" ]; then
    set -x
    echo "Debug mode enabled"
fi

# Download IP2Location databases with retry logic
# Usage: ./download-ip2location.sh <output_dir> <token>

OUTPUT_DIR="${1:-temp/compressed/ip2location}"
TOKEN="${2}"

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Download IP2Location with retry logic (different auth method)
download_ip2location_with_retry() {
    local url=$1
    local output=$2
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        echo "Attempt $attempt of $max_attempts for $(basename $output)"
        if curl -L --silent --show-error "$url" -o "$output" --fail; then
            echo "✅ Successfully downloaded $(basename $output)"
            # Check file size to ensure it's not an error page
            if [ $(wc -c < "$output") -lt 1000 ]; then
                echo "❌ Downloaded file is too small, likely an error"
                return 1
            fi
            return 0
        else
            echo "❌ Failed attempt $attempt"
            attempt=$((attempt + 1))
            [ $attempt -le $max_attempts ] && sleep 5
        fi
    done
    
    echo "❌ Failed to download after $max_attempts attempts: $(basename $output)"
    return 1
}

# Function to handle download failures
handle_download_failure() {
    local db_name=$1
    echo "Critical: Failed to download $db_name database" >> download_errors.txt
}

# Track if we're running in parallel mode
PARALLEL_MODE="${PARALLEL_MODE:-false}"

# Database configurations
declare -A DATABASES=(
    ["DB23BIN"]="https://www.ip2location.com/download?token=${TOKEN}&file=DB23BIN"
    ["DB23BINIPV6"]="https://www.ip2location.com/download?token=${TOKEN}&file=DB23BINIPV6"
    ["PX2BIN"]="https://www.ip2location.com/download?token=${TOKEN}&file=PX2BIN"
)

echo "Starting IP2Location downloads..."

if [ "$PARALLEL_MODE" = "true" ]; then
    # Start all downloads in parallel
    for db_name in "${!DATABASES[@]}"; do
        url="${DATABASES[$db_name]}"
        output_file="${OUTPUT_DIR}/${db_name}.zip"
        (download_ip2location_with_retry "$url" "$output_file" || handle_download_failure "$db_name") &
    done
    
    # Wait for all background jobs to complete
    echo "Waiting for all IP2Location downloads to complete..."
    wait
else
    # Sequential downloads
    for db_name in "${!DATABASES[@]}"; do
        url="${DATABASES[$db_name]}"
        output_file="${OUTPUT_DIR}/${db_name}.zip"
        if ! download_ip2location_with_retry "$url" "$output_file"; then
            handle_download_failure "$db_name"
        fi
    done
fi

# Check if any downloads failed
if [ -f download_errors.txt ]; then
    echo "❌ Some IP2Location downloads failed:"
    cat download_errors.txt
    rm -f download_errors.txt
    exit 1
fi

echo "✅ All IP2Location databases downloaded successfully"