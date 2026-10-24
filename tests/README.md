# Tests

Headless end-to-end tests for the mod's circuit features (Factorio **2.1**, Space Age required):

- link status virtual signals (`spt-link-up` / `spt-link-failing`, both absent = link down);
- the wiring gate: an unwired transmitter has no circuit network at all;
- the circuit "Enable if" condition (disabled = no upkeep port at all, so zero drain);
- the shared-pool energy round trip: a script-filled export port feeds the pool, the
  pool pays the upkeep through the import buffer (the link holds with no driver help),
  and the link starves when the donor runs dry;
- self-heal: a funded export reserve alone holds the link on a network without own
  generation (the engine discharges the reserve at the upkeep rate, no driver help);
- surplus collection: a free-energy source powers the grid alone and the engine-side
  surplus flows into the dynamic-priority export port (the local accumulator stays
  untouched);
- the blueprint tag restoration: condition and wire choices come back from build tags;
- child recreation after a hostile destruction of the hidden ports;
- save/load: invisible script wires and the status combinator slot are rebuilt on session start;
- save migration 1.2.0 -> 1.3.0: a map built and funded under the released 1.2.0 mod
  (extracted from git) is re-hosted with the current mod - the removed
  `spt-export-port` accumulator is replaced by a recreated `spt-export-interface`,
  the surviving ports and children are adopted with their charges, and the link
  carries over.

## How it works

`run.sh` builds a **temporary minimal mod directory** (symlinks only: base/space-age bundled set + `space-power-transmitter` + a driver mod) - the real mods directory and its `mod-list.json` are never touched. Then it:

1. `--create`s a throwaway map (validates the data stage);
2. hosts it headless for ~40s: the driver places a transmitter at `(0,0)`, wires substations and a constant combinator to it, walks it through every link state, the pool round trip, the surplus collection, the blueprint tag restoration and the child recreation, and asserts the signal values read back from the circuit networks;
3. re-hosts the map saved on shutdown: the driver asserts the combinator, the wires and the broadcast survived (`on_load` -> first-tick rebuild in the mod);
4. re-hosts with a version-bumped copy of the mod: the driver asserts the config-change flow kept the settings and the link;
5. builds a second map with the **1.2.0 mod extracted from git** plus the `spt-migration-test` driver, hosts it (the driver funds the old export accumulator and asserts the link), then re-hosts the same save with the current mod and asserts the migration carried the record, the children and the link over.

The Factorio binary is autodetected (macOS Steam install); override with `FACTORIO=/path/to/factorio`.

## Load test

`tests/loadtest.sh` hosts a **copy of the `spt_2.1_test` save** (the bug-context save)
with a temporary mods directory (the user's mods as symlinks + the repo mod + the
`spt-load-test` driver) and builds two isolated networks on a fresh surface, in a
dedicated force (the save's own base and pool are untouched):

- network 1: transmitter + a 500 GW `primary-output` source;
- network 2: transmitter + a 400 GW `primary-input` load, no own generation - the
  link is established in advance from the export reserve, the load is placed only
  after both links are up.

The driver drains the load buffer every tick, so the engine refill is exactly the
power the grid served; both links are watched every tick (`transmitter_info`).
PASS = no real link drops AND the steady window (last third of the run) delivers
95% of the demand. Scenarios via `SCENARIO=` (default `below`): `spec` (as
above), `machine` (the same load as `secondary-input`, i.e. normal machines),
`below` (a 40 GW `primary-input` load). `spec` and `machine` are guaranteed
verdict FAILs even on a perfectly working mod (the starved primary-input upkeep
port / the ~60 GW per-pair ceiling - see the findings below); they exist to
collect data, run them explicitly.

Findings (2026-10-24):

- the machine-draw estimator read `import_pending` before the ration refill, so
  the steady-state draw always measured 0 and the pool only ever funded the
  20 MJ cushion (~600 MW) - fixed in control.lua (the baseline is now captured
  after the refill);
- with the fix a single transmitter pair transfers up to ~58-60 GW steady
  (the 1 GJ import buffer refilled once per tick is the hard ceiling);
- a `primary-input` load large enough to outdraw the grid competes with the
  primary-input upkeep port in the same priority tier and starves it: the link
  fails after exactly 300 starve ticks (normal machines are `secondary-input`
  and cannot do this).

## Run

```bash
tests/run.sh
```

Exit code 0 = all green. The driver logs every check as `[spt-test] PASS/FAIL ...`; artifacts (logs, save, temp mod dir) are kept under `/tmp/spt-test.*` for debugging.

Run durations are `RUN1_SECONDS` / `RUN2_SECONDS` / `RUN3_SECONDS` / `RUN4A_SECONDS` / `RUN4B_SECONDS` (defaults 40/15/15/12/10) if the machine is slow and the "RESULT" lines are missing.
