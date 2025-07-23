#!/bin/bash
set -euo pipefail

# Enable debug mode if requested
if [ "${DEBUG_MODE:-false}" = "true" ]; then
    set -x
    echo "Debug mode enabled"
fi

# Download MaxMind databases with retry logic
# Usage: ./download-maxmind.sh <output_dir> <account_id> <license_key>

OUTPUT_DIR="${1:-temp/compressed/maxmind}"
ACCOUNT_ID="${2}"
LICENSE_KEY="${3}"

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Download with retry logic
download_with_retry() {
    local url=$1
    local output=$2
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        echo "Attempt $attempt of $max_attempts for $(basename $output)"
        if curl -J -L --silent --show-error \
             -u "${ACCOUNT_ID}:${LICENSE_KEY}" \
             "$url" -o "$output" --fail; then
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

# Database URLs
declare -A DATABASES=(
    ["GeoIP2-City"]="https://download.maxmind.com/geoip/databases/GeoIP2-City/download?suffix=tar.gz"
    ["GeoIP2-Country"]="https://download.maxmind.com/geoip/databases/GeoIP2-Country/download?suffix=tar.gz"
    ["GeoIP2-ISP"]="https://download.maxmind.com/geoip/databases/GeoIP2-ISP/download?suffix=tar.gz"
    ["GeoIP2-Connection-Type"]="https://download.maxmind.com/geoip/databases/GeoIP2-Connection-Type/download?suffix=tar.gz"
)

echo "Starting MaxMind downloads..."

if [ "$PARALLEL_MODE" = "true" ]; then
    # Start all downloads in parallel
    for db_name in "${!DATABASES[@]}"; do
        url="${DATABASES[$db_name]}"
        output_file="${OUTPUT_DIR}/${db_name}.tar.gz"
        (download_with_retry "$url" "$output_file" || handle_download_failure "$db_name") &
    done
    
    # Wait for all background jobs to complete
    echo "Waiting for all MaxMind downloads to complete..."
    wait
else
    # Sequential downloads
    for db_name in "${!DATABASES[@]}"; do
        url="${DATABASES[$db_name]}"
        output_file="${OUTPUT_DIR}/${db_name}.tar.gz"
        if ! download_with_retry "$url" "$output_file"; then
            handle_download_failure "$db_name"
        fi
    done
fi

# Check if any downloads failed
if [ -f download_errors.txt ]; then
    echo "❌ Some MaxMind downloads failed:"
    cat download_errors.txt
    rm -f download_errors.txt
    exit 1
fi

echo "✅ All MaxMind databases downloaded successfully"