#!/bin/bash
# Build, restart, and verify the MCP server in one step.
# Usage: ./dev.sh

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Building release..."
swift build -c release 2>&1 | tail -1

echo "Pointing server at dev data root via REELABS_DATA_DIR..."
launchctl setenv REELABS_DATA_DIR "$SCRIPT_DIR/data"

# Analytics warehouse telemetry (fire-and-forget POST after each render).
launchctl setenv REELABS_WAREHOUSE_URL    "https://wwqzjgtaystvvxrzzbcw.supabase.co/functions/v1/ingest-video-render"
launchctl setenv REELABS_WAREHOUSE_SECRET "84710dbf7d449bf458046fae00e5f45174e7a55b9628d8938c5b6c54dff15e8c"

# Set GCP service-account credentials for Speech-to-Text auth.
# William's default key; override by exporting GOOGLE_APPLICATION_CREDENTIALS before running dev.sh.
GCP_KEY="${GOOGLE_APPLICATION_CREDENTIALS:-$HOME/Desktop/Williams Hub/.secrets/gcp-spacestudios.json}"
if [ -f "$GCP_KEY" ]; then
    echo "GCP credentials: $GCP_KEY"
    launchctl setenv GOOGLE_APPLICATION_CREDENTIALS "$GCP_KEY"
else
    echo "WARNING: GCP credentials not found at $GCP_KEY — transcription will be disabled"
fi

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
