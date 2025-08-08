#!/bin/bash

# =========================================
# GeoIP API Comprehensive Test Suite
# =========================================
#
# Usage:
#   ./test.sh [options]
#
# Options:
#   -v, --verbose        Show detailed output for each test
#   -q, --quiet          Minimal output (exit code indicates success)
#   -j, --json           Output results in JSON format
#   -c, --category       Run specific test category only
#   -h, --help           Show this help message
#   -s, --skip-setup     Skip container health check
#   -r, --retry          Number of retries for failed tests (default: 0)
#   --test-downloads     Actually download files (slow, optional)
#   --start-container    Automatically start Docker container before tests
#   --cleanup            Remove Docker container after tests complete
#   --rebuild            Force rebuild container before starting
#   --no-container-check Skip all container management
#
# Categories:
#   health      Health and status endpoints
#   auth        Authentication endpoints
#   query       GeoIP query endpoints
#   session     Session management
#   download    Database download endpoints
#   install     Installation script endpoint
#   validation  Data validation tests
#   error       Error handling tests
#   admin       Admin endpoints (if enabled)
#   all         Run all tests (default)
#
# Examples:
#   ./test.sh                                  # Run all tests (requires running container)
#   ./test.sh --start-container                # Auto-start container and run tests
#   ./test.sh --start-container --cleanup      # Start container, test, then cleanup
#   ./test.sh -v --start-container             # Verbose output with container management
#   ./test.sh -c query                         # Run only query tests
#   ./test.sh -q -j > results.json            # JSON output for CI/CD
#   ./test.sh --rebuild --start-container      # Force rebuild and test
#
# Environment Variables:
#   API_URL       API endpoint (default: http://localhost:8080)
#   API_KEY       API key for authentication (default: test-key-1)
#   ADMIN_KEY     Admin key for admin endpoints (default: none)
#

set -euo pipefail

# =========================================
# Configuration
# =========================================

API_URL="${API_URL:-http://localhost:8080}"
API_KEY="${API_KEY:-test-key-1}"
ADMIN_KEY="${ADMIN_KEY:-}"
VERBOSE=false
QUIET=false
JSON_OUTPUT=false
CATEGORY="all"
SKIP_SETUP=false
RETRY_COUNT=0
TEST_DOWNLOADS=false
START_CONTAINER=false
CLEANUP_CONTAINER=false
REBUILD_CONTAINER=false
NO_CONTAINER_CHECK=false
TEST_START_TIME=$(date +%s)

# Container configuration
CONTAINER_NAME="geoip-api"
CONTAINER_IMAGE="geoip-api"
CONTAINER_PORT="8080"
ENV_FILE=".env.test"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
CURRENT_CATEGORY=""

# Test results array for JSON output
declare -a TEST_RESULTS

# =========================================
# Prerequisite Check Functions
# =========================================

check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if .env.test file exists
    if [[ ! -f "$ENV_FILE" ]]; then
        log -e "${RED}Error: $ENV_FILE file not found${NC}"
        log ""
        log "The test suite requires a $ENV_FILE file for configuration."
        log "Please copy the example file and customize it:"
        log ""
        log -e "  ${YELLOW}cp .env.example $ENV_FILE${NC}"
        log ""
        log "Then edit $ENV_FILE to set your test configuration."
        exit 1
    fi
    
    # Check if Docker is available
    if ! command -v docker >/dev/null 2>&1; then
        log -e "${RED}Error: Docker is not installed or not in PATH${NC}"
        log ""
        log "Please install Docker to run the test suite:"
        log "  https://docs.docker.com/get-docker/"
        exit 1
    fi
    
    # Check if Docker daemon is running
    if ! docker info >/dev/null 2>&1; then
        log -e "${RED}Error: Docker daemon is not running${NC}"
        log ""
        log "Please start Docker and try again:"
        log "  - On macOS: Start Docker Desktop"
        log "  - On Linux: sudo systemctl start docker"
        exit 1
    fi
    
    log -e "${GREEN}✓${NC} Prerequisites check passed"
}

check_docker_image() {
    log "Checking Docker image availability..."
    
    # Check if the Docker image exists
    if ! docker image inspect "$CONTAINER_IMAGE" >/dev/null 2>&1; then
        log -e "${RED}Error: Docker image '$CONTAINER_IMAGE' not found${NC}"
        log ""
        log "Please build the Docker image first:"
        log ""
        log -e "  ${YELLOW}docker build -t $CONTAINER_IMAGE .${NC}"
        log ""
        log "Or ensure you're in the correct directory with a Dockerfile."
        exit 1
    fi
    
    log -e "${GREEN}✓${NC} Docker image '$CONTAINER_IMAGE' found"
}

handle_existing_container() {
    # Check if container already exists
    if docker ps -a --filter "name=$CONTAINER_NAME" --format "table {{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
        local container_status=$(docker ps --filter "name=$CONTAINER_NAME" --format "table {{.Status}}" | tail -n +2)
        
        if [[ -n "$container_status" ]]; then
            log -e "${YELLOW}Warning: Container '$CONTAINER_NAME' is already running${NC}"
            log "  Status: $container_status"
            
            # Check if it's healthy
            local health_check=$(curl -s "$API_URL/health" 2>/dev/null || echo "")
            if [[ -n "$health_check" ]] && echo "$health_check" | grep -q '"status":"healthy"'; then
                log -e "${GREEN}✓${NC} Existing container is healthy, using it for tests"
                return 0
            else
                log -e "${YELLOW}Warning: Existing container is not responding, restarting...${NC}"
                docker stop "$CONTAINER_NAME" >/dev/null 2>&1
                docker rm "$CONTAINER_NAME" >/dev/null 2>&1
            fi
        else
            log "Removing stopped container '$CONTAINER_NAME'..."
            docker rm "$CONTAINER_NAME" >/dev/null 2>&1
        fi
    fi
    
    return 1
}

start_container() {
    log "Starting Docker container..."
    
    # Stop and remove existing container if rebuild requested
    if [[ "$REBUILD_CONTAINER" == true ]]; then
        log "Rebuilding: Stopping and removing existing container..."
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1
    fi
    
    # Check for existing container
    if handle_existing_container; then
        return 0
    fi
    
    # Check if port is already in use
    if netstat -tln 2>/dev/null | grep -q ":$CONTAINER_PORT " || ss -tln 2>/dev/null | grep -q ":$CONTAINER_PORT "; then
        log -e "${RED}Error: Port $CONTAINER_PORT is already in use${NC}"
        log ""
        log "Please stop the service using port $CONTAINER_PORT or use a different port:"
        log "  lsof -ti:$CONTAINER_PORT | xargs kill"
        exit 1
    fi
    
    # Start the container with the exact command specified
    log "Running: docker run -d --name $CONTAINER_NAME -p $CONTAINER_PORT:$CONTAINER_PORT --env-file $ENV_FILE -v geoip_databases:/data/databases $CONTAINER_IMAGE"
    
    local container_id
    container_id=$(docker run -d --name "$CONTAINER_NAME" -p "$CONTAINER_PORT:$CONTAINER_PORT" --env-file "$ENV_FILE" -v geoip_databases:/data/databases "$CONTAINER_IMAGE" 2>&1)
    
    if [[ $? -eq 0 ]]; then
        log -e "${GREEN}✓${NC} Container started successfully (ID: ${container_id:0:12})"
        return 0
    else
        log -e "${RED}Error: Failed to start container${NC}"
        log "Docker error: $container_id"
        
        # Show container logs if available
        if docker ps -a --filter "name=$CONTAINER_NAME" --format "table {{.Names}}" | grep -q "^$CONTAINER_NAME$"; then
            log ""
            log "Container logs:"
            docker logs "$CONTAINER_NAME" 2>&1 | tail -n 10
        fi
        
        exit 1
    fi
}

wait_for_container() {
    log "Waiting for container to be healthy..."
    
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        local health_check=$(curl -s "$API_URL/health" 2>/dev/null || echo "")
        
        if [[ -n "$health_check" ]] && echo "$health_check" | grep -q '"status":"healthy"'; then
            log -e "${GREEN}✓${NC} Container is healthy and ready"
            return 0
        fi
        
        ((attempt++))
        if [[ $attempt -eq $max_attempts ]]; then
            log -e "${RED}Error: Container failed to become healthy within ${max_attempts} seconds${NC}"
            log ""
            log "Container logs:"
            docker logs "$CONTAINER_NAME" 2>&1 | tail -n 20
            exit 1
        fi
        
        if [[ "$QUIET" == false ]]; then
            echo -n "."
        fi
        sleep 1
    done
}

cleanup_container() {
    if [[ "$CLEANUP_CONTAINER" == true ]]; then
        log ""
        log "Cleaning up container..."
        
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1
        
        log -e "${GREEN}✓${NC} Container cleaned up"
    fi
}

# =========================================
# Helper Functions
# =========================================

show_help() {
    LC_ALL=C sed -n '3,37p' "$0" | LC_ALL=C sed 's/^# //'
    exit 0
}

log() {
    if [[ "$QUIET" == false ]] && [[ "$JSON_OUTPUT" == false ]]; then
        echo -e "$@"
    fi
}

log_verbose() {
    if [[ "$VERBOSE" == true ]] && [[ "$JSON_OUTPUT" == false ]]; then
        echo "$@"
    fi
}

log_category() {
    CURRENT_CATEGORY="$1"
    if [[ "$QUIET" == false ]] && [[ "$JSON_OUTPUT" == false ]]; then
        echo -e "\n${YELLOW}═══ $1 ═══${NC}"
    fi
}

# Enhanced test function with retry capability
run_test() {
    local test_name="$1"
    local url="$2"
    local expected_status="${3:-200}"
    local method="${4:-GET}"
    local data="${5:-}"
    local headers="${6:-}"
    local validate_json="${7:-false}"
    local validate_func="${8:-}"
    
    local test_start=$(date +%s%N)
    local attempts=0
    local max_attempts=$((RETRY_COUNT + 1))
    local actual_status=""
    local response=""
    local test_passed=false
    
    while [[ $attempts -lt $max_attempts ]] && [[ "$test_passed" == false ]]; do
        attempts=$((attempts + 1))
        
        if [[ "$QUIET" == false ]] && [[ "$JSON_OUTPUT" == false ]]; then
            echo -n "Testing: $test_name"
            if [[ $attempts -gt 1 ]]; then
                echo -n " (attempt $attempts/$max_attempts)"
            fi
            echo -n "... "
        fi
        
        # Build curl command with timeout for all requests
        local curl_cmd="curl -s --max-time 5 -w '\n|||STATUS|||%{http_code}|||' -X $method"
        
        # Add headers
        if [[ -n "$headers" ]]; then
            curl_cmd="$curl_cmd $headers"
        fi
        
        # Add data for POST/PUT methods
        if [[ -n "$data" ]]; then
            curl_cmd="$curl_cmd -d '$data'"
        fi
        
        # Add URL
        curl_cmd="$curl_cmd '$url'"
        
        # Execute curl and capture response
        local full_response=$(eval "$curl_cmd" 2>/dev/null || echo "|||STATUS|||000|||")
        response=$(echo "$full_response" | LC_ALL=C sed 's/|||STATUS|||.*//')
        actual_status=$(echo "$full_response" | LC_ALL=C sed -n 's/.*|||STATUS|||\([0-9]*\)|||.*/\1/p')
        
        # Validate status code
        if [[ "$actual_status" == "$expected_status" ]]; then
            # Additional validation if requested
            if [[ "$validate_json" == "true" ]] && [[ -n "$response" ]]; then
                if echo "$response" | python3 -m json.tool > /dev/null 2>&1; then
                    test_passed=true
                else
                    actual_status="invalid_json"
                fi
            elif [[ -n "$validate_func" ]]; then
                if $validate_func "$response"; then
                    test_passed=true
                else
                    actual_status="validation_failed"
                fi
            else
                test_passed=true
            fi
        fi
        
        if [[ "$test_passed" == false ]] && [[ $attempts -lt $max_attempts ]]; then
            sleep 1
        fi
    done
    
    # Calculate test duration
    local test_end=$(date +%s%N)
    local duration_ms=$(( (test_end - test_start) / 1000000 ))
    
    # Record result
    local result_json="{\"category\":\"$CURRENT_CATEGORY\",\"test\":\"$test_name\",\"expected\":\"$expected_status\",\"actual\":\"$actual_status\",\"passed\":$test_passed,\"duration_ms\":$duration_ms,\"attempts\":$attempts}"
    TEST_RESULTS+=("$result_json")
    
    # Display result
    if [[ "$test_passed" == true ]]; then
        if [[ "$QUIET" == false ]] && [[ "$JSON_OUTPUT" == false ]]; then
            echo -e "${GREEN}✓${NC} (${duration_ms}ms)"
        fi
        log_verbose "  Response: $(echo "$response" | head -n 5)"
        ((TESTS_PASSED++))
        return 0
    else
        if [[ "$QUIET" == false ]] && [[ "$JSON_OUTPUT" == false ]]; then
            echo -e "${RED}✗${NC} (Expected: $expected_status, Got: $actual_status)"
        fi
        log_verbose "  Response: $response"
        ((TESTS_FAILED++))
        return 1
    fi
}

# Validation functions
validate_health_response() {
    local response="$1"
    echo "$response" | grep -q '"status":"healthy"' && \
    echo "$response" | grep -q '"databases_available":[0-9]' && \
    echo "$response" | grep -q '"databases_local":[0-9]' && \
    echo "$response" | grep -q '"databases_remote":[0-9]'
}

validate_query_response() {
    local response="$1"
    echo "$response" | grep -q '"country"' && \
    echo "$response" | grep -q '"usage_type"'
}

validate_full_data_response() {
    local response="$1"
    echo "$response" | grep -q '"_database_sources"' && \
    echo "$response" | grep -q '"_databases_available"'
}

validate_s3_url() {
    local response="$1"
    echo "$response" | grep -qE 'https://.*\.s3\.amazonaws\.com/.*' || \
    echo "$response" | grep -q '/download/'
}

check_container_health() {
    log "Checking container health..."
    
    local health_check=$(curl -s "$API_URL/health" 2>/dev/null || echo "")
    if [[ -z "$health_check" ]]; then
        log -e "${RED}Error: Cannot connect to API at $API_URL${NC}"
        log "Please ensure the container is running:"
        log "  docker ps | grep geoip-api"
        exit 1
    fi
    
    if echo "$health_check" | grep -q '"status":"healthy"'; then
        log -e "${GREEN}✓${NC} Container is healthy"
        
        # Extract database count
        local db_count=$(echo "$health_check" | LC_ALL=C sed -n 's/.*"databases_available":\([0-9]*\).*/\1/p')
        log "  Databases available: $db_count"
        
        # Extract storage mode
        local storage_mode=$(echo "$health_check" | LC_ALL=C sed -n 's/.*"storage_mode":"\([^"]*\)".*/\1/p')
        log "  Storage mode: $storage_mode"
    else
        log -e "${YELLOW}Warning: Container health check returned unexpected response${NC}"
    fi
}

# =========================================
# Parse Command Line Arguments
# =========================================

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -q|--quiet)
            QUIET=true
            shift
            ;;
        -j|--json)
            JSON_OUTPUT=true
            QUIET=true
            shift
            ;;
        -c|--category)
            CATEGORY="$2"
            shift 2
            ;;
        -s|--skip-setup)
            SKIP_SETUP=true
            shift
            ;;
        -r|--retry)
            RETRY_COUNT="$2"
            shift 2
            ;;
        --test-downloads)
            TEST_DOWNLOADS=true
            shift
            ;;
        --start-container)
            START_CONTAINER=true
            shift
            ;;
        --cleanup)
            CLEANUP_CONTAINER=true
            shift
            ;;
        --rebuild)
            REBUILD_CONTAINER=true
            shift
            ;;
        --no-container-check)
            NO_CONTAINER_CHECK=true
            shift
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            ;;
    esac
done

# =========================================
# Setup
# =========================================

if [[ "$JSON_OUTPUT" == false ]]; then
    log "========================================="
    log "     GeoIP API Comprehensive Test Suite"
    log "========================================="
    log "API URL: $API_URL"
    log "API Key: $API_KEY"
    
    if [[ "$VERBOSE" == true ]]; then
        log "Mode: Verbose"
    fi
    
    if [[ "$CATEGORY" != "all" ]]; then
        log "Category: $CATEGORY"
    fi
    
    if [[ $RETRY_COUNT -gt 0 ]]; then
        log "Retry Count: $RETRY_COUNT"
    fi
fi

# Pre-flight checks unless skipped
if [[ "$NO_CONTAINER_CHECK" == false ]]; then
    check_prerequisites
fi

# Container management
if [[ "$START_CONTAINER" == true ]]; then
    if [[ "$REBUILD_CONTAINER" == true ]]; then
        log "Rebuilding Docker image..."
        if ! docker build -t "$CONTAINER_IMAGE" . &>/dev/null; then
            log -e "${RED}Error: Failed to rebuild Docker image${NC}"
            exit 1
        fi
        log -g "Docker image rebuilt successfully"
    fi
    
    check_docker_image
    handle_existing_container
    start_container
    wait_for_container
fi

# Setup cleanup trap if requested
if [[ "$CLEANUP_CONTAINER" == true ]]; then
    trap cleanup_container EXIT
fi

# Check container health unless skipped
if [[ "$SKIP_SETUP" == false ]] && [[ "$NO_CONTAINER_CHECK" == false ]]; then
    check_container_health
fi

# =========================================
# Test Categories
# =========================================

# --- Health & Status Tests ---
if [[ "$CATEGORY" == "all" ]] || [[ "$CATEGORY" == "health" ]]; then
    log_category "Health & Status Tests"
    
    run_test "GET /health" \
        "$API_URL/health" \
        "200" \
        "GET" \
        "" \
        "" \
        "true" \
        "validate_health_response"
    
    run_test "GET / (root endpoint)" \
        "$API_URL/" \
        "200" \
        "GET"
    
    run_test "GET /metrics with auth" \
        "$API_URL/metrics" \
        "200" \
        "GET" \
        "" \
        "-H 'X-API-Key: $API_KEY'" \
        "true"
    
    run_test "GET /metrics without auth" \
        "$API_URL/metrics" \
        "401" \
        "GET"
fi

# --- Authentication Tests ---
if [[ "$CATEGORY" == "all" ]] || [[ "$CATEGORY" == "auth" ]]; then
    log_category "Authentication Tests"
    
    run_test "POST /auth with valid API key (all databases)" \
        "$API_URL/auth" \
        "200" \
        "POST" \
        '{"databases": "all"}' \
        "-H 'X-API-Key: $API_KEY' -H 'Content-Type: application/json'" \
        "true" \
        "validate_s3_url"
    
    run_test "POST /auth with invalid API key" \
        "$API_URL/auth" \
        "401" \
        "POST" \
        '{"databases": "all"}' \
        "-H 'X-API-Key: invalid-key' -H 'Content-Type: application/json'"
    
    run_test "POST /auth with missing API key" \
        "$API_URL/auth" \
        "401" \
        "POST" \
        '{"databases": "all"}' \
        "-H 'Content-Type: application/json'"
    
    run_test "POST /auth with specific databases" \
        "$API_URL/auth" \
        "200" \
        "POST" \
        '{"databases": ["GeoIP2-City.mmdb", "GeoIP2-ISP.mmdb"]}' \
        "-H 'X-API-Key: $API_KEY' -H 'Content-Type: application/json'" \
        "true"
    
    run_test "POST /auth with invalid database names" \
        "$API_URL/auth" \
        "400" \
        "POST" \
        '{"databases": ["invalid-db.mmdb"]}' \
        "-H 'X-API-Key: $API_KEY' -H 'Content-Type: application/json'"
    
    run_test "POST /auth with malformed JSON" \
        "$API_URL/auth" \
        "422" \
        "POST" \
        'invalid-json' \
        "-H 'X-API-Key: $API_KEY' -H 'Content-Type: application/json'"
    
    run_test "GET /auth (wrong method)" \
        "$API_URL/auth" \
        "405" \
        "GET" \
        "" \
        "-H 'X-API-Key: $API_KEY'"
fi

# --- GeoIP Query Tests ---
if [[ "$CATEGORY" == "all" ]] || [[ "$CATEGORY" == "query" ]]; then
    log_category "GeoIP Query Tests"
    
    run_test "GET /query single IP (8.8.8.8)" \
        "$API_URL/query?ips=8.8.8.8" \
        "200" \
        "GET" \
        "" \
        "-H 'X-API-Key: $API_KEY'" \
        "true" \
        "validate_query_response"
    
    run_test "GET /query multiple IPs" \
        "$API_URL/query?ips=8.8.8.8,1.1.1.1,208.67.222.222" \
        "200" \
        "GET" \
        "" \
        "-H 'X-API-Key: $API_KEY'" \
        "true"
    
    run_test "GET /query with full_data=true" \
        "$API_URL/query?ips=8.8.8.8&full_data=true" \
        "200" \
        "GET" \
        "" \
        "-H 'X-API-Key: $API_KEY'" \
        "true" \
        "validate_full_data_response"
    
    run_test "GET /query with invalid IP" \
        "$API_URL/query?ips=invalid.ip.address,8.8.8.8" \
        "200" \
        "GET" \
        "" \
        "-H 'X-API-Key: $API_KEY'" \
        "true"
    
    run_test "GET /query with IPv6 address" \
        "$API_URL/query?ips=2001:4860:4860::8888" \
        "200" \
        "GET" \
        "" \
        "-H 'X-API-Key: $API_KEY'" \
        "true"
    
    run_test "GET /query with private IP (192.168.1.1)" \
        "$API_URL/query?ips=192.168.1.1" \
        "200" \
        "GET" \
        "" \
        "-H 'X-API-Key: $API_KEY'" \
        "true"
    
    run_test "GET /query without authentication" \
        "$API_URL/query?ips=8.8.8.8" \
        "401" \
        "GET"
    
    run_test "GET /query with API key in query param" \
        "$API_URL/query?ips=8.8.8.8&api_key=$API_KEY" \
        "200" \
        "GET" \
        "" \
        "" \
        "true"
    
    # Test rate limiting (create a list of 51 IPs)
    many_ips="8.8.8.8"
    for i in {1..51}; do
        many_ips="$many_ips,1.1.1.$i"
    done
    
    run_test "GET /query with 52 IPs (rate limit test)" \
        "$API_URL/query?ips=$many_ips" \
        "200" \
        "GET" \
        "" \
        "-H 'X-API-Key: $API_KEY'" \
        "true"
fi

# --- Session Management Tests ---
if [[ "$CATEGORY" == "all" ]] || [[ "$CATEGORY" == "session" ]]; then
    log_category "Session Management Tests"
    
    run_test "POST /login with valid API key" \
        "$API_URL/login?api_key=$API_KEY" \
        "200" \
        "POST" \
        "" \
        "" \
        "true"
    
    run_test "POST /login with invalid API key" \
        "$API_URL/login?api_key=invalid-key" \
        "401" \
        "POST"
    
    run_test "POST /logout" \
        "$API_URL/logout" \
        "200" \
        "POST" \
        "" \
        "" \
        "true"
    
    # Test session persistence
    session_cookie=$(curl -s -c - -X POST "$API_URL/login?api_key=$API_KEY" | grep geoip_session | awk '{print $7}')
    if [[ -n "$session_cookie" ]]; then
        run_test "GET /query with session cookie" \
            "$API_URL/query?ips=8.8.8.8" \
            "200" \
            "GET" \
            "" \
            "-H 'Cookie: geoip_session=$session_cookie'" \
            "true"
    else
        ((TESTS_SKIPPED++))
        log "  ${YELLOW}⊘${NC} Session persistence test skipped (no cookie)"
    fi
fi

# --- Database URL Tests ---
if [[ "$CATEGORY" == "all" ]] || [[ "$CATEGORY" == "download" ]]; then
    log_category "Database URL Tests"
    
    # Get storage mode first
    storage_mode=$(curl -s "$API_URL/health" | LC_ALL=C sed -n 's/.*"storage_mode":"\([^"]*\)".*/\1/p')
    
    # Test that /auth returns proper URLs for databases
    log_verbose "  Testing URL format for $storage_mode storage mode"
    response=$(curl -s -X POST "$API_URL/auth" \
        -H "X-API-Key: $API_KEY" \
        -H "Content-Type: application/json" \
        -d '{"databases": ["GeoIP2-City.mmdb", "GeoIP2-Country.mmdb"]}')
    
    # Test 1: /auth returns URLs in correct format
    if [[ "$storage_mode" == "s3" ]]; then
        if echo "$response" | grep -qE 'https://.*\.s3\.amazonaws\.com/.*'; then
            ((TESTS_PASSED++))
            log "  ${GREEN}✓${NC} POST /auth returns S3 pre-signed URLs"
        else
            ((TESTS_FAILED++))
            log "  ${RED}✗${NC} POST /auth does not return S3 URLs"
        fi
    else
        if echo "$response" | grep -q '/download/'; then
            ((TESTS_PASSED++))
            log "  ${GREEN}✓${NC} POST /auth returns local download URLs"
        else
            ((TESTS_FAILED++))
            log "  ${RED}✗${NC} POST /auth does not return local URLs"
        fi
    fi
    
    # Test 2: All requested databases have URLs
    if echo "$response" | grep -q '"GeoIP2-City.mmdb"' && echo "$response" | grep -q '"GeoIP2-Country.mmdb"'; then
        ((TESTS_PASSED++))
        log "  ${GREEN}✓${NC} All requested databases have URLs"
    else
        ((TESTS_FAILED++))
        log "  ${RED}✗${NC} Not all requested databases have URLs"
        log_verbose "  Response: $response"
    fi
    
    # Test 3: Test URL accessibility (verify without full download)
    if [[ "$storage_mode" == "local" ]] || [[ "$storage_mode" == "hybrid" ]]; then
        # Extract a URL and test it
        url=$(echo "$response" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('GeoIP2-Country.mmdb', ''))" 2>/dev/null)
        if [[ -n "$url" ]]; then
            # For local URLs, test with Range header to avoid full download
            status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 -H "X-API-Key: $API_KEY" -H "Range: bytes=0-0" "$url" 2>/dev/null)
            if [[ "$status" == "200" ]]; then
                ((TESTS_PASSED++))
                log "  ${GREEN}✓${NC} Database URLs are accessible"
            else
                ((TESTS_FAILED++))
                log "  ${RED}✗${NC} Database URLs are not accessible (status: $status)"
            fi
        else
            ((TESTS_FAILED++))
            log "  ${RED}✗${NC} Could not extract URL from response"
        fi
        
        # Test 4: Direct download endpoint requires auth
        run_test "GET /download without auth" \
            "$API_URL/download/GeoIP2-City.mmdb" \
            "401" \
            "GET"
        
        # Test 5: Direct download endpoint handles invalid database
        run_test "GET /download invalid database" \
            "$API_URL/download/invalid-db.mmdb" \
            "404" \
            "GET" \
            "" \
            "-H 'X-API-Key: $API_KEY'"
    else
        # For S3 mode, test that the URL is accessible (but don't download)
        url=$(echo "$response" | python3 -c "import sys, json; data=json.load(sys.stdin); print(list(data.values())[0] if data else '')" 2>/dev/null)
        if [[ -n "$url" ]]; then
            # Test S3 URL with HEAD request
            status=$(curl -s -I -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null)
            if [[ "$status" == "200" ]]; then
                ((TESTS_PASSED++))
                log "  ${GREEN}✓${NC} S3 URLs are accessible"
            else
                ((TESTS_FAILED++))
                log "  ${RED}✗${NC} S3 URLs are not accessible (status: $status)"
            fi
        else
            ((TESTS_FAILED++))
            log "  ${RED}✗${NC} Could not extract S3 URL from response"
        fi
        
        # Skip direct download tests for S3 mode
        ((TESTS_SKIPPED+=2))
        log "  ${YELLOW}⊘${NC} Direct download tests skipped (S3 mode)"
    fi
    
    # Optional full download test (only if flag is set)
    if [[ "$TEST_DOWNLOADS" == true ]]; then
        log "  ${BLUE}Running full download test (this may take time)...${NC}"
        if [[ "$storage_mode" == "local" ]] || [[ "$storage_mode" == "hybrid" ]]; then
            run_test "GET /download full file (GeoIP2-Country.mmdb ~9MB)" \
                "$API_URL/download/GeoIP2-Country.mmdb" \
                "200" \
                "GET" \
                "" \
                "-H 'X-API-Key: $API_KEY' --max-time 30"
        else
            # For S3 mode, download from the actual S3 URL
            url=$(echo "$response" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('GeoIP2-Country.mmdb', ''))" 2>/dev/null)
            if [[ -n "$url" ]]; then
                status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 "$url" 2>/dev/null)
                if [[ "$status" == "200" ]]; then
                    ((TESTS_PASSED++))
                    log "  ${GREEN}✓${NC} Full S3 download successful"
                else
                    ((TESTS_FAILED++))
                    log "  ${RED}✗${NC} Full S3 download failed (status: $status)"
                fi
            fi
        fi
    else
        log_verbose "  Skipping full download test (use --test-downloads to enable)"
    fi
fi

# --- Installation Script Tests ---
if [[ "$CATEGORY" == "all" ]] || [[ "$CATEGORY" == "install" ]]; then
    log_category "Installation Script Tests"
    
    run_test "GET /install (basic)" \
        "$API_URL/install" \
        "200" \
        "GET"
    
    run_test "GET /install with cron" \
        "$API_URL/install?with_cron=true" \
        "200" \
        "GET"
    
    run_test "GET /install with custom directory" \
        "$API_URL/install?install_dir=/custom/path" \
        "200" \
        "GET"
fi

# --- Data Validation Tests ---
if [[ "$CATEGORY" == "all" ]] || [[ "$CATEGORY" == "validation" ]]; then
    log_category "Data Validation Tests"
    
    # Test specific field presence
    response=$(curl -s -H "X-API-Key: $API_KEY" "$API_URL/query?ips=8.8.8.8")
    
    # Check usage_type field
    if echo "$response" | grep -q '"usage_type":"DCH"'; then
        ((TESTS_PASSED++))
        log "  ${GREEN}✓${NC} usage_type field displays correctly (DCH)"
    else
        ((TESTS_FAILED++))
        log "  ${RED}✗${NC} usage_type field missing or incorrect"
    fi
    
    # Check ISP field
    if echo "$response" | grep -q '"isp":"Google'; then
        ((TESTS_PASSED++))
        log "  ${GREEN}✓${NC} ISP field displays correctly"
    else
        ((TESTS_FAILED++))
        log "  ${RED}✗${NC} ISP field missing or incorrect"
    fi
    
    # Test full_data mode database sources
    response=$(curl -s -H "X-API-Key: $API_KEY" "$API_URL/query?ips=8.8.8.8&full_data=true")
    
    if echo "$response" | grep -q '"_database_sources"'; then
        ((TESTS_PASSED++))
        log "  ${GREEN}✓${NC} Database sources included in full_data mode"
    else
        ((TESTS_FAILED++))
        log "  ${RED}✗${NC} Database sources missing in full_data mode"
    fi
    
    if echo "$response" | grep -q '"_databases_available"'; then
        ((TESTS_PASSED++))
        log "  ${GREEN}✓${NC} Available databases listed in full_data mode"
    else
        ((TESTS_FAILED++))
        log "  ${RED}✗${NC} Available databases missing in full_data mode"
    fi
    
    # Test consistency across multiple queries
    response1=$(curl -s -H "X-API-Key: $API_KEY" "$API_URL/query?ips=8.8.8.8" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['8.8.8.8'].get('country', ''))")
    sleep 0.5
    response2=$(curl -s -H "X-API-Key: $API_KEY" "$API_URL/query?ips=8.8.8.8" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['8.8.8.8'].get('country', ''))")
    
    if [[ "$response1" == "$response2" ]]; then
        ((TESTS_PASSED++))
        log "  ${GREEN}✓${NC} Query results are consistent"
    else
        ((TESTS_FAILED++))
        log "  ${RED}✗${NC} Query results are inconsistent"
    fi
fi

# --- Error Handling Tests ---
if [[ "$CATEGORY" == "all" ]] || [[ "$CATEGORY" == "error" ]]; then
    log_category "Error Handling Tests"
    
    run_test "POST /query (wrong method)" \
        "$API_URL/query" \
        "405" \
        "POST" \
        '{"ips": ["8.8.8.8"]}' \
        "-H 'X-API-Key: $API_KEY' -H 'Content-Type: application/json'"
    
    run_test "GET /nonexistent" \
        "$API_URL/nonexistent" \
        "404" \
        "GET" \
        "" \
        "-H 'X-API-Key: $API_KEY'"
    
    run_test "GET /query without IPs parameter" \
        "$API_URL/query" \
        "422" \
        "GET" \
        "" \
        "-H 'X-API-Key: $API_KEY'"
    
    run_test "POST /auth with wrong content-type" \
        "$API_URL/auth" \
        "422" \
        "POST" \
        '{"databases": "all"}' \
        "-H 'X-API-Key: $API_KEY' -H 'Content-Type: text/plain'"
fi

# --- Admin Tests ---
if [[ "$CATEGORY" == "all" ]] || [[ "$CATEGORY" == "admin" ]]; then
    log_category "Admin Tests"
    
    # Check if admin endpoints are enabled
    if [[ -n "$ADMIN_KEY" ]]; then
        run_test "POST /admin/reload-keys with valid admin key" \
            "$API_URL/admin/reload-keys" \
            "200" \
            "POST" \
            "" \
            "-H 'X-Admin-Key: $ADMIN_KEY'" \
            "true"
        
        run_test "POST /admin/reload-keys with invalid admin key" \
            "$API_URL/admin/reload-keys" \
            "401" \
            "POST" \
            "" \
            "-H 'X-Admin-Key: invalid-admin-key'"
    else
        ((TESTS_SKIPPED+=2))
        log "  ${YELLOW}⊘${NC} Admin tests skipped (no admin key configured)"
    fi
fi

# =========================================
# Summary
# =========================================

TEST_END_TIME=$(date +%s)
TOTAL_DURATION=$((TEST_END_TIME - TEST_START_TIME))
TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))

if [[ "$JSON_OUTPUT" == true ]]; then
    # Output JSON results
    echo "{"
    echo "  \"summary\": {"
    echo "    \"total\": $TOTAL_TESTS,"
    echo "    \"passed\": $TESTS_PASSED,"
    echo "    \"failed\": $TESTS_FAILED,"
    echo "    \"skipped\": $TESTS_SKIPPED,"
    echo "    \"duration_seconds\": $TOTAL_DURATION,"
    echo "    \"api_url\": \"$API_URL\""
    echo "  },"
    echo "  \"results\": ["
    
    # Output individual test results
    first=true
    for result in "${TEST_RESULTS[@]}"; do
        if [[ "$first" == true ]]; then
            first=false
        else
            echo ","
        fi
        echo -n "    $result"
    done
    
    echo ""
    echo "  ]"
    echo "}"
else
    log ""
    log "========================================="
    log "           Test Results Summary"
    log "========================================="
    log -e "Tests Passed:  ${GREEN}$TESTS_PASSED${NC}"
    log -e "Tests Failed:  ${RED}$TESTS_FAILED${NC}"
    
    if [[ $TESTS_SKIPPED -gt 0 ]]; then
        log -e "Tests Skipped: ${YELLOW}$TESTS_SKIPPED${NC}"
    fi
    
    log -e "Total Tests:   $TOTAL_TESTS"
    log -e "Duration:      ${TOTAL_DURATION}s"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        log ""
        log -e "${GREEN}✓ All tests passed successfully!${NC}"
        
        # Show UI access info
        log ""
        log "========================================="
        log "           Web UI Access"
        log "========================================="
        log "Open your browser and visit: $API_URL"
        log ""
        log "Available API keys for testing:"
        log "  • test-key-1"
        log "  • test-key-2"
        log "  • test-key-3"
        log ""
        log "Example queries:"
        log "  • $API_URL?ips=8.8.8.8"
        log "  • $API_URL?ips=1.1.1.1,8.8.8.8&full_data=true"
        
        exit 0
    else
        log ""
        log -e "${RED}✗ Some tests failed. Please review the results above.${NC}"
        
        if [[ "$VERBOSE" == false ]]; then
            log ""
            log "Run with -v flag for more detailed output:"
            log "  $0 -v"
        fi
        
        exit 1
    fi
fi