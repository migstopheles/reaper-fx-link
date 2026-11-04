#!/usr/bin/env bash
# Installs FX Link from this checkout into REAPER's Scripts folder (for development).
# Most users should install via ReaPack instead; see README.md.
#
# Works from WSL, Git Bash, macOS and Linux. Set REAPER_RESOURCE_PATH to override the
# detected REAPER resource folder (e.g. for a portable install).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -n "${REAPER_RESOURCE_PATH:-}" ]]; then
  RESOURCE="$REAPER_RESOURCE_PATH"
elif grep -qi microsoft /proc/version 2>/dev/null; then
  RESOURCE="$(wslpath "$(cd /mnt/c && cmd.exe /c 'echo %APPDATA%' | tr -d '\r')")/REAPER"
elif [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]]; then
  RESOURCE="$APPDATA/REAPER"
elif [[ "$OSTYPE" == darwin* ]]; then
  RESOURCE="$HOME/Library/Application Support/REAPER"
else
  RESOURCE="${XDG_CONFIG_HOME:-$HOME/.config}/REAPER"
fi

if [[ ! -d "$RESOURCE" ]]; then
  echo "REAPER resource folder not found: $RESOURCE" >&2
  echo "Set REAPER_RESOURCE_PATH (REAPER: Options > Show REAPER resource path)." >&2
  exit 1
fi

DEST="$RESOURCE/Scripts/FX Link"
mkdir -p "$DEST"
rm -rf "$DEST/fxlink"
cp -R "$ROOT/FX Link.lua" "$ROOT/FX Link - Diagnostics.lua" "$ROOT/fxlink" "$DEST/"

echo "Installed to: $DEST"
echo "First time only: in REAPER, Actions > Show action list > New action... > Load ReaScript..."
echo "and choose \"FX Link.lua\" in that folder. Re-run the action to pick up changes."
