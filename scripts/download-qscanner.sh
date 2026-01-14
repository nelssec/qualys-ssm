#!/bin/bash
# Download QScanner binaries for upload to S3
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== QScanner Binary Downloader ==="
echo ""

# Check if download script URL is set
if [ -z "$QSCANNER_DOWNLOAD_URL" ]; then
    echo "Please set QSCANNER_DOWNLOAD_URL or download manually from Qualys"
    echo ""
    echo "Manual steps:"
    echo "1. Go to Qualys Downloads page"
    echo "2. Download qscanner for linux-amd64 and linux-arm64"
    echo "3. Place them in the project root as:"
    echo "   - qscanner-linux-amd64"
    echo "   - qscanner-linux-arm64"
    echo "4. Run: make upload-qscanner"
    exit 1
fi

cd "$PROJECT_DIR"

echo "Downloading QScanner binaries..."

# Download AMD64
echo "Downloading linux-amd64..."
curl -sL "${QSCANNER_DOWNLOAD_URL}/qscanner-linux-amd64" -o qscanner-linux-amd64
chmod +x qscanner-linux-amd64

# Download ARM64
echo "Downloading linux-arm64..."
curl -sL "${QSCANNER_DOWNLOAD_URL}/qscanner-linux-arm64" -o qscanner-linux-arm64
chmod +x qscanner-linux-arm64

echo ""
echo "Downloaded:"
ls -la qscanner-linux-*

echo ""
echo "Next steps:"
echo "1. Deploy the stack: make deploy QUALYS_TOKEN=your-token"
echo "2. Upload binaries: make upload-qscanner"
