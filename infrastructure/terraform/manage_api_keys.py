#!/usr/bin/env python3
"""
Script to manage API keys for the GeoIP authentication service.

Usage:
    python manage_api_keys.py create --name "User Name" --email "user@example.com"
    python manage_api_keys.py list
    python manage_api_keys.py revoke --key "api_key_here"
    python manage_api_keys.py stats --key "api_key_here"
"""

import argparse
import boto3
import hashlib
import secrets
import json
from datetime import datetime, timedelta
from typing import Optional, Dict, List

# Initialize DynamoDB
dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('geoip-api-keys')


def generate_api_key() -> str:
    """Generate a secure API key."""
    return f"geoip_{secrets.token_urlsafe(32)}"


def hash_api_key(api_key: str) -> str:
    """Hash API key for storage."""
    return hashlib.sha256(api_key.encode()).hexdigest()


def create_api_key(name: str, email: str, expires_days: Optional[int] = None,
                   allowed_databases: Optional[List[str]] = None) -> str:
    """Create a new API key."""
    api_key = generate_api_key()
    key_hash = hash_api_key(api_key)
    
    item = {
        'api_key_hash': key_hash,
        'name': name,
        'email': email,
        'created_at': datetime.utcnow().isoformat(),
        'active': True,
        'request_count': 0
    }
    
    if expires_days:
        expires_at = datetime.utcnow() + timedelta(days=expires_days)
        item['expires_at'] = expires_at.isoformat()
    
    if allowed_databases:
        item['allowed_databases'] = allowed_databases
    else:
        item['allowed_databases'] = 'all'
    
    try:
        table.put_item(Item=item)
        print(f"✅ API key created successfully!")
        print(f"Name: {name}")
        print(f"Email: {email}")
        print(f"API Key: {api_key}")
        print(f"⚠️  Save this API key securely - it cannot be retrieved again!")
        
        if expires_days:
            print(f"Expires: {item['expires_at']}")
        
        return api_key
    except Exception as e:
        print(f"❌ Error creating API key: {str(e)}")
        return None


def list_api_keys() -> None:
    """List all API keys."""
    try:
        response = table.scan()
        items = response.get('Items', [])
        
        if not items:
            print("No API keys found.")
            return
        
        print(f"\n{'Name':<30} {'Email':<30} {'Active':<8} {'Requests':<10} {'Created':<20}")
        print("-" * 100)
        
        for item in items:
            name = item.get('name', 'Unknown')
            email = item.get('email', 'Unknown')
            active = "Yes" if item.get('active', True) else "No"
            requests = item.get('request_count', 0)
            created = item.get('created_at', 'Unknown')[:19]
            
            print(f"{name:<30} {email:<30} {active:<8} {requests:<10} {created:<20}")
    
    except Exception as e:
        print(f"❌ Error listing API keys: {str(e)}")


def revoke_api_key(api_key: str) -> None:
    """Revoke an API key."""
    key_hash = hash_api_key(api_key)
    
    try:
        table.update_item(
            Key={'api_key_hash': key_hash},
            UpdateExpression='SET active = :false, revoked_at = :timestamp',
            ExpressionAttributeValues={
                ':false': False,
                ':timestamp': datetime.utcnow().isoformat()
            }
        )
        print(f"✅ API key revoked successfully!")
    except Exception as e:
        print(f"❌ Error revoking API key: {str(e)}")


def get_api_key_stats(api_key: str) -> None:
    """Get statistics for an API key."""
    key_hash = hash_api_key(api_key)
    
    try:
        response = table.get_item(Key={'api_key_hash': key_hash})
        item = response.get('Item')
        
        if not item:
            print("❌ API key not found!")
            return
        
        print("\n📊 API Key Statistics")
        print("-" * 40)
        print(f"Name: {item.get('name', 'Unknown')}")
        print(f"Email: {item.get('email', 'Unknown')}")
        print(f"Active: {'Yes' if item.get('active', True) else 'No'}")
        print(f"Created: {item.get('created_at', 'Unknown')}")
        print(f"Last Used: {item.get('last_used', 'Never')}")
        print(f"Total Requests: {item.get('request_count', 0)}")
        
        if 'expires_at' in item:
            print(f"Expires: {item['expires_at']}")
        
        if 'allowed_databases' in item and item['allowed_databases'] != 'all':
            print(f"Allowed Databases: {', '.join(item['allowed_databases'])}")
    
    except Exception as e:
        print(f"❌ Error getting API key stats: {str(e)}")


def main():
    parser = argparse.ArgumentParser(description='Manage GeoIP API keys')
    subparsers = parser.add_subparsers(dest='command', help='Commands')
    
    # Create command
    create_parser = subparsers.add_parser('create', help='Create a new API key')
    create_parser.add_argument('--name', required=True, help='Name of the API key holder')
    create_parser.add_argument('--email', required=True, help='Email of the API key holder')
    create_parser.add_argument('--expires-days', type=int, help='Days until expiration')
    create_parser.add_argument('--databases', nargs='+', help='Allowed databases (default: all)')
    
    # List command
    list_parser = subparsers.add_parser('list', help='List all API keys')
    
    # Revoke command
    revoke_parser = subparsers.add_parser('revoke', help='Revoke an API key')
    revoke_parser.add_argument('--key', required=True, help='API key to revoke')
    
    # Stats command
    stats_parser = subparsers.add_parser('stats', help='Get API key statistics')
    stats_parser.add_argument('--key', required=True, help='API key to get stats for')
    
    args = parser.parse_args()
    
    if args.command == 'create':
        create_api_key(args.name, args.email, args.expires_days, args.databases)
    elif args.command == 'list':
        list_api_keys()
    elif args.command == 'revoke':
        revoke_api_key(args.key)
    elif args.command == 'stats':
        get_api_key_stats(args.key)
    else:
        parser.print_help()


if __name__ == '__main__':
    main()