#!/usr/bin/env python3
"""
GeoIP Database Update Script

A cross-platform script to download GeoIP databases from an authenticated API.
Supports async downloads, retry logic, and various configuration options.

Usage:
    geoip-update [OPTIONS]
    geoip-update --config config.yaml
    geoip-update --quiet --log-file /var/log/geoip-update.log

Examples:
    # Default (production endpoint)
    geoip-update --api-key your-key
    
    # Local testing with Docker API
    geoip-update --api-key test-key-1 --endpoint http://localhost:8080/auth
    
    # Using environment variables
    export GEOIP_API_ENDPOINT=http://localhost:8080/auth
    geoip-update --api-key test-key-1
    
    # Custom endpoint
    geoip-update --api-key key --endpoint https://custom.api.example.com/auth

Environment Variables:
    GEOIP_API_KEY       API key for authentication
    GEOIP_API_ENDPOINT  API endpoint URL (default: https://geoipdb.net/auth)
    GEOIP_TARGET_DIR    Default target directory
"""

import asyncio
import aiohttp
import click
import json
import logging
import os
import sys
import tempfile
import time
import shutil
import signal
import hashlib
import platform
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple
from dataclasses import dataclass, field
from concurrent.futures import ThreadPoolExecutor

# Optional imports for database validation
try:
    import geoip2.database
    HAS_GEOIP2 = True
except ImportError:
    HAS_GEOIP2 = False

try:
    from IP2Location import IP2Location
    HAS_IP2LOCATION = True
except ImportError:
    HAS_IP2LOCATION = False

try:
    from IP2Proxy import IP2Proxy
    HAS_IP2PROXY = True
except ImportError:
    HAS_IP2PROXY = False

__all__ = ['Config', 'LockFile', 'GeoIPUpdater', 'main']

try:
    import yaml
    HAS_YAML = True
except ImportError:
    HAS_YAML = False

# Platform-specific imports for file locking
if platform.system() == 'Windows':
    import msvcrt
    fcntl = None
else:
    import fcntl
    msvcrt = None

# Constants
DEFAULT_ENDPOINT = "https://geoipdb.net/auth"
DEFAULT_TARGET_DIR = "./geoip"
DEFAULT_RETRIES = 3
DEFAULT_TIMEOUT = 300
DEFAULT_MAX_CONCURRENT = 4
LOCK_FILE = Path(tempfile.gettempdir()) / "geoip-update.lock"

# Available databases for validation
AVAILABLE_DATABASES = {
    'GeoIP2-City.mmdb',
    'GeoIP2-Country.mmdb',
    'GeoIP2-ISP.mmdb',
    'GeoIP2-Connection-Type.mmdb',
    'IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN',
    'IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN',
    'IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN',
}

# Configure logging
logger = logging.getLogger(__name__)


@dataclass
class Config:
    """Configuration for the GeoIP updater."""
    api_key: str = ""
    api_endpoint: str = DEFAULT_ENDPOINT
    target_dir: Path = Path(DEFAULT_TARGET_DIR)
    databases: List[str] = field(default_factory=lambda: ["all"])
    log_file: Optional[Path] = None
    max_retries: int = DEFAULT_RETRIES
    timeout: int = DEFAULT_TIMEOUT
    max_concurrent: int = DEFAULT_MAX_CONCURRENT
    quiet: bool = False
    verbose: bool = False
    no_lock: bool = False
    verify_ssl: bool = True
    user_agent: str = "GeoIP-Update-Python/1.0"


class LockFile:
    """Cross-platform lock file implementation."""
    
    def __init__(self, path: Path, no_lock: bool = False):
        self.path = path
        self.no_lock = no_lock
        self.fd = None
        self.locked = False
    
    def acquire(self) -> bool:
        """Acquire the lock.
        
        Returns:
            bool: True if lock acquired successfully, False otherwise.
        """
        if self.no_lock:
            return True
        
        try:
            # Try to read existing lock
            if self.path.exists():
                try:
                    with open(self.path, 'r') as f:
                        pid = int(f.read().strip())
                    
                    # Check if process is still running
                    if self._is_process_running(pid):
                        logger.error(f"Another instance is already running (PID: {pid})")
                        return False
                    else:
                        logger.warning(f"Removing stale lock file (PID: {pid})")
                        self.path.unlink()
                except (ValueError, IOError):
                    pass
            
            # Create new lock
            self.fd = open(self.path, 'w')
            
            if platform.system() == 'Windows':
                # Windows file locking
                if msvcrt:
                    msvcrt.locking(self.fd.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                # Unix file locking
                if fcntl:
                    fcntl.flock(self.fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            
            # Write PID
            self.fd.write(str(os.getpid()))
            self.fd.flush()
            self.locked = True
            logger.debug(f"Acquired lock (PID: {os.getpid()})")
            return True
            
        except (IOError, OSError) as e:
            logger.error(f"Failed to acquire lock: {e}")
            if self.fd:
                self.fd.close()
            return False
    
    def release(self):
        """Release the lock."""
        if self.no_lock or not self.locked:
            return
        
        try:
            if self.fd:
                if platform.system() == 'Windows':
                    if msvcrt:
                        msvcrt.locking(self.fd.fileno(), msvcrt.LK_UNLCK, 1)
                else:
                    if fcntl:
                        fcntl.flock(self.fd.fileno(), fcntl.LOCK_UN)
                self.fd.close()
            
            if self.path.exists():
                self.path.unlink()
            
            logger.debug("Released lock")
        except Exception as e:
            logger.warning(f"Error releasing lock: {e}")
        finally:
            self.locked = False
    
    def _is_process_running(self, pid: int) -> bool:
        """Check if a process with given PID is running.
        
        Args:
            pid: Process ID to check.
            
        Returns:
            bool: True if process is running, False otherwise.
        """
        if platform.system() == 'Windows':
            import subprocess
            try:
                result = subprocess.run(['tasklist', '/FI', f'PID eq {pid}'], 
                                      capture_output=True, text=True, check=False)
                return str(pid) in result.stdout
            except:
                return False
        else:
            try:
                os.kill(pid, 0)
                return True
            except OSError:
                return False
    
    def __enter__(self):
        if not self.acquire():
            sys.exit(1)
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        self.release()


class GeoIPUpdater:
    """Main class for updating GeoIP databases."""
    
    def __init__(self, config: Config):
        self.config = config
        self.session: Optional[aiohttp.ClientSession] = None
        self.temp_dir: Optional[Path] = None
        self.downloaded_files: Set[str] = set()
        self.failed_files: Set[str] = set()
        
        # Clean and normalize the API endpoint
        self._normalize_endpoint()
    
    def _normalize_endpoint(self):
        """Normalize the API endpoint URL, auto-appending /auth if needed."""
        # Remove trailing slashes and whitespace
        endpoint = self.config.api_endpoint.rstrip('/ \t\n\r')
        
        # Auto-append /auth if it's the base geoipdb.net domain
        if endpoint in ('https://geoipdb.net', 'http://geoipdb.net'):
            endpoint = f"{endpoint}/auth"
            logger.info(f"Appended /auth to endpoint: {endpoint}")
        elif not endpoint.endswith('/auth'):
            # For other endpoints, just log what we're using
            logger.debug(f"Using endpoint as provided: {endpoint}")
        
        self.config.api_endpoint = endpoint
    
    async def __aenter__(self):
        """Async context manager entry."""
        timeout = aiohttp.ClientTimeout(total=self.config.timeout)
        connector = aiohttp.TCPConnector(
            limit=self.config.max_concurrent,
            force_close=True,
            ssl=self.config.verify_ssl
        )
        self.session = aiohttp.ClientSession(
            timeout=timeout,
            connector=connector,
            headers={'User-Agent': self.config.user_agent}
        )
        
        # Create temporary directory
        self.temp_dir = Path(tempfile.mkdtemp(prefix="geoip-update-"))
        logger.debug(f"Created temporary directory: {self.temp_dir}")
        
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb):
        """Async context manager exit."""
        if self.session:
            await self.session.close()
        
        # Cleanup temporary directory
        if self.temp_dir and self.temp_dir.exists():
            try:
                shutil.rmtree(self.temp_dir)
                logger.debug("Removed temporary directory")
            except Exception as e:
                logger.warning(f"Failed to remove temporary directory: {e}")
    
    async def authenticate(self) -> Dict[str, str]:
        """Authenticate with the API and get download URLs.
        
        Returns:
            Dict[str, str]: Dictionary mapping database names to download URLs.
            
        Raises:
            Exception: If authentication fails after all retries.
        """
        logger.info("Authenticating with API endpoint")
        
        headers = {
            'X-API-Key': self.config.api_key,
            'Content-Type': 'application/json'
        }
        
        body = {
            'databases': 'all' if 'all' in self.config.databases else self.config.databases
        }
        
        for attempt in range(self.config.max_retries):
            try:
                async with self.session.post(
                    self.config.api_endpoint,
                    headers=headers,
                    json=body
                ) as response:
                    if response.status == 200:
                        data = await response.json()
                        logger.info(f"Received URLs for {len(data)} databases")
                        return data
                    elif response.status == 401:
                        raise Exception("Authentication failed (401) - check your API key")
                    elif response.status == 403:
                        raise Exception("Access forbidden (403) - check your permissions")
                    elif response.status == 429:
                        retry_after = int(response.headers.get('Retry-After', 60))
                        logger.warning(f"Rate limited (429) - waiting {retry_after} seconds")
                        await asyncio.sleep(retry_after)
                    else:
                        text = await response.text()
                        logger.warning(f"API error {response.status}: {text}")
                
            except aiohttp.ClientError as e:
                logger.warning(f"Network error on attempt {attempt + 1}: {e}")
            
            if attempt < self.config.max_retries - 1:
                delay = min(2 ** attempt, 60)
                logger.info(f"Retrying in {delay} seconds...")
                await asyncio.sleep(delay)
        
        raise Exception(f"Failed to authenticate after {self.config.max_retries} attempts")
    
    def validate_database_file(self, file_path: Path, db_name: str) -> bool:
        """Validate downloaded database file."""
        if not file_path.exists():
            return False
        
        # Check file size
        size = file_path.stat().st_size
        if size == 0:
            logger.error(f"Database file {db_name} is empty")
            return False
        
        # Basic validation based on file type
        try:
            with open(file_path, 'rb') as f:
                header = f.read(16)
                
                if db_name.endswith('.mmdb'):
                    # MaxMind database should start with specific bytes
                    if len(header) < 16:
                        logger.error(f"Invalid MMDB file {db_name}: too small")
                        return False
                    # MMDB files have metadata at the end with marker \xab\xcd\xef followed by MaxMind.com
                    # Read the last 100KB to find the metadata section
                    read_size = min(size, 100000)
                    f.seek(max(0, size - read_size))
                    content = f.read(read_size)
                    if b'\xab\xcd\xefMaxMind.com' not in content:
                        logger.warning(f"MMDB file {db_name} may be invalid: missing MaxMind metadata marker")
                
                elif db_name.endswith('.BIN'):
                    # IP2Location binary files have specific structure
                    if len(header) < 4:
                        logger.error(f"Invalid BIN file {db_name}: too small")
                        return False
                    
                    # Try to validate with IP2Location/IP2Proxy libraries if available
                    if 'PROXY' in db_name.upper() or 'PX' in db_name.upper():
                        if HAS_IP2PROXY:
                            try:
                                db = IP2Proxy(str(file_path))
                                # Try a simple query to validate
                                result = db.get_all('8.8.8.8')
                                logger.debug(f"IP2Proxy validation successful for {db_name}")
                            except Exception as e:
                                logger.warning(f"IP2Proxy validation failed for {db_name}: {e}")
                                return False
                    elif HAS_IP2LOCATION:
                        try:
                            db = IP2Location(str(file_path))
                            # Try a simple query to validate
                            result = db.get_all('8.8.8.8')
                            logger.debug(f"IP2Location validation successful for {db_name}")
                        except Exception as e:
                            logger.warning(f"IP2Location validation failed for {db_name}: {e}")
                            return False
                
                # Additional validation: Try to open with geoip2 if it's an MMDB file
                if db_name.endswith('.mmdb') and HAS_GEOIP2:
                    try:
                        reader = geoip2.database.Reader(str(file_path))
                        # Try a simple lookup to ensure it works
                        try:
                            if 'City' in db_name:
                                reader.city('8.8.8.8')
                            elif 'Country' in db_name:
                                reader.country('8.8.8.8')
                            elif 'ISP' in db_name:
                                reader.isp('8.8.8.8')
                            else:
                                # Generic test
                                reader.country('8.8.8.8')
                        except:
                            pass  # Some lookups may fail for certain IPs, but file is valid
                        reader.close()
                        logger.debug(f"GeoIP2 validation successful for {db_name}")
                    except Exception as e:
                        logger.warning(f"GeoIP2 validation failed for {db_name}: {e}")
                        return False
            
            return True
            
        except Exception as e:
            logger.error(f"Error validating {db_name}: {e}")
            return False
    
    async def download_database(self, name: str, url: str) -> bool:
        """Download a single database file."""
        temp_file = self.temp_dir / name
        target_file = self.config.target_dir / name
        
        logger.info(f"Downloading: {name}")
        
        for attempt in range(self.config.max_retries):
            try:
                async with self.session.get(url) as response:
                    if response.status == 200:
                        # Download to temporary file
                        with open(temp_file, 'wb') as f:
                            async for chunk in response.content.iter_chunked(8192):
                                f.write(chunk)
                        
                        # Validate file
                        if not self.validate_database_file(temp_file, name):
                            raise Exception("Downloaded file failed validation")
                        
                        file_size = temp_file.stat().st_size
                        
                        # Move to target location (atomic on same filesystem)
                        shutil.move(str(temp_file), str(target_file))
                        
                        logger.info(f"Successfully downloaded: {name} ({file_size:,} bytes)")
                        self.downloaded_files.add(name)
                        return True
                    else:
                        logger.warning(f"Download failed for {name}: HTTP {response.status}")
                
            except Exception as e:
                logger.warning(f"Error downloading {name} on attempt {attempt + 1}: {e}")
            
            if attempt < self.config.max_retries - 1:
                delay = min(2 ** attempt, 60)
                await asyncio.sleep(delay)
        
        logger.error(f"Failed to download {name} after {self.config.max_retries} attempts")
        self.failed_files.add(name)
        return False
    
    async def update_databases(self):
        """Main update process."""
        logger.info("Starting GeoIP database update")
        logger.info(f"Target directory: {self.config.target_dir}")
        
        # Ensure target directory exists
        self.config.target_dir.mkdir(parents=True, exist_ok=True)
        
        # Get download URLs
        try:
            urls = await self.authenticate()
        except Exception as e:
            logger.error(f"Authentication failed: {e}")
            raise
        
        if not urls:
            logger.warning("No databases to download")
            return
        
        # Download databases concurrently
        tasks = []
        semaphore = asyncio.Semaphore(self.config.max_concurrent)
        
        async def download_with_semaphore(name: str, url: str):
            async with semaphore:
                return await self.download_database(name, url)
        
        for name, url in urls.items():
            task = asyncio.create_task(download_with_semaphore(name, url))
            tasks.append(task)
        
        # Wait for all downloads
        await asyncio.gather(*tasks, return_exceptions=True)
        
        # Summary
        total = len(urls)
        success = len(self.downloaded_files)
        failed = len(self.failed_files)
        
        logger.info(f"Download summary: {success} successful, {failed} failed out of {total}")
        
        if failed > 0:
            logger.error(f"Failed databases: {', '.join(sorted(self.failed_files))}")
            raise Exception(f"Failed to download {failed} databases")


def setup_logging(config: Config):
    """Setup logging configuration."""
    handlers = []
    
    # Console handler
    if not config.quiet:
        console_handler = logging.StreamHandler()
        console_handler.setFormatter(
            logging.Formatter('%(asctime)s [%(levelname)s] %(message)s')
        )
        handlers.append(console_handler)
    
    # File handler
    if config.log_file:
        config.log_file.parent.mkdir(parents=True, exist_ok=True)
        file_handler = logging.FileHandler(config.log_file)
        file_handler.setFormatter(
            logging.Formatter('%(asctime)s [%(levelname)s] %(message)s')
        )
        handlers.append(file_handler)
    
    # Configure logger
    logging.basicConfig(
        level=logging.DEBUG if config.verbose else logging.INFO,
        handlers=handlers
    )


def load_config_file(config_path: Path) -> dict:
    """Load configuration from YAML file."""
    if not HAS_YAML:
        logger.error("PyYAML is required for config file support. Install with: pip install pyyaml")
        sys.exit(1)
    
    try:
        with open(config_path, 'r') as f:
            return yaml.safe_load(f) or {}
    except yaml.YAMLError as e:
        logger.error(f"Invalid YAML in config file: {e}")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Failed to load config file: {e}")
        sys.exit(1)


async def fetch_databases_info(config: Config) -> Optional[dict]:
    """Fetch database information from the /databases endpoint."""
    databases_endpoint = config.api_endpoint.replace('/auth', '/databases')
    
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(
                databases_endpoint,
                timeout=aiohttp.ClientTimeout(total=10),
                ssl=config.verify_ssl
            ) as response:
                if response.status == 200:
                    return await response.json()
                else:
                    logger.debug(f"Database discovery endpoint returned {response.status}")
                    return None
    except Exception as e:
        logger.debug(f"Database discovery not available: {e}")
        return None


async def list_databases_command(config: Config):
    """List all available databases and their aliases."""
    db_info = await fetch_databases_info(config)
    
    if db_info:
        print("Available GeoIP Databases:")
        print("=========================")
        print()
        print(f"Total databases: {db_info['total']}")
        print()
        
        # MaxMind databases
        maxmind = db_info['providers']['maxmind']
        print(f"MaxMind databases ({maxmind['count']}):")
        for db in maxmind['databases']:
            aliases = ', '.join(db['aliases'])
            print(f"  • {db['name']} (aliases: {aliases})")
        print()
        
        # IP2Location databases
        ip2location = db_info['providers']['ip2location']
        print(f"IP2Location databases ({ip2location['count']}):")
        for db in ip2location['databases']:
            aliases = ', '.join(db['aliases'])
            print(f"  • {db['name']} (aliases: {aliases})")
        print()
        
        print("Bulk Selection Options:")
        print("  • all - All databases")
        print("  • maxmind/all - All MaxMind databases")
        print("  • ip2location/all - All IP2Location databases")
        print()
        print("Usage Notes:")
        print("  • Database names are case-insensitive")
        print("  • File extensions are optional in most cases")
        print("  • Use short aliases for easier selection")
    else:
        print("Database discovery not available.")
        print("Using legacy database list:")
        print("  • GeoIP2-City.mmdb")
        print("  • GeoIP2-Country.mmdb")
        print("  • GeoIP2-ISP.mmdb")
        print("  • GeoIP2-Connection-Type.mmdb")
        print("  • IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN")
        print("  • IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN")
        print("  • IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN")


async def show_examples_command(config: Config):
    """Show usage examples for database selection."""
    db_info = await fetch_databases_info(config)
    
    print("Database Selection Examples:")
    print("===========================")
    print()
    
    if db_info and 'examples' in db_info:
        examples = db_info['examples']
        
        print("Single Database Selection:")
        for example in examples.get('single_database', []):
            print(f'  geoip-update --api-key YOUR_KEY --databases "{example}"')
        print()
        
        print("Multiple Database Selection:")
        for example in examples.get('multiple_databases', []):
            dbs = ','.join(example)
            print(f'  geoip-update --api-key YOUR_KEY --databases "{dbs}"')
        print()
        
        print("Bulk Selection:")
        for example in examples.get('bulk_selection', []):
            print(f'  geoip-update --api-key YOUR_KEY --databases "{example}"')
        print()
    
    print("Common Examples:")
    print("  # Download all databases")
    print("  geoip-update --api-key YOUR_KEY")
    print()
    print("  # Download specific databases using aliases")
    print('  geoip-update --api-key YOUR_KEY --databases "city" --databases "country"')
    print()
    print("  # Download all MaxMind databases")
    print('  geoip-update --api-key YOUR_KEY --databases "maxmind/all"')
    print()
    print("  # Case insensitive selection")
    print('  geoip-update --api-key YOUR_KEY --databases "CITY" --databases "ISP"')
    print()
    print("  # Local testing with Docker API")
    print('  geoip-update --api-key test-key-1 --endpoint http://localhost:8080/auth --databases "city"')


def validate_database_files_command(config: Config):
    """Validate existing database files."""
    import glob
    
    setup_logging(config)
    logger = logging.getLogger('geoip-update')
    logger.info("Validating database files...")
    
    # Check if directory exists
    if not config.target_dir.exists():
        logger.error(f"Directory does not exist: {config.target_dir}")
        sys.exit(1)
    
    total_files = 0
    valid_files = 0
    invalid_files = 0
    has_errors = False
    
    # Validate MMDB files
    mmdb_files = glob.glob(str(config.target_dir / "*.mmdb"))
    for file_path in mmdb_files:
        total_files += 1
        file_path = Path(file_path)
        basename = file_path.name
        
        # Check file size
        try:
            size = file_path.stat().st_size
            if size < 1000:
                logger.error(f"  ❌ {basename} - File too small ({size} bytes)")
                invalid_files += 1
                has_errors = True
                continue
        except Exception as e:
            logger.error(f"  ❌ {basename} - Cannot read file: {e}")
            invalid_files += 1
            has_errors = True
            continue
        
        # Validate MMDB format
        try:
            # Check for MaxMind.com marker in last 100KB
            with open(file_path, 'rb') as f:
                f.seek(max(0, size - 100000))
                content = f.read()
                if b'\xab\xcd\xefMaxMind.com' not in content:
                    logger.error(f"  ❌ {basename} - Invalid MMDB format (missing MaxMind metadata)")
                    invalid_files += 1
                    has_errors = True
                else:
                    size_mb = size // (1024 * 1024)
                    logger.info(f"  ✅ {basename} ({size_mb}MB) - Valid MMDB format")
                    valid_files += 1
        except Exception as e:
            logger.error(f"  ❌ {basename} - Error validating: {e}")
            invalid_files += 1
            has_errors = True
    
    # Validate BIN files
    bin_files = glob.glob(str(config.target_dir / "*.BIN"))
    for file_path in bin_files:
        total_files += 1
        file_path = Path(file_path)
        basename = file_path.name
        
        # Check file size
        try:
            size = file_path.stat().st_size
            if size < 1000:
                logger.error(f"  ❌ {basename} - File too small ({size} bytes)")
                invalid_files += 1
                has_errors = True
                continue
        except Exception as e:
            logger.error(f"  ❌ {basename} - Cannot read file: {e}")
            invalid_files += 1
            has_errors = True
            continue
        
        # Basic BIN validation - check if it's binary data
        try:
            with open(file_path, 'rb') as f:
                sample = f.read(100)
                # Check for non-printable characters (binary data)
                is_binary = any(b < 0x20 and b not in (0x09, 0x0A, 0x0D) for b in sample)
                
                if is_binary:
                    size_mb = size // (1024 * 1024)
                    logger.info(f"  ✅ {basename} ({size_mb}MB) - Valid BIN format")
                    valid_files += 1
                else:
                    logger.warning(f"  ⚠️  {basename} - Could not verify BIN format (may still be valid)")
        except Exception as e:
            logger.error(f"  ❌ {basename} - Error validating: {e}")
            invalid_files += 1
            has_errors = True
    
    # Summary
    logger.info("\nValidation Summary:")
    logger.info(f"  Total files: {total_files}")
    logger.info(f"  Valid files: {valid_files}")
    logger.info(f"  Invalid files: {invalid_files}")
    
    if total_files == 0:
        logger.error("\n✗ No database files found!")
        sys.exit(1)
    
    if has_errors:
        logger.error("\n✗ Validation FAILED - some databases are invalid!")
        sys.exit(1)
    else:
        logger.info("\n✓ Validation PASSED - all databases are valid!")
        sys.exit(0)


async def check_database_names_command(config: Config):
    """Validate database names with API without downloading."""
    if not config.databases or config.databases == ['all']:
        print("✓ Database selection 'all' is valid")
        return
    
    # Prepare the request
    data = {"databases": config.databases}
    
    try:
        async with aiohttp.ClientSession() as session:
            async with session.post(
                config.api_endpoint,
                json=data,
                headers={'X-API-Key': config.api_key},
                timeout=aiohttp.ClientTimeout(total=10),
                ssl=config.verify_ssl
            ) as response:
                if response.status == 200:
                    result = await response.json()
                    db_count = len(result)
                    print("✓ All database names are valid")
                    print(f"✓ Resolved to {db_count} database(s)")
                    
                    # Show resolved databases
                    for db_name in sorted(result.keys()):
                        print(f"  → {db_name}")
                else:
                    error_text = await response.text()
                    try:
                        error_json = json.loads(error_text)
                        error_msg = error_json.get('detail', error_text)
                    except:
                        error_msg = error_text
                    print(f"✗ Validation failed: {error_msg}")
                    sys.exit(1)
    except Exception as e:
        print(f"✗ Validation failed: {e}")
        sys.exit(1)


@click.command()
@click.option('-k', '--api-key', help='API key (or use GEOIP_API_KEY env var)')
@click.option('-e', '--endpoint', help='API endpoint URL')
@click.option('-d', '--directory', type=click.Path(), help='Target directory (default: ./geoip)')
@click.option('-b', '--databases', multiple=True, help='Database names or "all" (default: all)')
@click.option('-c', '--config', type=click.Path(exists=True), help='Configuration file (YAML)')
@click.option('-l', '--log-file', type=click.Path(), help='Log file path')
@click.option('-r', '--retries', type=int, help='Max retries (default: 3)')
@click.option('-t', '--timeout', type=int, help='Download timeout in seconds (default: 300)')
@click.option('--concurrent', type=int, help='Max concurrent downloads (default: 4)')
@click.option('-q', '--quiet', is_flag=True, help='Quiet mode (no output except errors)')
@click.option('-v', '--verbose', is_flag=True, help='Verbose output')
@click.option('--no-lock', is_flag=True, help="Don't use lock file")
@click.option('--no-ssl-verify', is_flag=True, help="Don't verify SSL certificates (not recommended)")
@click.option('--list-databases', is_flag=True, help='List all available databases and aliases')
@click.option('--show-examples', is_flag=True, help='Show usage examples for database selection')
@click.option('--check-names', is_flag=True, help='Validate database names with API without downloading')
@click.option('--validate-only', is_flag=True, help='Validate existing database files')
@click.version_option(version='1.0.0')
def main(api_key, endpoint, directory, databases, config, log_file, retries, 
         timeout, concurrent, quiet, verbose, no_lock, no_ssl_verify,
         list_databases, show_examples, check_names, validate_only):
    """Download GeoIP databases from authenticated API."""
    
    # Create default config
    config_obj = Config()
    
    # Load from config file if specified
    if config:
        config_path = Path(config)
        data = load_config_file(config_path)
        
        config_obj.api_key = data.get('api_key', config_obj.api_key)
        config_obj.api_endpoint = data.get('api_endpoint', config_obj.api_endpoint)
        config_obj.target_dir = Path(data.get('target_dir', config_obj.target_dir))
        config_obj.databases = data.get('databases', config_obj.databases)
        config_obj.max_retries = data.get('max_retries', config_obj.max_retries)
        config_obj.timeout = data.get('timeout', config_obj.timeout)
        config_obj.max_concurrent = data.get('max_concurrent', config_obj.max_concurrent)
        config_obj.verify_ssl = data.get('verify_ssl', config_obj.verify_ssl)
        config_obj.user_agent = data.get('user_agent', config_obj.user_agent)
    
    # Override with environment variables
    config_obj.api_key = os.environ.get('GEOIP_API_KEY', config_obj.api_key)
    config_obj.api_endpoint = os.environ.get('GEOIP_API_ENDPOINT', config_obj.api_endpoint)
    if 'GEOIP_TARGET_DIR' in os.environ:
        config_obj.target_dir = Path(os.environ['GEOIP_TARGET_DIR'])
    
    # Override with command line arguments
    if api_key:
        config_obj.api_key = api_key
    if endpoint:
        config_obj.api_endpoint = endpoint
    if directory:
        config_obj.target_dir = Path(directory)
    if databases:
        config_obj.databases = list(databases)
    if log_file:
        config_obj.log_file = Path(log_file)
    if retries is not None:
        config_obj.max_retries = retries
    if timeout is not None:
        config_obj.timeout = timeout
    if concurrent is not None:
        config_obj.max_concurrent = concurrent
    
    config_obj.quiet = quiet
    config_obj.verbose = verbose
    config_obj.no_lock = no_lock
    config_obj.verify_ssl = not no_ssl_verify
    
    # Setup logging
    setup_logging(config_obj)
    
    # Handle special commands that don't require full configuration
    if list_databases:
        asyncio.run(list_databases_command(config_obj))
        return
    
    if show_examples:
        asyncio.run(show_examples_command(config_obj))
        return
    
    if check_names:
        if not config_obj.api_key:
            logger.error("API key required for name checking. Use --api-key or set GEOIP_API_KEY")
            sys.exit(1)
        asyncio.run(check_database_names_command(config_obj))
        return
    
    if validate_only:
        # Validate existing database files
        validate_database_files_command(config_obj)
        return
    
    # Validate configuration
    if not config_obj.api_key:
        logger.error("API key not provided. Use --api-key or set GEOIP_API_KEY")
        sys.exit(1)
    
    # Log endpoint being used (helpful for debugging)
    if config_obj.api_endpoint.startswith('http://localhost') or config_obj.api_endpoint.startswith('http://127.0.0.1'):
        logger.info(f"Using local API endpoint: {config_obj.api_endpoint}")
    elif config_obj.api_endpoint == DEFAULT_ENDPOINT:
        logger.info(f"Using production API endpoint: {config_obj.api_endpoint}")
    else:
        logger.info(f"Using custom API endpoint: {config_obj.api_endpoint}")
    
    # Signal handler for cleanup
    def signal_handler(signum, frame):
        logger.error("Interrupted by signal")
        sys.exit(1)
    
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    
    # Run update
    exit_code = 0
    
    try:
        with LockFile(LOCK_FILE, config_obj.no_lock):
            # Run async update
            async def run():
                async with GeoIPUpdater(config_obj) as updater:
                    await updater.update_databases()
            
            asyncio.run(run())
            logger.info("GeoIP update completed successfully")
            
    except KeyboardInterrupt:
        logger.error("Interrupted by user")
        exit_code = 1
    except Exception as e:
        logger.error(f"Update failed: {e}")
        exit_code = 1
    
    sys.exit(exit_code)


if __name__ == '__main__':
    main()