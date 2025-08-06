"""
Configuration management for GeoIP Docker API.
"""

import os
from typing import List, Optional
from functools import lru_cache
from pydantic import Field
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Application settings with environment variable support."""
    
    # API Configuration
    api_keys: List[str] = Field(
        default_factory=lambda: os.environ.get('API_KEYS', '').split(',') if os.environ.get('API_KEYS') else [],
        description="Comma-separated list of allowed API keys"
    )
    
    # Storage Configuration
    storage_mode: str = Field(
        default="s3",
        description="Storage mode: s3, local, or hybrid"
    )
    
    # S3 Configuration (for s3 and hybrid modes)
    s3_bucket: str = Field(
        default="ytz-geoip",
        description="S3 bucket name for GeoIP databases"
    )
    aws_access_key_id: Optional[str] = Field(
        default=None,
        description="AWS Access Key ID (optional, uses IAM role if not provided)"
    )
    aws_secret_access_key: Optional[str] = Field(
        default=None,
        description="AWS Secret Access Key (optional, uses IAM role if not provided)"
    )
    aws_region: str = Field(
        default="us-east-1",
        description="AWS region"
    )
    url_expiry_seconds: int = Field(
        default=3600,
        description="Pre-signed URL expiry time in seconds"
    )
    
    # Local Storage Configuration (for local and hybrid modes)
    local_data_path: str = Field(
        default="/data",
        description="Path to local GeoIP database files"
    )
    
    # Server Configuration
    port: int = Field(
        default=8080,
        description="Server port"
    )
    workers: int = Field(
        default=1,
        description="Number of worker processes"
    )
    debug: bool = Field(
        default=False,
        description="Debug mode"
    )
    
    # Admin Configuration
    enable_admin: bool = Field(
        default=False,
        description="Enable admin endpoints"
    )
    admin_key: Optional[str] = Field(
        default=None,
        description="Admin API key for management endpoints"
    )
    
    # Logging Configuration
    log_level: str = Field(
        default="INFO",
        description="Logging level"
    )
    
    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"
        case_sensitive = False
        
        # Allow extra fields from environment
        extra = "ignore"


@lru_cache()
def get_settings(force_reload: bool = False) -> Settings:
    """
    Get cached settings instance.
    
    Args:
        force_reload: Force reload settings from environment
    
    Returns:
        Settings instance
    """
    if force_reload:
        get_settings.cache_clear()
    
    return Settings()


def validate_settings(settings: Settings) -> bool:
    """
    Validate settings configuration.
    
    Args:
        settings: Settings instance to validate
    
    Returns:
        True if valid, raises exception if invalid
    """
    # Check storage mode
    if settings.storage_mode not in ['s3', 'local', 'hybrid']:
        raise ValueError(f"Invalid storage_mode: {settings.storage_mode}")
    
    # Check API keys
    if not settings.api_keys:
        raise ValueError("No API keys configured")
    
    # Clean up API keys (remove empty strings)
    settings.api_keys = [k.strip() for k in settings.api_keys if k.strip()]
    
    if not settings.api_keys:
        raise ValueError("No valid API keys after cleanup")
    
    # Check S3 configuration if needed
    if settings.storage_mode in ['s3', 'hybrid']:
        if not settings.s3_bucket:
            raise ValueError("S3 bucket name required for s3/hybrid mode")
    
    # Check local path if needed
    if settings.storage_mode in ['local', 'hybrid']:
        if not settings.local_data_path:
            raise ValueError("Local data path required for local/hybrid mode")
    
    # Check admin configuration
    if settings.enable_admin and not settings.admin_key:
        raise ValueError("Admin key required when admin endpoints are enabled")
    
    return True


# Environment variable reference
ENVIRONMENT_VARIABLES = """
# API Configuration
API_KEYS=key1,key2,key3              # Comma-separated API keys

# Storage Configuration
STORAGE_MODE=s3                      # Options: s3, local, hybrid

# S3 Configuration (for s3/hybrid modes)
S3_BUCKET=ytz-geoip                  # S3 bucket name
AWS_ACCESS_KEY_ID=your-key-id        # Optional: AWS credentials
AWS_SECRET_ACCESS_KEY=your-secret    # Optional: AWS credentials
AWS_REGION=us-east-1                 # AWS region
URL_EXPIRY_SECONDS=3600              # Pre-signed URL expiry

# Local Storage (for local/hybrid modes)
LOCAL_DATA_PATH=/data                # Path to GeoIP files

# Server Configuration
PORT=8080                            # Server port
WORKERS=1                            # Worker processes
DEBUG=false                          # Debug mode

# Admin Configuration
ENABLE_ADMIN=false                   # Enable admin endpoints
ADMIN_KEY=your-admin-key            # Admin API key

# Logging
LOG_LEVEL=INFO                       # Log level
"""