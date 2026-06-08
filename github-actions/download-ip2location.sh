#!/bin/bash
set -euo pipefail

# Enable debug mode if requested
if [ "${DEBUG_MODE:-false}" = "true" ]; then
    set -x
    echo "Debug mode enabled"
fi

# Download IP2Location databases with retry logic.
# Usage: ./download-ip2location.sh <output_dir> <token>
#
# Resilient behaviour: a single database that cannot be downloaded (e.g. an
# expired entitlement returning a "NO PERMISSION" error page, or a daily
# download-limit message) does NOT fail the whole run. The bad file is removed
# (so it can't clobber the last-good copy on S3 or break extraction) and the
# database is reported as degraded. The script only exits non-zero when EVERY
# database fails (a genuine token/outage problem).

OUTPUT_DIR="${1:-temp/compressed/ip2location}"
TOKEN="${2}"

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Download IP2Location with retry logic.
download_ip2location_with_retry() {
    local url=$1
    local output=$2
    local db_name=$3
    local max_attempts=3
    local attempt=1
    local size

    while [ $attempt -le $max_attempts ]; do
        echo "Attempt $attempt of $max_attempts for $(basename "$output")"
        if curl -L --silent --show-error "$url" -o "$output" --fail; then
            # The download endpoint returns its error responses as HTTP 200 with
            # a short plain-text body, so --fail can't catch them. Verify the
            # file is a real archive by size, and surface the error body so the
            # actual reason (NO PERMISSION / daily limit) is visible in the logs.
            size=$(wc -c < "$output")
            if [ "$size" -ge 1000 ]; then
                echo "✅ Successfully downloaded $(basename "$output") (${size} bytes)"
                return 0
            fi
            echo "❌ ${db_name}: file too small (${size} bytes) — likely an IP2Location error response"
            echo "   ↳ response body:"
            head -c 500 "$output" 2>/dev/null | sed 's/^/      /' || true
            echo ""
        else
            echo "❌ ${db_name}: download attempt $attempt failed (curl error)"
        fi
        attempt=$((attempt + 1))
        [ $attempt -le $max_attempts ] && sleep 5
    done

    echo "❌ Failed to download ${db_name} after ${max_attempts} attempts"
    # Never leave a corrupt/partial file behind: it would be uploaded to S3
    # (overwriting the last-good copy) and break extraction/validation.
    rm -f "$output"
    return 1
}

# Record a degraded (non-fatal) download failure.
handle_download_failure() {
    local db_name=$1
    echo "$db_name" >> download_failed.txt
    echo "::warning::IP2Location database '${db_name}' could not be downloaded; keeping the last published copy on S3"
}

# Track if we're running in parallel mode
PARALLEL_MODE="${PARALLEL_MODE:-false}"

# Database product codes. The download URL is derived from each code, so a
# plain indexed array is used (works on bash 3.2+, unlike `declare -A`, so the
# script is runnable locally on macOS as documented in CLAUDE.md).
DATABASES=("DB23BIN" "DB23BINIPV6" "PX2BIN")
TOTAL=${#DATABASES[@]}

ip2location_url() {
    echo "https://www.ip2location.com/download?token=${TOKEN}&file=${1}"
}

# Start clean (in case of re-runs in the same workspace)
rm -f download_failed.txt

echo "Starting IP2Location downloads..."

if [ "$PARALLEL_MODE" = "true" ]; then
    # Start all downloads in parallel
    for db_name in "${DATABASES[@]}"; do
        url="$(ip2location_url "$db_name")"
        output_file="${OUTPUT_DIR}/${db_name}.zip"
        (download_ip2location_with_retry "$url" "$output_file" "$db_name" || handle_download_failure "$db_name") &
    done

    # Wait for all background jobs to complete
    echo "Waiting for all IP2Location downloads to complete..."
    wait
else
    # Sequential downloads
    for db_name in "${DATABASES[@]}"; do
        url="$(ip2location_url "$db_name")"
        output_file="${OUTPUT_DIR}/${db_name}.zip"
        if ! download_ip2location_with_retry "$url" "$output_file" "$db_name"; then
            handle_download_failure "$db_name"
        fi
    done
fi

# Tally results
FAILED_COUNT=0
FAILED_LIST=""
if [ -f download_failed.txt ]; then
    FAILED_COUNT=$(wc -l < download_failed.txt | tr -d ' ')
    FAILED_LIST=$(paste -sd, download_failed.txt)
    rm -f download_failed.txt
fi
SUCCESS_COUNT=$((TOTAL - FAILED_COUNT))

echo ""
echo "IP2Location downloads: ${SUCCESS_COUNT}/${TOTAL} succeeded"
[ -n "$FAILED_LIST" ] && echo "Degraded (unavailable): ${FAILED_LIST}"

# Expose results to the workflow when running in GitHub Actions
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "failed=${FAILED_LIST}" >> "$GITHUB_OUTPUT"
    echo "succeeded=${SUCCESS_COUNT}" >> "$GITHUB_OUTPUT"
fi

# Only a total failure is fatal — otherwise publish what we have.
if [ "$SUCCESS_COUNT" -eq 0 ]; then
    echo "❌ All IP2Location downloads failed — check IP2LOCATION_TOKEN and account status"
    exit 1
fi

if [ "$FAILED_COUNT" -gt 0 ]; then
    echo "⚠️  IP2Location completed with degraded results: ${FAILED_LIST} unavailable (kept last-good S3 copy)"
    exit 0
fi

echo "✅ All IP2Location databases downloaded successfully"
