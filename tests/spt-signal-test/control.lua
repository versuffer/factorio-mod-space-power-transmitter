-- End-to-end test driver for the space-power-transmitter circuit features (1.2.0).
-- Runs the transmitter through every link state by filling and starving the hidden
-- upkeep port, asserts the status signal values, exercises the circuit "Enable if"
-- condition, the shared-pool energy round trip (donor export -> pool -> import ->
-- upkeep), the blueprint tag restoration (condition + wire choices), the child
-- recreation after a hostile destruction, the force-build (destroy + rebuild) cycle,
-- and the save/load rebuild of the script wires.
--
-- Signal expectations (read back from the transmitter's circuit network):
--   link up    -> spt-link-up = 1, spt-link-failing = 0
--   starving   -> spt-link-failing = 1, spt-link-up = 0
--   link down  -> both signals absent (0)
--
-- The script wires follow the player's wiring lazily (a staggered poll, up to 60
-- ticks), so the substations are wired right after the transmitter is placed, and
-- checks that depend on the poll wait ~70 ticks. State lives in storage.test_state:
-- after a save/load cycle the run resumes in the "persist" phase and asserts that
-- the combinator, wires and values were rebuilt.

local TRANSMITTER = "space-power-transmitter"
local UPKEEP_PORT = "spt-upkeep-port-normal"
local ENABLE_CONDITION_TAG = "spt_enable_condition"
local SIGNAL_NAMES = { "spt-link-up", "spt-link-failing" }
local RED = defines.wire_connector_id.circuit_red
local GREEN = defines.wire_connector_id.circuit_green

local function say(msg)
  log("[spt-test] " .. tostring(msg))
end

local function upkeep_port(surface, position)
  return surface.find_entities_filtered({
    name = UPKEEP_PORT,
    position = position,
    radius = 0.1,
    limit = 1,
  })[1]
end

local function read_signals(entity, connector)
  local network = entity.get_circuit_network(connector)
  local values = {}
  for _, name in ipairs(SIGNAL_NAMES) do
    values[name] = network and network.get_signal({ type = "virtual", name = name }) or "no-network"
  end
  return values
end

-- expected: { ["spt-link-up"] = 1 } etc.; every other signal must be 0
-- ("no-network" counts as 0 for absent expectations)
local function check(state, tag, entity, connector, expected)
  local values = read_signals(entity, connector)
  local ok = true
  for name, value in pairs(values) do
    local want = expected[name] or 0
    if value ~= want and not (want == 0 and value == "no-network") then ok = false end
  end
  if ok then
    say("PASS " .. tag)
  else
    state.failures = state.failures + 1
    say(string.format("FAIL %s: expected %s, got %s",
      tag, serpent.line(expected), serpent.line(values)))
  end
end

-- set in on_load: this session resumed from a save (a real save/load cycle).
-- A module local, NOT a storage field - on_load must never modify storage.
local resumed = false

script.on_load(function()
  resumed = true
end)

script.on_init(function()
  -- the session that created the map is not a reload: the persist phase only
  -- runs in a session resumed via on_load
  if not storage.test_state then storage.test_state = { failures = 0, phase = "new" } end
  storage.test_state.fresh_session = true
end)

script.on_event(defines.events.on_tick, function(event)
  local tick = event.tick
  if tick < 2 then return end
  if not storage.test_state then storage.test_state = { failures = 0, phase = "new" } end
  local state = storage.test_state
  local transmitter = state.transmitter

  if state.phase == "persist" then
    -- this session must be a RELOAD (on_load), not the one that created the map;
    -- the poll re-attaches the script wires within ~60 ticks, restoring the
    -- status broadcast, so the check itself waits 70 ticks after the reload
    if not resumed then return end
    if state.fresh_session then
      state.fresh_session = nil
      resumed = false -- re-armed by on_load in the next session
      return
    end
    if not state.resumed_tick then state.resumed_tick = tick end
    if tick - state.resumed_tick < 70 then return end
    local comb = transmitter.surface.find_entities_filtered({
      name = "spt-status-combinator", position = transmitter.position, radius = 0.1, limit = 1 })[1]
    if comb then
      local behavior = comb.get_control_behavior()
      say("persist diagnostics: combinator sections=" ..
        (behavior and tostring(behavior.sections_count) or "no-behavior"))
    end
    local info = remote.call("space-power-transmitter", "transmitter_info", transmitter.unit_number)
    local expected = {}
    if info.signal_state then expected[info.signal_state] = 1 end
    check(state, "persisted transmitter (save/load)", transmitter, RED, expected)
    say("PERSIST RESULT: " .. (state.failures == 0 and "PASS" or ("FAIL (" .. state.failures .. " failures)")))
    state.phase = "done2"
    return
  elseif state.phase == "done2" or state.phase == "done" then
    return
  end

  local phase, phase_start = state.phase, state.phase_start

  if not transmitter then
    local surface = game.surfaces[1]
    transmitter = surface.create_entity({ name = TRANSMITTER, position = { 0, 0 }, force = "player" })
    if not transmitter then
      state.failures = state.failures + 1
      say("FAIL: could not create the transmitter")
      return
    end
    state.transmitter = transmitter
    -- player-origin wires onto both colors: the status signals ride either color
    -- (the invisible script wires follow them within the ~60 tick poll)
    local red_pole = surface.create_entity({ name = "substation", position = { 6, 0 }, force = "player" })
    local green_pole = surface.create_entity({ name = "substation", position = { -6, 0 }, force = "player" })
    state.red_pole = red_pole
    state.green_pole = green_pole
    transmitter.get_wire_connector(RED, true).connect_to(
      red_pole.get_wire_connector(RED, true), false, defines.wire_origin.player)
    transmitter.get_wire_connector(GREEN, true).connect_to(
      green_pole.get_wire_connector(GREEN, true), false, defines.wire_origin.player)
    state.phase, state.phase_start = "prime", tick
    return
  end

  local t = tick - phase_start
  local port = upkeep_port(transmitter.surface, transmitter.position)

  if phase == "prime" then
    -- wait for the mod to pick the transmitter up, then pay the upkeep every tick
    if t == 3 then
      local count = remote.call("space-power-transmitter", "transmitter_count")
      say("registered transmitters: " .. tostring(count))
      if count < 1 then
        state.failures = state.failures + 1
        say("FAIL: the transmitter was not registered")
      end
      check(state, "fresh transmitter is down (unwired)", transmitter, RED, {})
      -- wiring gate: a transmitter with no player wire has no circuit network at all
      -- (the same predicate hides the Enable-if panel). The main transmitter is wired
      -- by the driver below, so the gate is checked on a bare one.
      local bare = transmitter.surface.create_entity({
        name = TRANSMITTER, position = { 30, 0 }, force = "player" })
      if bare.get_circuit_network(RED) == nil
          and bare.get_circuit_network(GREEN) == nil then
        say("PASS unwired transmitter has no circuit network")
      else
        state.failures = state.failures + 1
        say("FAIL: unwired transmitter has a circuit network (script wires not gated)")
      end
      bare.destroy()
    elseif t > 3 and port then
      port.energy = port.electric_buffer_size
    end
    if t >= 120 then
      check(state, "link established", transmitter, RED, { ["spt-link-up"] = 1 })
      state.phase, state.phase_start = "starve", tick
    end

  elseif phase == "starve" then
    -- no upkeep payment: the buffer drains within 2 ticks, the starve countdown
    -- runs 300 ticks, then the link drops
    if t == 100 then
      check(state, "starving warns (link failing)", transmitter, RED, { ["spt-link-failing"] = 1 })
    elseif t >= 340 then
      check(state, "link dropped", transmitter, RED, {})
      state.phase, state.phase_start = "relink", tick
    end

  elseif phase == "relink" then
    if port then port.energy = port.electric_buffer_size end
    if t >= 120 then
      check(state, "link restored", transmitter, RED, { ["spt-link-up"] = 1 })
      state.phase, state.phase_start = "leak", tick
    end

  elseif phase == "leak" then
    -- the status broadcast must reach both player-wired poles...
    check(state, "signals on the red-wired pole", state.red_pole, RED, { ["spt-link-up"] = 1 })
    check(state, "signals on the green-wired pole", state.green_pole, GREEN, { ["spt-link-up"] = 1 })
    -- ...and the other color's network must stay clean (no network = clean too)
    local leak = read_signals(state.green_pole, RED)
    if (leak["spt-link-up"] == "no-network" or leak["spt-link-up"] == 0)
        and (leak["spt-link-failing"] == "no-network" or leak["spt-link-failing"] == 0) then
      say("PASS no signal leak into the red network of the green-wired pole")
    else
      state.failures = state.failures + 1
      say("FAIL: signals leaked into the red network: " .. serpent.line(leak))
    end
    state.phase, state.phase_start = "pool", tick

  elseif phase == "pool" then
    -- the energy round trip through the shared pool: with the driver NOT paying the
    -- upkeep, the only energy source is the transmitter's own export port (filled by
    -- the script). The pool must collect from the donor export, inject into the
    -- import buffer, and the import-fed upkeep must hold the link.
    if t == 1 then
      local surface = transmitter.surface
      local export = surface.find_entities_filtered({
        name = "spt-export-port", position = transmitter.position, radius = 0.1, limit = 1 })[1]
      if export then
        export.energy = 5e8 -- 500 MJ of donor charge
      else
        state.failures = state.failures + 1
        say("FAIL: the export port was not found")
      end
      remote.call("space-power-transmitter", "set_pool", transmitter.force.name, 0)
      state.pool_donor = export
    elseif t == 40 then
      -- ~40 ticks of self-paid upkeep (10 MJ/tick drawn from the donor through the
      -- pool: 500 MJ / 10 MJ per tick = the donor dries at ~t=50)
      check(state, "pool round trip holds the link", transmitter, RED, { ["spt-link-up"] = 1 })
      local export = state.pool_donor
      if export and export.valid and export.energy < 4.5e8 then
        say("PASS pool drained the donor export port")
      else
        state.failures = state.failures + 1
        say("FAIL: the donor export port was not drained: " .. tostring(export and export.energy))
      end
      local pool = remote.call("space-power-transmitter", "pool", transmitter.force.name)
      if pool ~= nil and pool < 1e7 then
        say("PASS pool balance stays near zero (pure transit)")
      else
        state.failures = state.failures + 1
        say("FAIL: pool balance is not transiting: " .. tostring(pool))
      end
    elseif t == 110 then
      -- the donor ran dry at ~t=50: the link must be starving (failing), not dropped
      -- (the 300-tick starve countdown is still running) and not healthy
      check(state, "starving when the pool source runs dry", transmitter, RED,
        { ["spt-link-failing"] = 1 })
      -- the driver resumes paying: the link re-establishes by itself
    elseif t > 110 and port then
      port.energy = port.electric_buffer_size
    end
    if t >= 185 then
      check(state, "link re-established after the pool recovered", transmitter, RED,
        { ["spt-link-up"] = 1 })
      state.phase, state.phase_start = "enable", tick
    end

  elseif phase == "enable" then
    -- circuit "Enable if": a constant combinator drives signal-green; the condition
    -- enables the transmitter only while signal-green > 0
    if t == 1 then
      local driver = transmitter.surface.create_entity({
        name = "constant-combinator", position = { 0, 4 }, force = "player" })
      state.driver = driver
      driver.get_wire_connector(RED, true).connect_to(
        transmitter.get_wire_connector(RED, true), false, defines.wire_origin.player)
      local behavior = driver.get_or_create_control_behavior()
      local section = behavior.get_section(1) or behavior.add_section()
      section.set_slot(1, {
        value = { type = "virtual", name = "signal-green", quality = "normal" },
        min = 0,
      })
      local ok = remote.call("space-power-transmitter", "set_enable_condition",
        transmitter.unit_number,
        { signal = { type = "virtual", name = "signal-green" }, comparator = ">", constant = 0 })
      if not ok then
        state.failures = state.failures + 1
        say("FAIL: set_enable_condition returned false")
      end
    elseif t >= 4 and not state.checked_disabled then
      state.checked_disabled = true
      local info = remote.call("space-power-transmitter", "transmitter_info", transmitter.unit_number)
      if port == nil and info.link_down == true and info.disabled == true then
        say("PASS disabled: no upkeep port (zero drain), link down")
      else
        state.failures = state.failures + 1
        say(string.format("FAIL disabled state: port=%s info=%s",
          tostring(port), serpent.line(info)))
      end
    elseif t >= 6 and not state.pulsed then
      state.pulsed = true
      local behavior = state.driver.get_or_create_control_behavior()
      local section = behavior.get_section(1)
      section.set_slot(1, {
        value = { type = "virtual", name = "signal-green", quality = "normal" },
        min = 1,
      })
    elseif t >= 8 and t < 150 and port then
      -- a powered local grid: pay the upkeep so the link can re-establish
      port.energy = port.electric_buffer_size
    elseif t >= 150 and not state.checked_enabled then
      state.checked_enabled = true
      local info = remote.call("space-power-transmitter", "transmitter_info", transmitter.unit_number)
      if port ~= nil and info.disabled == false
          and read_signals(transmitter, RED)["spt-link-up"] == 1 then
        say("PASS re-enabled: upkeep port back, link re-established, spt-link-up=1")
      else
        state.failures = state.failures + 1
        say(string.format("FAIL re-enabled state: port=%s info=%s signals=%s",
          tostring(port), serpent.line(info), serpent.line(read_signals(transmitter, RED))))
      end
    elseif t >= 154 and not state.cleared_condition then
      state.cleared_condition = true
      remote.call("space-power-transmitter", "set_enable_condition", transmitter.unit_number, nil)
    elseif t >= 158 and not state.checked_cleared then
      state.checked_cleared = true
      local cond = remote.call("space-power-transmitter", "get_enable_condition", transmitter.unit_number)
      local info = remote.call("space-power-transmitter", "transmitter_info", transmitter.unit_number)
      if cond == nil and info.disabled == false then
        say("PASS condition cleared: transmitter stays enabled")
      else
        state.failures = state.failures + 1
        say("FAIL condition clear: cond=" .. serpent.line(cond) .. " info=" .. serpent.line(info))
      end
      say("RESULT: " .. (state.failures == 0 and "PASS" or ("FAIL (" .. state.failures .. " failures)")))
      state.phase, state.phase_start = "blueprint", tick
    end

  elseif phase == "blueprint" then
    -- the blueprint tag flow: a built transmitter picks the condition and the wire
    -- choices back up from the event tags (what the engine delivers for robot-built
    -- ghosts)
    if t == 1 then
      local surface = transmitter.surface
      local fresh = surface.create_entity({
        name = TRANSMITTER, position = { 20, 0 }, force = "player" })
      state.tagged = fresh
      script.raise_script_built({
        entity = fresh,
        tags = {
          [ENABLE_CONDITION_TAG] = {
            signal = { type = "virtual", name = "signal-green" },
            comparator = ">=",
            constant = 7,
          },
          ["spt_enable_wire_in"] = "red",
          ["spt_enable_wire_out"] = "green",
        },
      })
    elseif t == 5 then
      local fresh = state.tagged
      local cond = remote.call("space-power-transmitter", "get_enable_condition", fresh.unit_number)
      local want = { comparator = ">=", constant = 7, signal = { name = "signal-green", type = "virtual" } }
      if cond and cond.comparator == want.comparator and cond.constant == want.constant
          and cond.signal.name == want.signal.name and cond.signal.type == want.signal.type then
        say("PASS blueprint tags restore the enable condition")
      else
        state.failures = state.failures + 1
        say("FAIL blueprint condition: " .. serpent.line(cond))
      end
      local wires = remote.call("space-power-transmitter", "get_enable_wires", fresh.unit_number)
      if wires and wires.wire_in == "red" and wires.wire_out == "green" then
        say("PASS blueprint tags restore the wire choices")
      else
        state.failures = state.failures + 1
        say("FAIL blueprint wires: " .. serpent.line(wires))
      end
    elseif t == 8 then
      state.tagged.destroy() -- unregisters itself
      state.tagged = nil
      state.phase, state.phase_start = "forcebuild", tick
    end

  elseif phase == "forcebuild" then
    -- what super force build (ctrl+shift+click) does: destroy the old transmitter
    -- and build a fresh one at the same position in the same tick
    if t == 1 then
      local surface = transmitter.surface
      local old_un = transmitter.unit_number
      transmitter.destroy()
      local fresh = surface.create_entity({
        name = TRANSMITTER, position = { 0, 0 }, force = "player",
      })
      state.transmitter = fresh
      if not fresh then
        state.failures = state.failures + 1
        say("FAIL: the force-built transmitter could not be created")
        state.phase = "done"
        return
      end
      -- the engine preserves the player wires on a real force build
      fresh.get_wire_connector(RED, true).connect_to(
        state.red_pole.get_wire_connector(RED, true), false, defines.wire_origin.player)
      fresh.get_wire_connector(GREEN, true).connect_to(
        state.green_pole.get_wire_connector(GREEN, true), false, defines.wire_origin.player)
      script.raise_script_built({ entity = fresh })
      say("force-build: " .. tostring(old_un) .. " -> " .. tostring(fresh.unit_number)
        .. " created_tags=" .. serpent.line(fresh.tags))
    elseif t == 12 then
      -- hostile-mod simulation: destroy two hidden children; the destruction report
      -- must recreate them (the upkeep port back with its cached buffer size). The
      -- destroy waits a few ticks: a force build leaves the fresh record's adopted
      -- children dead for several ticks until the recreation scan catches up.
      local surface = transmitter.surface
      local upkeep = surface.find_entities_filtered({
        name = UPKEEP_PORT, position = transmitter.position, radius = 0.1, limit = 1 })[1]
      local import = surface.find_entities_filtered({
        name = "spt-import-port", position = transmitter.position, radius = 0.1, limit = 1 })[1]
      if upkeep then upkeep.destroy() end
      if import then import.destroy() end
    elseif t == 16 and not state.checked_children then
      state.checked_children = true
      local surface = transmitter.surface
      local upkeep = surface.find_entities_filtered({
        name = UPKEEP_PORT, position = transmitter.position, radius = 0.1, limit = 1 })[1]
      local import = surface.find_entities_filtered({
        name = "spt-import-port", position = transmitter.position, radius = 0.1, limit = 1 })[1]
      if upkeep and import and import.electric_buffer_size == 1e9 then
        say("PASS destroyed children recreated (import buffer size cached)")
      else
        state.failures = state.failures + 1
        say(string.format("FAIL child recreate: upkeep=%s import=%s",
          tostring(upkeep and upkeep.energy), tostring(import and import.electric_buffer_size)))
      end
    elseif t >= 8 and t < 150 and port then
      port.energy = port.electric_buffer_size
    elseif t >= 150 and not state.checked_force then
      state.checked_force = true
      local info = remote.call("space-power-transmitter", "transmitter_info", transmitter.unit_number)
      local cond = remote.call("space-power-transmitter", "get_enable_condition", transmitter.unit_number)
      if read_signals(state.transmitter, RED)["spt-link-up"] == 1 and info.disabled == false then
        say("PASS force-built transmitter: rebuilt, adopted, broadcast restored")
      else
        state.failures = state.failures + 1
        say(string.format("FAIL force-built state: signals=%s info=%s",
          serpent.line(read_signals(state.transmitter, RED)), serpent.line(info)))
      end
      say("RESULT: " .. (state.failures == 0 and "PASS" or ("FAIL (" .. state.failures .. " failures)")))
      state.phase, state.phase_start = "persist", tick
    end
  end
end)
