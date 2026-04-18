# Install ReeLabs MCP

This guide is for AI agents (Claude, Cursor, etc.) helping a user install the ReeLabs MCP server on their Mac. Drive the install through the user's shell; check each step before moving on.

## Prerequisites

Verify before starting:

- **macOS 14 (Sonoma) or newer** — `sw_vers -productVersion` should return 14.x or higher.
- **Homebrew installed** — `which brew` should return a path. If it does not, install Homebrew from https://brew.sh first.
- **An MCP-capable client** — Claude Code, Claude Desktop, or Cursor. The user should have at least one installed.

If any prerequisite fails, stop and resolve it before continuing.

## Step 1 — Install the server

```bash
brew install wmbransford/tap/reelabs-mcp && brew services start reelabs-mcp
```

Verify: `brew services list | grep reelabs-mcp` should show `started`.

If `brew services list` shows `error`, run `brew services restart reelabs-mcp` and check the logs at `~/Library/Logs/Homebrew/reelabs-mcp/`.

## Step 2 — Sign in

```bash
reelabs-mcp sign-in
```

This opens the user's default browser for authentication. The CLI waits for the browser callback and stores credentials locally. After a successful sign-in, the terminal prints a confirmation.

If the browser does not open, the CLI prints a URL the user can paste manually.

## Step 3 — Register with Claude

For Claude Code:

```bash
claude mcp add reelabs reelabs-mcp
```

For Claude Desktop or Cursor, edit the MCP configuration JSON (location varies by client) and add:

```json
{
  "mcpServers": {
    "reelabs": {
      "command": "reelabs-mcp"
    }
  }
}
```

Restart the client to pick up the new server.

## Step 4 — Verify

After restarting the client, the user should see ReeLabs tools available. Verify by asking the agent to probe a sample video:

```
Ask: "Probe /path/to/any-video.mp4 and tell me its duration."
```

The agent should call `reelabs_probe` and return duration, resolution, fps, codec, and audio details. If the tool list is empty or the call fails, check `brew services list` and restart the service.

## Data location

ReeLabs stores projects, presets, transcripts, and rendered output under:

```
~/Library/Application Support/ReelabsMCP/
```

For development or shared setups, set `REELABS_DATA_DIR` to override the default root.

## Uninstall

```bash
brew services stop reelabs-mcp
brew uninstall reelabs-mcp
claude mcp remove reelabs
```

Projects and assets remain at `~/Library/Application Support/ReelabsMCP/`. Delete that folder to wipe everything.

## Troubleshooting

- **`brew services` shows `error`** — check `~/Library/Logs/Homebrew/reelabs-mcp/` for the stderr log.
- **Sign-in hangs** — kill the process, re-run `reelabs-mcp sign-in`, and use the printed fallback URL in the browser.
- **Client does not see tools** — confirm the MCP config points to `reelabs-mcp` (the CLI shim), not the raw Swift binary. Restart the client fully.
- **Free transcription quota exhausted** — the free tier is 90 minutes per month. The CLI prints a friendly error when the quota is hit; upgrade or wait for the next cycle.

## Links

- Product site: https://reelabs.ai
- Source and issues: https://github.com/wmbransford/reelabs-mcp
- Email support: hello@reelabs.ai
