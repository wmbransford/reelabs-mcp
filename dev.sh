#!/bin/bash
# Build, restart, and verify the MCP server in one step.
# Usage: ./dev.sh

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Building release..."
swift build -c release 2>&1 | tail -1

echo "Pointing server at dev data root via REELABS_DATA_DIR..."
launchctl setenv REELABS_DATA_DIR "$SCRIPT_DIR/data"

echo "Restarting server via launchd..."
launchctl kickstart -k "gui/$(id -u)/com.reelabs.mcp"
sleep 2

PID=$(pgrep -f '.build/release/ReelabsMCP' || true)
if [ -n "$PID" ]; then
    echo "Server running (PID $PID). Reconnect with /mcp in Claude Code."
else
    echo "ERROR: Server did not start. Check /tmp/reelabs-mcp.stderr.log"
    exit 1
fi
