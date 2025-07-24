#!/usr/bin/env python3
"""
GeoIP Database Validation Script for GitHub Action

This script validates specific GeoIP database files for use in the GitHub Action.
It's a lighter version of validate-databases.py that only validates requested files.

Usage:
    python validate-geoip-action.py <directory> --databases <comma-separated-list>
"""

import os
import sys
import argparse
import geoip2.database
from IP2Location import IP2Location
from IP2Proxy import IP2Proxy


def validate_mmdb_file(file_path):
    """Validate a MaxMind database file."""
    try:
        reader = geoip2.database.Reader(file_path)
        test_ip = '8.8.8.8'
        
        # Test based on database type
        if "City" in file_path:
            result = reader.city(test_ip)
            info = f"{result.city.name}, {result.country.name}" if result.city.name else result.country.name
        elif "Connection-Type" in file_path:
            result = reader.connection_type(test_ip)
            info = result.connection_type
        elif "Country" in file_path:
            result = reader.country(test_ip)
            info = result.country.name
        elif "ISP" in file_path:
            result = reader.isp(test_ip)
            info = result.isp
        else:
            # Generic validation
            info = "Valid"
            
        reader.close()
        print(f"✅ {os.path.basename(file_path)}: {info}")
        return True
    except Exception as e:
        print(f"❌ {os.path.basename(file_path)}: {str(e)}")
        return False


def validate_ip2location_file(file_path):
    """Validate an IP2Location database file."""
    try:
        db = IP2Location(file_path)
        test_ip = '8.8.8.8'
        result = db.get_all(test_ip)
        
        info = "Valid"
        if hasattr(result, 'country_short') and result.country_short != '-':
            info = f"{result.country_short}"
            if hasattr(result, 'city') and result.city != '-':
                info += f", {result.city}"
        
        print(f"✅ {os.path.basename(file_path)}: {info}")
        return True
    except Exception as e:
        print(f"❌ {os.path.basename(file_path)}: {str(e)}")
        return False


def validate_ip2proxy_file(file_path):
    """Validate an IP2Proxy database file."""
    try:
        db = IP2Proxy(file_path)
        test_ip = '8.8.8.8'
        
        # Try modern API first
        result = db.get_all(test_ip)
        if hasattr(result, 'is_proxy'):
            info = f"Proxy: {result.is_proxy}"
        else:
            # Fallback to legacy API
            is_proxy = db.is_proxy(test_ip)
            info = f"Proxy: {is_proxy}"
            
        print(f"✅ {os.path.basename(file_path)}: {info}")
        return True
    except Exception as e:
        print(f"❌ {os.path.basename(file_path)}: {str(e)}")
        return False


def validate_file(file_path):
    """Validate a single database file based on its type."""
    # Check file exists and has reasonable size
    if not os.path.exists(file_path):
        print(f"❌ {os.path.basename(file_path)}: File not found")
        return False
        
    file_size = os.path.getsize(file_path)
    if file_size < 1000:
        print(f"❌ {os.path.basename(file_path)}: File too small ({file_size} bytes)")
        return False
    
    # Validate based on file type
    if file_path.endswith('.mmdb'):
        return validate_mmdb_file(file_path)
    elif file_path.endswith('.BIN'):
        if 'PROXY' in file_path.upper() or 'PX2' in file_path.upper():
            return validate_ip2proxy_file(file_path)
        else:
            return validate_ip2location_file(file_path)
    else:
        print(f"⚠️  {os.path.basename(file_path)}: Unknown file type")
        return True  # Don't fail on unknown types


def main():
    parser = argparse.ArgumentParser(description='Validate GeoIP database files')
    parser.add_argument('directory', help='Directory containing database files')
    parser.add_argument('--databases', required=True, help='Comma-separated list of database files to validate')
    parser.add_argument('--quiet', action='store_true', help='Suppress informational output')
    
    args = parser.parse_args()
    
    if not args.quiet:
        print(f"🔍 Validating GeoIP databases in: {args.directory}\n")
    
    # Parse database list
    databases = [db.strip() for db in args.databases.split(',') if db.strip()]
    
    if not databases:
        print("⚠️  No databases specified for validation")
        sys.exit(0)
    
    # Validate each specified database
    all_valid = True
    validated_count = 0
    
    for db_name in databases:
        file_path = os.path.join(args.directory, db_name)
        if validate_file(file_path):
            validated_count += 1
        else:
            all_valid = False
    
    # Summary
    if not args.quiet:
        print(f"\n{'='*50}")
        print(f"Validation Summary:")
        print(f"Total files validated: {validated_count}/{len(databases)}")
    
    if not all_valid:
        if not args.quiet:
            print("\n❌ One or more database files failed validation!")
        sys.exit(1)
    else:
        if not args.quiet:
            print("\n✅ All database files validated successfully!")
        sys.exit(0)


if __name__ == "__main__":
    main()