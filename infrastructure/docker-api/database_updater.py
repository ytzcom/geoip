"""
Database Updater Module

Downloads GeoIP databases from S3 using internal API methods.
Runs on a schedule (Monday 4am) to keep databases up-to-date.
"""

import asyncio
import aiohttp
import logging
import subprocess
import time
from pathlib import Path
from typing import Dict, Optional, Tuple

import boto3
from botocore.exceptions import ClientError

from config import get_settings

logger = logging.getLogger(__name__)

# Import the AVAILABLE_DATABASES mapping from app.py
AVAILABLE_DATABASES = {
    # MaxMind databases
    'GeoIP2-City.mmdb': 'raw/maxmind/GeoIP2-City.mmdb',
    'GeoIP2-Country.mmdb': 'raw/maxmind/GeoIP2-Country.mmdb',
    'GeoIP2-ISP.mmdb': 'raw/maxmind/GeoIP2-ISP.mmdb',
    'GeoIP2-Connection-Type.mmdb': 'raw/maxmind/GeoIP2-Connection-Type.mmdb',
    # IP2Location databases
    'IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN': 
        'raw/ip2location/IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN',
    'IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN': 
        'raw/ip2location/IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN',
    'IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN': 'raw/ip2location/IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN',
}


class DatabaseUpdater:
    """Handles downloading and updating GeoIP databases from S3."""
    
    def __init__(self):
        self.settings = get_settings()
        self.s3_client = self._init_s3_client()
        self.database_path = Path(self.settings.database_path)
        
        # Download configuration
        self.max_retries = 3
        self.retry_delay = 5  # seconds
        self.min_file_size = 1000  # bytes - files smaller than this are likely error pages
        self.download_timeout = 1800  # 30 minutes for large files
        self.connection_timeout = 60  # 1 minute for connection
        self.progress_log_interval = 10  # Log progress every 10 seconds for large files
        
    def _init_s3_client(self):
        """Initialize S3 client."""
        if self.settings.aws_access_key_id and self.settings.aws_secret_access_key:
            return boto3.client(
                's3',
                aws_access_key_id=self.settings.aws_access_key_id,
                aws_secret_access_key=self.settings.aws_secret_access_key,
                region_name=self.settings.aws_region
            )
        else:
            # Use default AWS credentials (IAM role, etc.)
            return boto3.client('s3', region_name=self.settings.aws_region)
    
    def generate_s3_presigned_url(self, database_name: str) -> Optional[str]:
        """
        Generate S3 pre-signed URL for database.
        This replicates the functionality from app.py.
        """
        if not self.s3_client or database_name not in AVAILABLE_DATABASES:
            return None
        
        s3_key = AVAILABLE_DATABASES[database_name]
        
        try:
            url = self.s3_client.generate_presigned_url(
                'get_object',
                Params={
                    'Bucket': self.settings.s3_bucket,
                    'Key': s3_key
                },
                ExpiresIn=3600  # 1 hour expiry for downloads
            )
            return url
        except Exception as e:
            logger.error(f"Error generating S3 URL for {database_name}: {str(e)}")
            return None
    
    async def download_database_with_progress(self, session: aiohttp.ClientSession, 
                                           database_name: str, s3_path: str, 
                                           url: str, attempt: int = 1) -> Tuple[bool, Optional[str]]:
        """
        Download a single database with progress tracking and error handling.
        
        Args:
            session: aiohttp session for downloads
            database_name: Name of the database
            s3_path: S3 path relative to bucket root
            url: Pre-signed S3 URL
            attempt: Current attempt number
            
        Returns:
            Tuple of (success: bool, error_message: Optional[str])
        """
        # Prepare local path
        local_path = self.database_path / s3_path
        local_path.parent.mkdir(parents=True, exist_ok=True)
        
        # Create temp file for atomic replacement
        temp_path = local_path.with_suffix(f'.tmp.{attempt}')
        
        start_time = time.time()
        last_progress_time = start_time
        
        try:
            logger.info(f"Starting download of {database_name} (attempt {attempt}/{self.max_retries})")
            
            timeout = aiohttp.ClientTimeout(
                total=self.download_timeout,
                connect=self.connection_timeout
            )
            
            async with session.get(url, timeout=timeout) as response:
                if response.status != 200:
                    error_msg = f"HTTP {response.status}: {response.reason}"
                    logger.warning(f"Download failed for {database_name}: {error_msg}")
                    return False, error_msg
                
                # Get content length for progress tracking
                content_length = response.headers.get('Content-Length')
                total_size = int(content_length) if content_length else None
                
                logger.info(f"Downloading {database_name}" + 
                           (f" ({total_size:,} bytes)" if total_size else " (size unknown)"))
                
                downloaded = 0
                chunk_size = 8192  # 8KB chunks
                
                with open(temp_path, 'wb') as f:
                    async for chunk in response.content.iter_chunked(chunk_size):
                        f.write(chunk)
                        downloaded += len(chunk)
                        
                        # Log progress for large files
                        current_time = time.time()
                        if current_time - last_progress_time >= self.progress_log_interval:
                            progress_info = f"Downloaded {downloaded:,} bytes"
                            if total_size:
                                percent = (downloaded / total_size) * 100
                                progress_info += f" ({percent:.1f}%)"
                            logger.info(f"{database_name}: {progress_info}")
                            last_progress_time = current_time
                
                # Validate file size
                if downloaded < self.min_file_size:
                    error_msg = f"File too small ({downloaded} bytes), likely an error page"
                    logger.error(f"Download validation failed for {database_name}: {error_msg}")
                    temp_path.unlink()
                    return False, error_msg
                
                # Atomic replace
                temp_path.replace(local_path)
                
                duration = time.time() - start_time
                speed_mbps = (downloaded / (1024 * 1024)) / duration if duration > 0 else 0
                
                logger.info(f"✅ Successfully downloaded {database_name}: " + 
                           f"{downloaded:,} bytes in {duration:.1f}s ({speed_mbps:.1f} MB/s)")
                return True, None
                
        except asyncio.TimeoutError:
            error_msg = f"Download timeout after {self.download_timeout}s"
            logger.warning(f"Timeout downloading {database_name}: {error_msg}")
        except aiohttp.ClientError as e:
            error_msg = f"Client error: {str(e)}"
            logger.warning(f"Client error downloading {database_name}: {error_msg}")
        except Exception as e:
            error_msg = f"Unexpected error: {str(e)}"
            logger.error(f"Error downloading {database_name}: {error_msg}")
        
        # Cleanup temp file on failure
        if temp_path.exists():
            temp_path.unlink()
        
        return False, error_msg

    async def download_database(self, session: aiohttp.ClientSession, 
                              database_name: str, s3_path: str) -> bool:
        """
        Download a single database with retry logic.
        
        Args:
            session: aiohttp session for downloads
            database_name: Name of the database
            s3_path: S3 path relative to bucket root
            
        Returns:
            True if successful, False otherwise
        """
        # Generate S3 pre-signed URL
        url = self.generate_s3_presigned_url(database_name)
        if not url:
            logger.error(f"❌ Failed to generate URL for {database_name}")
            return False
        
        # Try download with retries
        for attempt in range(1, self.max_retries + 1):
            success, error_msg = await self.download_database_with_progress(
                session, database_name, s3_path, url, attempt
            )
            
            if success:
                return True
            
            # If this wasn't the last attempt, wait before retrying
            if attempt < self.max_retries:
                retry_delay = self.retry_delay * (2 ** (attempt - 1))  # Exponential backoff
                logger.info(f"Retrying {database_name} in {retry_delay}s (attempt {attempt + 1}/{self.max_retries})")
                await asyncio.sleep(retry_delay)
            else:
                logger.error(f"❌ Failed to download {database_name} after {self.max_retries} attempts. Last error: {error_msg}")
        
        return False
    
    async def update_all_databases(self) -> Dict[str, bool]:
        """
        Download all databases from S3 concurrently.
        
        Returns:
            Dictionary mapping database names to success status
        """
        logger.info("🚀 Starting parallel database update from S3...")
        start_time = time.time()
        
        # Create aiohttp session with connection limits
        connector = aiohttp.TCPConnector(
            limit=10,  # Total connection limit
            limit_per_host=5,  # Per-host connection limit
            ttl_dns_cache=300,  # DNS cache TTL
            use_dns_cache=True,
        )
        
        timeout = aiohttp.ClientTimeout(
            total=self.download_timeout,
            connect=self.connection_timeout
        )
        
        results = {}
        
        async with aiohttp.ClientSession(connector=connector, timeout=timeout) as session:
            # Create tasks for all databases
            tasks = {}
            for db_name, s3_path in AVAILABLE_DATABASES.items():
                task = self.download_database(session, db_name, s3_path)
                tasks[db_name] = task
                logger.info(f"📋 Queued download task for {db_name}")
            
            logger.info(f"⚡ Starting {len(tasks)} parallel downloads...")
            
            # Execute all downloads concurrently with proper error handling
            download_results = await asyncio.gather(
                *tasks.values(), 
                return_exceptions=True
            )
            
            # Map results back to database names
            for db_name, result in zip(tasks.keys(), download_results):
                if isinstance(result, Exception):
                    logger.error(f"❌ Exception downloading {db_name}: {result}")
                    results[db_name] = False
                else:
                    results[db_name] = result
        
        # Log detailed summary
        successful = [name for name, success in results.items() if success]
        failed = [name for name, success in results.items() if not success]
        
        duration = time.time() - start_time
        logger.info(f"🏁 Database update complete in {duration:.1f}s: {len(successful)}/{len(results)} successful")
        
        if successful:
            logger.info(f"✅ Successfully downloaded: {', '.join(successful)}")
        
        if failed:
            logger.error(f"❌ Failed downloads: {', '.join(failed)}")
        
        # Validate databases if all downloaded successfully
        if len(successful) == len(results):
            logger.info("🔍 All downloads successful, running validation...")
            await self.validate_databases()
        else:
            logger.warning(f"⚠️  Skipping validation due to {len(failed)} failed downloads")
        
        return results
    
    async def validate_databases(self) -> bool:
        """
        Validate downloaded databases using the existing validation script.
        
        Returns:
            True if validation successful, False otherwise
        """
        validation_script = Path("/app/scripts/validate-databases.py")
        
        # Check if validation script exists
        if not validation_script.exists():
            logger.warning("Validation script not found, skipping validation")
            return True
        
        try:
            # Run validation script
            result = subprocess.run(
                ['python', str(validation_script), str(self.database_path / 'raw')],
                capture_output=True,
                text=True,
                timeout=60
            )
            
            if result.returncode == 0:
                logger.info("Database validation successful")
                logger.debug(f"Validation output: {result.stdout}")
                return True
            else:
                logger.error(f"Database validation failed: {result.stderr}")
                return False
                
        except subprocess.TimeoutExpired:
            logger.error("Database validation timed out")
            return False
        except Exception as e:
            logger.error(f"Error running validation: {e}")
            return False
    
    async def cleanup_old_files(self):
        """Remove any temporary or old database files."""
        try:
            # Remove .tmp and .tmp.* files (from retry attempts)
            temp_patterns = ["*.tmp", "*.tmp.*"]
            cleaned_count = 0
            
            for pattern in temp_patterns:
                for tmp_file in self.database_path.rglob(pattern):
                    try:
                        tmp_file.unlink()
                        logger.debug(f"🗑️  Removed temp file: {tmp_file}")
                        cleaned_count += 1
                    except Exception as e:
                        logger.warning(f"Failed to remove temp file {tmp_file}: {e}")
            
            if cleaned_count > 0:
                logger.info(f"🧹 Cleaned up {cleaned_count} temporary files")
            
        except Exception as e:
            logger.warning(f"Error during cleanup: {e}")
    
    def get_download_status(self) -> Dict[str, Dict[str, any]]:
        """
        Get current status of all databases for debugging.
        
        Returns:
            Dictionary with database status information
        """
        status = {}
        
        for db_name, s3_path in AVAILABLE_DATABASES.items():
            local_path = self.database_path / s3_path
            
            db_status = {
                'name': db_name,
                's3_path': s3_path,
                'local_path': str(local_path),
                'exists': local_path.exists(),
                'size_bytes': 0,
                'size_mb': 0,
                'last_modified': None,
                'temp_files': []
            }
            
            if local_path.exists():
                stat = local_path.stat()
                db_status['size_bytes'] = stat.st_size
                db_status['size_mb'] = round(stat.st_size / (1024 * 1024), 2)
                db_status['last_modified'] = stat.st_mtime
            
            # Check for temp files
            temp_pattern = local_path.with_suffix('.tmp*')
            for tmp_file in local_path.parent.glob(f"{local_path.stem}.tmp*"):
                db_status['temp_files'].append(str(tmp_file))
            
            status[db_name] = db_status
            
        return status


async def update_databases():
    """
    Main function to update databases from S3.
    Called by the scheduler in app.py.
    """
    updater = DatabaseUpdater()
    
    try:
        # Update all databases
        results = await updater.update_all_databases()
        
        # Cleanup
        await updater.cleanup_old_files()
        
        # Clear cache after successful update
        try:
            from cache import get_cache
            cache = get_cache()
            await cache.clear_all()
            logger.info("Cache cleared after database update")
        except Exception as e:
            logger.warning(f"Failed to clear cache: {e}")
        
        # Reload databases in reader if it exists
        try:
            from geoip_reader import GeoIPReader
            # Only reload if the reader singleton has been initialized
            if hasattr(GeoIPReader, '_instance') and GeoIPReader._instance is not None:
                reader = GeoIPReader()
                reader.reload_databases()
                logger.info("GeoIP reader reloaded with new databases")
            else:
                logger.info("GeoIP reader not yet initialized, will load databases on first use")
        except Exception as e:
            logger.warning(f"Failed to reload GeoIP reader: {e}")
        
        return results
        
    except Exception as e:
        logger.error(f"Database update failed: {e}")
        return {}


# For testing
if __name__ == "__main__":
    import asyncio
    
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )
    
    asyncio.run(update_databases())