#!/usr/bin/env bash
# Runs the engine/model tests against a mock REAPER API, on Lua 5.4 (via Node + wasmoon).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/tests"
[[ -d node_modules ]] || npm install --silent
node run.mjs "$ROOT" tests/run_tests.lua
