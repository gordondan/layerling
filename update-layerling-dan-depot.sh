#!/bin/bash
# dan-depot wrapper for update-layerling.sh (untracked, so it never blocks updates).
# The upstream script deploys with docker/compose.local.yml only, which binds
# 127.0.0.1:3100. This re-applies docker/compose.dan-depot.yml afterwards so the
# editor and its token-protected MCP bridge stay reachable at http://192.168.1.228:3100.
# Usage: ./update-layerling-dan-depot.sh [--check] [--main] [--force]
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
docker info >/dev/null 2>&1 || { echo "!! Cannot reach Docker. If you were just added to the docker group, log out and back in (or run: newgrp docker)." >&2; exit 1; }
bash "$DIR/update-layerling.sh" "$@"; status=$?
case " $* " in *" --check "*) exit $status ;; esac
echo; echo "==> Re-applying LAN port (compose.dan-depot.yml)"
docker compose -f "$DIR/docker/compose.local.yml" -f "$DIR/docker/compose.dan-depot.yml" up -d --no-build || exit 1
for _ in $(seq 1 30); do curl -fsS -o /dev/null http://192.168.1.228:3100/ && { echo "==> Layerling is up at http://192.168.1.228:3100"; exit $status; }; sleep 2; done
echo "!! Layerling did not answer at http://192.168.1.228:3100" >&2; exit 1
