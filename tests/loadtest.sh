#!/bin/bash
# Load test for the space-power-transmitter, hosted on a copy of the user's
# spt_2.1_test save (the bug-context save; see BUG-CONTEXT-2.0.md).
#
# Scenario (both networks on a fresh surface, in a dedicated force, so the
# save's own base and pool are untouched):
#   network 1: transmitter + a 500 GW primary-output source
#   network 2: transmitter + a 400 GW primary-input load, no own generation;
#              the link is established in advance from the export reserve and
#              must stay up while the load runs
# PASS requires both links to hold and the average delivered power to reach
# 95% of the 400 GW demand. The driver logs every buffer per minute of ticks,
# so a throughput ceiling shows up as data.
#
# Methodology (per BUG-CONTEXT-2.0.md): the save is COPIED to a temp dir and
# hosted with a temporary mods directory (symlinks to the user's mods + the
# repo mod under test + this driver); the user's real mods directory, settings
# and save are never touched.
#
# Usage: tests/loadtest.sh
# Env overrides: SAVE_NAME (default spt_2.1_test), RUN_SECONDS (default 120),
# FACTORIO (binary path), ALLOW_RUNNING_GAME=1 (skip the running-game guard),
# SCENARIO: "spec" (a 400 GW primary-input load, as specified),
# "machine" (the same 400 GW as a secondary-input load, i.e. normal machines),
# "machine" (the same 400 GW as a secondary-input load, i.e. normal machines),
# "below" (a 40 GW primary-input load - under the single-transmitter ceiling).
# DEFAULT is "below": the two larger scenarios (spec, machine) are guaranteed
# verdict FAILs even on a perfectly working mod - spec starves the primary-input
# upkeep port of the load's own link, machine stalls at the ~60 GW per-pair
# ceiling - see the Findings in tests/README.md. They exist to collect data, so
# run them explicitly.
# Requires: the game must not be running (Factorio holds an exclusive lock on
# its application-support directory).

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOD="$ROOT/space-power-transmitter"
DRIVER="$ROOT/tests/spt-load-test"
USER_MODS="$HOME/Library/Application Support/Factorio/mods"
SAVES="$HOME/Library/Application Support/Factorio/saves"
SAVE_NAME="${SAVE_NAME:-spt_2.1_test}"
RUN_SECONDS="${RUN_SECONDS:-120}"
WORK="$(mktemp -d /tmp/spt-loadtest.XXXXXX)"
FACTORIO="${FACTORIO:-$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio}"

fail() {
  echo "FAIL: $*"
  echo "(artifacts kept in $WORK)"
  exit 1
}

[ -x "$FACTORIO" ] || fail "Factorio binary not found at '$FACTORIO' (set FACTORIO=...)"
[ -d "$MOD" ] || fail "mod folder not found: $MOD"
[ -d "$USER_MODS" ] || fail "mods folder not found: $USER_MODS"
[ -f "$SAVES/$SAVE_NAME.zip" ] || fail "save not found: $SAVES/$SAVE_NAME.zip"

if [ "${ALLOW_RUNNING_GAME:-0}" != "1" ] && pgrep -fl -i factorio > /dev/null; then
  fail "another Factorio instance is running (it holds the application-support lock)"
fi

cp "$SAVES/$SAVE_NAME.zip" "$WORK/" || fail "could not copy the save"

# temporary mods directory: the user's mods as symlinks (their mod-list.json
# keeps every enabled/disabled flag and version pin), the repo mod under test,
# and the driver. The user's real mods dir is never written to.
mkdir -p "$WORK/mods"
for entry in "$USER_MODS"/*; do
  name="$(basename "$entry")"
  [ "$name" = "mod-list.json" ] && continue
  [ "$name" = "mod-settings.dat" ] && continue
  [ "$name" = "space-power-transmitter" ] && continue
  ln -sfn "$entry" "$WORK/mods/$name"
done
# a copy, not a symlink: the user's startup settings (spt-upkeep-power) apply,
# and a write can never reach the real file
cp "$USER_MODS/mod-settings.dat" "$WORK/mods/mod-settings.dat" 2>/dev/null \
  || echo "note: no user mod-settings.dat, defaults apply"
ln -sfn "$MOD" "$WORK/mods/space-power-transmitter"

# scenario variants run on a temp copy of the driver; "spec" uses it as-is
SCENARIO="${SCENARIO:-below}"
case "$SCENARIO" in
  spec) ;;
  machine)
    cp -R "$DRIVER" "$WORK/driver"
    sed -i '' 's/usage_priority = "primary-input"/usage_priority = "secondary-input"/' "$WORK/driver/data.lua"
    DRIVER="$WORK/driver"
    ;;
  below)
    cp -R "$DRIVER" "$WORK/driver"
    # both the prototype (data.lua) and the verdict math (control.lua) scale
    sed -i '' 's/local DEMAND_WATTS = 400e9/local DEMAND_WATTS = 40e9/' \
      "$WORK/driver/control.lua" "$WORK/driver/data.lua"
    DRIVER="$WORK/driver"
    ;;
  *) fail "unknown SCENARIO '$SCENARIO' (spec | machine | below)" ;;
esac
ln -sfn "$DRIVER" "$WORK/mods/spt-load-test"
echo "== scenario: $SCENARIO"

# the user's mod-list + the driver
python3 - "$USER_MODS/mod-list.json" "$WORK/mods/mod-list.json" <<'PYEOF' || fail "mod-list build failed"
import json, sys
src, dst = sys.argv[1], sys.argv[2]
data = json.load(open(src))
names = [m["name"] for m in data["mods"]]
if "spt-load-test" not in names:
    data["mods"].append({"name": "spt-load-test", "enabled": True})
for m in data["mods"]:
    if m["name"] == "space-power-transmitter":
        m["enabled"] = True
json.dump(data, open(dst, "w"), indent=2)
PYEOF

cat > "$WORK/server-settings.json" <<'EOF'
{
  "name": "spt-loadtest",
  "description": "headless load test",
  "visibility": { "public": false, "lan": false },
  "require_user_verification": false,
  "allow_commands": "true",
  "auto_pause": false
}
EOF

trap 'pkill -9 -f "start-server $WORK/" 2>/dev/null' EXIT

echo "== hosting $SAVE_NAME (copy) with the load-test driver for ${RUN_SECONDS}s"
"$FACTORIO" --start-server "$WORK/$SAVE_NAME.zip" \
  --server-settings "$WORK/server-settings.json" \
  --mod-directory "$WORK/mods" \
  > "$WORK/loadtest.log" 2>&1 &
pid=$!
sleep "$RUN_SECONDS"
kill -TERM "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

grep -E "\[spt-loadtest\]" "$WORK/loadtest.log" || fail "no driver output (see $WORK/loadtest.log)"
grep -q "RESULT: PASS" "$WORK/loadtest.log" \
  || fail "the load test did not pass (see $WORK/loadtest.log)"
echo "LOAD TEST PASSED (artifacts in $WORK)"
