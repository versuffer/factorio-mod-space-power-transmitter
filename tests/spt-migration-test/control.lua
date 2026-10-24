-- Migration test driver for the space-power-transmitter (1.2.0 -> 1.3.0 save migration).
--
-- Phase "prepare" (the map is hosted with the 1.2.0 mod extracted from git):
--   places a transmitter at (0,0), pays the upkeep until the link establishes,
--   funds the v1 EXPORT ACCUMULATOR port ("spt-export-port"), and marks the
--   state prepared. The server saves the map on its clean shutdown.
-- Phase "verify" (the same map re-hosted with the 1.3.0 mod; the version change
-- fires on_configuration_changed in both the mod and this driver):
--   the old accumulator prototype no longer exists, so the engine removed the
--   old port with its banked charge (documented loss). The migration must:
--     1. keep the transmitter record and the children (import port, upkeep port) alive;
--     2. replace the export port with the fresh dynamic-priority interface
--        ("spt-export-interface", 1 GJ buffer, freshly empty);
--     3. carry the link state over: the link is up immediately, long before a
--        fresh 60-tick relink could complete (and nothing else could establish
--        it that fast - the driver pays the upkeep, which a carried link runs on;
--        the banked charge that could fake a relink died with the old port).
--
-- No circuit wiring here: the verdicts read remote transmitter_info, so the
-- driver runs unchanged under both mod versions.

local TRANSMITTER = "space-power-transmitter"
local EXPORT_V1 = "spt-export-port"      -- 1.x accumulator prototype (removed in 1.3.0)
local EXPORT_V2 = "spt-export-interface" -- 2.x dynamic-priority interface
local IMPORT_PORT = "spt-import-port"
local UPKEEP_PORT = "spt-upkeep-port-normal"

local PREPARE_WAIT = 220 -- ticks paid: relink needs 60, this leaves headroom

local function say(msg)
  log("[spt-migration-test] " .. tostring(msg))
end

local function find(surface, name, pos)
  return surface.find_entities_filtered({ name = name, position = pos, radius = 0.1, limit = 1 })[1]
end

local function tx_info(unit_number)
  local ok, info = pcall(remote.call, "space-power-transmitter", "transmitter_info", unit_number)
  return ok and info or nil
end

local function pay_upkeep(surface, pos)
  local port = find(surface, UPKEEP_PORT, pos)
  if port then port.energy = port.electric_buffer_size end
  return port
end

-- on_load hook (headless re-host): the phase machine resumes from storage
script.on_load(function()
  say("on_load: phase=" .. tostring(storage.mig and storage.mig.phase))
end)

script.on_configuration_changed(function()
  local state = storage.mig
  say("on_configuration_changed: phase=" .. tostring(state and state.phase))
  if state and state.phase == "prepared" then
    state.phase, state.verify_start = "verify", nil
  end
end)

script.on_event(defines.events.on_tick, function(event)
  local tick = event.tick
  if tick < 3 then return end
  local surface = game.surfaces[1]
  local state = storage.mig
  if not state then
    state = { phase = "prepare", failures = 0 }
    storage.mig = state
  end
  local pos = state.pos or { x = 0, y = 0 }
  local tx = find(surface, TRANSMITTER, pos)

  if state.phase == "prepare" then
    if not (tx and tx.valid) then
      tx = surface.create_entity({ name = TRANSMITTER, position = pos, force = "player" })
      if not tx then
        say("FAIL prepare: could not create the transmitter")
        say("MIGRATION RESULT: FAIL (prepare)")
        state.phase = "done"
        return
      end
      state.pos = tx.position
      state.prepared_at = tick
      say("transmitter placed at " .. serpent.line(tx.position))
    end
    pay_upkeep(surface, state.pos)
    if not state.funded then
      local export = find(surface, EXPORT_V1, state.pos)
      if export then
        export.energy = 2e8 -- funded accumulator: the charge is expected to be lost
        state.funded = true
        say(string.format("v1 export accumulator funded: %.0f MJ", export.energy / 1e6))
      end
    end
    if state.prepared_at and tick - state.prepared_at >= PREPARE_WAIT then
      local info = tx_info(tx.unit_number)
      if info and info.signal_state == "spt-link-up" then
        say("PASS v1 map prepared: link up under the 1.2.0 mod")
        say("MIGRATION PREP: " .. (state.failures == 0 and "PASS" or "FAIL")
          .. string.format(" (export accumulator E=%.0f MJ)",
            (find(surface, EXPORT_V1, state.pos) and find(surface, EXPORT_V1, state.pos).energy or 0) / 1e6))
      else
        state.failures = state.failures + 1
        say(string.format("FAIL prepare: link never established (%s)", tostring(info and info.signal_state)))
      end
      state.phase = "prepared"
    end

  elseif state.phase == "prepared" then
    -- pay the upkeep so the link state saved on shutdown is deterministic (up)
    if (tx and tx.valid) then pay_upkeep(surface, state.pos) end

  elseif state.phase == "verify" then
    if not state.verify_start then state.verify_start = tick end
    if not (tx and tx.valid) then
      state.failures = state.failures + 1
      say("FAIL migration: the transmitter record is gone at " .. serpent.line(state.pos))
      say("MIGRATION RESULT: FAIL")
      state.phase = "done"
      return
    end
    pay_upkeep(surface, state.pos)
    local t = tick - state.verify_start
    if t == 8 then
      -- carried link: must be up right away - a fresh relink needs 60 paid ticks
      local info = tx_info(tx.unit_number)
      if info and info.signal_state == "spt-link-up" then
        say("PASS migration: the link carried over immediately")
      else
        state.failures = state.failures + 1
        say(string.format("FAIL migration: link not carried (t=%d, info=%s)", tick,
          serpent.line(info)))
      end
    elseif t >= 30 and not state.checked_ports then
      state.checked_ports = true
      -- 1) the old accumulator port is gone: the prototype no longer exists, so a
      -- name-filtered surface scan is not even possible - absence of the prototype
      -- is what the engine removed the saved port against
      if not prototypes.entity[EXPORT_V1] then
        say("PASS migration: the v1 export accumulator prototype is gone (its saved entity was removed by the engine)")
      else
        state.failures = state.failures + 1
        say("FAIL migration: the v1 export prototype unexpectedly exists")
      end
      -- 2) the fresh dynamic-priority export interface exists at the tile
      local fresh = find(surface, EXPORT_V2, state.pos)
      if fresh and fresh.valid and fresh.type == "electric-energy-interface"
          and math.abs(fresh.electric_buffer_size - 1e9) < 1 then
        say(string.format("PASS migration: fresh export interface (E=%.0f MJ of 1000)", fresh.energy / 1e6))
      else
        state.failures = state.failures + 1
        say("FAIL migration: the export interface was not recreated at the transmitter tile")
      end
      -- 3) the surviving children were adopted (import + upkeep ports live)
      local import_port = find(surface, IMPORT_PORT, state.pos)
      local upkeep = find(surface, UPKEEP_PORT, state.pos)
      if import_port and import_port.valid and upkeep and upkeep.valid then
        say(string.format("PASS migration: children adopted (import E=%.0f MJ)",
          import_port.energy / 1e6))
      else
        state.failures = state.failures + 1
        say("FAIL migration: the import/upkeep ports were not adopted")
      end
      say("MIGRATION RESULT: " ..
        (state.failures == 0 and "PASS" or ("FAIL (" .. state.failures .. " failures)")))
      state.phase = "done"
    end
  end
end)
