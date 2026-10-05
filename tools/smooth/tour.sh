#!/bin/bash
# Frame meter for Cortexy: runs scenarios on the real panel (it shows on screen; the screen must be awake and
# unlocked) and prints how late the main thread made frames: hitch ms per second (< 5 smooth) and the worst frame.
#   tools/smooth/tour.sh [scenario...]          the working tree; default: every scenario
#   REF=v0.2.1 tools/smooth/tour.sh typing      an older version, to compare
# Scenarios: slide typing openLong pages search hover firstOpenCold firstOpenWarm typingCPU (the last needs no screen)
# It builds a copy under build/smooth (an optimized build with testing on), with SmoothTour.swift added to its tests;
# the repo's own Tests/ never get it.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$SRC/tools/smooth"
OUT="$SRC/build/smooth"
if [[ -n "${REF:-}" ]]; then
  DEST="$OUT/repo-$REF"; mkdir -p "$DEST"
  find "$DEST" -mindepth 1 -maxdepth 1 ! -name .build -exec rm -rf {} +
  git -C "$SRC" archive "$REF" | tar -x -C "$DEST"
else
  DEST="$OUT/repo"; mkdir -p "$DEST"
  rsync -a --delete --exclude .git --exclude .build --exclude build "$SRC/" "$DEST/"
fi
cp "$HERE/SmoothTour.swift" "$DEST/Tests/CortexyTests/SmoothTour.swift"
cd "$DEST"
PLUG="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
swift build -c release --build-tests -Xswiftc -enable-testing -Xswiftc -plugin-path -Xswiftc "$PLUG" 2>&1 | grep -E "error:" || true
SCEN=("$@"); [[ ${#SCEN[@]} -eq 0 ]] && SCEN=(slide typing openLong pages search hover firstOpenCold firstOpenWarm)
for s in "${SCEN[@]}"; do
  # each scenario in its own process: a cold start means cold
  swift test -c release --skip-build -Xswiftc -enable-testing -Xswiftc -plugin-path -Xswiftc "$PLUG" --filter "SmoothTour.*\b$s\b" 2>&1 | grep -E "^SMOOTH|✘|error" || true
done
