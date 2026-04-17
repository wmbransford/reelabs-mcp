#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY_NAME="ReelabsMCP"
PLIST_LABEL="com.reelabs.mcp"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
MCP_PORT=52849

echo "=== ReeLabs MCP v2 Setup ==="
echo ""

# Build release binary
echo "Building release binary..."
cd "$SCRIPT_DIR"
swift build -c release 2>&1

BINARY_PATH="$SCRIPT_DIR/.build/release/$BINARY_NAME"

if [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: Build failed — binary not found at $BINARY_PATH"
    exit 1
fi

echo "Binary built at: $BINARY_PATH"
echo ""

# --- launchd daemon setup ---
echo "Setting up launchd daemon..."

# Unload existing agent if running
if launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"; then
    echo "Stopping existing daemon..."
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
    sleep 1
fi

# Generate launchd plist
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BINARY_PATH}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardErrorPath</key>
    <string>/tmp/reelabs-mcp.stderr.log</string>
    <key>StandardOutPath</key>
    <string>/tmp/reelabs-mcp.stdout.log</string>
</dict>
</plist>
PLIST

echo "Created plist at: $PLIST_PATH"

# Load the agent
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
echo "Daemon loaded."

# Wait for it to start
sleep 2

# Verify
if launchctl list 2>/dev/null | grep -q "$PLIST_LABEL"; then
    echo "Daemon is running."
else
    echo "WARNING: Daemon may not have started. Check /tmp/reelabs-mcp.stderr.log"
fi

# --- Update .mcp.json ---
cat > "$SCRIPT_DIR/.mcp.json" <<JSON
{
  "mcpServers": {
    "reelabs": {
      "type": "http",
      "url": "http://127.0.0.1:${MCP_PORT}/mcp"
    }
  }
}
JSON

echo ""
echo "=== Setup Complete ==="
echo ""
echo "MCP server running as launchd daemon '${PLIST_LABEL}'"
echo "  URL: http://127.0.0.1:${MCP_PORT}/mcp"
echo "  Binary: $BINARY_PATH"
echo "  Plist: $PLIST_PATH"
echo "  Logs: /tmp/reelabs-mcp.stderr.log"
echo ""
echo "Commands:"
echo "  Stop:    launchctl bootout gui/\$(id -u)/$PLIST_LABEL"
echo "  Start:   launchctl bootstrap gui/\$(id -u) $PLIST_PATH"
echo "  Logs:    tail -f /tmp/reelabs-mcp.stderr.log"
echo "  Stdio:   $BINARY_PATH --stdio"
echo ""
echo "Restart Claude Code to pick up the HTTP transport."
echo ""
echo "Next: sign in to enable transcription."
echo "  $BINARY_PATH sign-in"
