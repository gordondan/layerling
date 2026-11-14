#!/bin/zsh
# One-time setup: keep layerling designs as .lyl files in ~/projects/layerling-designs,
# version them in a private GitHub repo, and run layerling + the backup job at login.
set -e
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
DESIGNS="$HOME/projects/layerling-designs"
REPO_NAME="layerling-designs"
PORT=3100
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs/layerling"
SYNC="$HOME/.local/bin/layerling-designs-sync.sh"
UIDN="$(id -u)"

step() { print -P "\n%F{cyan}== $1%f"; }
fail() { print -P "%F{red}!! $1%f"; read -k 1 -s "?Press any key to close..."; exit 1; }

step "Checking tools"
command -v git >/dev/null || fail "git is missing (install Xcode command line tools: xcode-select --install)"
command -v npm >/dev/null || fail "npm is missing"
if ! command -v gh >/dev/null; then
  command -v brew >/dev/null || fail "GitHub CLI (gh) is missing and Homebrew isn't installed"
  brew install gh
fi
if ! gh auth status >/dev/null 2>&1; then
  step "Sign in to GitHub (a browser window will open)"
  gh auth login --hostname github.com --git-protocol https --web
fi
gh auth setup-git >/dev/null
GH_USER="$(gh api user -q .login)"
echo "GitHub user: $GH_USER"

step "Designs folder: $DESIGNS"
mkdir -p "$DESIGNS" "$LOGS" "$(dirname "$SYNC")" "$AGENTS"
cd "$DESIGNS"
[ -d .git ] || git init -q -b main
cat > .gitignore <<'EOF'
# layerling regenerates card pictures under a new name on every save
.thumbnails/
# atomic-write temp files
.*.tmp
.DS_Store
EOF
cat > .gitattributes <<'EOF'
*.lyl binary
*.skf binary
*.png binary
EOF
[ -f README.md ] || cat > README.md <<EOF
# layerling designs

Designs from the local layerling at http://localhost:$PORT, saved as .lyl files.
Committed and pushed every 15 minutes when something changed (launchd job \`com.layerling.designs-sync\`).

- Restore one design: open the .lyl in layerling (Open a design), or check out an older commit of it.
- Logs: ~/Library/Logs/layerling/
EOF
git add -A
git diff --cached --quiet || git commit -q -m "Set up layerling designs repo"

step "GitHub repo $GH_USER/$REPO_NAME (private)"
if ! git remote get-url origin >/dev/null 2>&1; then
  if gh repo view "$GH_USER/$REPO_NAME" >/dev/null 2>&1; then
    git remote add origin "https://github.com/$GH_USER/$REPO_NAME.git"
  else
    gh repo create "$REPO_NAME" --private --source=. --remote=origin --description "layerling designs (auto-backed up)"
  fi
fi
git push -u origin main

step "Backup job (every 15 minutes)"
cat > "$SYNC" <<'EOF'
#!/bin/zsh
# Commit and push layerling designs when anything changed.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$HOME/projects/layerling-designs" || exit 1
[ -f .git/index.lock ] && exit 0
git add -A
if ! git diff --cached --quiet; then
  summary="$(git diff --cached --name-status | awk '{print $1}' | sort | uniq -c | awk '{printf "%s%s %s", sep, $1, $2; sep=", "}')"
  git commit -q -m "Auto backup $(date '+%Y-%m-%d %H:%M') ($summary)"
fi
if [ -n "$(git rev-list "@{u}..HEAD" 2>/dev/null)" ] || ! git rev-parse "@{u}" >/dev/null 2>&1; then
  git push -q -u origin main && echo "$(date '+%F %T') pushed $(git rev-parse --short HEAD)"
fi
EOF
chmod +x "$SYNC"

cat > "$AGENTS/com.layerling.designs-sync.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.layerling.designs-sync</string>
  <key>ProgramArguments</key><array><string>/bin/zsh</string><string>-l</string><string>$SYNC</string></array>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOGS/designs-sync.log</string>
  <key>StandardErrorPath</key><string>$LOGS/designs-sync.log</string>
</dict></plist>
EOF

step "layerling at login on port $PORT, saving designs to the folder"
cat > "$AGENTS/com.layerling.server.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.layerling.server</string>
  <key>ProgramArguments</key><array>
    <string>/bin/zsh</string><string>-lc</string>
    <string>cd "$APP_DIR" &amp;&amp; exec npm run dev -- -p $PORT</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>LAYERLING_SHARED_PROJECTS_DIR</key><string>$DESIGNS</string>
    <key>LAYERLING_NEW_DESIGNS_ON_SERVER</key><string>always</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>$LOGS/server.log</string>
  <key>StandardErrorPath</key><string>$LOGS/server.log</string>
</dict></plist>
EOF

# Stop the copy started by hand so the background one can take the port.
for label in com.layerling.server com.layerling.designs-sync; do
  launchctl bootout "gui/$UIDN/$label" 2>/dev/null || true
done
pids="$(lsof -ti tcp:$PORT -sTCP:LISTEN 2>/dev/null || true)"
if [ -n "$pids" ]; then echo "Stopping the layerling already on port $PORT ($pids)"; kill $pids 2>/dev/null || true; sleep 2; fi

launchctl bootstrap "gui/$UIDN" "$AGENTS/com.layerling.server.plist"
launchctl bootstrap "gui/$UIDN" "$AGENTS/com.layerling.designs-sync.plist"

echo -n "Waiting for layerling to come up"
for i in {1..90}; do
  if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/"; then echo " - up."; break; fi
  echo -n "."; sleep 2
done
curl -fsS -o /dev/null "http://127.0.0.1:$PORT/" || fail "layerling didn't start - see $LOGS/server.log"

step "Done"
echo "Designs folder: $DESIGNS"
echo "Repo:           https://github.com/$GH_USER/$REPO_NAME"
echo "Logs:           $LOGS"
echo
echo "Turn it off later with:"
echo "  launchctl bootout gui/$UIDN/com.layerling.server; launchctl bootout gui/$UIDN/com.layerling.designs-sync"
echo
read -k 1 -s "?Press any key to close..."
