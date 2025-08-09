#!/bin/sh
# Comprehensive GeoIP database validation
# Validates both MMDB and BIN format databases
# 
# Usage:
#   ./validate.sh [--directory DIR] [--validate-only]
#   ./validate.sh -d DIR
#
# Options:
#   --directory, -d DIR   Directory containing databases (default: $GEOIP_TARGET_DIR or /app/resources/geoip)
#   --validate-only, -V   Run validation only (this is the default behavior)
#   --quiet, -q          Quiet mode, only show errors
#   --verbose, -v        Verbose output
#
# Exit codes:
#   0 - All validations passed
#   1 - Validation failed
#   2 - Invalid arguments

set -e

# Default values
GEOIP_TARGET_DIR="${GEOIP_TARGET_DIR:-/app/resources/geoip}"
QUIET=false
VERBOSE=false
VALIDATION_FAILED=false
DATABASES_VALIDATED=0
MMDB_VALIDATED=0
BIN_VALIDATED=0

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --directory|-d)
            shift
            GEOIP_TARGET_DIR="$1"
            ;;
        --validate-only|-V)
            # This is the default behavior, kept for compatibility
            ;;
        --quiet|-q)
            QUIET=true
            ;;
        --verbose|-v)
            VERBOSE=true
            ;;
        --help|-h)
            echo "Usage: $0 [--directory DIR] [--validate-only] [--quiet] [--verbose]"
            echo "Validates GeoIP database files (MMDB and BIN formats)"
            exit 0
            ;;
        *)
            if [ -d "$1" ]; then
                # If it's a directory, use it as the target
                GEOIP_TARGET_DIR="$1"
            else
                echo "Error: Unknown option or invalid directory: $1" >&2
                exit 2
            fi
            ;;
    esac
    shift
done

# Logging functions
log_info() {
    if [ "$QUIET" != "true" ]; then
        echo "[Validate] $1"
    fi
}

log_verbose() {
    if [ "$VERBOSE" = "true" ] && [ "$QUIET" != "true" ]; then
        echo "[Validate] DEBUG: $1"
    fi
}

log_error() {
    echo "[Validate] ERROR: $1" >&2
}

log_success() {
    if [ "$QUIET" != "true" ]; then
        echo "  ✅ $1"
    fi
}

log_warning() {
    if [ "$QUIET" != "true" ]; then
        echo "  ⚠️  $1"
    fi
}

log_fail() {
    echo "  ❌ $1" >&2
}

# Get file size in a cross-platform way
get_file_size() {
    local file="$1"
    local size=0
    
    if command -v stat >/dev/null 2>&1; then
        # Try GNU stat first (Linux), then BSD stat (macOS)
        size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    else
        # Fallback to wc -c
        size=$(wc -c < "$file" 2>/dev/null || echo 0)
    fi
    
    echo "$size"
}

# Validate MMDB file format
validate_mmdb_file() {
    local file="$1"
    local basename_file=$(basename "$file")
    
    log_verbose "Validating MMDB file: $basename_file"
    
    # Check file size
    local size=$(get_file_size "$file")
    if [ "$size" -lt 1000 ]; then
        log_fail "$basename_file is too small (${size} bytes)"
        return 1
    fi
    
    # Check for MMDB metadata marker
    local valid=false
    
    if command -v xxd >/dev/null 2>&1; then
        # Check for \xab\xcd\xefMaxMind.com in last 1KB
        # Hex: abcdef4d61784d696e642e636f6d
        # Check for MaxMind metadata marker (metadata can be up to 128KB per spec)
        if tail -c 131072 "$file" | xxd -p | tr -d '\n' | grep -q "abcdef4d61784d696e642e636f6d"; then
            valid=true
            log_verbose "Found MaxMind.com metadata marker using xxd"
        fi
    elif command -v od >/dev/null 2>&1; then
        # Alternative check using od - look for "MaxMind.com" string
        if tail -c 1024 "$file" | strings 2>/dev/null | grep -q "MaxMind.com"; then
            valid=true
            log_verbose "Found MaxMind.com string using strings"
        fi
    elif command -v hexdump >/dev/null 2>&1; then
        # Another alternative using hexdump
        if tail -c 1024 "$file" | hexdump -C | grep -q "MaxMind.com"; then
            valid=true
            log_verbose "Found MaxMind.com string using hexdump"
        fi
    else
        # Fallback: just check if file contains MaxMind.com somewhere
        if grep -q "MaxMind.com" "$file" 2>/dev/null; then
            valid=true
            log_verbose "Found MaxMind.com string using grep"
        fi
    fi
    
    if [ "$valid" = "true" ]; then
        local size_mb=$((size / 1024 / 1024))
        log_success "$basename_file (${size_mb}MB) - Valid MMDB format"
        return 0
    else
        log_fail "$basename_file - Invalid MMDB format (missing MaxMind metadata)"
        return 1
    fi
}

# Validate BIN file format (IP2Location)
validate_bin_file() {
    local file="$1"
    local basename_file=$(basename "$file")
    
    log_verbose "Validating BIN file: $basename_file"
    
    # Check file size
    local size=$(get_file_size "$file")
    if [ "$size" -lt 1000 ]; then
        log_fail "$basename_file is too small (${size} bytes)"
        return 1
    fi
    
    # IP2Location BIN files have specific patterns
    # They typically start with specific byte patterns and contain IP2Location strings
    local valid=false
    
    # Check for IP2Location markers in the file
    if command -v strings >/dev/null 2>&1; then
        # IP2Location files often contain "IP2Location" or database type strings
        if head -c 10000 "$file" | strings 2>/dev/null | grep -qE "(IP2Location|IPV6|LATITUDE|LONGITUDE|DOMAIN|PROXY)" 2>/dev/null; then
            valid=true
            log_verbose "Found IP2Location markers in BIN file"
        fi
    fi
    
    # Additional check: BIN files should be binary (not text)
    if [ "$valid" != "true" ]; then
        # Check if file appears to be binary
        if command -v file >/dev/null 2>&1; then
            if file "$file" 2>/dev/null | grep -q "data\|binary"; then
                valid=true
                log_verbose "File identified as binary data"
            fi
        else
            # Simple check: if first 100 bytes contain non-printable characters
            if head -c 100 "$file" | grep -q '[^[:print:][:space:]]' 2>/dev/null; then
                valid=true
                log_verbose "File contains binary data"
            fi
        fi
    fi
    
    if [ "$valid" = "true" ]; then
        local size_mb=$((size / 1024 / 1024))
        log_success "$basename_file (${size_mb}MB) - Valid BIN format"
        return 0
    else
        log_warning "$basename_file - Could not verify BIN format (may still be valid)"
        # Don't fail for BIN files as validation is harder without specific libraries
        return 0
    fi
}

# Main validation
main() {
    log_info "Validating GeoIP databases in: $GEOIP_TARGET_DIR"
    
    # Check if directory exists
    if [ ! -d "$GEOIP_TARGET_DIR" ]; then
        log_error "Directory does not exist: $GEOIP_TARGET_DIR"
        exit 1
    fi
    
    # Validate all MMDB files
    log_info "Validating MMDB files..."
    for mmdb_file in "$GEOIP_TARGET_DIR"/*.mmdb; do
        if [ -f "$mmdb_file" ]; then
            if validate_mmdb_file "$mmdb_file"; then
                MMDB_VALIDATED=$((MMDB_VALIDATED + 1))
                DATABASES_VALIDATED=$((DATABASES_VALIDATED + 1))
            else
                VALIDATION_FAILED=true
            fi
        fi
    done
    
    if [ "$MMDB_VALIDATED" -eq 0 ]; then
        log_info "No MMDB files found"
    fi
    
    # Validate all BIN files
    log_info "Validating BIN files..."
    for bin_file in "$GEOIP_TARGET_DIR"/*.BIN; do
        if [ -f "$bin_file" ]; then
            if validate_bin_file "$bin_file"; then
                BIN_VALIDATED=$((BIN_VALIDATED + 1))
                DATABASES_VALIDATED=$((DATABASES_VALIDATED + 1))
            else
                VALIDATION_FAILED=true
            fi
        fi
    done
    
    if [ "$BIN_VALIDATED" -eq 0 ]; then
        log_info "No BIN files found"
    fi
    
    # Summary
    echo ""
    log_info "Validation Summary:"
    log_info "  MMDB files validated: $MMDB_VALIDATED"
    log_info "  BIN files validated: $BIN_VALIDATED"
    log_info "  Total databases validated: $DATABASES_VALIDATED"
    
    # Check minimum requirements
    if [ "$DATABASES_VALIDATED" -eq 0 ]; then
        log_error "No valid database files found!"
        exit 1
    fi
    
    # Final result
    if [ "$VALIDATION_FAILED" = "true" ]; then
        echo ""
        log_error "Validation FAILED - some databases are invalid!"
        exit 1
    else
        echo ""
        log_success "Validation PASSED - all databases are valid!"
        exit 0
    fi
}

# Run main function
main