#!/bin/bash
set -euo pipefail

# Extract GeoIP databases from compressed archives
# Usage: ./extract-databases.sh

# Extract MaxMind databases
extract_maxmind_databases() {
    local compressed_dir="temp/compressed/maxmind"
    local output_dir="temp/raw/maxmind"
    
    echo "Extracting MaxMind databases..."
    
    if [ ! -d "$compressed_dir" ]; then
        echo "Error: MaxMind compressed directory not found: $compressed_dir"
        return 1
    fi
    
    # Create output directory
    mkdir -p "$output_dir"
    
    # Extract each tar.gz file
    local extracted_count=0
    for file in "$compressed_dir"/*.tar.gz; do
        if [ -f "$file" ]; then
            echo "Extracting $(basename "$file")..."
            if tar -zxf "$file" --strip-components 1 --wildcards --no-anchored -C "$output_dir" "*.mmdb"; then
                ((extracted_count++))
            else
                echo "Warning: Failed to extract $(basename "$file")"
            fi
        fi
    done
    
    if [ $extracted_count -eq 0 ]; then
        echo "Error: No MaxMind databases were extracted"
        return 1
    fi
    
    echo "✅ Extracted $extracted_count MaxMind databases"
    return 0
}

# Extract IP2Location databases
extract_ip2location_databases() {
    local compressed_dir="temp/compressed/ip2location"
    local output_dir="temp/raw/ip2location"
    
    echo "Extracting IP2Location databases..."
    
    if [ ! -d "$compressed_dir" ]; then
        echo "Error: IP2Location compressed directory not found: $compressed_dir"
        return 1
    fi
    
    # Create output directory
    mkdir -p "$output_dir"
    
    local extracted_count=0
    
    # Extract DB23 BIN files
    if [ -f "$compressed_dir/DB23BIN.zip" ]; then
        echo "Extracting DB23BIN.zip..."
        if unzip -jo "$compressed_dir/DB23BIN.zip" -d "$output_dir" \
            "IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN"; then
            ((extracted_count++))
        fi
    fi
    
    if [ -f "$compressed_dir/DB23BINIPV6.zip" ]; then
        echo "Extracting DB23BINIPV6.zip..."
        if unzip -jo "$compressed_dir/DB23BINIPV6.zip" -d "$output_dir" \
            "IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN"; then
            ((extracted_count++))
        fi
    fi
    
    # Extract PX2 files
    if [ -f "$compressed_dir/PX2BIN.zip" ]; then
        echo "Extracting PX2BIN.zip..."
        if unzip -jo "$compressed_dir/PX2BIN.zip" -d "$output_dir" \
            "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN"; then
            ((extracted_count++))
        fi
    fi
    
    if [ $extracted_count -eq 0 ]; then
        echo "Error: No IP2Location databases were extracted"
        return 1
    fi
    
    echo "✅ Extracted $extracted_count IP2Location databases"
    return 0
}

# Main execution
main() {
    echo "=== Starting database extraction ==="
    
    local maxmind_success=false
    local ip2location_success=false
    
    # Extract MaxMind databases
    if extract_maxmind_databases; then
        maxmind_success=true
    fi
    
    # Extract IP2Location databases
    if extract_ip2location_databases; then
        ip2location_success=true
    fi
    
    # List extracted files
    echo ""
    echo "=== MaxMind extracted files ==="
    if [ -d "temp/raw/maxmind" ]; then
        ls -la temp/raw/maxmind/
    else
        echo "No MaxMind files extracted"
    fi
    
    echo ""
    echo "=== IP2Location extracted files ==="
    if [ -d "temp/raw/ip2location" ]; then
        ls -la temp/raw/ip2location/
    else
        echo "No IP2Location files extracted"
    fi
    
    # Check overall success
    if [ "$maxmind_success" = false ] || [ "$ip2location_success" = false ]; then
        echo ""
        echo "❌ Some database extractions failed"
        exit 1
    fi
    
    echo ""
    echo "✅ All databases extracted successfully"
}

# Run main function
main