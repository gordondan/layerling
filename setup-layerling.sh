#!/bin/bash
# Sets up a local Layerling instance + its MCP server for Claude Desktop and Claude Code.
# Usage: bash setup-layerling.sh [install-dir]   (default: ~/projects/layerling)
set -euo pipefail

DEST="${1:-$HOME/projects/layerling}"
REPO="https://github.com/henmedia/layerling.git"
DESKTOP_CFG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"

say() { printf '\n==> %s\n' "$*"; }

# --- Node >= 22.18 -----------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    say "Node not found - installing via Homebrew"
    brew install node
  else
    echo "Node.js >= 22.18 is required. Install it (brew install node, or nodejs.org) and re-run." >&2
    exit 1
  fi
fi
NODE_BIN="$(command -v node)"
if ! node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=18)?0:1)'; then
  echo "Node $(node -v) at $NODE_BIN is too old; Layerling needs >= 22.18. Upgrade (brew upgrade node) and re-run." >&2
  exit 1
fi
say "Using node $(node -v) at $NODE_BIN"

# --- Clone / update ----------------------------------------------------------
if [ -d "$DEST/.git" ]; then
  say "Updating existing checkout at $DEST"
  git -C "$DEST" pull --ff-only
else
  say "Cloning Layerling into $DEST"
  mkdir -p "$(dirname "$DEST")"
  git clone "$REPO" "$DEST"
fi

say "Installing npm dependencies (a few minutes the first time)"
(cd "$DEST" && npm install)

MCP_SCRIPT="$DEST/scripts/layerling-mcp-server.mjs"

# --- Claude Desktop config (merge, with backup) -------------------------------
say "Registering MCP server in Claude Desktop config"
mkdir -p "$(dirname "$DESKTOP_CFG")"
[ -f "$DESKTOP_CFG" ] && cp "$DESKTOP_CFG" "$DESKTOP_CFG.bak.$(date +%Y%m%d%H%M%S)"
CFG="$DESKTOP_CFG" NODE_BIN="$NODE_BIN" MCP_SCRIPT="$MCP_SCRIPT" node -e '
  const fs = require("fs");
  const p = process.env.CFG;
  let cfg = {};
  if (fs.existsSync(p)) {
    const raw = fs.readFileSync(p, "utf8").trim();
    if (raw) cfg = JSON.parse(raw);
  }
  cfg.mcpServers = cfg.mcpServers || {};
  cfg.mcpServers.layerling = { command: process.env.NODE_BIN, args: [process.env.MCP_SCRIPT] };
  fs.writeFileSync(p, JSON.stringify(cfg, null, 2) + "\n");
  console.log("Wrote", p);
'

# --- Claude Code (user scope), if the CLI is installed -------------------------
if command -v claude >/dev/null 2>&1; then
  say "Registering MCP server with Claude Code (user scope)"
  claude mcp remove layerling -s user >/dev/null 2>&1 || true
  claude mcp add layerling -s user -- "$NODE_BIN" "$MCP_SCRIPT"
else
  say "Claude Code CLI not found - skipped. Later: claude mcp add layerling -s user -- \"$NODE_BIN\" \"$MCP_SCRIPT\""
fi

# --- Double-clickable launcher -------------------------------------------------
LAUNCHER="$DEST/Start Layerling.command"
cat > "$LAUNCHER" <<EOF
#!/bin/sh
export PATH="$(dirname "$NODE_BIN"):\$PATH"
exec sh "$DEST/scripts/start-layerling.sh"
EOF
chmod +x "$LAUNCHER"

cat <<EOF

Done.
  Checkout:  $DEST
  Launcher:  $LAUNCHER   (double-click; keep its Terminal window open while you work)
  MCP:       $NODE_BIN $MCP_SCRIPT

Next:
  1. Double-click "Start Layerling.command" - it starts http://127.0.0.1:3000 and opens it.
  2. Fully quit and reopen Claude Desktop (Cmd+Q), then ask it to list Layerling editors.
     If no editor tab is open, the MCP server opens one for you.
EOF
