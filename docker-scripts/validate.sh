#!/bin/sh
# Basic GeoIP database validation
# Works without Python dependencies
# 
# Usage:
#   ./validate.sh [directory]
#
# Validates that GeoIP databases exist and have reasonable sizes

set -e

# Get target directory from argument or environment
GEOIP_TARGET_DIR="${1:-${GEOIP_TARGET_DIR:-/app/resources/geoip}}"

echo "[Validate] Checking GeoIP databases in: $GEOIP_TARGET_DIR"

# Check if directory exists
if [ ! -d "$GEOIP_TARGET_DIR" ]; then
    echo "[Validate] ❌ Directory does not exist: $GEOIP_TARGET_DIR"
    exit 1
fi

# Expected databases with minimum sizes (in bytes)
# These are conservative minimums - actual files are much larger
validate_database() {
    local db_name="$1"
    local min_size="$2"
    local required="${3:-false}"
    
    local db_path="$GEOIP_TARGET_DIR/$db_name"
    
    if [ -f "$db_path" ]; then
        # Get file size in a cross-platform way
        local size=0
        if command -v stat >/dev/null 2>&1; then
            # Try GNU stat first (Linux), then BSD stat (macOS)
            size=$(stat -c%s "$db_path" 2>/dev/null || stat -f%z "$db_path" 2>/dev/null || echo 0)
        else
            # Fallback to wc -c
            size=$(wc -c < "$db_path" 2>/dev/null || echo 0)
        fi
        
        if [ "$size" -ge "$min_size" ]; then
            # Convert to MB for display
            local size_mb=$((size / 1024 / 1024))
            echo "  ✅ $db_name (${size_mb}MB)"
            return 0
        else
            echo "  ⚠️  $db_name seems too small (${size} bytes, expected >= ${min_size})"
            return 1
        fi
    else
        if [ "$required" = "true" ]; then
            echo "  ❌ $db_name missing (required)"
            return 1
        else
            echo "  ℹ️  $db_name missing (optional)"
            return 0
        fi
    fi
}

# Validate databases
validation_failed=false
databases_found=0
total_size=0

echo "[Validate] Checking MaxMind databases..."

# MaxMind databases (required)
if validate_database "GeoIP2-City.mmdb" 10485760 true; then  # 10MB minimum
    databases_found=$((databases_found + 1))
else
    validation_failed=true
fi

if validate_database "GeoIP2-Country.mmdb" 1048576 true; then  # 1MB minimum
    databases_found=$((databases_found + 1))
else
    validation_failed=true
fi

# Optional MaxMind databases
validate_database "GeoIP2-ISP.mmdb" 1048576 false || true
validate_database "GeoIP2-Connection-Type.mmdb" 524288 false || true  # 512KB minimum

echo ""
echo "[Validate] Checking IP2Location databases..."

# IP2Location databases (optional but check if present)
validate_database "IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN" 10485760 false || true
validate_database "IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN" 10485760 false || true
validate_database "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN" 1048576 false || true

echo ""

# Check for any .mmdb files for additional validation
mmdb_count=0
for mmdb_file in "$GEOIP_TARGET_DIR"/*.mmdb; do
    if [ -f "$mmdb_file" ]; then
        mmdb_count=$((mmdb_count + 1))
        
        # Basic MMDB format check - look for MMDB magic bytes
        if command -v xxd >/dev/null 2>&1; then
            # Check for MMDB metadata marker in last 1KB of file
            if tail -c 1024 "$mmdb_file" | xxd -p | grep -q "abcdef4d657461646174"; then
                :  # Valid MMDB format detected
            else
                basename_file=$(basename "$mmdb_file")
                echo "  ⚠️  $basename_file may have invalid MMDB format"
            fi
        elif command -v od >/dev/null 2>&1; then
            # Alternative check using od
            if tail -c 100 "$mmdb_file" | od -An -tx1 | grep -q "4d 4d 44 42"; then
                :  # Found MMDB marker
            else
                basename_file=$(basename "$mmdb_file")
                echo "  ⚠️  $basename_file may have invalid format"
            fi
        fi
    fi
done

# Check for any .BIN files
bin_count=0
for bin_file in "$GEOIP_TARGET_DIR"/*.BIN; do
    if [ -f "$bin_file" ]; then
        bin_count=$((bin_count + 1))
    fi
done

# Calculate total size
if command -v du >/dev/null 2>&1; then
    total_size=$(du -sh "$GEOIP_TARGET_DIR" 2>/dev/null | cut -f1)
    echo "[Validate] Total size: $total_size"
fi

echo "[Validate] Summary:"
echo "  MMDB files found: $mmdb_count"
echo "  BIN files found: $bin_count"
echo "  Required databases present: $databases_found/2"

# Final result
if [ "$validation_failed" = "true" ]; then
    echo ""
    echo "[Validate] ❌ Validation FAILED - required databases missing or invalid!"
    exit 1
else
    if [ $databases_found -ge 2 ]; then
        echo ""
        echo "[Validate] ✅ Validation PASSED - all required databases present!"
        exit 0
    else
        echo ""
        echo "[Validate] ⚠️  Validation WARNING - some databases missing but not critical"
        exit 0
    fi
fi