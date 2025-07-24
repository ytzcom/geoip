"""
Lambda function for GeoIP API key authentication and pre-signed URL generation.
Refactored to follow SOLID principles.
"""

import json
import os
import boto3
import hashlib
import time
import re
from abc import ABC, abstractmethod
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Any, Tuple, Union
from functools import wraps
from botocore.exceptions import ClientError, BotoCoreError

# Environment variables
S3_BUCKET = os.environ.get('S3_BUCKET', 'ytz-geoip')
DYNAMODB_TABLE = os.environ.get('DYNAMODB_TABLE', 'geoip-api-keys')
REQUEST_LOGS_TABLE = os.environ.get('REQUEST_LOGS_TABLE', 'geoip-request-logs')
URL_EXPIRY_SECONDS = int(os.environ.get('URL_EXPIRY_SECONDS', '3600'))
RATE_LIMIT_REQUESTS = int(os.environ.get('RATE_LIMIT_REQUESTS', '100'))
RATE_LIMIT_WINDOW_SECONDS = int(os.environ.get('RATE_LIMIT_WINDOW_SECONDS', '3600'))

# Security constants
MAX_REQUEST_SIZE = 1024 * 10  # 10KB max request size
MAX_DATABASE_NAME_LENGTH = 100
API_KEY_PATTERN = re.compile(r'^[a-zA-Z0-9_-]{20,64}$')
DATABASE_NAME_PATTERN = re.compile(r'^[a-zA-Z0-9_.-]+$')


def retry_with_backoff(max_retries: int = 3, initial_delay: float = 0.5, 
                      backoff_factor: float = 2.0, max_delay: float = 10.0):
    """
    Decorator for retrying functions with exponential backoff.
    
    Args:
        max_retries: Maximum number of retry attempts
        initial_delay: Initial delay between retries in seconds
        backoff_factor: Factor to multiply delay by after each retry
        max_delay: Maximum delay between retries in seconds
    """
    def decorator(func):
        @wraps(func)
        def wrapper(*args, **kwargs):
            delay = initial_delay
            last_exception = None
            
            for attempt in range(max_retries + 1):
                try:
                    return func(*args, **kwargs)
                except (ClientError, BotoCoreError) as e:
                    last_exception = e
                    if attempt < max_retries:
                        # Check if error is retryable
                        error_code = e.response.get('Error', {}).get('Code', '') if hasattr(e, 'response') else ''
                        if error_code in ['ThrottlingException', 'ProvisionedThroughputExceededException', 
                                        'RequestLimitExceeded', 'ServiceUnavailable', 'InternalServerError']:
                            print(f"Retryable error in {func.__name__}: {error_code}. Retrying in {delay}s...")
                            time.sleep(delay)
                            delay = min(delay * backoff_factor, max_delay)
                            continue
                    # Non-retryable error or max retries reached
                    raise
                except Exception as e:
                    # Non-AWS errors are not retried
                    raise
            
            # If we get here, we've exhausted retries
            if last_exception:
                raise last_exception
        
        return wrapper
    return decorator


class Validator:
    """Handles all validation logic (Single Responsibility)."""
    
    @staticmethod
    def validate_api_key_format(api_key: str) -> bool:
        """Validate API key format for security."""
        if not api_key or not isinstance(api_key, str):
            return False
        return bool(API_KEY_PATTERN.match(api_key))
    
    @staticmethod
    def validate_database_name(name: str) -> bool:
        """Validate database name for security (prevent path traversal)."""
        if not name or not isinstance(name, str):
            return False
        if len(name) > MAX_DATABASE_NAME_LENGTH:
            return False
        if '..' in name or '/' in name or '\\' in name:
            return False
        return bool(DATABASE_NAME_PATTERN.match(name))
    
    @staticmethod
    def validate_request_size(body: Optional[str]) -> bool:
        """Validate request size."""
        if not body:
            return True
        return len(body) <= MAX_REQUEST_SIZE
    
    @staticmethod
    def validate_http_method(method: str) -> bool:
        """Validate HTTP method."""
        return method in ['POST', 'OPTIONS']


class DatabaseRepository:
    """Manages database configurations (Single Responsibility)."""
    
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
    
    @classmethod
    def get_available_databases(cls) -> List[str]:
        """Get list of available database names."""
        return list(cls.AVAILABLE_DATABASES.keys())
    
    @classmethod
    def get_s3_key(cls, database_name: str) -> Optional[str]:
        """Get S3 key for a database."""
        return cls.AVAILABLE_DATABASES.get(database_name)
    
    @classmethod
    def sanitize_database_list(cls, databases: List[str], validator: Validator) -> List[str]:
        """Sanitize and validate database list."""
        if not isinstance(databases, list):
            return []
        
        # Limit number of databases to prevent abuse
        databases = databases[:20]
        
        # Validate each database name
        sanitized = []
        for db in databases:
            if isinstance(db, str) and validator.validate_database_name(db) and db in cls.AVAILABLE_DATABASES:
                sanitized.append(db)
        
        return sanitized


class ApiKeyService:
    """Handles API key operations (Single Responsibility)."""
    
    def __init__(self, dynamodb_table):
        self.table = dynamodb_table
    
    @staticmethod
    def hash_api_key(api_key: str) -> str:
        """Hash API key for storage."""
        return hashlib.sha256(api_key.encode()).hexdigest()
    
    @retry_with_backoff(max_retries=3)
    def validate_api_key(self, api_key: str) -> Optional[Dict]:
        """Validate API key and return key metadata if valid."""
        if not api_key:
            return None
        
        key_hash = self.hash_api_key(api_key)
        
        try:
            response = self.table.get_item(Key={'api_key_hash': key_hash})
            item = response.get('Item')
            
            if not item:
                return None
            
            # Check if key is active
            if not item.get('active', True):
                return None
            
            # Check expiration
            if 'expires_at' in item:
                expires_at = datetime.fromisoformat(item['expires_at'])
                if expires_at < datetime.utcnow():
                    return None
            
            return item
        except (ClientError, BotoCoreError) as e:
            print(f"AWS error validating API key: {str(e)}")
            raise  # Let retry decorator handle it
        except Exception as e:
            print(f"Error validating API key: {str(e)}")
            return None
    
    @retry_with_backoff(max_retries=2)  # Fewer retries for non-critical operations
    def update_usage_stats(self, api_key_hash: str) -> None:
        """Update usage statistics for the API key."""
        try:
            self.table.update_item(
                Key={'api_key_hash': api_key_hash},
                UpdateExpression='ADD request_count :inc SET last_used = :timestamp',
                ExpressionAttributeValues={
                    ':inc': 1,
                    ':timestamp': datetime.utcnow().isoformat()
                }
            )
        except (ClientError, BotoCoreError) as e:
            print(f"AWS error updating usage stats: {str(e)}")
            # Don't raise for non-critical operations
        except Exception as e:
            print(f"Error updating usage stats: {str(e)}")


class RateLimiter:
    """Handles rate limiting (Single Responsibility)."""
    
    def __init__(self, request_logs_table, rate_limit: int, window_seconds: int):
        self.table = request_logs_table
        self.rate_limit = rate_limit
        self.window_seconds = window_seconds
    
    @retry_with_backoff(max_retries=3)
    def check_rate_limit(self, api_key_hash: str) -> bool:
        """Check if API key has exceeded rate limit."""
        try:
            window_start = int(time.time()) - self.window_seconds
            
            response = self.table.query(
                KeyConditionExpression='api_key_hash = :key_hash AND request_time > :window_start',
                ExpressionAttributeValues={
                    ':key_hash': api_key_hash,
                    ':window_start': window_start
                },
                Select='COUNT'
            )
            
            request_count = response.get('Count', 0)
            return request_count < self.rate_limit
        except (ClientError, BotoCoreError) as e:
            print(f"AWS error checking rate limit: {str(e)}")
            # Allow request on error for availability
            return True
        except Exception as e:
            print(f"Error checking rate limit: {str(e)}")
            # Allow request on error
            return True
    
    @retry_with_backoff(max_retries=2)  # Fewer retries for non-critical operations
    def log_request(self, api_key_hash: str, databases: List[str]) -> None:
        """Log API request for analytics and rate limiting."""
        try:
            current_time = int(time.time())
            self.table.put_item(
                Item={
                    'api_key_hash': api_key_hash,
                    'request_time': current_time,
                    'databases': databases,
                    'timestamp': datetime.utcnow().isoformat(),
                    'ttl': current_time + (30 * 24 * 60 * 60)  # 30 days TTL
                }
            )
        except (ClientError, BotoCoreError) as e:
            print(f"AWS error logging request: {str(e)}")
            # Don't raise for non-critical operations
        except Exception as e:
            print(f"Error logging request: {str(e)}")


class UrlGenerator:
    """Handles pre-signed URL generation (Single Responsibility)."""
    
    def __init__(self, s3_client, bucket: str, expiry_seconds: int):
        self.s3_client = s3_client
        self.bucket = bucket
        self.expiry_seconds = expiry_seconds
    
    def generate_presigned_urls(self, databases: List[str], db_repository: DatabaseRepository) -> Dict[str, str]:
        """Generate pre-signed URLs for requested databases."""
        urls = {}
        
        for db_name in databases:
            s3_key = db_repository.get_s3_key(db_name)
            if s3_key:
                try:
                    url = self._generate_single_url(s3_key)
                    urls[db_name] = url
                except Exception as e:
                    print(f"Error generating URL for {db_name}: {str(e)}")
        
        return urls
    
    @retry_with_backoff(max_retries=3)
    def _generate_single_url(self, s3_key: str) -> str:
        """Generate a single pre-signed URL with retry logic."""
        return self.s3_client.generate_presigned_url(
            'get_object',
            Params={
                'Bucket': self.bucket,
                'Key': s3_key
            },
            ExpiresIn=self.expiry_seconds
        )


class ResponseBuilder:
    """Handles response generation (Single Responsibility)."""
    
    @staticmethod
    def generate_response(status_code: int, body: Any, headers: Optional[Dict] = None) -> Dict:
        """Generate API Gateway response with security headers."""
        response = {
            'statusCode': status_code,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Headers': 'Content-Type,X-API-Key',
                'Access-Control-Allow-Methods': 'POST,OPTIONS',
                'X-Content-Type-Options': 'nosniff',
                'X-Frame-Options': 'DENY',
                'X-XSS-Protection': '1; mode=block',
                'Strict-Transport-Security': 'max-age=31536000; includeSubDomains',
                'Cache-Control': 'no-store, no-cache, must-revalidate, private'
            },
            'body': json.dumps(body) if not isinstance(body, str) else body
        }
        
        if headers:
            response['headers'].update(headers)
        
        return response


class RequestHandler:
    """Main request handler that coordinates all services (Dependency Injection)."""
    
    def __init__(self, validator: Validator, api_key_service: ApiKeyService, 
                 rate_limiter: RateLimiter, url_generator: UrlGenerator,
                 db_repository: DatabaseRepository, response_builder: ResponseBuilder):
        self.validator = validator
        self.api_key_service = api_key_service
        self.rate_limiter = rate_limiter
        self.url_generator = url_generator
        self.db_repository = db_repository
        self.response_builder = response_builder
    
    def handle_request(self, event: Dict) -> Dict:
        """Handle the incoming request."""
        try:
            # Handle OPTIONS request for CORS
            if event.get('httpMethod') == 'OPTIONS':
                return self.response_builder.generate_response(200, '')
            
            # Validate HTTP method
            if event.get('httpMethod') != 'POST':
                return self.response_builder.generate_response(405, {'error': 'Method not allowed'})
            
            # Check request size
            if not self.validator.validate_request_size(event.get('body')):
                return self.response_builder.generate_response(413, {'error': 'Request too large'})
            
            # Extract and validate API key
            headers = event.get('headers', {})
            api_key = headers.get('X-API-Key') or headers.get('x-api-key')
            
            if not api_key:
                return self.response_builder.generate_response(401, {'error': 'Missing API key'})
            
            if not self.validator.validate_api_key_format(api_key):
                return self.response_builder.generate_response(401, {'error': 'Invalid API key format'})
            
            # Validate API key
            key_metadata = self.api_key_service.validate_api_key(api_key)
            if not key_metadata:
                return self.response_builder.generate_response(401, {'error': 'Invalid API key'})
            
            key_hash = self.api_key_service.hash_api_key(api_key)
            
            # Check rate limit
            if not self.rate_limiter.check_rate_limit(key_hash):
                return self.response_builder.generate_response(429, {
                    'error': 'Rate limit exceeded',
                    'retry_after': self.rate_limiter.window_seconds
                })
            
            # Parse and validate request body
            databases = self._parse_request_body(event.get('body', '{}'))
            if isinstance(databases, Dict):  # Error response
                return databases
            
            # Check allowed databases for this key
            databases = self._filter_allowed_databases(databases, key_metadata)
            if not databases:
                return self.response_builder.generate_response(403, {'error': 'No authorized databases requested'})
            
            # Generate pre-signed URLs
            urls = self.url_generator.generate_presigned_urls(databases, self.db_repository)
            
            if not urls:
                return self.response_builder.generate_response(500, {'error': 'Failed to generate download URLs'})
            
            # Log request and update stats
            self.rate_limiter.log_request(key_hash, list(urls.keys()))
            self.api_key_service.update_usage_stats(key_hash)
            
            # Return successful response
            return self.response_builder.generate_response(200, urls, {
                'X-RateLimit-Limit': str(self.rate_limiter.rate_limit),
                'X-RateLimit-Window': str(self.rate_limiter.window_seconds)
            })
            
        except Exception as e:
            print(f"Unexpected error in handle_request: {type(e).__name__}: {str(e)}")
            return self.response_builder.generate_response(500, {'error': 'Internal server error'})
    
    def _parse_request_body(self, body_str: str) -> Union[List[str], Dict]:
        """Parse request body and return databases list or error response."""
        try:
            if not body_str:
                body_str = '{}'
            body = json.loads(body_str)
            
            if not isinstance(body, dict):
                return self.response_builder.generate_response(400, {'error': 'Request body must be a JSON object'})
            
            requested_databases = body.get('databases', 'all')
            
            if requested_databases == 'all':
                return self.db_repository.get_available_databases()
            elif isinstance(requested_databases, list):
                databases = self.db_repository.sanitize_database_list(requested_databases, self.validator)
                if not databases and requested_databases:
                    return self.response_builder.generate_response(400, {'error': 'No valid databases in request'})
                return databases
            else:
                return self.response_builder.generate_response(400, {'error': 'databases parameter must be "all" or an array'})
                
        except (json.JSONDecodeError, ValueError):
            return self.response_builder.generate_response(400, {'error': 'Invalid JSON in request body'})
    
    def _filter_allowed_databases(self, databases: List[str], key_metadata: Dict) -> List[str]:
        """Filter databases based on API key permissions."""
        allowed_databases = key_metadata.get('allowed_databases', 'all')
        if allowed_databases != 'all' and isinstance(allowed_databases, list):
            return [db for db in databases if db in allowed_databases]
        return databases


# Initialize services (Dependency Injection Container)
def create_services():
    """Create and wire up all services."""
    # AWS clients
    s3_client = boto3.client('s3')
    dynamodb = boto3.resource('dynamodb')
    api_keys_table = dynamodb.Table(DYNAMODB_TABLE)
    request_logs_table = dynamodb.Table(REQUEST_LOGS_TABLE)
    
    # Services
    validator = Validator()
    api_key_service = ApiKeyService(api_keys_table)
    rate_limiter = RateLimiter(request_logs_table, RATE_LIMIT_REQUESTS, RATE_LIMIT_WINDOW_SECONDS)
    url_generator = UrlGenerator(s3_client, S3_BUCKET, URL_EXPIRY_SECONDS)
    db_repository = DatabaseRepository()
    response_builder = ResponseBuilder()
    
    # Main handler with dependency injection
    request_handler = RequestHandler(
        validator, api_key_service, rate_limiter, 
        url_generator, db_repository, response_builder
    )
    
    return request_handler


# Global handler instance
request_handler = create_services()


def lambda_handler(event: Dict, context: Any) -> Dict:
    """Lambda entry point."""
    return request_handler.handle_request(event)