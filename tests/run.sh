#!/bin/bash
# End-to-end headless tests for the space-power-transmitter circuit features
# (1.3.0): link status virtual signals, the circuit "Enable if" condition, the
# save/load rebuild of the invisible script wires, the dynamic-priority
# export port's engine-side surplus collection, and the 1.2.0 -> 1.3.0 save
# migration.
#
# What it does:
#   1. builds a temporary minimal mod directory (base/space-age + the mod under
#      test + the spt-signal-test driver) - the real mods directory and its
#      mod-list.json are never touched;
#   2. creates a throwaway map (validates the data stage);
#   3. runs a headless server: the driver places a transmitter, walks it through
#      every link state and asserts the signal values on the circuit network;
#   4. re-hosts the saved map: the driver asserts that the combinator, the
#      script wires and the status broadcast survived the save/load;
#   5. re-hosts with a version-bumped copy: the driver asserts the config-change
#      flow (settings + link carried over);
#   6. build a second map with the 1.2.0 mod (extracted from git), host it (the
#      spt-migration-test driver funds the link and the old export accumulator),
#      then re-host the same save with the current mod and assert the record,
#      the fresh export interface and the carried link.
#
# Usage: tests/run.sh
# Env overrides: FACTORIO (binary path), RUN1_SECONDS (default 40),
# RUN2_SECONDS / RUN3_SECONDS / RUN4A_SECONDS / RUN4B_SECONDS
# (defaults 15/15/12/10), MIG_COMMIT (default: the last 1.x commit).
# Requires: Space Age (the mod's dependency); the game must not be running
# (Factorio holds an exclusive lock on its application-support directory).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD="$ROOT/space-power-transmitter"
TESTMOD="$ROOT/tests/spt-signal-test"
MIGMOD="$ROOT/tests/spt-migration-test"
WORK="$(mktemp -d /tmp/spt-test.XXXXXX)"
FACTORIO="${FACTORIO:-$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio}"
RUN1_SECONDS="${RUN1_SECONDS:-40}"
RUN2_SECONDS="${RUN2_SECONDS:-15}"
RUN3_SECONDS="${RUN3_SECONDS:-15}"
RUN4A_SECONDS="${RUN4A_SECONDS:-12}"
RUN4B_SECONDS="${RUN4B_SECONDS:-10}"
# the last commit of the 1.x line: its mod hosts run 4a's map for the migration
MIG_COMMIT="${MIG_COMMIT:-230c998}"

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

# run_server MAP MODDIR OUTBASE SECONDS: host the map for SECONDS seconds, then
# stop it and echo the [spt-test] lines the driver logged (script log() goes to
# the server stdout)
run_server() {
  local map="$1" moddir="$2" out="$3" seconds="$4"
  "$FACTORIO" --start-server "$map" \
    --server-settings "$WORK/server-settings.json" \
    --mod-directory "$moddir" \
    > "$out.log" 2>&1 &
  local pid=$!
  sleep "$seconds"
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  grep -E "\[spt-.*test\]" "$out.log" || true
}

check_results() {
  local out="$1" wanted="$2"
  grep -q "$wanted" "$out" || fail "$wanted missing (see $out.log)"
  grep -q "FAIL" "$out" && fail "$out had FAIL lines"
}

trap 'pkill -9 -f "start-server $WORK/" 2>/dev/null' EXIT

echo "== data stage"
# the running game holds the application-support lock; an isolated --config write-data
# (see ALLOW_RUNNING_GAME) does not touch it, so the guard can be opted out
if [ "${ALLOW_RUNNING_GAME:-0}" != "1" ]; then
  pgrep -fl -i factorio > /dev/null \
    && fail "another Factorio instance is running (it holds the application-support lock)"
fi
"$FACTORIO" --create "$WORK/test.zip" --mod-directory "$WORK/mods" > "$WORK/create.log" 2>&1 \
  || fail "data stage crashed (see $WORK/create.log)"
grep -iE "error while" "$WORK/create.log" > /dev/null \
  && fail "data stage errors (see $WORK/create.log)"
echo "ok"

echo "== run 1: link states + enable if + surplus"
run_server "$WORK/test.zip" "$WORK/mods" "$WORK/run1" "$RUN1_SECONDS" > "$WORK/run1.txt"
cat "$WORK/run1.txt"
check_results "$WORK/run1.txt" "RESULT: PASS"

echo "== run 2: save/load persistence"
run_server "$WORK/test.zip" "$WORK/mods" "$WORK/run2" "$RUN2_SECONDS" > "$WORK/run2.txt"
cat "$WORK/run2.txt"
check_results "$WORK/run2.txt" "PERSIST RESULT: PASS"

echo "== run 3: on_configuration_changed (mod version change)"
# replace the symlink with a copy and bump the version in the copy: a version change
# fires on_configuration_changed for the mod (the repo's info.json is not touched)
rm "$WORK/mods/space-power-transmitter"
cp -R "$MOD" "$WORK/mods/space-power-transmitter"
sed -i '' 's/"version": "1.3.0"/"version": "1.3.1"/' "$WORK/mods/space-power-transmitter/info.json"
run_server "$WORK/test.zip" "$WORK/mods" "$WORK/run3" "$RUN3_SECONDS" > "$WORK/run3.txt"
cat "$WORK/run3.txt"
check_results "$WORK/run3.txt" "CONFIG RESULT: PASS"

echo "== run 4a: build a 1.2.0 map (the mod extracted from git) + fund the link"
# the migration driver only needs the transmitter running under the 1.x mod
rm -rf "$WORK/mods-mig" "$WORK/mig1"
mkdir -p "$WORK/mods-mig" "$WORK/mig1"
git -C "$ROOT" archive "$MIG_COMMIT" space-power-transmitter | tar -x -C "$WORK/mig1" \
  || fail "could not extract the 1.2.0 mod from git (commit $MIG_COMMIT)"
grep -q '"version": "1.2.0"' "$WORK/mig1/space-power-transmitter/info.json" \
  || fail "the extracted mod is not 1.2.0 (commit $MIG_COMMIT)"
ln -sfn "$WORK/mig1/space-power-transmitter" "$WORK/mods-mig/space-power-transmitter"
ln -sfn "$MIGMOD" "$WORK/mods-mig/spt-migration-test"
cat > "$WORK/mods-mig/mod-list.json" <<'EOF'
{
  "mods": [
    { "name": "base", "enabled": true },
    { "name": "elevated-rails", "enabled": true },
    { "name": "quality", "enabled": true },
    { "name": "recycler", "enabled": true },
    { "name": "space-age", "enabled": true },
    { "name": "space-power-transmitter", "enabled": true },
    { "name": "spt-migration-test", "enabled": true }
  ]
}
EOF
"$FACTORIO" --create "$WORK/migration.zip" --mod-directory "$WORK/mods-mig" \
  > "$WORK/create-mig.log" 2>&1 || fail "1.2.0 data stage crashed (see $WORK/create-mig.log)"
grep -iE "error while" "$WORK/create-mig.log" > /dev/null \
  && fail "1.2.0 data stage errors (see $WORK/create-mig.log)"
run_server "$WORK/migration.zip" "$WORK/mods-mig" "$WORK/run4a" "$RUN4A_SECONDS" > "$WORK/run4a.txt"
cat "$WORK/run4a.txt"
check_results "$WORK/run4a.txt" "MIGRATION PREP: PASS"

echo "== run 4b: re-host the 1.2.0 save with the current mod (migration)"
rm -rf "$WORK/mods-mig/space-power-transmitter"
ln -sfn "$MOD" "$WORK/mods-mig/space-power-transmitter"
run_server "$WORK/migration.zip" "$WORK/mods-mig" "$WORK/run4b" "$RUN4B_SECONDS" > "$WORK/run4b.txt"
cat "$WORK/run4b.txt"
check_results "$WORK/run4b.txt" "MIGRATION RESULT: PASS"

echo "ALL TESTS PASSED (artifacts in $WORK)"
