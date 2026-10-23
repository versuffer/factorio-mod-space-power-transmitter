# Tests

Headless end-to-end tests for the mod's circuit features (Factorio **2.1**, Space Age required):

- link status virtual signals (`spt-link-up` / `spt-link-failing`, both absent = link down);
- the wiring gate: an unwired transmitter has no circuit network at all;
- the circuit "Enable if" condition (disabled = no upkeep port at all, so zero drain);
- the shared-pool energy round trip: a script-filled export port feeds the pool, the
  pool pays the upkeep through the import buffer (the link holds with no driver help),
  and the link starves when the donor runs dry;
- the blueprint tag restoration: condition and wire choices come back from build tags;
- child recreation after a hostile destruction of the hidden ports;
- save/load: invisible script wires and the status combinator slot are rebuilt on session start.

## How it works

`run.sh` builds a **temporary minimal mod directory** (symlinks only: base/space-age bundled set + `space-power-transmitter` + the `spt-signal-test` driver mod) - the real mods directory and its `mod-list.json` are never touched. Then it:

1. `--create`s a throwaway map (validates the data stage);
2. hosts it headless for ~30s: the driver places a transmitter at `(0,0)`, walks it through every link state, the pool round trip, the blueprint tag restoration and the child recreation, wires substations and a constant combinator to it, and asserts the signal values read back from the circuit networks;
3. re-hosts the map saved on shutdown: the driver asserts the combinator, the wires and the broadcast survived (`on_load` -> first-tick rebuild in the mod).

The Factorio binary is autodetected (macOS Steam install); override with `FACTORIO=/path/to/factorio`.

## Run

```bash
tests/run.sh
```

Exit code 0 = all green. The driver logs every check as `[spt-test] PASS/FAIL ...`; artifacts (logs, save, temp mod dir) are kept under `/tmp/spt-test.*` for debugging.

Run durations are `RUN1_SECONDS` / `RUN2_SECONDS` (defaults 30/15) if the machine is slow and the "RESULT" lines are missing.
