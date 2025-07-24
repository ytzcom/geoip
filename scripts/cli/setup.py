#!/usr/bin/env python3
"""Setup script for GeoIP Update tool."""

from setuptools import setup, find_packages
from pathlib import Path

# Read the README for long description
this_directory = Path(__file__).parent
long_description = (this_directory / "README.md").read_text() if (this_directory / "README.md").exists() else ""

setup(
    name="geoip-update",
    version="1.0.0",
    author="GeoIP Update",
    description="Download GeoIP databases from authenticated API",
    long_description=long_description,
    long_description_content_type="text/markdown",
    url="https://github.com/yourusername/geoip-update",
    py_modules=["geoip-update"],
    python_requires=">=3.7",
    install_requires=[
        "aiohttp>=3.8.0",
        "pyyaml>=5.4.0",
        "click>=8.0.0",
    ],
    extras_require={
        "dev": [
            "pytest>=6.0",
            "pytest-asyncio>=0.18.0",
            "black>=21.0",
            "flake8>=3.9.0",
        ]
    },
    entry_points={
        "console_scripts": [
            "geoip-update=geoip-update:main",
        ],
    },
    classifiers=[
        "Development Status :: 4 - Beta",
        "Intended Audience :: System Administrators",
        "License :: OSI Approved :: MIT License",
        "Operating System :: OS Independent",
        "Programming Language :: Python :: 3",
        "Programming Language :: Python :: 3.7",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Topic :: System :: Systems Administration",
        "Topic :: Internet :: WWW/HTTP",
    ],
)