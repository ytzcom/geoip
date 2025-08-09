"""
Lambda function for GeoIP API key authentication and pre-signed URL generation.
Uses environment variables for API key storage - perfect for internal use.
"""

import json
import os
import boto3
from typing import Dict, List, Optional, Any

# Environment variables
S3_BUCKET = os.environ.get('S3_BUCKET', 'ytz-geoip')
ALLOWED_API_KEYS = os.environ.get('ALLOWED_API_KEYS', '').split(',')
URL_EXPIRY_SECONDS = int(os.environ.get('URL_EXPIRY_SECONDS', '3600'))

# S3 client
s3_client = boto3.client('s3')

# Available databases mapping
AVAILABLE_DATABASES = {
    # MaxMind databases
    'GeoIP2-City.mmdb': 'raw/maxmind/GeoIP2-City.mmdb',
    'GeoIP2-Country.mmdb': 'raw/maxmind/GeoIP2-Country.mmdb',
    'GeoIP2-ISP.mmdb': 'raw/maxmind/GeoIP2-ISP.mmdb',
    'GeoIP2-Connection-Type.mmdb': 'raw/maxmind/GeoIP2-Connection-Type.mmdb',
    # IP2Location databases
    'IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN': 'raw/ip2location/IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN',
    'IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN': 'raw/ip2location/IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN',
    'IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN': 'raw/ip2location/IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN',
}


def generate_response(status_code: int, body: Any) -> Dict:
    """Generate API Gateway response."""
    return {
        'statusCode': status_code,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Headers': 'Content-Type,X-API-Key',
            'Access-Control-Allow-Methods': 'POST,OPTIONS',
        },
        'body': json.dumps(body) if not isinstance(body, str) else body
    }


def validate_api_key(api_key: str) -> bool:
    """Validate API key against allowed list."""
    if not api_key or not ALLOWED_API_KEYS:
        return False
    
    # Clean up the allowed keys list (remove empty strings)
    valid_keys = [k.strip() for k in ALLOWED_API_KEYS if k.strip()]
    
    return api_key in valid_keys


def generate_presigned_urls(databases: List[str]) -> Dict[str, str]:
    """Generate pre-signed URLs for requested databases."""
    urls = {}
    
    for db_name in databases:
        s3_key = AVAILABLE_DATABASES.get(db_name)
        if s3_key:
            try:
                url = s3_client.generate_presigned_url(
                    'get_object',
                    Params={
                        'Bucket': S3_BUCKET,
                        'Key': s3_key
                    },
                    ExpiresIn=URL_EXPIRY_SECONDS
                )
                urls[db_name] = url
            except Exception as e:
                print(f"Error generating URL for {db_name}: {str(e)}")
    
    return urls


def lambda_handler(event: Dict, context: Any) -> Dict:
    """Lambda entry point."""
    try:
        # Handle OPTIONS request for CORS
        if event.get('httpMethod') == 'OPTIONS':
            return generate_response(200, '')
        
        # Validate HTTP method
        if event.get('httpMethod') != 'POST':
            return generate_response(405, {'error': 'Method not allowed'})
        
        # Extract and validate API key
        headers = event.get('headers', {})
        api_key = headers.get('X-API-Key') or headers.get('x-api-key')
        
        if not api_key:
            return generate_response(401, {'error': 'Missing API key'})
        
        if not validate_api_key(api_key):
            return generate_response(401, {'error': 'Invalid API key'})
        
        # Parse request body
        try:
            body = json.loads(event.get('body', '{}'))
        except json.JSONDecodeError:
            return generate_response(400, {'error': 'Invalid JSON in request body'})
        
        # Determine which databases to return
        requested_databases = body.get('databases', 'all')
        
        if requested_databases == 'all':
            databases = list(AVAILABLE_DATABASES.keys())
        elif isinstance(requested_databases, list):
            # Validate requested databases exist
            databases = [db for db in requested_databases if db in AVAILABLE_DATABASES]
            if not databases and requested_databases:
                return generate_response(400, {'error': 'No valid databases in request'})
        else:
            return generate_response(400, {'error': 'databases parameter must be "all" or an array'})
        
        # Generate pre-signed URLs
        urls = generate_presigned_urls(databases)
        
        if not urls:
            return generate_response(500, {'error': 'Failed to generate download URLs'})
        
        # Return successful response
        return generate_response(200, urls)
        
    except Exception as e:
        print(f"Unexpected error: {str(e)}")
        return generate_response(500, {'error': 'Internal server error'})