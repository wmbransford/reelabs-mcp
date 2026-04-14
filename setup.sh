#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY_NAME="ReelabsMCP"

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

# Register with Claude Code
CLAUDE_CONFIG="$HOME/.claude/settings.json"
CLAUDE_DIR="$HOME/.claude"

mkdir -p "$CLAUDE_DIR"

# Check if settings.json exists and has mcpServers
if [ -f "$CLAUDE_CONFIG" ]; then
    # Use python3 to merge the config
    python3 -c "
import json, sys

config_path = '$CLAUDE_CONFIG'
binary_path = '$BINARY_PATH'

with open(config_path, 'r') as f:
    config = json.load(f)

if 'mcpServers' not in config:
    config['mcpServers'] = {}

config['mcpServers']['reelabs'] = {
    'command': binary_path,
    'args': [],
    'env': {}
}

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)

print('Updated Claude config at:', config_path)
"
else
    # Create new config
    python3 -c "
import json

config = {
    'mcpServers': {
        'reelabs': {
            'command': '$BINARY_PATH',
            'args': [],
            'env': {}
        }
    }
}

with open('$CLAUDE_CONFIG', 'w') as f:
    json.dump(config, f, indent=2)

print('Created Claude config at: $CLAUDE_CONFIG')
"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "MCP server registered as 'reelabs' in Claude Code."
echo "Binary: $BINARY_PATH"
echo ""
echo "To configure Chirp transcription, edit config.json:"
echo "  chirp_api_key: Your Google Cloud API key"
echo "  chirp_project_id: Your Google Cloud project ID"
echo ""
echo "Restart Claude Code to pick up the new MCP server."
