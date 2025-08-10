#!/usr/bin/env python3
"""
Docker Hub Cleanup Script
Removes old PR and SHA tags from Docker Hub repositories
Uses Docker Registry v2 authentication (works with both passwords and PATs)
"""

import os
import sys
import json
import requests
from datetime import datetime, timedelta, timezone
import re
import argparse
import time
from urllib.parse import quote
from functools import wraps
import base64


class DockerHubCleaner:
    def __init__(self, username, password, namespace, dry_run=False, verbose=False):
        self.username = username
        self.password = password  # Can be password or Personal Access Token
        self.namespace = namespace
        self.dry_run = dry_run
        self.verbose = verbose
        self.hub_url = "https://hub.docker.com/v2"
        self.auth_url = "https://auth.docker.io"
        self.registry_url = "https://registry-1.docker.io/v2"
        self.tokens = {}  # Cache tokens per repository
        self.request_timeout = 30  # 30 seconds timeout for API requests
        self.max_retries = 3
        self.retry_delay = 1  # Initial delay in seconds
        
    def log(self, message, level="INFO"):
        """Log message with timestamp"""
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        if level == "DEBUG" and not self.verbose:
            return
        print(f"[{timestamp}] {message}")
    
    def retry_with_backoff(func):
        """Decorator for retrying API calls with exponential backoff"""
        @wraps(func)
        def wrapper(self, *args, **kwargs):
            last_exception = None
            delay = self.retry_delay
            
            for attempt in range(self.max_retries):
                try:
                    return func(self, *args, **kwargs)
                
                except requests.exceptions.Timeout as e:
                    last_exception = e
                    self.log(f"⏱️  Request timeout (attempt {attempt + 1}/{self.max_retries})", "WARNING")
                
                except requests.exceptions.HTTPError as e:
                    if e.response.status_code == 429:  # Rate limited
                        retry_after = int(e.response.headers.get('Retry-After', delay))
                        self.log(f"⚠️  Rate limited, waiting {retry_after} seconds...", "WARNING")
                        time.sleep(retry_after)
                        continue
                    elif e.response.status_code == 401:  # Unauthorized
                        self.log(f"  Authentication issue (401): {e}", "DEBUG")
                        # Don't retry auth errors
                        raise e
                    last_exception = e
                
                except requests.exceptions.RequestException as e:
                    last_exception = e
                    self.log(f"⚠️  Request failed (attempt {attempt + 1}/{self.max_retries}): {e}", "WARNING")
                
                if attempt < self.max_retries - 1:
                    self.log(f"⏳ Waiting {delay} seconds before retry...", "DEBUG")
                    time.sleep(delay)
                    delay *= 2  # Exponential backoff
            
            # All retries exhausted
            raise last_exception if last_exception else Exception("Max retries exceeded")
        
        return wrapper
    
    def get_basic_auth_header(self):
        """Get basic auth header for authentication"""
        credentials = f"{self.username}:{self.password}"
        encoded = base64.b64encode(credentials.encode()).decode('ascii')
        return f"Basic {encoded}"
    
    @retry_with_backoff
    def get_bearer_token(self, repository):
        """Get bearer token for specific repository operations"""
        # Check if we have a cached token for this repository
        if repository in self.tokens:
            token_data = self.tokens[repository]
            # Simple cache - tokens typically last 5 minutes
            if (datetime.now(timezone.utc) - token_data['created']).total_seconds() < 240:  # 4 minutes
                self.log(f"  Using cached token for {repository}", "DEBUG")
                return token_data['token']
        
        # Request new token
        scope = f"repository:{self.namespace}/{repository}:pull,push,delete"
        url = f"{self.auth_url}/token"
        params = {
            "service": "registry.docker.io",
            "scope": scope
        }
        
        headers = {
            "Authorization": self.get_basic_auth_header()
        }
        
        self.log(f"  Requesting bearer token for {repository}...", "DEBUG")
        
        try:
            response = requests.get(url, params=params, headers=headers, timeout=self.request_timeout)
            response.raise_for_status()
            token = response.json().get("token")
            
            # Cache the token
            self.tokens[repository] = {
                'token': token,
                'created': datetime.now(timezone.utc)
            }
            
            self.log(f"  ✅ Got bearer token for {repository}", "DEBUG")
            return token
            
        except requests.exceptions.RequestException as e:
            self.log(f"  Failed to get bearer token for {repository}: {e}", "DEBUG")
            raise
    
    @retry_with_backoff
    def get_tags_registry(self, repository):
        """Get tags using Docker Registry API (more reliable)"""
        tags = []
        token = self.get_bearer_token(repository)
        
        url = f"{self.registry_url}/{self.namespace}/{repository}/tags/list"
        headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/json"
        }
        
        try:
            response = requests.get(url, headers=headers, timeout=self.request_timeout)
            response.raise_for_status()
            data = response.json()
            
            tag_names = data.get("tags", [])
            if not tag_names:
                return []
            
            # For each tag, we need to get its manifest to get the last updated time
            # This is more complex but more accurate
            self.log(f"  Found {len(tag_names)} tags, fetching details...", "DEBUG")
            
            for tag_name in tag_names:
                # For simplicity, we'll use a default date for now
                # In production, you'd want to fetch manifest for each tag
                tags.append({
                    "name": tag_name,
                    "last_updated": datetime.now(timezone.utc).isoformat()  # Placeholder
                })
            
            return tags
            
        except requests.exceptions.RequestException as e:
            self.log(f"  Registry API failed, trying Hub API: {e}", "DEBUG")
            # Fall back to Hub API
            return self.get_tags_hub(repository)
    
    @retry_with_backoff
    def get_tags_hub(self, repository):
        """Get tags using Docker Hub API (fallback)"""
        tags = []
        page = 1
        page_size = 100
        
        # Docker Hub API doesn't require authentication for public repos
        # But we'll use basic auth if available
        headers = {}
        if self.username and self.password:
            headers["Authorization"] = self.get_basic_auth_header()
        
        while True:
            url = f"{self.hub_url}/repositories/{self.namespace}/{repository}/tags"
            params = {
                "page": page,
                "page_size": page_size
            }
            
            self.log(f"📄 Fetching page {page} of tags for {repository}...", "DEBUG")
            
            try:
                response = requests.get(
                    url, 
                    headers=headers, 
                    params=params,
                    timeout=self.request_timeout
                )
                response.raise_for_status()
                data = response.json()
                
                if "results" not in data:
                    break
                    
                tags.extend(data["results"])
                self.log(f"  Found {len(data['results'])} tags on page {page}", "DEBUG")
                
                if not data.get("next"):
                    break
                    
                page += 1
                
            except requests.exceptions.RequestException as e:
                self.log(f"❌ Failed to get tags for {repository}: {e}", "ERROR")
                break
        
        return tags
    
    def get_tags(self, repository):
        """Get all tags for a repository (tries both APIs)"""
        # Try Hub API first (has better tag metadata)
        tags = self.get_tags_hub(repository)
        
        # If Hub API fails, try Registry API
        if not tags:
            self.log(f"  Trying Registry API as fallback...", "DEBUG")
            tags = self.get_tags_registry(repository)
        
        return tags
    
    @retry_with_backoff
    def delete_tag(self, repository, tag):
        """Delete a specific tag from a repository"""
        if self.dry_run:
            self.log(f"  🔍 [DRY RUN] Would delete: {repository}:{tag}")
            return True
        
        # Try Registry API delete first (more reliable)
        try:
            token = self.get_bearer_token(repository)
            
            # First, get the manifest digest
            manifest_url = f"{self.registry_url}/{self.namespace}/{repository}/manifests/{tag}"
            headers = {
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.docker.distribution.manifest.v2+json"
            }
            
            response = requests.get(manifest_url, headers=headers, timeout=self.request_timeout)
            response.raise_for_status()
            
            # Get the digest from headers
            digest = response.headers.get('Docker-Content-Digest')
            if not digest:
                raise Exception("No digest found in manifest response")
            
            # Now delete by digest
            delete_url = f"{self.registry_url}/{self.namespace}/{repository}/manifests/{digest}"
            response = requests.delete(delete_url, headers=headers, timeout=self.request_timeout)
            response.raise_for_status()
            
            self.log(f"  ✅ Deleted: {repository}:{tag}")
            return True
            
        except Exception as e:
            self.log(f"  Registry delete failed, trying Hub API: {e}", "DEBUG")
            
            # Fall back to Hub API delete
            try:
                # URL encode the tag name to handle special characters
                encoded_tag = quote(tag, safe='')
                url = f"{self.hub_url}/repositories/{self.namespace}/{repository}/tags/{encoded_tag}"
                
                headers = {}
                if self.username and self.password:
                    headers["Authorization"] = self.get_basic_auth_header()
                
                response = requests.delete(url, headers=headers, timeout=self.request_timeout)
                response.raise_for_status()
                self.log(f"  ✅ Deleted via Hub API: {repository}:{tag}")
                return True
                
            except requests.exceptions.RequestException as e2:
                self.log(f"  ❌ Failed to delete {repository}:{tag}: {e2}", "ERROR")
                return False
    
    def test_authentication(self):
        """Test if authentication works"""
        self.log("🔐 Testing authentication...")
        
        # Test 1: Try to get a token for a known repository
        # Note: This might fail with the namespace as repo name, which is expected
        try:
            test_repo = self.namespace  # Use namespace as test repo
            token = self.get_bearer_token(test_repo)
            if token:
                self.log("✅ Bearer token authentication successful")
                return True
        except Exception as e:
            # Only show this in verbose mode - it's expected to fail sometimes
            self.log(f"  Bearer token test with namespace failed (expected): {e}", "DEBUG")
        
        # Test 2: Try Hub API with basic auth
        try:
            url = f"{self.hub_url}/repositories/{self.namespace}"
            headers = {"Authorization": self.get_basic_auth_header()}
            response = requests.get(url, headers=headers, timeout=self.request_timeout)
            if response.status_code == 200:
                self.log("✅ Hub API authentication successful")
                return True
        except Exception as e:
            self.log(f"⚠️  Hub API test failed: {e}", "DEBUG")
        
        self.log("❌ Authentication failed - please check your credentials", "ERROR")
        self.log("   Make sure DOCKERHUB_USERNAME and DOCKERHUB_PASSWORD are set correctly", "ERROR")
        self.log("   Password can be either your Docker Hub password or a Personal Access Token", "ERROR")
        return False
    
    def cleanup_repository(self, repository, pr_retention_days=30, sha_retention_days=14):
        """Clean up old tags from a repository"""
        self.log(f"\n📦 Processing repository: {repository}")
        
        tags = self.get_tags(repository)
        if not tags:
            self.log(f"  ℹ️  No tags found")
            # Return consistent dict even when no tags
            return {
                "repository": repository,
                "total_tags": 0,
                "protected": 0,
                "deleted": 0,
                "kept": 0,
                "failed": 0
            }
        
        self.log(f"  📊 Found {len(tags)} total tags")
        
        # Calculate cutoff dates
        now = datetime.now(timezone.utc)
        pr_cutoff = now - timedelta(days=pr_retention_days)
        sha_cutoff = now - timedelta(days=sha_retention_days)
        
        # Patterns for different tag types
        pr_pattern = re.compile(r'^pr-\d+$')
        sha_pattern = re.compile(r'^(main|master|develop)-[a-f0-9]{7,}$')
        protected_pattern = re.compile(r'^(latest|main|master|develop|\d+\.\d+\.\d+|v\d+\.\d+\.\d+|\d+\.\d+|\d+)$')
        
        deleted_count = 0
        protected_count = 0
        kept_count = 0
        failed_count = 0
        
        for tag in tags:
            tag_name = tag.get("name")
            if not tag_name:
                continue
            
            # Parse last updated date
            last_updated_str = tag.get("last_updated", "")
            try:
                # Handle both ISO format and simple datetime
                if last_updated_str:
                    # Docker Hub dates end with 'Z' for UTC
                    last_updated = datetime.strptime(
                        last_updated_str[:19], 
                        "%Y-%m-%dT%H:%M:%S"
                    ).replace(tzinfo=timezone.utc)
                else:
                    # If no date, assume it's old enough to consider
                    last_updated = datetime.now(timezone.utc) - timedelta(days=365)
            except (ValueError, TypeError):
                self.log(f"  ⚠️  Skipping {tag_name}: unable to parse date", "WARNING")
                kept_count += 1
                continue
            
            # Check if tag is protected
            if protected_pattern.match(tag_name):
                self.log(f"  🛡️  Protected: {tag_name}")
                protected_count += 1
                continue
            
            # Check PR tags
            if pr_pattern.match(tag_name):
                if last_updated < pr_cutoff:
                    if self.delete_tag(repository, tag_name):
                        deleted_count += 1
                    else:
                        failed_count += 1
                else:
                    self.log(f"  ⏳ Keeping PR tag (recent): {tag_name}")
                    kept_count += 1
                continue
            
            # Check SHA tags
            if sha_pattern.match(tag_name):
                if last_updated < sha_cutoff:
                    if self.delete_tag(repository, tag_name):
                        deleted_count += 1
                    else:
                        failed_count += 1
                else:
                    self.log(f"  ⏳ Keeping SHA tag (recent): {tag_name}")
                    kept_count += 1
                continue
            
            # Unknown tag format - keep it
            self.log(f"  ❓ Keeping unknown format: {tag_name}")
            kept_count += 1
        
        # Summary
        self.log(f"\n  📈 Summary for {repository}:")
        self.log(f"     Protected: {protected_count}")
        self.log(f"     Deleted: {deleted_count}")
        self.log(f"     Kept: {kept_count}")
        if failed_count > 0:
            self.log(f"     Failed: {failed_count}", "WARNING")
        
        return {
            "repository": repository,
            "total_tags": len(tags),
            "protected": protected_count,
            "deleted": deleted_count,
            "kept": kept_count,
            "failed": failed_count
        }


def main():
    parser = argparse.ArgumentParser(description="Clean up old Docker Hub tags")
    parser.add_argument("--dry-run", action="store_true", help="Preview what would be deleted")
    parser.add_argument("--verbose", action="store_true", help="Enable verbose logging")
    parser.add_argument("--pr-retention", type=int, default=30, help="Days to keep PR tags (default: 30)")
    parser.add_argument("--sha-retention", type=int, default=14, help="Days to keep SHA tags (default: 14)")
    parser.add_argument("--repositories", nargs="+", help="List of repositories to clean")
    
    args = parser.parse_args()
    
    # Get credentials from environment
    username = os.environ.get("DOCKERHUB_USERNAME")
    password = os.environ.get("DOCKERHUB_PASSWORD")
    namespace = os.environ.get("DOCKER_NAMESPACE", "ytzcom")
    
    if not username or not password:
        print("❌ Error: DOCKERHUB_USERNAME and DOCKERHUB_PASSWORD environment variables are required")
        print("   DOCKERHUB_PASSWORD can be either your Docker Hub password or a Personal Access Token")
        sys.exit(2)  # Exit code 2 for configuration error
    
    # Default repositories if none specified
    if not args.repositories:
        args.repositories = [
            "geoip-scripts",
            "geoip-updater",
            "geoip-updater-cron",
            "geoip-updater-k8s",
            "geoip-updater-go",
            "geoip-api",
            "geoip-api-nginx",
            "geoip-api-dev"
        ]
    
    # Initialize cleaner
    cleaner = DockerHubCleaner(username, password, namespace, args.dry_run, args.verbose)
    
    # Test authentication
    if not cleaner.test_authentication():
        sys.exit(2)  # Exit code 2 for authentication failure
    
    # Process each repository
    results = []
    failed_repos = []
    
    for repo in args.repositories:
        try:
            result = cleaner.cleanup_repository(
                repo, 
                args.pr_retention,
                args.sha_retention
            )
            results.append(result)
            
            # Track repositories with failures
            if result and result.get("failed", 0) > 0:
                failed_repos.append(repo)
                
        except Exception as e:
            cleaner.log(f"❌ Failed to process {repo}: {e}", "ERROR")
            failed_repos.append(repo)
            # Add a failure result for this repository
            results.append({
                "repository": repo,
                "total_tags": 0,
                "protected": 0,
                "deleted": 0,
                "kept": 0,
                "failed": -1  # -1 indicates complete failure
            })
    
    # Print final summary
    print("\n" + "="*60)
    print("🎯 CLEANUP COMPLETE")
    print("="*60)
    
    if args.dry_run:
        print("ℹ️  This was a DRY RUN - no tags were actually deleted")
    
    # Calculate totals
    total_deleted = sum(r.get("deleted", 0) for r in results)
    total_kept = sum(r.get("kept", 0) for r in results)
    total_protected = sum(r.get("protected", 0) for r in results)
    total_failed = sum(r.get("failed", 0) for r in results if r.get("failed", 0) > 0)
    
    print(f"\n📊 Overall Statistics:")
    print(f"   Repositories processed: {len(results)}")
    print(f"   Tags deleted: {total_deleted}")
    print(f"   Tags kept: {total_kept}")
    print(f"   Tags protected: {total_protected}")
    
    if total_failed > 0:
        print(f"   ⚠️  Tags failed to delete: {total_failed}")
    
    if failed_repos:
        print(f"\n❌ Failed repositories:")
        for repo in failed_repos:
            print(f"   - {repo}")
    
    if args.dry_run and total_deleted > 0:
        print(f"\n💡 To actually delete these {total_deleted} tags, run without --dry-run")
    
    # Exit with appropriate code
    if failed_repos:
        sys.exit(1)  # Exit code 1 for partial failure
    else:
        sys.exit(0)  # Exit code 0 for success


if __name__ == "__main__":
    main()