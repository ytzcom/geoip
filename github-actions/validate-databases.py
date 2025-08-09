#!/usr/bin/env python3
"""
GeoIP Database Validation Script

This script validates MaxMind and IP2Location database files to ensure they are
properly formatted and can be read by their respective libraries.

Requirements:
    pip install geoip2 IP2Location IP2Proxy

Usage:
    python validate-databases.py [base_directory]
    
    If no base_directory is provided, defaults to ./temp/raw/
"""

import os
import sys
import geoip2.database
from IP2Location import IP2Location
from IP2Proxy import IP2Proxy


def validate_mmdb_file(file_path):
    """Validate a MaxMind database file by attempting to open it."""
    try:
        reader = geoip2.database.Reader(file_path)
        # Try a sample lookup based on the database type
        test_ip = '8.8.8.8'
        
        if "City" in file_path:
            result = reader.city(test_ip)
            print(f"✅ Validated MaxMind City database: {os.path.basename(file_path)}")
            print(f"   Sample lookup: {test_ip} -> {result.city.name}, {result.country.name}")
        elif "Connection-Type" in file_path:
            result = reader.connection_type(test_ip)
            print(f"✅ Validated MaxMind Connection-Type database: {os.path.basename(file_path)}")
            print(f"   Sample lookup: {test_ip} -> {result.connection_type}")
        elif "Country" in file_path:
            result = reader.country(test_ip)
            print(f"✅ Validated MaxMind Country database: {os.path.basename(file_path)}")
            print(f"   Sample lookup: {test_ip} -> {result.country.name}")
        elif "ISP" in file_path:
            result = reader.isp(test_ip)
            print(f"✅ Validated MaxMind ISP database: {os.path.basename(file_path)}")
            print(f"   Sample lookup: {test_ip} -> {result.isp}")
        else:
            print(f"✅ Validated MaxMind database: {os.path.basename(file_path)}")
            
        reader.close()
        return True
    except Exception as e:
        print(f"❌ Invalid MaxMind database file {file_path}: {str(e)}")
        return False


def validate_ip2location_file(file_path):
    """Validate an IP2Location database file by attempting to open it."""
    try:
        # Correct instantiation of the IP2Location class
        db = IP2Location(file_path)
        
        # Try a sample lookup to ensure it's working
        test_ip = '8.8.8.8'
        result = db.get_all(test_ip)
        
        print(f"✅ Validated IP2Location database: {os.path.basename(file_path)}")
        
        # Display some sample data if available
        if hasattr(result, 'country_short') and result.country_short != '-':
            print(f"   Sample lookup: {test_ip} -> {result.country_short}, {result.city}")
        
        return True
    except Exception as e:
        print(f"❌ Invalid IP2Location database file {file_path}: {str(e)}")
        return False


def validate_ip2location_proxy_file(file_path):
    """Validate an IP2Location proxy database file."""
    try:
        # Use the IP2Proxy class for proxy database validation
        db = IP2Proxy(file_path)
        
        # Try a sample lookup
        test_ip = '8.8.8.8'
        result = db.get_all(test_ip)
        
        # Verify that we can access proxy-specific fields
        if hasattr(result, 'is_proxy') or hasattr(result, 'proxy_type'):
            print(f"✅ Validated IP2Location proxy database: {os.path.basename(file_path)}")
            if hasattr(result, 'is_proxy'):
                print(f"   Sample lookup: {test_ip} -> Proxy: {result.is_proxy}")
            return True
        else:
            # Alternative approach for older versions
            is_proxy = db.is_proxy(test_ip)
            proxy_type = db.get_proxy_type(test_ip)
            country_code = db.get_country_short(test_ip)
            
            print(f"✅ Validated IP2Location proxy database: {os.path.basename(file_path)}")
            print(f"   Sample lookup: {test_ip} -> Proxy: {is_proxy}, Type: {proxy_type}, Country: {country_code}")
            return True
            
    except Exception as e:
        print(f"❌ Invalid IP2Location proxy database file {file_path}: {str(e)}")
        return False


def main():
    # Get base directory from command line or use default
    if len(sys.argv) > 1:
        base_dir = sys.argv[1]
    else:
        base_dir = "./temp/raw/"
    
    print(f"\n🔍 Validating GeoIP databases in: {base_dir}\n")
    
    # Paths to check
    maxmind_dir = os.path.join(base_dir, "maxmind")
    ip2location_dir = os.path.join(base_dir, "ip2location")
    
    all_valid = True
    validated_count = 0
    
    # Validate MaxMind databases
    if os.path.exists(maxmind_dir):
        print("=== Validating MaxMind Databases ===")
        for file in os.listdir(maxmind_dir):
            if file.endswith('.mmdb'):
                file_path = os.path.join(maxmind_dir, file)
                
                # Check file size
                file_size = os.path.getsize(file_path)
                if file_size < 1000:  # Basic size check
                    print(f"❌ File appears too small to be valid: {file} ({file_size} bytes)")
                    all_valid = False
                    continue
                
                if validate_mmdb_file(file_path):
                    validated_count += 1
                else:
                    all_valid = False
        print()
    
    # Validate IP2Location databases
    if os.path.exists(ip2location_dir):
        print("=== Validating IP2Location Databases ===")
        for file in os.listdir(ip2location_dir):
            file_path = os.path.join(ip2location_dir, file)
            
            # Check file size
            file_size = os.path.getsize(file_path)
            if file_size < 1000:  # Basic size check
                print(f"❌ File appears too small to be valid: {file} ({file_size} bytes)")
                
                # Check if it's an error response
                with open(file_path, 'r', errors='ignore') as f:
                    start = f.read(200)
                    if "<?xml" in start or "<error>" in start or "Access Denied" in start:
                        print(f"   File contains error message, not binary data")
                
                all_valid = False
                continue
            
            # Determine file type and validate accordingly
            if file.endswith('.BIN'):
                if 'PROXY' in file.upper() or 'PX2' in file.upper():
                    if validate_ip2location_proxy_file(file_path):
                        validated_count += 1
                    else:
                        all_valid = False
                else:
                    if validate_ip2location_file(file_path):
                        validated_count += 1
                    else:
                        all_valid = False
            else:
                print(f"⚠️  Unknown file type: {file}")
    
    # Summary
    print(f"\n{'='*50}")
    print(f"Validation Summary:")
    print(f"Total files validated: {validated_count}")
    
    if not all_valid:
        print("\n❌ One or more GeoIP files failed validation!")
        sys.exit(1)
    else:
        print("\n✅ All GeoIP files validated successfully!")
        sys.exit(0)


if __name__ == "__main__":
    main()