#!/bin/bash
# One-time: give Claude Desktop's layerling MCP server the token the Docker copy on :3100 uses.
export PATH="/opt/homebrew/bin:$PATH"
DIR="$(cd "$(dirname "$0")" && pwd)"
TOKEN="$(grep -E '^LAYERLING_MCP_TOKEN=' "$DIR/docker/.env" | head -1 | cut -d= -f2- | tr -d '"'"'"' \r')"
[ -z "$TOKEN" ] && { echo "No LAYERLING_MCP_TOKEN in docker/.env"; read -n 1 -s; exit 1; }
CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
[ -f "$CFG" ] || { echo "Claude Desktop config not found at $CFG"; read -n 1 -s; exit 1; }
cp "$CFG" "$CFG.bak.$(date +%Y%m%d%H%M%S)"
CFG="$CFG" TOKEN="$TOKEN" node -e '
  const fs = require("fs"), p = process.env.CFG;
  const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
  if (!cfg.mcpServers?.layerling) { console.log("No layerling entry in Claude Desktop config - run Finish Setup first."); process.exit(1); }
  cfg.mcpServers.layerling.env = { ...(cfg.mcpServers.layerling.env || {}),
    LAYERLING_URL: "http://127.0.0.1:3100", LAYERLING_MCP_TOKEN: process.env.TOKEN };
  fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
  console.log("Claude Desktop: LAYERLING_URL and LAYERLING_MCP_TOKEN set.");
'
echo; echo "Done. Quit and reopen Claude Desktop (Cmd+Q)."
read -n 1 -s -r -p "Press any key to close..."
