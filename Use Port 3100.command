#!/bin/bash
# One-time: point the Layerling MCP server at http://127.0.0.1:3100 in Claude Desktop and Claude Code.
export PATH="/opt/homebrew/bin:$PATH"
URL="http://127.0.0.1:3100"
DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_BIN="$(command -v node)"
MCP_SCRIPT="$DIR/scripts/layerling-mcp-server.mjs"
CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
if [ -f "$CFG" ]; then
  cp "$CFG" "$CFG.bak.$(date +%Y%m%d%H%M%S)"
  CFG="$CFG" URL="$URL" node -e '
    const fs = require("fs"), p = process.env.CFG;
    const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
    if (!cfg.mcpServers?.layerling) { console.log("No layerling entry in Claude Desktop config - run Finish Setup first."); process.exit(1); }
    cfg.mcpServers.layerling.env = { ...(cfg.mcpServers.layerling.env || {}), LAYERLING_URL: process.env.URL };
    fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
    console.log("Claude Desktop: LAYERLING_URL =", process.env.URL);
  '
fi
if command -v claude >/dev/null 2>&1; then
  claude mcp remove layerling -s user >/dev/null 2>&1 || true
  claude mcp add layerling -s user -e LAYERLING_URL="$URL" -- "$NODE_BIN" "$MCP_SCRIPT" && echo "Claude Code: updated"
fi
echo; echo "Done. Quit and reopen Claude Desktop (Cmd+Q)."
read -n 1 -s -r -p "Press any key to close..."
