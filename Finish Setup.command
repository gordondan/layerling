#!/bin/bash
# Double-click to finish Layerling setup on this Mac (npm install + MCP registration).
cd "$(dirname "$0")" || exit 1
bash ./setup-layerling.sh "$(pwd)"
echo; read -n 1 -s -r -p "Press any key to close..."
