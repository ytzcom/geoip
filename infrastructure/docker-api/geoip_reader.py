"""
GeoIP Database Reader Module

Provides unified interface for reading MaxMind and IP2Location databases
and querying IP addresses for geographic and network information.
"""

import os
import logging
from pathlib import Path
from typing import Dict, Any, Optional
import geoip2.database
from IP2Location import IP2Location
from IP2Proxy import IP2Proxy

logger = logging.getLogger(__name__)


class GeoIPReader:
    """Singleton class for reading GeoIP databases and querying IP addresses."""
    
    _instance = None
    
    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._initialized = False
        return cls._instance
    
    def __init__(self):
        """Initialize the GeoIP reader with all available databases."""
        if self._initialized:
            return
            
        self.databases = {}
        self.database_path = Path(os.environ.get('DATABASE_PATH', '/data/databases'))
        self._load_databases()
        self._initialized = True
    
    def _load_databases(self):
        """Load all available GeoIP databases."""
        # MaxMind databases
        maxmind_path = self.database_path / 'raw' / 'maxmind'
        if maxmind_path.exists():
            self._load_maxmind_databases(maxmind_path)
        
        # IP2Location databases
        ip2location_path = self.database_path / 'raw' / 'ip2location'
        if ip2location_path.exists():
            self._load_ip2location_databases(ip2location_path)
    
    def _load_maxmind_databases(self, path: Path):
        """Load MaxMind MMDB databases."""
        mmdb_files = {
            'city': 'GeoIP2-City.mmdb',
            'country': 'GeoIP2-Country.mmdb',
            'isp': 'GeoIP2-ISP.mmdb',
            'connection_type': 'GeoIP2-Connection-Type.mmdb'
        }
        
        for db_type, filename in mmdb_files.items():
            db_path = path / filename
            if db_path.exists():
                try:
                    self.databases[f'maxmind_{db_type}'] = geoip2.database.Reader(str(db_path))
                    logger.info(f"Loaded MaxMind {db_type} database: {filename}")
                except Exception as e:
                    logger.error(f"Failed to load MaxMind {db_type} database: {e}")
    
    def _load_ip2location_databases(self, path: Path):
        """Load IP2Location BIN databases."""
        # IP2Location DB23 IPv4
        db23_path = path / 'IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN'
        if db23_path.exists():
            try:
                self.databases['ip2location_v4'] = IP2Location()
                self.databases['ip2location_v4'].open(str(db23_path))
                logger.info("Loaded IP2Location IPv4 database")
            except Exception as e:
                logger.error(f"Failed to load IP2Location IPv4 database: {e}")
        
        # IP2Location DB23 IPv6
        db23_ipv6_path = path / 'IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN'
        if db23_ipv6_path.exists():
            try:
                self.databases['ip2location_v6'] = IP2Location()
                self.databases['ip2location_v6'].open(str(db23_ipv6_path))
                logger.info("Loaded IP2Location IPv6 database")
            except Exception as e:
                logger.error(f"Failed to load IP2Location IPv6 database: {e}")
        
        # IP2Proxy database
        proxy_path = path / 'IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN'
        if proxy_path.exists():
            try:
                self.databases['ip2proxy'] = IP2Proxy()
                # IP2Proxy.open() returns None on success, not 0
                result = self.databases['ip2proxy'].open(str(proxy_path))
                if result is None or result == 0:
                    logger.info("Loaded IP2Proxy database")
                else:
                    logger.error(f"Failed to open IP2Proxy database: error code {result}")
                    del self.databases['ip2proxy']
            except Exception as e:
                logger.error(f"Failed to load IP2Proxy database: {e}")
    
    async def query(self, ip: str, full_data: bool = False) -> Optional[Dict[str, Any]]:
        """
        Query an IP address against all available databases.
        
        Args:
            ip: IP address to query
            full_data: Whether to return all available data or just essential fields
            
        Returns:
            Dictionary containing GeoIP data or None if not found
        """
        result = {}
        
        # In full_data mode, track which databases provided which data
        if full_data:
            database_sources = {}
        
        # Query MaxMind databases
        maxmind_data = self._query_maxmind(ip)
        if maxmind_data:
            result.update(maxmind_data)
            if full_data:
                # Track which fields came from MaxMind
                for key in maxmind_data:
                    database_sources[key] = 'MaxMind'
        
        # Query IP2Location databases
        ip2location_data = self._query_ip2location(ip)
        if ip2location_data:
            # For overlapping fields, track both sources
            if full_data:
                for key in ip2location_data:
                    if key in result and key in database_sources:
                        # Field exists from another source, combine sources
                        if isinstance(database_sources[key], str):
                            database_sources[key] = [database_sources[key]]
                        if 'IP2Location' not in database_sources[key]:
                            database_sources[key].append('IP2Location')
                    else:
                        database_sources[key] = 'IP2Location'
            result.update(ip2location_data)
        
        # Query IP2Proxy database
        proxy_data = self._query_ip2proxy(ip)
        if proxy_data:
            if full_data:
                for key in proxy_data:
                    database_sources[key] = 'IP2Proxy'
            result.update(proxy_data)
        
        if not result:
            return None
        
        # Add database sources to result in full_data mode
        if full_data:
            result['_database_sources'] = database_sources
            # Also add which databases were queried
            result['_databases_available'] = self.get_database_status()
        
        # Filter to essential fields if not full_data
        if not full_data:
            essential_fields = {
                'country', 'country_code', 'city', 'region', 'postal_code',
                'isp', 'organization', 'timezone', 'is_proxy', 'is_vpn',
                'usage_type', 'latitude', 'longitude'
            }
            result = {k: v for k, v in result.items() if k in essential_fields}
        
        return result
    
    def _query_maxmind(self, ip: str) -> Dict[str, Any]:
        """Query MaxMind databases for IP information."""
        data = {}
        
        # City database (most comprehensive)
        if 'maxmind_city' in self.databases:
            try:
                response = self.databases['maxmind_city'].city(ip)
                data.update({
                    'country': response.country.name,
                    'country_code': response.country.iso_code,
                    'city': response.city.name,
                    'region': response.subdivisions.most_specific.name if response.subdivisions else None,
                    'postal_code': response.postal.code,
                    'latitude': response.location.latitude,
                    'longitude': response.location.longitude,
                    'timezone': response.location.time_zone,
                    'accuracy_radius': response.location.accuracy_radius,
                })
            except Exception as e:
                logger.debug(f"MaxMind city query failed for {ip}: {e}")
        
        # Country database (fallback if city not available)
        elif 'maxmind_country' in self.databases:
            try:
                response = self.databases['maxmind_country'].country(ip)
                data.update({
                    'country': response.country.name,
                    'country_code': response.country.iso_code,
                })
            except Exception as e:
                logger.debug(f"MaxMind country query failed for {ip}: {e}")
        
        # ISP database
        if 'maxmind_isp' in self.databases:
            try:
                response = self.databases['maxmind_isp'].isp(ip)
                data.update({
                    'isp': response.isp,
                    'organization': response.organization,
                    'autonomous_system_number': response.autonomous_system_number,
                    'autonomous_system_organization': response.autonomous_system_organization,
                })
            except Exception as e:
                logger.debug(f"MaxMind ISP query failed for {ip}: {e}")
        
        # Connection Type database
        if 'maxmind_connection_type' in self.databases:
            try:
                response = self.databases['maxmind_connection_type'].connection_type(ip)
                data['connection_type'] = response.connection_type
            except Exception as e:
                logger.debug(f"MaxMind connection type query failed for {ip}: {e}")
        
        return data
    
    def _query_ip2location(self, ip: str) -> Dict[str, Any]:
        """Query IP2Location databases for IP information."""
        data = {}
        
        # Determine which database to use based on IP version
        if ':' in ip and 'ip2location_v6' in self.databases:
            db = self.databases['ip2location_v6']
        elif 'ip2location_v4' in self.databases:
            db = self.databases['ip2location_v4']
        else:
            return data
        
        try:
            rec = db.get_all(ip)
            if rec:
                data.update({
                    'country': rec.country_long,
                    'country_code': rec.country_short,
                    'region': rec.region,
                    'city': rec.city,
                    'latitude': rec.latitude,
                    'longitude': rec.longitude,
                    'isp': rec.isp,
                    'domain': rec.domain,
                    'usage_type': rec.usage_type,  # Fixed field name
                    'mobile_brand': rec.mobile_brand,  # Fixed field name
                })
                # Remove None values and '-' placeholders
                data = {k: v for k, v in data.items() if v is not None and v != '-'}
        except Exception as e:
            logger.debug(f"IP2Location query failed for {ip}: {e}")
        
        return data
    
    def _query_ip2proxy(self, ip: str) -> Dict[str, Any]:
        """Query IP2Proxy database for proxy detection."""
        data = {}
        
        if 'ip2proxy' not in self.databases:
            return data
        
        try:
            result = self.databases['ip2proxy'].get_all(ip)
            if result:
                # Check if it's a proxy
                is_proxy = result['is_proxy'] > 0
                data['is_proxy'] = is_proxy
                
                if is_proxy:
                    proxy_types = {
                        'VPN': False,
                        'TOR': False,
                        'DCH': False,  # Data Center/Hosting
                        'PUB': False,  # Public Proxy
                        'WEB': False,  # Web Proxy
                        'SES': False,  # Search Engine Spider
                    }
                    
                    proxy_type = result.get('proxy_type', '-')
                    if proxy_type != '-':
                        for ptype in proxy_type.split(','):
                            ptype = ptype.strip()
                            if ptype in proxy_types:
                                proxy_types[ptype] = True
                    
                    data['is_vpn'] = proxy_types['VPN']
                    data['is_tor'] = proxy_types['TOR']
                    data['is_datacenter'] = proxy_types['DCH']
                    data['proxy_type'] = proxy_type
                else:
                    data['is_vpn'] = False
                    data['is_tor'] = False
                    data['is_datacenter'] = False
        except Exception as e:
            logger.debug(f"IP2Proxy query failed for {ip}: {e}")
        
        return data
    
    def reload_databases(self):
        """Reload all databases (useful after updates)."""
        logger.info("Reloading GeoIP databases...")
        
        # Close existing database connections
        for db_name, db in self.databases.items():
            if hasattr(db, 'close'):
                try:
                    db.close()
                except:
                    pass
        
        # Clear and reload
        self.databases.clear()
        self._load_databases()
        logger.info("GeoIP databases reloaded")
    
    def get_database_status(self) -> Dict[str, bool]:
        """Get the status of loaded databases."""
        return {
            'maxmind_city': 'maxmind_city' in self.databases,
            'maxmind_country': 'maxmind_country' in self.databases,
            'maxmind_isp': 'maxmind_isp' in self.databases,
            'maxmind_connection_type': 'maxmind_connection_type' in self.databases,
            'ip2location_v4': 'ip2location_v4' in self.databases,
            'ip2location_v6': 'ip2location_v6' in self.databases,
            'ip2proxy': 'ip2proxy' in self.databases,
        }