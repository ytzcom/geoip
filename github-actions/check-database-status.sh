#!/bin/bash
set -euo pipefail

# Check the status of GeoIP databases on S3
# Usage: ./check-database-status.sh [bucket-name]

BUCKET="${1:-ytz-geoip}"

echo "🔍 Checking GeoIP Database Status on S3 Bucket: $BUCKET"
echo "================================================"

# Function to get human-readable file size
get_file_size() {
    local size_bytes=$1
    
    if [ "$size_bytes" -eq 0 ]; then
        echo "N/A"
    elif [ "$size_bytes" -lt 1024 ]; then
        echo "${size_bytes}B"
    elif [ "$size_bytes" -lt 1048576 ]; then
        echo "$((size_bytes / 1024))KB"
    elif [ "$size_bytes" -lt 1073741824 ]; then
        echo "$((size_bytes / 1048576))MB"
    else
        echo "$((size_bytes / 1073741824))GB"
    fi
}

# Function to calculate age in days
get_age_days() {
    local timestamp=$1
    local current_time=$(date +%s)
    local file_time=$(date -d "$timestamp" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$timestamp" +%s 2>/dev/null || echo 0)
    
    if [ "$file_time" -eq 0 ]; then
        echo "Unknown"
    else
        local age_seconds=$((current_time - file_time))
        local age_days=$((age_seconds / 86400))
        echo "${age_days} days"
    fi
}

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo "❌ Error: AWS CLI is not installed"
    exit 1
fi

# Check if bucket exists and is accessible
if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
    echo "❌ Error: Cannot access bucket '$BUCKET'"
    echo "Make sure the bucket exists and you have proper permissions"
    exit 1
fi

echo "✅ Bucket is accessible"
echo ""

# Check MaxMind databases
echo "📦 MaxMind Databases (MMDB)"
echo "------------------------"

MAXMIND_DBS=("GeoIP2-City.mmdb" "GeoIP2-Country.mmdb" "GeoIP2-ISP.mmdb" "GeoIP2-Connection-Type.mmdb")

for db in "${MAXMIND_DBS[@]}"; do
    key="raw/maxmind/$db"
    
    if aws s3api head-object --bucket "$BUCKET" --key "$key" 2>/dev/null > /tmp/head_output.json; then
        size=$(jq -r '.ContentLength' /tmp/head_output.json)
        last_modified=$(jq -r '.LastModified' /tmp/head_output.json)
        
        size_readable=$(get_file_size "$size")
        age=$(get_age_days "$last_modified")
        
        printf "%-30s %10s  Updated: %-20s  Age: %s\n" "$db" "$size_readable" "$last_modified" "$age"
    else
        printf "%-30s %10s  %s\n" "$db" "MISSING" "❌ Not found"
    fi
done

echo ""

# Check IP2Location databases
echo "📦 IP2Location Databases"
echo "---------------------"

IP2LOCATION_DBS=(
    "IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN"
    "IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN"
    "IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN"
)

for db in "${IP2LOCATION_DBS[@]}"; do
    key="raw/ip2location/$db"
    
    if aws s3api head-object --bucket "$BUCKET" --key "$key" 2>/dev/null > /tmp/head_output.json; then
        size=$(jq -r '.ContentLength' /tmp/head_output.json)
        last_modified=$(jq -r '.LastModified' /tmp/head_output.json)
        
        size_readable=$(get_file_size "$size")
        age=$(get_age_days "$last_modified")
        
        # Shorten the display name for better formatting
        display_name=$(echo "$db" | sed 's/IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE/DB23/g' | sed 's/IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE/DB23-IPV6/g' | sed 's/IP2PROXY-IP-PROXYTYPE-COUNTRY/PX2/g' | sed 's/IPV6-PROXYTYPE-COUNTRY/PX2-IPV6/g')
        
        printf "%-30s %10s  Updated: %-20s  Age: %s\n" "$display_name" "$size_readable" "$last_modified" "$age"
    else
        display_name=$(echo "$db" | sed 's/IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE/DB23/g' | sed 's/IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE/DB23-IPV6/g' | sed 's/IP2PROXY-IP-PROXYTYPE-COUNTRY/PX2/g' | sed 's/IPV6-PROXYTYPE-COUNTRY/PX2-IPV6/g')
        printf "%-30s %10s  %s\n" "$display_name" "MISSING" "❌ Not found"
    fi
done

echo ""

# Summary
echo "📊 Summary"
echo "----------"

# Count total files
TOTAL_FILES=$(aws s3 ls "s3://$BUCKET/raw/" --recursive | wc -l)
MAXMIND_FILES=$(aws s3 ls "s3://$BUCKET/raw/maxmind/" --recursive | wc -l)
IP2LOCATION_FILES=$(aws s3 ls "s3://$BUCKET/raw/ip2location/" --recursive | wc -l)

echo "Total database files: $TOTAL_FILES"
echo "MaxMind databases: $MAXMIND_FILES"
echo "IP2Location databases: $IP2LOCATION_FILES"

# Check for old databases
echo ""
echo "⚠️  Warnings"
echo "-----------"

OLD_THRESHOLD=14  # Days

# Check for databases older than threshold
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "raw/" --query 'Contents[?Size > `0`].[Key,LastModified]' --output text | while read -r key last_modified; do
    if [ ! -z "$last_modified" ]; then
        age_days=$(get_age_days "$last_modified")
        age_num=$(echo "$age_days" | awk '{print $1}')
        
        if [[ "$age_num" =~ ^[0-9]+$ ]] && [ "$age_num" -gt "$OLD_THRESHOLD" ]; then
            echo "⚠️  $(basename $key) is $age_days old (last updated: $last_modified)"
        fi
    fi
done

# Clean up
rm -f /tmp/head_output.json

echo ""
echo "✅ Status check complete"