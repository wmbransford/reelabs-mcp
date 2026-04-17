#!/bin/sh
# ReeLabs MCP one-line installer.
# Usage: curl -fsSL https://reelabs.ai/install.sh | sh

set -e

REPO="wmbransford/reelabs-mcp"
INSTALL_DIR="/usr/local/bin"
BINARY_NAME="reelabs-mcp"

OS="$(uname -s)"
if [ "$OS" != "Darwin" ]; then
    echo "ReeLabs MCP is macOS-only. Detected: $OS"
    exit 1
fi

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MACOS_MAJOR" -lt 15 ]; then
    echo "ReeLabs MCP requires macOS 15 (Sequoia) or newer."
    echo "Detected macOS $(sw_vers -productVersion)."
    exit 1
fi

echo "Fetching the latest release..."
LATEST=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -o '"tag_name": *"[^"]*"' \
    | head -1 \
    | sed 's/"tag_name": *"\(.*\)"/\1/')

if [ -z "$LATEST" ]; then
    echo "Could not fetch the latest release from github.com/${REPO}."
    exit 1
fi

VERSION="${LATEST#v}"
TARBALL="reelabs-mcp-${VERSION}-macos.tar.gz"
URL="https://github.com/${REPO}/releases/download/${LATEST}/${TARBALL}"
SHA_URL="${URL}.sha256"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading ${LATEST}..."
curl -fsSL "$URL" -o "$TMPDIR/$TARBALL"
curl -fsSL "$SHA_URL" -o "$TMPDIR/$TARBALL.sha256"

echo "Verifying checksum..."
(cd "$TMPDIR" && shasum -a 256 -c "$TARBALL.sha256" >/dev/null)

echo "Extracting..."
tar -xzf "$TMPDIR/$TARBALL" -C "$TMPDIR"

if [ -w "$INSTALL_DIR" ]; then
    install -m 0755 "$TMPDIR/ReelabsMCP" "$INSTALL_DIR/$BINARY_NAME"
else
    echo "Installing to $INSTALL_DIR/$BINARY_NAME (requires sudo)..."
    sudo install -m 0755 "$TMPDIR/ReelabsMCP" "$INSTALL_DIR/$BINARY_NAME"
fi

echo ""
echo "Installed ${BINARY_NAME} ${VERSION} to ${INSTALL_DIR}/${BINARY_NAME}"
echo ""
echo "Next:"
echo "  ${BINARY_NAME} sign-in     # Connect this device to your ReeLabs account"
echo "  ${BINARY_NAME}             # Run the MCP server (foreground)"
echo ""
echo "To run as a background service, use Homebrew instead:"
echo "  brew install reelabs/tap/reelabs-mcp"
echo "  brew services start reelabs-mcp"
