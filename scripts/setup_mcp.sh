#!/usr/bin/env bash
# ============================================================================
# setup_mcp.sh — build the godot-mcp server from source.
# ----------------------------------------------------------------------------
# godot-mcp (https://github.com/Coding-Solo/godot-mcp) is an MCP server that
# lets an AI client drive the Godot engine: run the project, launch the editor,
# read debug output, create scenes/nodes, query the Godot version, etc.
#
# This builds it from source into GODOT_MCP_DIR. A portable alternative that
# needs no build step is to point your MCP client at:  npx -y @coding-solo/godot-mcp
# ============================================================================
set -euo pipefail

GODOT_MCP_DIR="${GODOT_MCP_DIR:-/home/user/tools/godot-mcp}"

if [ ! -d "$GODOT_MCP_DIR/.git" ]; then
  echo ">> Cloning godot-mcp into $GODOT_MCP_DIR"
  git clone --depth 1 https://github.com/Coding-Solo/godot-mcp.git "$GODOT_MCP_DIR"
fi

cd "$GODOT_MCP_DIR"
echo ">> npm install"
npm install --no-audit --no-fund
echo ">> npm run build"
npm run build
echo ">> Built MCP server: $GODOT_MCP_DIR/build/index.js"
echo ">> Wire it into .mcp.json (see this repo's .mcp.json for the exact shape)."
