#!/bin/bash
set -euo pipefail

# Upload files to S3 with appropriate content types
# Usage: ./upload-to-s3.sh <source_dir> <s3_bucket> <s3_prefix> <file_pattern> <content_type>

SOURCE_DIR="${1}"
S3_BUCKET="${2}"
S3_PREFIX="${3}"
FILE_PATTERN="${4}"
CONTENT_TYPE="${5}"

# Validate inputs
if [ -z "$SOURCE_DIR" ] || [ -z "$S3_BUCKET" ] || [ -z "$S3_PREFIX" ] || [ -z "$FILE_PATTERN" ] || [ -z "$CONTENT_TYPE" ]; then
    echo "Error: All parameters are required"
    echo "Usage: $0 <source_dir> <s3_bucket> <s3_prefix> <file_pattern> <content_type>"
    exit 1
fi

# Check if source directory exists
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: Source directory does not exist: $SOURCE_DIR"
    exit 1
fi

echo "Uploading files from $SOURCE_DIR to s3://${S3_BUCKET}/${S3_PREFIX}..."
echo "File pattern: $FILE_PATTERN"
echo "Content type: $CONTENT_TYPE"

# Count files to upload
FILE_COUNT=$(find "$SOURCE_DIR" -name "$FILE_PATTERN" 2>/dev/null | wc -l)

if [ "$FILE_COUNT" -eq 0 ]; then
    echo "Warning: No files matching pattern '$FILE_PATTERN' found in $SOURCE_DIR"
    exit 0
fi

echo "Found $FILE_COUNT files to upload"

# Upload files using aws s3 sync
aws s3 sync "$SOURCE_DIR/" "s3://${S3_BUCKET}/${S3_PREFIX}/" \
    --acl public-read \
    --content-type "$CONTENT_TYPE" \
    --exclude "*" \
    --include "$FILE_PATTERN" \
    --no-progress

# Verify upload success
UPLOADED_COUNT=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" --recursive | grep -E "${FILE_PATTERN}$" | wc -l)

if [ "$UPLOADED_COUNT" -gt 0 ]; then
    echo "✅ Successfully uploaded $UPLOADED_COUNT files to S3"
else
    echo "❌ No files were uploaded to S3"
    exit 1
fi