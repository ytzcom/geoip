#!/usr/bin/env python3
"""
GeoIP Database Update Script

A cross-platform script to download GeoIP databases from an authenticated API.
Supports async downloads, retry logic, and various configuration options.

Usage:
    geoip-update [OPTIONS]
    geoip-update --config config.yaml
    geoip-update --quiet --log-file /var/log/geoip-update.log

Environment Variables:
    GEOIP_API_KEY       API key for authentication
    GEOIP_API_ENDPOINT  API endpoint URL
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
DEFAULT_ENDPOINT = "REPLACE_WITH_DEPLOYED_API_GATEWAY_URL/auth"  # e.g., https://xxx.execute-api.region.amazonaws.com/v1/auth
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
                    # MMDB files contain "MMDB" marker
                    f.seek(0)
                    content = f.read(min(size, 4096))
                    if b'MMDB' not in content:
                        logger.warning(f"MMDB file {db_name} may be invalid: missing MMDB marker")
                
                elif db_name.endswith('.BIN'):
                    # IP2Location binary files have specific structure
                    if len(header) < 4:
                        logger.error(f"Invalid BIN file {db_name}: too small")
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
@click.version_option(version='1.0.0')
def main(api_key, endpoint, directory, databases, config, log_file, retries, 
         timeout, concurrent, quiet, verbose, no_lock, no_ssl_verify):
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
    
    # Validate configuration
    if not config_obj.api_key:
        logger.error("API key not provided. Use --api-key or set GEOIP_API_KEY")
        sys.exit(1)
    
    if config_obj.api_endpoint == DEFAULT_ENDPOINT:
        logger.warning("="*60)
        logger.warning("IMPORTANT: Using placeholder API endpoint!")
        logger.warning("Please update with your actual API Gateway URL:")
        logger.warning("  1. Get URL from Terraform: terraform output api_gateway_url")
        logger.warning("  2. Run: ./update-api-endpoint.sh <API_URL>")
        logger.warning("="*60)
    
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