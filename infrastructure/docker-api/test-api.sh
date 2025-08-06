#!/bin/bash
# Test script for GeoIP Docker API

set -euo pipefail

# Configuration
API_URL="${API_URL:-http://localhost:8080}"
API_KEY="${API_KEY:-test-key-1}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counter
TESTS_PASSED=0
TESTS_FAILED=0

# Test function
run_test() {
    local test_name="$1"
    local url="$2"
    local expected_status="${3:-200}"
    local method="${4:-GET}"
    local data="${5:-}"
    local headers="${6:-}"
    
    echo -n "Testing: $test_name... "
    
    # Build curl command
    local curl_cmd="curl -s -o /dev/null -w %{http_code} -X $method $url"
    if [ -n "$headers" ]; then
        curl_cmd="$curl_cmd $headers"
    fi
    if [ -n "$data" ]; then
        curl_cmd="$curl_cmd -d '$data'"
    fi
    
    # Run the command and capture the status code
    actual_status=$(eval "$curl_cmd" 2>/dev/null || echo "000")
    
    if [ "$actual_status" = "$expected_status" ]; then
        echo -e "${GREEN}✓${NC}"
        ((TESTS_PASSED++))
        return 0
    else
        echo -e "${RED}✗${NC} (Expected: $expected_status, Got: $actual_status)"
        ((TESTS_FAILED++))
        return 1
    fi
}

echo "=========================================="
echo "GeoIP Docker API Test Suite"
echo "=========================================="
echo "API URL: $API_URL"
echo "API Key: $API_KEY"
echo ""

# Test 1: Health check
echo -e "${YELLOW}Health Check Tests${NC}"
run_test "GET /health" \
    "$API_URL/health" \
    "200" \
    "GET"

# Test 2: Root endpoint
echo -e "\n${YELLOW}Root Endpoint Tests${NC}"
run_test "GET /" \
    "$API_URL/" \
    "200" \
    "GET"

# Test 3: Authentication - Valid API key
echo -e "\n${YELLOW}Authentication Tests${NC}"
run_test "Valid API key" \
    "$API_URL/auth" \
    "200" \
    "POST" \
    '{"databases": "all"}' \
    "-H 'X-API-Key: $API_KEY' -H 'Content-Type: application/json'"

# Test 4: Authentication - Invalid API key
run_test "Invalid API key" \
    "$API_URL/auth" \
    "401" \
    "POST" \
    '{"databases": "all"}' \
    "-H 'X-API-Key: invalid-key' -H 'Content-Type: application/json'"

# Test 5: Authentication - Missing API key
run_test "Missing API key" \
    "$API_URL/auth" \
    "401" \
    "POST" \
    '{"databases": "all"}' \
    "-H 'Content-Type: application/json'"

# Test 6: Specific databases request
echo -e "\n${YELLOW}Database Request Tests${NC}"
run_test "Specific databases" \
    "$API_URL/auth" \
    "200" \
    "POST" \
    '{"databases": ["GeoIP2-City.mmdb", "GeoIP2-Country.mmdb"]}' \
    "-H 'X-API-Key: $API_KEY' -H 'Content-Type: application/json'"

# Test 7: Invalid database request (should return 400 when all databases are invalid)
run_test "Invalid database name" \
    "$API_URL/auth" \
    "400" \
    "POST" \
    '{"databases": ["invalid-db.mmdb"]}' \
    "-H 'X-API-Key: $API_KEY' -H 'Content-Type: application/json'"

# Test 8: Metrics endpoint
echo -e "\n${YELLOW}Metrics Tests${NC}"
run_test "GET /metrics with auth" \
    "$API_URL/metrics" \
    "200" \
    "GET" \
    "" \
    "-H 'X-API-Key: $API_KEY'"

run_test "GET /metrics without auth" \
    "$API_URL/metrics" \
    "401" \
    "GET"

# Test 9: Invalid JSON (FastAPI returns 422 for validation errors)
echo -e "\n${YELLOW}Error Handling Tests${NC}"
run_test "Invalid JSON body" \
    "$API_URL/auth" \
    "422" \
    "POST" \
    'invalid-json' \
    "-H 'X-API-Key: $API_KEY' -H 'Content-Type: application/json'"

# Test 10: Wrong HTTP method
run_test "Wrong HTTP method (GET instead of POST)" \
    "$API_URL/auth" \
    "405" \
    "GET" \
    "" \
    "-H 'X-API-Key: $API_KEY'"

# Verify S3 URLs are valid format
echo -e "\n${YELLOW}S3 URL Validation${NC}"
echo -n "Checking S3 pre-signed URL format... "
url_response=$(curl -s -X POST $API_URL/auth \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"databases": ["GeoIP2-City.mmdb"]}' | jq -r '."GeoIP2-City.mmdb"')

if [[ "$url_response" =~ ^https://.*\.s3\.amazonaws\.com/.* ]]; then
    echo -e "${GREEN}✓${NC} Valid S3 URL format"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗${NC} Invalid S3 URL format"
    ((TESTS_FAILED++))
fi

# Check if URL contains required parameters
echo -n "Checking S3 URL parameters... "
if [[ "$url_response" =~ AWSAccessKeyId.*Signature.*Expires ]]; then
    echo -e "${GREEN}✓${NC} Contains required parameters"
    ((TESTS_PASSED++))
else
    echo -e "${RED}✗${NC} Missing required parameters"
    ((TESTS_FAILED++))
fi

# Summary
echo ""
echo "=========================================="
echo "Test Results Summary"
echo "=========================================="
echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "\n${GREEN}All tests passed successfully!${NC}"
    exit 0
else
    echo -e "\n${RED}Some tests failed. Please review the results above.${NC}"
    exit 1
fi