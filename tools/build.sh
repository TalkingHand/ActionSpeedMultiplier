#!/usr/bin/env bash
# Build TransferSpeedMultiplier.jar into the mod folder (one jar, no hot-reload logic jar).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="${HARNESS:-$ROOT/../PZTestHarness}"
cd "$ROOT"
BUILD_DIR="$ROOT/build" bash "$HARNESS/tools/javabuild.sh" "$ROOT/java/src/main/java" \
  "$ROOT/Contents/mods/TransferSpeedMultiplier/42/media/java/TransferSpeedMultiplier.jar"
