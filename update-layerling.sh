#!/bin/bash
# Updates the always-on layerling on dan-depot (docker/compose.local.yml, http://127.0.0.1:3100)
# to the newest release tag, rebuilds the image and restarts the container.
# The checkout's "origin" is the fork (gordondan/layerling, which holds this script and the compose
# file); "upstream" is henmedia/layerling. The fork's main is pulled first, then the upstream release
# is merged in and the result pushed back to the fork.
# If the new build fails or doesn't answer, the previous image and commit are put back.
#
# Usage: bash update-layerling.sh [--check] [--main] [--force]
#   --check   only report whether an update is available
#   --main    update to the tip of upstream/main instead of the newest release tag
#   --force   rebuild and redeploy even when already up to date
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE=(docker compose -f "$DIR/docker/compose.local.yml")
IMAGE="layerling-local"
URL="http://127.0.0.1:3100/"
BRANCH="main"
FORK="origin"
UPSTREAM="upstream"

CHECK=0; USE_MAIN=0; FORCE=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --main)  USE_MAIN=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\n==> %s\n' "$*"; }
fail() { printf '\n!! %s\n' "$*" >&2; exit 1; }

cd "$DIR"

# --- Preflight -----------------------------------------------------------------
command -v git >/dev/null    || fail "git is missing"
command -v docker >/dev/null || fail "docker is missing"
docker info >/dev/null 2>&1  || fail "Docker isn't running - start Docker Desktop and try again"
[ -f docker/.env ]           || fail "docker/.env is missing (it holds LAYERLING_MCP_TOKEN)"

# layerling joins the Cloudflare tunnel's Docker network (see docker/compose.local.yml);
# start the tunnel first if that network doesn't exist yet.
TUNNEL_DIR="$HOME/source/repos/cloudflare-tunnel"
TUNNEL_NET="cloudflare-tunnel"
ensure_tunnel_network() {
  docker network inspect "$TUNNEL_NET" >/dev/null 2>&1 && return 0
  [ -f "$TUNNEL_DIR/docker-compose.yml" ] || fail "Docker network '$TUNNEL_NET' is missing and $TUNNEL_DIR/docker-compose.yml isn't there to create it"
  say "Starting the Cloudflare tunnel (creates the '$TUNNEL_NET' network)"
  (cd "$TUNNEL_DIR" && docker compose up -d) || fail "Couldn't start the Cloudflare tunnel"
}
ensure_tunnel_network

current_branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$current_branch" = "$BRANCH" ] || fail "On branch '$current_branch'; switch to $BRANCH first"
git diff --quiet && git diff --cached --quiet || fail "Tracked files have local changes; commit or stash them first"

git remote get-url "$UPSTREAM" >/dev/null 2>&1 || fail "No '$UPSTREAM' remote; add it: git remote add $UPSTREAM https://github.com/henmedia/layerling.git"

# --- What's available ------------------------------------------------------------
say "Checking for updates"
git fetch --quiet "$FORK" "$BRANCH"
git fetch --quiet --tags "$UPSTREAM" "$BRANCH"
current_version="$(node -p 'require("./package.json").version' 2>/dev/null || sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' package.json | head -1)"
old_commit="$(git rev-parse HEAD)"

# Our own changes on the fork come first (fast-forward only).
fork_changed=0
if ! git merge-base --is-ancestor "$FORK/$BRANCH" HEAD; then
  [ "$CHECK" = 1 ] && echo "The fork's $BRANCH has commits not checked out here."
  if [ "$CHECK" != 1 ]; then
    git merge --quiet --ff-only "$FORK/$BRANCH" || fail "Local $BRANCH and $FORK/$BRANCH have diverged; sort it out by hand."
    fork_changed=1
  fi
fi

if [ "$USE_MAIN" = 1 ]; then
  target="$UPSTREAM/$BRANCH"
  target_label="$UPSTREAM/$BRANCH ($(git rev-parse --short "$target"))"
else
  target="$(git tag -l 'v[0-9]*' --sort=-v:refname | head -1)"
  [ -n "$target" ] || fail "No release tags found"
  target_label="$target"
fi
target_commit="$(git rev-parse "$target^{commit}")"

echo "Installed: $current_version ($(git rev-parse --short HEAD))"
echo "Available: $target_label"

if git merge-base --is-ancestor "$target_commit" HEAD && [ "$fork_changed" = 1 ] && [ "$CHECK" != 1 ]; then
  echo "Up to date with $target_label; deploying the fork's new commits."
elif git merge-base --is-ancestor "$target_commit" HEAD; then
  echo "Already up to date."
  [ "$CHECK" = 1 ] && exit 0
  if [ "$FORCE" != 1 ]; then
    # Still apply changes to docker/compose.local.yml (e.g. the tunnel network) without a rebuild.
    if docker image inspect "$IMAGE:latest" >/dev/null 2>&1; then
      "${COMPOSE[@]}" up -d --no-build
    fi
    exit 0
  fi
  say "--force: rebuilding anyway"
else
  echo "Update available: $(git rev-list --count HEAD.."$target_commit") new commits."
  [ "$CHECK" = 1 ] && exit 0
fi

# --- Keep the running image so we can roll back -------------------------------
if docker image inspect "$IMAGE:latest" >/dev/null 2>&1; then
  docker tag "$IMAGE:latest" "$IMAGE:previous"
fi

rollback() {
  say "Rolling back to $current_version ($(git rev-parse --short "$old_commit"))"
  git merge --quiet --ff-only "$old_commit" 2>/dev/null || git reset --quiet --keep "$old_commit"
  if docker image inspect "$IMAGE:previous" >/dev/null 2>&1; then
    docker tag "$IMAGE:previous" "$IMAGE:latest"
    "${COMPOSE[@]}" up -d --no-build --force-recreate
  fi
  fail "$1 - the previous version is running again."
}

# --- Install ------------------------------------------------------------------
say "Updating the checkout to $target_label"
if ! git merge --quiet --no-edit -m "Merge $target_label" "$target_commit"; then
  git merge --abort 2>/dev/null || true
  git reset --quiet --keep "$old_commit"
  fail "Merging $target_label into $BRANCH conflicted; nothing was deployed. Merge it by hand."
fi
new_version="$(node -p 'require("./package.json").version' 2>/dev/null || echo "?")"

say "Building and deploying $new_version (several minutes)"
"${COMPOSE[@]}" up -d --build || rollback "The build or start failed"

# --- Health check ---------------------------------------------------------------
printf 'Waiting for %s' "$URL"
for _ in $(seq 1 90); do
  if curl -fsS -o /dev/null "$URL"; then echo " - up."; up=1; break; fi
  printf '.'; sleep 2
done
[ "${up:-0}" = 1 ] || { echo; "${COMPOSE[@]}" logs --tail 40 layerling || true; rollback "layerling didn't answer after the update"; }

if ! docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' layerling | grep -qw "$TUNNEL_NET"; then
  echo "!! layerling isn't on the '$TUNNEL_NET' network; the Cloudflare tunnel will answer 502." >&2
fi

# Drop the old image layers now that the new one works.
docker image rm "$IMAGE:previous" >/dev/null 2>&1 || true
docker image prune -f --filter "label=com.docker.compose.project=layerling" >/dev/null 2>&1 || true

if [ "$(git rev-parse HEAD)" != "$(git rev-parse "$FORK/$BRANCH")" ]; then
  git push --quiet "$FORK" "HEAD:$BRANCH" || echo "!! Couldn't push $BRANCH to the fork ($FORK); push it by hand." >&2
fi

say "Done: layerling $current_version -> $new_version at $URL"
if ! git diff --quiet "$old_commit" HEAD -- scripts/layerling-mcp-*.mjs; then
  echo "The MCP server changed too - quit and reopen Claude Desktop / restart Claude Code to pick it up."
fi
