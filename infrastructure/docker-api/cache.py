"""
Caching Layer for GeoIP Query Results

Provides multiple cache backend implementations with automatic
invalidation on Monday 4am (database update time).
"""

import json
import logging
import sqlite3
import time
from abc import ABC, abstractmethod
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Dict, Optional

import redis
from config import get_settings

logger = logging.getLogger(__name__)


def get_next_monday_4am_timestamp() -> int:
    """Calculate the timestamp for next Monday at 4am."""
    now = datetime.now()
    days_until_monday = (7 - now.weekday()) % 7
    if days_until_monday == 0 and now.hour >= 4:
        # It's Monday after 4am, get next Monday
        days_until_monday = 7
    
    next_monday = now + timedelta(days=days_until_monday)
    next_monday_4am = next_monday.replace(hour=4, minute=0, second=0, microsecond=0)
    
    return int(next_monday_4am.timestamp())


class CacheInterface(ABC):
    """Abstract base class for cache implementations."""
    
    @abstractmethod
    async def get(self, key: str) -> Optional[Dict[str, Any]]:
        """Get a value from the cache."""
        pass
    
    @abstractmethod
    async def set(self, key: str, value: Dict[str, Any]) -> None:
        """Set a value in the cache."""
        pass
    
    @abstractmethod
    async def clear_all(self) -> None:
        """Clear all cache entries."""
        pass
    
    @abstractmethod
    async def close(self) -> None:
        """Close any open connections."""
        pass


class MemoryCache(CacheInterface):
    """In-memory cache with automatic TTL."""
    
    def __init__(self, ttl: Optional[int] = None):
        self.cache: Dict[str, tuple[Dict[str, Any], int]] = {}
        self.ttl = ttl
        logger.info("Initialized memory cache")
    
    def _get_expiry(self) -> int:
        """Get expiry timestamp."""
        if self.ttl:
            return int(time.time()) + self.ttl
        else:
            # Default to next Monday 4am
            return get_next_monday_4am_timestamp()
    
    async def get(self, key: str) -> Optional[Dict[str, Any]]:
        """Get a value from memory cache."""
        if key in self.cache:
            value, expiry = self.cache[key]
            if time.time() < expiry:
                return value
            else:
                # Expired, remove it
                del self.cache[key]
        return None
    
    async def set(self, key: str, value: Dict[str, Any]) -> None:
        """Set a value in memory cache."""
        expiry = self._get_expiry()
        self.cache[key] = (value, expiry)
    
    async def clear_all(self) -> None:
        """Clear all cache entries."""
        self.cache.clear()
        logger.info("Cleared memory cache")
    
    async def close(self) -> None:
        """No cleanup needed for memory cache."""
        pass


class RedisCache(CacheInterface):
    """Redis cache backend."""
    
    def __init__(self, redis_url: str, ttl: Optional[int] = None):
        self.redis_client = redis.from_url(redis_url, decode_responses=True)
        self.ttl = ttl
        logger.info(f"Initialized Redis cache: {redis_url}")
    
    def _get_ttl(self) -> int:
        """Get TTL in seconds."""
        if self.ttl:
            return self.ttl
        else:
            # Calculate seconds until next Monday 4am
            return get_next_monday_4am_timestamp() - int(time.time())
    
    async def get(self, key: str) -> Optional[Dict[str, Any]]:
        """Get a value from Redis cache."""
        try:
            value = self.redis_client.get(f"geoip:{key}")
            if value:
                return json.loads(value)
        except Exception as e:
            logger.error(f"Redis get error: {e}")
        return None
    
    async def set(self, key: str, value: Dict[str, Any]) -> None:
        """Set a value in Redis cache."""
        try:
            ttl = self._get_ttl()
            self.redis_client.setex(
                f"geoip:{key}",
                ttl,
                json.dumps(value)
            )
        except Exception as e:
            logger.error(f"Redis set error: {e}")
    
    async def clear_all(self) -> None:
        """Clear all GeoIP cache entries."""
        try:
            pattern = "geoip:*"
            cursor = 0
            while True:
                cursor, keys = self.redis_client.scan(cursor, match=pattern, count=100)
                if keys:
                    self.redis_client.delete(*keys)
                if cursor == 0:
                    break
            logger.info("Cleared Redis cache")
        except Exception as e:
            logger.error(f"Redis clear error: {e}")
    
    async def close(self) -> None:
        """Close Redis connection."""
        try:
            self.redis_client.close()
        except:
            pass


class SQLiteCache(CacheInterface):
    """SQLite cache backend for persistence."""
    
    def __init__(self, db_path: str = "/data/cache.db", ttl: Optional[int] = None):
        self.db_path = db_path
        self.ttl = ttl
        self._init_db()
        logger.info(f"Initialized SQLite cache: {db_path}")
    
    def _init_db(self):
        """Initialize SQLite database."""
        Path(self.db_path).parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS geoip_cache (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                expiry INTEGER NOT NULL
            )
        """)
        cursor.execute("CREATE INDEX IF NOT EXISTS idx_expiry ON geoip_cache(expiry)")
        conn.commit()
        conn.close()
    
    def _get_expiry(self) -> int:
        """Get expiry timestamp."""
        if self.ttl:
            return int(time.time()) + self.ttl
        else:
            return get_next_monday_4am_timestamp()
    
    async def get(self, key: str) -> Optional[Dict[str, Any]]:
        """Get a value from SQLite cache."""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        try:
            cursor.execute(
                "SELECT value, expiry FROM geoip_cache WHERE key = ?",
                (key,)
            )
            row = cursor.fetchone()
            
            if row:
                value_json, expiry = row
                if time.time() < expiry:
                    return json.loads(value_json)
                else:
                    # Expired, remove it
                    cursor.execute("DELETE FROM geoip_cache WHERE key = ?", (key,))
                    conn.commit()
        except Exception as e:
            logger.error(f"SQLite get error: {e}")
        finally:
            conn.close()
        
        return None
    
    async def set(self, key: str, value: Dict[str, Any]) -> None:
        """Set a value in SQLite cache."""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        try:
            expiry = self._get_expiry()
            cursor.execute(
                "INSERT OR REPLACE INTO geoip_cache (key, value, expiry) VALUES (?, ?, ?)",
                (key, json.dumps(value), expiry)
            )
            conn.commit()
        except Exception as e:
            logger.error(f"SQLite set error: {e}")
        finally:
            conn.close()
    
    async def clear_all(self) -> None:
        """Clear all cache entries."""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        try:
            cursor.execute("DELETE FROM geoip_cache")
            conn.commit()
            logger.info("Cleared SQLite cache")
        except Exception as e:
            logger.error(f"SQLite clear error: {e}")
        finally:
            conn.close()
    
    async def close(self) -> None:
        """Cleanup expired entries."""
        conn = sqlite3.connect(self.db_path)
        cursor = conn.cursor()
        
        try:
            cursor.execute(
                "DELETE FROM geoip_cache WHERE expiry < ?",
                (int(time.time()),)
            )
            conn.commit()
        except:
            pass
        finally:
            conn.close()


class NoCache(CacheInterface):
    """No-op cache implementation."""
    
    async def get(self, key: str) -> Optional[Dict[str, Any]]:
        """Always returns None."""
        return None
    
    async def set(self, key: str, value: Dict[str, Any]) -> None:
        """Does nothing."""
        pass
    
    async def clear_all(self) -> None:
        """Does nothing."""
        pass
    
    async def close(self) -> None:
        """Does nothing."""
        pass


def get_cache(cache_type: Optional[str] = None) -> CacheInterface:
    """
    Factory function to get the appropriate cache implementation.
    
    Args:
        cache_type: Type of cache to use (memory, redis, sqlite, none)
        
    Returns:
        CacheInterface implementation
    """
    settings = get_settings()
    cache_type = cache_type or settings.cache_type
    
    if cache_type == "redis":
        if settings.redis_url:
            return RedisCache(settings.redis_url, settings.cache_ttl)
        else:
            logger.warning("Redis cache requested but REDIS_URL not configured, falling back to memory cache")
            return MemoryCache(settings.cache_ttl)
    elif cache_type == "sqlite":
        return SQLiteCache(ttl=settings.cache_ttl)
    elif cache_type == "none":
        return NoCache()
    else:
        # Default to memory cache
        return MemoryCache(settings.cache_ttl)