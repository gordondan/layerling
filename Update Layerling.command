#!/bin/bash
# Double-click to update the always-on layerling on port 3100 to the newest release.
cd "$(dirname "$0")" || exit 1
bash ./update-layerling.sh "$@"
echo; read -n 1 -s -r -p "Press any key to close..."
