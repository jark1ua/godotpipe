#!/usr/bin/env bash
# ============================================================================
# setup_godot.sh — download + install the Godot 4 engine this project uses.
# ----------------------------------------------------------------------------
# The engine is a single self-contained binary (no system install needed).
# We pull it from GitHub Releases because that host is reachable here;
# godotengine.org is NOT required.
#
# Override defaults with env vars, e.g.:
#   GODOT_VERSION=4.6.3-stable GODOT_PREFIX=$HOME/tools/godot ./scripts/setup_godot.sh
# ============================================================================
set -euo pipefail

GODOT_VERSION="${GODOT_VERSION:-4.6.3-stable}"
GODOT_PREFIX="${GODOT_PREFIX:-/home/user/tools/godot}"
ZIP="Godot_v${GODOT_VERSION}_linux.x86_64.zip"
URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/${ZIP}"

mkdir -p "$GODOT_PREFIX"
echo ">> Downloading $URL"
curl -L --fail --retry 3 -o "/tmp/$ZIP" "$URL"
echo ">> Extracting into $GODOT_PREFIX"
unzip -o "/tmp/$ZIP" -d "$GODOT_PREFIX" >/dev/null
BIN="$(ls "$GODOT_PREFIX"/Godot_v*_linux.x86_64 | head -1)"
chmod +x "$BIN"
ln -sf "$BIN" "$GODOT_PREFIX/godot"
echo ">> Installed: $("$GODOT_PREFIX/godot" --headless --version)"
echo ">> Use this binary as GODOT_PATH: $GODOT_PREFIX/godot"
