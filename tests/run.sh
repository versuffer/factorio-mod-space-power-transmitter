#!/bin/bash
# End-to-end headless tests for the space-power-transmitter circuit features
# (1.2.0): link status virtual signals, the circuit "Enable if" condition and
# the save/load rebuild of the invisible script wires.
#
# What it does:
#   1. builds a temporary minimal mod directory (base/space-age + the mod under
#      test + the spt-signal-test driver mod) - the real mods directory and its
#      mod-list.json are never touched;
#   2. creates a throwaway map (validates the data stage);
#   3. runs a headless server: the driver places a transmitter, walks it through
#      every link state and asserts the signal values on the circuit network;
#   4. re-hosts the saved map: the driver asserts that the combinator, the
#      script wires and the status broadcast survived the save/load.
#
# Usage: tests/run.sh
# Env overrides: FACTORIO (binary path), RUN1_SECONDS (default 30),
# RUN2_SECONDS (default 15).
# Requires: Space Age (the mod's dependency); the game must not be running
# (Factorio holds an exclusive lock on its application-support directory).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD="$ROOT/space-power-transmitter"
TESTMOD="$ROOT/tests/spt-signal-test"
WORK="$(mktemp -d /tmp/spt-test.XXXXXX)"
FACTORIO="${FACTORIO:-$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio}"
RUN1_SECONDS="${RUN1_SECONDS:-30}"
RUN2_SECONDS="${RUN2_SECONDS:-15}"

fail() {
  echo "FAIL: $*"
  echo "(artifacts kept in $WORK)"
  exit 1
}

[ -x "$FACTORIO" ] || fail "Factorio binary not found at '$FACTORIO' (set FACTORIO=...)"
[ -d "$MOD" ] || fail "mod folder not found: $MOD"

# minimal mod directory: only the game and the two mods under test
mkdir -p "$WORK/mods"
ln -sfn "$MOD" "$WORK/mods/space-power-transmitter"
ln -sfn "$TESTMOD" "$WORK/mods/spt-signal-test"
cat > "$WORK/mods/mod-list.json" <<'EOF'
{
  "mods": [
    { "name": "base", "enabled": true },
    { "name": "elevated-rails", "enabled": true },
    { "name": "quality", "enabled": true },
    { "name": "recycler", "enabled": true },
    { "name": "space-age", "enabled": true },
    { "name": "space-power-transmitter", "enabled": true },
    { "name": "spt-signal-test", "enabled": true }
  ]
}
EOF
cat > "$WORK/server-settings.json" <<'EOF'
{
  "name": "spt-test",
  "description": "headless test",
  "visibility": { "public": false, "lan": false },
  "require_user_verification": false,
  "allow_commands": "true",
  "auto_pause": false
}
EOF

# run_server SECONDS: host the map for SECONDS seconds, then stop it and echo
# the [spt-test] lines the driver logged (script log() goes to the server stdout)
run_server() {
  "$FACTORIO" --start-server "$WORK/test.zip" \
    --server-settings "$WORK/server-settings.json" \
    --mod-directory "$WORK/mods" \
    > "$WORK/server.log" 2>&1 &
  local pid=$!
  sleep "$1"
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  grep -E "\[spt-test\]" "$WORK/server.log" || true
}

trap 'pkill -9 -f "start-server $WORK/test.zip" 2>/dev/null' EXIT

echo "== data stage"
pgrep -fl -i factorio > /dev/null \
  && fail "another Factorio instance is running (it holds the application-support lock)"
"$FACTORIO" --create "$WORK/test.zip" --mod-directory "$WORK/mods" > "$WORK/create.log" 2>&1 \
  || fail "data stage crashed (see $WORK/create.log)"
grep -iE "error while" "$WORK/create.log" > /dev/null \
  && fail "data stage errors (see $WORK/create.log)"
echo "ok"

echo "== run 1: link states + enable if"
run_server "$RUN1_SECONDS" > "$WORK/run1.txt"
cat "$WORK/run1.txt"
grep -q "RESULT: PASS" "$WORK/run1.txt" || fail "run 1 (see $WORK/server.log)"
grep -q "FAIL" "$WORK/run1.txt" && fail "run 1 had FAIL lines"

echo "== run 2: save/load persistence"
run_server "$RUN2_SECONDS" > "$WORK/run2.txt"
cat "$WORK/run2.txt"
grep -q "PERSIST RESULT: PASS" "$WORK/run2.txt" || fail "run 2 (see $WORK/server.log)"
grep -q "FAIL" "$WORK/run2.txt" && fail "run 2 had FAIL lines"

echo "ALL TESTS PASSED (artifacts in $WORK)"
