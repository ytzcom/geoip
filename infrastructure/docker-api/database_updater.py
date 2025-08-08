"""
Database Updater Module

Downloads GeoIP databases from S3 using internal API methods.
Runs on a schedule (Monday 4am) to keep databases up-to-date.
"""

import asyncio
import aiohttp
import logging
import subprocess
from pathlib import Path
from typing import Dict, Optional

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
    
    async def download_database(self, session: aiohttp.ClientSession, 
                              database_name: str, s3_path: str) -> bool:
        """
        Download a single database from S3.
        
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
            logger.error(f"Failed to generate URL for {database_name}")
            return False
        
        # Prepare local path
        local_path = self.database_path / s3_path
        local_path.parent.mkdir(parents=True, exist_ok=True)
        
        # Create temp file for atomic replacement
        temp_path = local_path.with_suffix('.tmp')
        
        try:
            # Download file
            async with session.get(url) as response:
                if response.status == 200:
                    content = await response.read()
                    
                    # Write to temp file
                    with open(temp_path, 'wb') as f:
                        f.write(content)
                    
                    # Atomic replace
                    temp_path.replace(local_path)
                    
                    logger.info(f"Downloaded {database_name} ({len(content):,} bytes)")
                    return True
                else:
                    logger.error(f"Failed to download {database_name}: HTTP {response.status}")
                    return False
                    
        except Exception as e:
            logger.error(f"Error downloading {database_name}: {e}")
            if temp_path.exists():
                temp_path.unlink()
            return False
    
    async def update_all_databases(self) -> Dict[str, bool]:
        """
        Download all databases from S3.
        
        Returns:
            Dictionary mapping database names to success status
        """
        logger.info("Starting database update from S3...")
        
        # Create download tasks
        results = {}
        
        async with aiohttp.ClientSession() as session:
            tasks = []
            for db_name, s3_path in AVAILABLE_DATABASES.items():
                task = self.download_database(session, db_name, s3_path)
                tasks.append((db_name, task))
            
            # Execute downloads concurrently
            for db_name, task in tasks:
                results[db_name] = await task
        
        # Log summary
        successful = sum(1 for success in results.values() if success)
        total = len(results)
        logger.info(f"Database update complete: {successful}/{total} successful")
        
        # Validate databases if all downloaded successfully
        if successful == total:
            await self.validate_databases()
        
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
            # Remove .tmp files
            for tmp_file in self.database_path.rglob("*.tmp"):
                tmp_file.unlink()
                logger.debug(f"Removed temp file: {tmp_file}")
        except Exception as e:
            logger.warning(f"Error during cleanup: {e}")


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