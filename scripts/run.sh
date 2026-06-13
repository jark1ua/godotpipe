#!/usr/bin/env bash
# ============================================================================
# run.sh — build the C# then launch the game.
# ----------------------------------------------------------------------------
#   ./scripts/run.sh             # desktop: opens a window (needs a GPU/display)
#   HEADLESS=1 ./scripts/run.sh  # server:  Xvfb + software OpenGL, no display
#
# Uses the Godot .NET build (GODOT_PATH) because this project contains C#.
# ============================================================================
set -euo pipefail

GODOT="${GODOT_PATH:-/home/user/tools/godot-mono/godot-mono}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Compile the C# so the engine has a fresh assembly to load.
if command -v dotnet >/dev/null 2>&1; then
  echo ">> Building C# (GodotPipe.csproj)"
  dotnet build "$ROOT/GodotPipe.csproj" -c Debug -v minimal
fi

if [ "${HEADLESS:-0}" = "1" ]; then
  export LIBGL_ALWAYS_SOFTWARE=1
  exec xvfb-run -a -s "-screen 0 1600x900x24" \
    "$GODOT" --path "$ROOT" \
    --rendering-method gl_compatibility --rendering-driver opengl3
else
  exec "$GODOT" --path "$ROOT"
fi
