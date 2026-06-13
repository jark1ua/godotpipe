#!/usr/bin/env bash
# ============================================================================
# capture.sh — headless proof renders.
# ----------------------------------------------------------------------------
# Runs tools/capture.tscn under Xvfb + software GL with the Godot .NET build,
# writing docs/<scene>.png. With no args it regenerates all three scene shots;
# pass "scene out" to capture just one:
#   ./scripts/capture.sh res://scenes/world.tscn res://docs/world.png
# ============================================================================
set -euo pipefail

GODOT="${GODOT_PATH:-/home/user/tools/godot-mono/godot-mono}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LIBGL_ALWAYS_SOFTWARE=1

# The world scene needs the compiled C# assembly present.
if command -v dotnet >/dev/null 2>&1; then
  dotnet build "$ROOT/GodotPipe.csproj" -c Debug -v quiet
fi

shoot() {
  echo ">> $1 -> $2"
  xvfb-run -a -s "-screen 0 1600x900x24" "$GODOT" --path "$ROOT" \
    --rendering-method gl_compatibility --rendering-driver opengl3 \
    "$ROOT/tools/capture.tscn" -- "$1" "$2" 2>&1 | grep -E "CAPTURE_RESULT" || true
}

if [ "$#" -ge 2 ]; then
  shoot "$1" "$2"
else
  shoot res://scenes/title_screen.tscn res://docs/title_screen.png
  shoot res://scenes/main_menu.tscn   res://docs/main_menu.png
  shoot res://scenes/world.tscn       res://docs/world.png
fi
echo ">> Screenshots in $ROOT/docs/"
