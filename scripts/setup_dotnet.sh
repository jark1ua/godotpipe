#!/usr/bin/env bash
# ============================================================================
# setup_dotnet.sh — install the C# toolchain this project needs.
# ----------------------------------------------------------------------------
# Two pieces, both required to build + run the C# parts:
#   1. the .NET 8 SDK            (compiles GodotPipe.csproj)
#   2. the Godot 4 .NET/Mono build  (a SEPARATE engine binary from the standard
#      one — only this flavor can load C#)
#
# The standard (non-.NET) Godot binary cannot open this project once it contains
# C#, so use the binary installed here (…/godot-mono) as GODOT_PATH.
#
# Env overrides:
#   GODOT_VERSION       (default 4.6.3-stable)
#   GODOT_MONO_PREFIX   (default /home/user/tools/godot-mono)
# ============================================================================
set -euo pipefail

GODOT_VERSION="${GODOT_VERSION:-4.6.3-stable}"
MONO_PREFIX="${GODOT_MONO_PREFIX:-/home/user/tools/godot-mono}"

echo ">> Installing .NET SDK 8.0 via apt"
apt-get update -y
apt-get install -y dotnet-sdk-8.0
echo ">> dotnet $(dotnet --version)"

ZIP="Godot_v${GODOT_VERSION}_mono_linux_x86_64.zip"
URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/${ZIP}"
mkdir -p "$MONO_PREFIX"
echo ">> Downloading Godot .NET build: $URL"
curl -L --fail --retry 3 -o "/tmp/$ZIP" "$URL"
unzip -o "/tmp/$ZIP" -d "$MONO_PREFIX" >/dev/null

BIN="$(find "$MONO_PREFIX" -type f -name 'Godot_v*_mono_linux.x86_64' | head -1)"
chmod +x "$BIN"
ln -sf "$BIN" "$MONO_PREFIX/godot-mono"
echo ">> Godot .NET ready: $("$MONO_PREFIX/godot-mono" --headless --version)"
echo ">> Now build the C#:  dotnet build GodotPipe.csproj"
