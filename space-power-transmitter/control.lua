local TRANSMITTER_NAME = "space-power-transmitter"
local BEAM_NAME = "spt-beam"
local HUM_NAME = "spt-hum"
local IMPORT_PORT_NAME = "spt-import-port"
local EXPORT_PORT_NAME = "spt-export-port"
local UPKEEP_PORT_PREFIX = "spt-upkeep-port-"
local STATUS_COMBINATOR_NAME = "spt-status-combinator"

local RELINK_PAID_TICKS = 60
local STARVE_LIMIT = 300

-- create_entity failures (a blocked position, a hostile mod) are retried on an
-- exponential backoff instead of every tick
local CREATE_BACKOFF_MIN = 30
local CREATE_BACKOFF_MAX = 1800

-- force and quality changes are rare (scripted force merges, quality upgrades by
-- other mods): each transmitter re-checks them once per period, phases spread
-- across transmitters by unit number
local FORCE_CHECK_PERIOD = 60

-- shared read-only tables: the hot loop must not allocate on every tick
local PORT_KEYS = { "import", "export", "upkeep" }
local EXCHANGE_KEYS = { "import", "export" }

-- link status broadcast to the circuit network by the hidden status combinator:
-- spt-link-up = 1 while the link is healthy, spt-link-failing = 1 while the upkeep
-- is not being paid (the link will drop soon); both absent = the link is down
local SIGNAL_NONE, SIGNAL_UP, SIGNAL_FAILING = 0, 1, 2
local SIGNAL_NAME = {
  [SIGNAL_UP] = "spt-link-up",
  [SIGNAL_FAILING] = "spt-link-failing",
}
-- the wire connector set for a wire choice; shared read-only tables: the hot loop
-- must not allocate
local CONNECTORS = {
  both = {
    [defines.wire_connector_id.circuit_red] = true,
    [defines.wire_connector_id.circuit_green] = true,
  },
  red = { [defines.wire_connector_id.circuit_red] = true },
  green = { [defines.wire_connector_id.circuit_green] = true },
}
local WIRE_CONNECTOR_IDS = {
  defines.wire_connector_id.circuit_red,
  defines.wire_connector_id.circuit_green,
}

-- dropdown rows in the Enable-if GUI, same keys as the CONNECTORS table
local WIRE_CHOICES = { "both", "red", "green" }
local WIRE_INDEX = { both = 1, red = 2, green = 3 }
local WIRE_ITEMS = { { "spt-enable.wire-both" }, { "spt-enable.wire-red" }, { "spt-enable.wire-green" } }

-- validates a wire choice read back from tags/paste: anything else means "absent"
local function wire_choice(value)
  return WIRE_INDEX[value] and value or nil
end

-- the status combinator sits offset from the transmitter's center: at the exact
-- center its hidden entity blocks super force build (ctrl+shift+click) of
-- transmitter blueprints over the existing entity
local STATUS_OFFSET = { 0, -3 }

local function status_combinator_position(entity)
  return { entity.position.x + STATUS_OFFSET[1], entity.position.y + STATUS_OFFSET[2] }
end
-- circuit "Enable if": while the condition is false the transmitter is off - it
-- holds no link and consumes no upkeep. API comparator strings, in GUI order
-- (the GUI shows the vanilla glyphs).
local COMPARATOR_CHOICES = { ">", ">=", "<", "<=", "=", "≠" }
local COMPARATOR_GLYPHS = { ">", "≥", "<", "≤", "=", "≠" }
local COMPARATOR_FUNCTIONS = {
  [">"] = function(value, constant) return value > constant end,
  [">="] = function(value, constant) return value >= constant end,
  ["<"] = function(value, constant) return value < constant end,
  ["<="] = function(value, constant) return value <= constant end,
  ["="] = function(value, constant) return value == constant end,
  ["≠"] = function(value, constant) return value ~= constant end,
}

-- transmitters awaiting re-registration after a force change: the registry is
-- being iterated on this tick, so the rebuild waits for the pass to finish
local deferred_registrations = {}

-- set by the registry mutators; the tick handler is refreshed at most once per
-- event (a rescan registers many records at once)
local tick_handler_dirty = false

local power = require("__space-power-transmitter__.common.power")
local BASE_UPKEEP = power.upkeep_watts()

-- forward declaration: defined after on_tick
local update_tick_handler

-- forward declaration: defined in the settings-paste section; registration applies
-- the entity's own tags (engine re-creations and clones carry them)
local apply_enable_settings

local function upkeep_rate_per_tick(quality)
  return BASE_UPKEEP * (power.QUALITY_MULTIPLIERS[quality] or 1) / 60
end

-- unknown quality tiers (from other mods) fall back to the normal upkeep port prototype
local function upkeep_port_name(quality)
  return UPKEEP_PORT_PREFIX .. (power.QUALITY_MULTIPLIERS[quality] and quality or "normal")
end

-- Load-time verification: the whole upkeep mechanic relies on the engine applying an
-- electric-energy-interface input_flow_limit as joules per tick ("Max amount of energy
-- this ElectricEnergyInterface will take from electric network in one tick"). If the
-- semantics ever change, the link would silently starve on healthy grids, so the
-- prototype check aborts the load with an error, and the behavioral self-test raises a
-- one-shot script error (an on_tick handler cannot abort the load).

local SELFTEST_SURFACE_NAME = "spt-selftest"
local SELFTEST_TICKS = 3

local function verify_upkeep_prototypes()
  for quality, multiplier in pairs(power.QUALITY_MULTIPLIERS) do
    local name = UPKEEP_PORT_PREFIX .. quality
    local prototype = prototypes.entity[name]
    local source = prototype and prototype.electric_energy_source_prototype
    local expected_buffer = BASE_UPKEEP * multiplier / 30
    local expected_flow = BASE_UPKEEP * multiplier / 60
    if not (source
        and math.abs(source.buffer_capacity - expected_buffer) < 1) then
      local actual_buffer = source and source.buffer_capacity or "missing"
      error("space-power-transmitter: the upkeep port prototype '" .. name
        .. "' does not match the shared power module (buffer " .. tostring(actual_buffer)
        .. " vs " .. expected_buffer .. ") - a conflicting mod may have overridden it")
    end
    -- 2.1.x quirk: the getter documents the quality parameter as optional, but rejects
    -- both the omission and a plain quality-name string in some builds - try the
    -- quality prototype object, then the name. If the getter is unusable in this
    -- build, the flow check is skipped with a log entry: the behavioral self-test
    -- still verifies the actual input_flow_limit semantics end to end.
    local quality_prototype = prototypes.quality and prototypes.quality[quality] or quality
    local ok, actual_flow = pcall(source.get_input_flow_limit, source, quality_prototype)
    if not ok then
      ok, actual_flow = pcall(source.get_input_flow_limit, source, quality)
    end
    if not ok then
      log("space-power-transmitter: could not read the input flow limit of '" .. name
        .. "' (the getter rejects every documented argument form: " .. tostring(actual_flow)
        .. ") - skipping the prototype-level flow check")
    elseif math.abs(actual_flow - expected_flow) >= 1 then
      error("space-power-transmitter: the upkeep port prototype '" .. name
        .. "' does not match the shared power module (flow " .. tostring(actual_flow)
        .. " vs " .. expected_flow .. ") - a conflicting mod may have overridden it")
    end
  end
end

local function start_selftest()
  -- a crash mid-self-test could have left the surface behind: reuse the base name if
  -- free, otherwise pick a suffix (a player surface with a colliding name is not ours
  -- to delete)
  local surface_name
  for i = 0, 100 do
    local candidate = i == 0 and SELFTEST_SURFACE_NAME or (SELFTEST_SURFACE_NAME .. "-" .. i)
    if not game.surfaces[candidate] then
      surface_name = candidate
      break
    end
  end
  if not surface_name then
    log("space-power-transmitter: could not pick an unused self-test surface name - skipping the self-test")
    return
  end
  local surface = game.create_surface(surface_name)
  local pole_position = surface.find_non_colliding_position("substation", { 0, 0 }, 100, 2)
  local pole = pole_position
    and surface.create_entity({ name = "substation", position = pole_position, force = "neutral" })
  local source = pole
    and surface.create_entity({ name = EXPORT_PORT_NAME, position = { pole.position.x + 3, pole.position.y }, force = "neutral" })
  local load = pole
    and surface.create_entity({ name = upkeep_port_name("normal"), position = { pole.position.x - 3, pole.position.y }, force = "neutral" })
  if not (pole and source and load) then
    -- hostile map generation on the temp surface: fail open, but say so
    game.delete_surface(surface)
    log("space-power-transmitter: could not create the input_flow_limit self-test entities - skipping the self-test")
    return
  end
  source.energy = source.electric_buffer_size
  -- after SELFTEST_TICKS engine power updates the port must hold at least one tick of
  -- burn (the rate): ~rate with the joules-per-tick semantics, ~rate/60 without
  storage.selftest = { started_at = game.tick, load = load, expected = BASE_UPKEEP / 60, surface = surface_name }
  tick_handler_dirty = true
end

local function finish_selftest(tick)
  local st = storage.selftest
  if tick - st.started_at < SELFTEST_TICKS then return end
  local load = st.load
  local measured = load and load.valid and load.energy or 0
  storage.selftest = nil
  local surface = game.surfaces[st.surface]
  if surface then game.delete_surface(surface) end
  -- refresh directly: the error below unwinds on_tick before the end-of-tick refresh,
  -- which would leave an empty handler registered forever
  update_tick_handler()
  if not (load and load.valid) then
    log("space-power-transmitter: the self-test port was lost - skipping the input_flow_limit check")
  elseif measured < st.expected then
    error(string.format(
      "space-power-transmitter: self-test failed: the upkeep port charged %.0f J in %d ticks, expected >= %.0f J. "
        .. "The engine no longer applies an electric-energy-interface input_flow_limit as joules per tick; "
        .. "the upkeep mechanic cannot work correctly. Please report this to the mod author.",
      measured, SELFTEST_TICKS, st.expected))
  end
end

local function init_storage()
  storage.transmitters = storage.transmitters or {}
  storage.pools = storage.pools or {}
  storage.destroy_regs = storage.destroy_regs or {}
  storage.by_force = storage.by_force or {}
  storage.child_regs = storage.child_regs or {}
  storage.force_index_by_name = storage.force_index_by_name or {}
  storage.enable_guis = storage.enable_guis or {}
end

local function destroy_if_valid(entity)
  if entity and entity.valid then entity.destroy() end
end

local function set_beam(T, active)
  if T.beam_active == active then return end
  local beam = T.beam
  if beam and beam.valid then
    beam.render_to_forces = active and {} or "neutral"
  end
  T.beam_active = active
end

-- the alert icon is a SignalID: the transmitter item's icon
local ALERT_ICON = { type = "item", name = "space-power-transmitter" }
-- a nil type would make a remove_alert filter table "empty", which sweeps ALL alerts
-- of the force (vanilla ones included) - resolve it once and never pass nil
local ALERT_TYPE_CUSTOM = defines.alert_type.custom

local function notify_link_dropped(T)
  -- per-force custom alert: every connected player of the force sees it, map pin included
  T.entity.force.add_custom_alert(T.entity, ALERT_ICON, { "spt-alert.link-dropped" }, true)
end

local function clear_link_alert(T)
  T.entity.force.remove_alert({ type = ALERT_TYPE_CUSTOM, entity = T.entity })
end

-- a manual section holding slot 1 = the one active status signal (a down link
-- clears the slot, so both signals read as absent); the engine broadcasts it on
-- every connected network for free
local function write_status_signal(T)
  local combinator = T.status_combinator
  if not (combinator and combinator.valid) then return end
  local behavior = combinator.get_or_create_control_behavior()
  if not behavior then return end
  local section = behavior.get_section(1)
  if not section then section = behavior.add_section() end
  if not section then return end
  section.active = true
  local signal_name = SIGNAL_NAME[T.signal_state]
  if signal_name then
    section.set_slot(1, {
      value = { type = "virtual", name = signal_name, quality = "normal" },
      min = 1,
    })
  else
    section.clear_slot(1)
  end
end

-- keeps the invisible script wires in sync with the player's own wiring: the hidden
-- status combinator joins a connector only while the player has wired that connector
-- themselves. An unwired transmitter then has no circuit network at all - exactly like
-- any other unwired entity - so the native "Circuit connection" GUI section stays away.
-- Self-healing on save/load: script wires are not serialized, player wires are, and
-- the check runs against the actual connection state, not a stored flag.
local function refresh_status_wiring(T)
  local entity = T.entity
  local combinator = T.status_combinator
  if not (entity and entity.valid and combinator and combinator.valid) then return end
  local chosen = CONNECTORS[T.wire_out]
  local changed = false
  for _, connector_id in ipairs(WIRE_CONNECTOR_IDS) do
    -- no create: an unallocated connector means no wires to inspect or detach
    local transmitter_connector = entity.get_wire_connector(connector_id, false)
    if transmitter_connector then
      local player_wired, script_wired = false, false
      for _, connection in ipairs(transmitter_connector.connections) do
        if connection.origin == defines.wire_origin.player then
          player_wired = true
        elseif connection.origin == defines.wire_origin.script then
          script_wired = true
        end
      end
      local should = player_wired and chosen[connector_id]
      if should and not script_wired then
        local combinator_connector = combinator.get_wire_connector(connector_id, true)
        if combinator_connector then
          combinator_connector.connect_to(transmitter_connector, false, defines.wire_origin.script)
          changed = true
        end
      elseif not should and script_wired then
        -- a script wire implies both connectors exist
        local combinator_connector = combinator.get_wire_connector(connector_id, false)
        if combinator_connector then
          combinator_connector.disconnect_from(transmitter_connector, defines.wire_origin.script)
          changed = true
        end
      end
    end
  end
  if changed then
    -- a fresh attach must restore the broadcast (the combinator slot does not
    -- reliably survive save/load either)
    if not T.disabled then write_status_signal(T) end
    -- the accumulator's own charge signal is noise next to the status signals
    local behavior = entity.get_or_create_control_behavior()
    if behavior and behavior.read_charge then behavior.read_charge = false end
  end
end

-- the Enable-if panel shows only while the transmitter is wired into a circuit
-- network, like the native "Circuit connection" section. Any connection counts: the
-- script wires exist only while the player wires the transmitter themselves, so this
-- is exactly "the transmitter has a circuit network".
local function transmitter_is_wired(entity)
  for _, connector_id in ipairs(WIRE_CONNECTOR_IDS) do
    local connector = entity.get_wire_connector(connector_id, false)
    if connector and #connector.connections > 0 then return true end
  end
  return false
end

-- circuit "Enable if" settings travel with copies, blueprints and entity clones
local ENABLE_CONDITION_TAG = "spt_enable_condition"
local ENABLE_WIRE_IN_TAG = "spt_enable_wire_in"
local ENABLE_WIRE_OUT_TAG = "spt_enable_wire_out"

-- the condition and the wire choices live in entity.tags: they survive blueprint
-- copies (the setup handler reads them) and engine re-creations
local function copy_condition(condition)
  if not condition then return nil end
  return {
    signal = { type = condition.signal.type, name = condition.signal.name },
    comparator = condition.comparator,
    constant = condition.constant,
  }
end

-- the enable condition reads the signal from both wire colors (vanilla machines
-- sum them too); no condition means always enabled
local function evaluate_enable_condition(T)
  local condition = T.enable_condition
  if not condition then return true end
  local entity = T.entity
  if not (entity and entity.valid) then return true end
  local chosen = CONNECTORS[T.wire_in]
  local value = 0
  -- fixed order (not pairs over the set): the float sum must stay deterministic
  for _, connector_id in ipairs(WIRE_CONNECTOR_IDS) do
    if chosen[connector_id] then
      local network = entity.get_circuit_network(connector_id)
      if network then
        value = value + network.get_signal(condition.signal)
      end
    end
  end
  return COMPARATOR_FUNCTIONS[condition.comparator](value, condition.constant)
end

local function set_link(T, up)
  if up then
    if not T.link_down then return end
    T.link_down = false
    T.ever_linked = true
    T.starve_ticks = 0
    T.paid_ticks = 0
    T.alert_refresh = nil
    set_beam(T, true) -- the beam marks a powered link
    clear_link_alert(T)
  else
    if T.link_down then return end
    -- no warning icon: the unlit beam is the down-link indicator - and a
    -- deliberately disabled transmitter must not raise the alert at all
    T.link_down = true
    set_beam(T, false)
    if not T.disabled then
      notify_link_dropped(T)
      T.alert_refresh = 60
    end
  end
end

-- child entities (ports, beam) are tracked for destruction: the recreate scan is
-- event-driven (children_dirty), the per-tick validity sweep is only a staggered
-- safety net. Registration numbers live in storage.child_regs (reg -> unit number);
-- records are looked up by unit number so no record table is aliased in storage.
local function track_child(T, key, entity)
  T.child_regs = T.child_regs or {}
  local old_reg = T.child_regs[key]
  if old_reg then storage.child_regs[old_reg] = nil end
  if entity then
    local reg = script.register_on_object_destroyed(entity)
    T.child_regs[key] = reg
    storage.child_regs[reg] = T.unit_number
  else
    T.child_regs[key] = nil
  end
end

-- Reuse a still-valid orphan left at our position (prototype migrations and
-- lost-validity races would otherwise leave duplicates at the tile); extra duplicates
-- beyond the first are destroyed. Returns the adopted entity or a fresh one (nil when
-- the create failed). A nil create_smoke keeps the default build smoke.
local function adopt_or_create(entity, name, create_smoke, position)
  position = position or entity.position
  local found
  for _, orphan in ipairs(entity.surface.find_entities_filtered({
      name = name,
      position = position,
      radius = 0.1,
    })) do
    if orphan.valid and orphan.force == entity.force then
      if not found then
        found = orphan
      else
        orphan.destroy()
      end
    end
  end
  if found then return found end
  return entity.surface.create_entity({
    name = name,
    position = position,
    force = entity.force,
    create_build_effect_smoke = create_smoke,
  })
end

-- Recreate a lost child (port, beam, hum, combinator): each recreator returns the
-- still-valid child, adopts a valid orphan left at the tile, or creates a fresh
-- entity (nil when the create failed - a failed recreate sets children_dirty so the
-- caller backs off). A recreate flags the tile for the duplicate scan.
local function recreate_port(T, key)
  local port = T.ports[key]
  if port and port.valid then return port end
  local entity = T.entity
  if not (entity and entity.valid) then return nil end
  T.rescan = true
  local name
  if key == "import" then
    name = IMPORT_PORT_NAME
  elseif key == "export" then
    name = EXPORT_PORT_NAME
  else
    name = upkeep_port_name(T.quality)
  end
  port = adopt_or_create(entity, name)
  T.ports[key] = port
  track_child(T, key, port)
  if port then
    T.port_sizes[key] = port.electric_buffer_size
    if key == "import" then
      -- a fresh baseline: the adopted port's current charge must not read as a grid draw
      T.import_pending = port.energy
    end
  else
    T.children_dirty = true
  end
  return port
end

local function recreate_beam(T)
  if T.beam and T.beam.valid then return T.beam end
  local entity = T.entity
  if not (entity and entity.valid) then return nil end
  T.rescan = true
  local beam = adopt_or_create(entity, BEAM_NAME, false)
  if beam then
    beam.render_to_forces = T.beam_active and {} or "neutral"
  else
    T.children_dirty = true
  end
  T.beam = beam
  track_child(T, "beam", beam)
  return beam
end

local function recreate_hum(T)
  if T.hum and T.hum.valid then return T.hum end
  local entity = T.entity
  if not (entity and entity.valid) then return nil end
  T.rescan = true
  local hum = adopt_or_create(entity, HUM_NAME, false)
  if not hum then T.children_dirty = true end
  T.hum = hum
  track_child(T, "hum", hum)
  return hum
end

local function recreate_status_combinator(T)
  if T.status_combinator and T.status_combinator.valid then return T.status_combinator end
  local entity = T.entity
  if not (entity and entity.valid) then return nil end
  T.rescan = true
  local combinator = adopt_or_create(entity, STATUS_COMBINATOR_NAME, false,
    status_combinator_position(entity))
  if not combinator then T.children_dirty = true end
  T.status_combinator = combinator
  track_child(T, "status", combinator)
  -- the script wires follow the player's wiring and the broadcast is restored with them
  refresh_status_wiring(T)
  return combinator
end

-- the non-port children, in recreate order
local RECREATORS = { recreate_beam, recreate_hum, recreate_status_combinator }

-- keeps a unit-number list sorted on insert: the per-force registry stays sorted at
-- all times, so the rationing scans and the drain order are deterministic without a
-- per-tick sort
local function register_in_list(list, unit_number)
  local i = #list
  while i >= 1 and list[i] > unit_number do
    list[i + 1] = list[i]
    i = i - 1
  end
  list[i + 1] = unit_number
end

local function register_transmitter(entity)
  local unit_number = entity.unit_number
  if storage.transmitters[unit_number] then return end

  local quality = entity.quality.name
  local T = {
    entity = entity,
    unit_number = unit_number,
    force_index = entity.force.index,
    force_name = entity.force.name,
    quality = quality,
    rate = upkeep_rate_per_tick(quality),
    ports = {},
    port_sizes = {},
    signal_state = SIGNAL_NONE,
    enable_condition = nil,
    wire_in = "both",
    wire_out = "both",
    disabled = false,
    beam_active = false,
    link_down = true,
    ever_linked = false,
    paid_ticks = 0,
    starve_ticks = 0,
    upkeep_need = 0,
    machine_need = 0,
    machine_draw = 0,
    import_pending = 0,
    demand = 0,
    rescan = true,
    children_dirty = false,
    child_regs = {},
    destroy_reg = script.register_on_object_destroyed(entity),
  }
  -- the recreators adopt still-valid orphans left at the tile (a lost validity race
  -- or a foreign record's teardown): creating fresh duplicates would let the rescan
  -- pass destroy their banked energy instead of putting it back to work
  for _, key in ipairs(PORT_KEYS) do
    recreate_port(T, key)
  end
  for _, recreate in ipairs(RECREATORS) do
    recreate(T)
  end
  storage.destroy_regs[T.destroy_reg] = unit_number
  storage.transmitters[unit_number] = T
  -- pools are keyed by force name; this index map resolves the name back when the
  -- force is merged away (on_forces_merged only reports the source index)
  storage.force_index_by_name[T.force_name] = T.force_index
  local list = storage.by_force[T.force_name]
  if not list then
    list = {}
    storage.by_force[T.force_name] = list
  end
  register_in_list(list, unit_number)
  -- the entity's own tags restore its settings: the engine keeps them on
  -- re-creations and entity clones (blueprint builds deliver theirs through the
  -- build events, which run after registration and re-apply idempotently)
  local tags = entity.tags
  if tags then
    apply_enable_settings(T, tags[ENABLE_CONDITION_TAG], tags[ENABLE_WIRE_IN_TAG], tags[ENABLE_WIRE_OUT_TAG])
  end
  tick_handler_dirty = true
end

local function return_exchange_energy(T)
  -- energy held by both ports belongs to the pool; save it from destruction
  local ports = T.ports
  if ports then
    for _, key in ipairs(EXCHANGE_KEYS) do
      local port = ports[key]
      if port and port.valid and port.energy > 0 then
        -- the ports keep the force they were created with, and after a force merge
        -- the engine reassigns them - keying the refund by the port's own force
        -- always lands it on a live force's pool
        local force_name = port.force.name
        storage.pools[force_name] = (storage.pools[force_name] or 0) + port.energy
        port.energy = 0
      end
    end
  end
  T.import_pending = 0
end

local function unregister(T, keep_children)
  local entity_valid = (T.entity and T.entity.valid) and true or false
  -- keep_children: rebuild-only mode (on_configuration_changed) - the hidden ports and
  -- the beam stay alive with their charges and register re-adopts them, so an update
  -- drops no links (a network without own generation could never relink from the grid)
  local destroy_children = not (keep_children and entity_valid)
  if destroy_children then
    return_exchange_energy(T)
    destroy_if_valid(T.beam)
    destroy_if_valid(T.hum)
    destroy_if_valid(T.status_combinator)
    local ports = T.ports
    if ports then
      for _, key in ipairs(PORT_KEYS) do
        destroy_if_valid(ports[key])
      end
    end
  end
  -- drop the child destruction tracking BEFORE destroying: the queued
  -- on_object_destroyed events must not set flags on a dead record
  local child_regs = T.child_regs
  if child_regs then
    for _, reg in pairs(child_regs) do
      storage.child_regs[reg] = nil
    end
  end
  if T.destroy_reg then storage.destroy_regs[T.destroy_reg] = nil end
  storage.transmitters[T.unit_number] = nil
  local list = storage.by_force[T.force_name]
  if list then
    for i = 1, #list do
      if list[i] == T.unit_number then
        table.remove(list, i)
        break
      end
    end
    if not next(list) then storage.by_force[T.force_name] = nil end
  end
  -- the pin must not outlive the record: on a force change the engine keeps the alert
  -- (the entity survives) and the old force's players would see it forever
  if destroy_children then
    if entity_valid then
      T.entity.force.remove_alert({ type = ALERT_TYPE_CUSTOM, entity = T.entity })
    else
      -- the engine prunes alerts of destroyed targets by itself; in case it does not,
      -- sweep the force's custom alerts - other downed links re-raise theirs in a second
      local force = game.forces[T.force_name]
      if force then
        force.remove_alert({ type = ALERT_TYPE_CUSTOM })
      end
    end
  end
  tick_handler_dirty = true
end

local function update_transmitter(T, tick)
  local entity = T.entity
  if not (entity and entity.valid) then
    unregister(T)
    return
  end

  local phase_due = tick % FORCE_CHECK_PERIOD == T.unit_number % FORCE_CHECK_PERIOD
  if phase_due then
    -- a force change rebuilds the record: the hidden ports keep the force they were
    -- created with, and the banked exchange energy belongs to the old force's grid
    if entity.force.index ~= T.force_index then
      -- the link alert was raised on the OLD force (the engine keeps it while the
      -- entity survives, and the new force's alert set does not hold it)
      local old_force = game.forces[T.force_name]
      if old_force then
        old_force.remove_alert({ type = ALERT_TYPE_CUSTOM, entity = entity })
      end
      unregister(T)
      -- the registry is being iterated: re-register after the pass
      deferred_registrations[#deferred_registrations + 1] = entity
      return
    end

    -- quality upgrades swap the upkeep port tier; carry the reserve charge over
    local quality = entity.quality.name
    if quality ~= T.quality then
      local old_port = T.ports.upkeep
      local reserve = old_port and old_port.valid and old_port.energy or 0
      destroy_if_valid(old_port)
      T.quality = quality
      T.rate = upkeep_rate_per_tick(quality)
      -- a disabled transmitter has no upkeep port by design: the tier swap takes
      -- effect when it is enabled again (the recreate scan stays idle meanwhile)
      if not T.disabled then
        local new_port = recreate_port(T, "upkeep")
        if new_port and reserve > 0 then
          new_port.energy = math.min(reserve, T.port_sizes.upkeep)
        end
      end
    end

    -- keep the invisible script wires in sync with the player's wiring: they are
    -- not serialized by the engine, and an unwired transmitter must have no circuit
    -- network at all (so the native "Circuit connection" section stays away)
    refresh_status_wiring(T)
  end

  -- missing ports and beam are recreated on a destruction report (children_dirty) or
  -- on a backoff, not every tick: in steady state no validity checks run here at all,
  -- and a persistently failing create (a blocking mod, a corrupted position) must not
  -- cost API calls per tick. The staggered sweep is the safety net for lost reports
  -- (it piggybacks on the force-check phase and never cuts a pending backoff short).
  if T.children_dirty
      or (T.retry_at and tick >= T.retry_at)
      or (not T.retry_at and phase_due) then
    -- the report is being handled now: a failing recreate re-sets children_dirty so
    -- this backs off instead of spinning every tick
    T.children_dirty = false
    for _, key in ipairs(PORT_KEYS) do
      local port = T.ports[key]
      if not (port and port.valid) then
        if key == "upkeep" and T.disabled then
          -- deliberately removed while disabled: it stays away until re-enabled
          T.ports[key] = nil
        else
          recreate_port(T, key)
        end
      end
    end
    for _, recreate in ipairs(RECREATORS) do
      recreate(T)
    end
    if T.children_dirty then
      T.retry_backoff = math.min((T.retry_backoff or CREATE_BACKOFF_MIN) * 2, CREATE_BACKOFF_MAX)
      T.retry_at = tick + T.retry_backoff
    else
      T.retry_at = nil
      T.retry_backoff = nil
    end
  end

  -- destroy orphan duplicate ports and beams (prototype migrations and lost-validity
  -- races leave them behind); only after a registration or a recreate - in steady
  -- state this never runs. Orphans of a foreign force are not ours to destroy. The
  -- status combinator lives at its own offset position, everything else at the center.
  if T.rescan then
    T.rescan = false
    for _, scan in ipairs({
        { name = IMPORT_PORT_NAME, current = T.ports.import },
        { name = EXPORT_PORT_NAME, current = T.ports.export },
        { name = upkeep_port_name(T.quality), current = T.ports.upkeep },
        { name = BEAM_NAME, current = T.beam },
        { name = HUM_NAME, current = T.hum },
        { name = STATUS_COMBINATOR_NAME, current = T.status_combinator,
          position = status_combinator_position(entity) },
      }) do
      for _, orphan in ipairs(entity.surface.find_entities_filtered({
          name = scan.name,
          position = scan.position or entity.position,
          radius = 0.1,
        })) do
        if orphan.valid and orphan ~= scan.current and orphan.force == entity.force then
          orphan.destroy()
        end
      end
    end
  end

  -- circuit "Enable if": a disabled transmitter holds no link and consumes nothing.
  -- The upkeep port is REMOVED, not just unpaid - the engine would keep feeding its
  -- buffer from the local grid at the full rate otherwise.
  local disabled = not evaluate_enable_condition(T)
  if disabled ~= T.disabled then
    T.disabled = disabled
    T.paid_ticks, T.starve_ticks = 0, 0
    T.signal_state = SIGNAL_NONE
    write_status_signal(T)
    if disabled then
      set_link(T, false) -- no link alert: turning it off is deliberate
      T.upkeep_need, T.machine_need, T.demand = 0, 0, 0
      destroy_if_valid(T.ports.upkeep)
      T.ports.upkeep = nil
      track_child(T, "upkeep", nil)
    else
      -- the recreate scan rebuilds the upkeep port; the link re-establishes by
      -- paying the upkeep, like on a fresh transmitter
      T.children_dirty = true
      T.link_down = true
    end
  end

  -- custom alerts are one-shot for the engine: viewing the target surface (a click on
  -- the alert travels there) dismisses it. Vanilla-style, re-raise it every second
  -- while the link is down so the pin does not get silenced for good. Runs before the
  -- upkeep port check: a lost port must not silence the pin either.
  if T.link_down and not T.disabled then
    T.alert_refresh = (T.alert_refresh or 60) - 1
    if T.alert_refresh <= 0 then
      notify_link_dropped(T)
      T.alert_refresh = 60
    end
  end

  local upkeep_port = T.ports.upkeep
  if not (upkeep_port and upkeep_port.valid) then
    -- no upkeep port means no trustworthy measurements: zero out the needs so stale
    -- demand from an older tick cannot feed the rationing. The import baseline stays
    -- fresh: the grid may drain the buffer while it cannot be measured, and the next
    -- tick's draw must not read as a spike.
    if not T.link_down then
      -- the port is gone (a failed recreate or a hostile mod): the link cannot be
      -- held - drop it instead of broadcasting a healthy link that pays nothing
      set_link(T, false)
    end
    T.demand = 0
    T.upkeep_need = 0
    T.machine_need = 0
    local import_port = T.ports.import
    T.import_pending = import_port and import_port.valid and import_port.energy or 0
    return
  end

  -- upkeep: a pure rate load, always consuming ("always active"). The link drops only
  -- after STARVE_LIMIT consecutive ticks of underpayment (time-based hysteresis) and
  -- re-establishes after RELINK_PAID_TICKS ticks of full payment. The comparison has a
  -- 1 J tolerance: the rate is fractional (W / 60) while buffers are integer-joule.
  local rate = T.rate
  local buffered = upkeep_port.energy
  local consumed = math.min(buffered, rate)
  upkeep_port.energy = buffered - consumed
  if T.link_down then
    if consumed >= rate - 1 then
      T.paid_ticks = T.paid_ticks + 1
      if T.paid_ticks >= RELINK_PAID_TICKS then
        set_link(T, true)
      end
    else
      T.paid_ticks = 0
    end
  elseif consumed < rate - 1 then
    T.paid_ticks = 0
    T.starve_ticks = T.starve_ticks + 1
    if T.starve_ticks >= STARVE_LIMIT then
      set_link(T, false)
    end
  else
    T.paid_ticks = 0
    T.starve_ticks = 0
  end

  -- circuit status: link up / about to drop (starving) / down (both signals
  -- absent); written only on a state change, the engine broadcasts the
  -- combinator's signals on its own
  local signal_state = T.link_down and SIGNAL_NONE
    or (consumed >= rate - 1 and SIGNAL_UP or SIGNAL_FAILING)
  if signal_state ~= T.signal_state then
    T.signal_state = signal_state
    write_status_signal(T)
  end

  -- transformer ports (Power Overload style), working simultaneously:
  -- export (secondary-input load): the grid pushes local surplus in; rationing drains
  --                                it to the demanders (transit - see ration_force)
  -- import (secondary-output source): rationing fills it from the donors; the grid
  --                                   draws on deficit
  T.upkeep_need = 0
  T.machine_need = 0
  T.demand = 0
  local import_port = T.ports.import
  if import_port and import_port.valid then
    local energy = import_port.energy
    local pending = T.import_pending
    local drew = 0
    if energy < pending then
      drew = pending - energy
    end
    T.import_pending = energy
    -- the machine draw estimate (what the grid drew from the import buffer minus the
    -- upkeep share actually paid): smoothed with an exponential average, sub-joule
    -- noise snapped to zero so the idle exit engages
    local raw_machine_draw = math.max(0, drew - consumed)
    T.machine_draw = T.machine_draw * 0.7 + raw_machine_draw * 0.3
    if T.machine_draw < 1 then T.machine_draw = 0 end
    if not T.link_down then
      -- refill need: keep the buffer at the two-tick upkeep cushion plus one tick of
      -- the estimated machine draw. The pool then pays every joule the grid consumed
      -- EXACTLY ONCE - the old scheme billed the machine draw twice (the cushion
      -- refill covered the whole depletion and the machine tier paid it again),
      -- manufacturing up to the machine draw per tick out of nothing.
      local import_size = T.port_sizes.import or import_port.electric_buffer_size
      local target = math.min(import_size, rate * 2 + T.machine_draw)
      local need = math.max(0, target - energy)
      T.upkeep_need = math.min(need, math.max(0, rate * 2 - energy)) -- cushion part first
      T.machine_need = need - T.upkeep_need                          -- machine part second
      T.demand = math.max(0, rate - consumed) + T.upkeep_need + T.machine_need
    end
  end
end

-- scratch lists of serviced transmitters and donor energies: reused every tick,
-- entries above the counts are stale but never read
local serviced = {}
local serviced_count = 0
local donors = {}
local donor_energy = {}
local donor_count = 0

-- Inject one tier's budget into the serviced import ports, proportionally to each
-- transmitter's need; capped by the free buffer space (the unpayable share stays in
-- the pool for the next tier / the transit return). Returns the remaining pool.
local function inject_tier(pool, total, need_key)
  if total <= 0 or pool <= 0 then return pool end
  local budget = math.min(pool, total)
  for i = 1, serviced_count do
    local T = serviced[i]
    local share = budget * T[need_key] / total
    local import_port = T.ports.import
    if import_port and import_port.valid and share > 0 then
      local space = (T.port_sizes.import or import_port.electric_buffer_size) - import_port.energy
      local inject = math.min(share, space)
      if inject > 0 then
        import_port.energy = import_port.energy + inject
        pool = pool - inject
      end
    end
  end
  return pool
end

local function ration_force(force_name)
  -- the persistent per-force registry: unit numbers, deterministic on iteration,
  -- maintained by register/unregister - no per-tick filtering or allocation.
  -- The pool is keyed by force NAME (the same keyspace as the registry).
  local all = storage.by_force[force_name]
  if not all then return end
  local transmitters = storage.transmitters
  local pool = storage.pools[force_name] or 0

  -- service list: LINKED transmitters only (a surface that cannot pay its own upkeep
  -- is not part of the grid and receives nothing from the pool - it recovers from
  -- local generation and its own reserve; its residual import buffer drains to the
  -- machines and is not refilled). Two demand tiers:
  --   tier 1 (upkeep): refill the import buffer cushion - the primary-input upkeep
  --                    port draws before any machine, a full cushion means the link
  --                    is paid even while machines starve;
  --   tier 2 (machines): what the grid actually drew from the import buffer.
  serviced_count = 0
  local tier1_total = 0
  local tier2_total = 0
  for i = 1, #all do
    local T = transmitters[all[i]]
    if T and not T.link_down then
      local upkeep_need = T.upkeep_need
      local machine_need = T.machine_need
      if upkeep_need + machine_need > 0 then
        serviced_count = serviced_count + 1
        serviced[serviced_count] = T
        tier1_total = tier1_total + upkeep_need
        tier2_total = tier2_total + machine_need
      end
    end
  end
  local total_demand = tier1_total + tier2_total

  -- fully idle: nothing to distribute and nothing to collect - skip the rest
  if total_demand == 0 and pool == 0 then return end

  -- collect from donors whatever the bank cannot cover: drain linked export
  -- accumulators proportionally to the charge they hold, down to zero when needed
  -- (the floor from the harvest above is dipped only on shortage). The registry is
  -- kept sorted by unit number, so the drain order is deterministic for free. Donor
  -- energies are read once: no engine update runs inside the tick, so the values
  -- cannot change between this scan and the drain.
  local remaining = total_demand - pool
  donor_count = 0
  local available = 0
  if remaining > 0 then
    for i = 1, #all do
      local T = transmitters[all[i]]
      if T and not T.link_down then
        local port = T.ports.export
        if port and port.valid then
          local energy = port.energy
          if energy > 0 then
            donor_count = donor_count + 1
            donors[donor_count] = T
            donor_energy[donor_count] = energy
            available = available + energy
          end
        end
      end
    end
    -- available is only zero when there are no donors: the drain loop below does not
    -- run, the tiers split whatever the pool already holds
    local scale = available > 0 and math.min(1, remaining / available) or 1
    for i = 1, donor_count do
      if remaining <= 0 then break end
      local port = donors[i].ports.export
      local energy = donor_energy[i]
      local take = math.min(energy * scale, remaining)
      if take > 0 then
        port.energy = energy - take
        pool = pool + take
        remaining = remaining - take
      end
    end
  end

  -- tier 1: upkeep is paid first, in full whenever the bank allows
  pool = inject_tier(pool, tier1_total, "upkeep_need")
  -- tier 2: machines split whatever is left, proportionally to their draw
  pool = inject_tier(pool, tier2_total, "machine_need")

  -- pure transit: nothing is stored centrally - whatever could not be injected
  -- (or was never demanded) is parked back in the donors' export accumulators.
  -- Only LINKED transmitters receive it: a broken link must recover from local
  -- sources, not from the grid. Full ports end the suction: a full accumulator
  -- has no empty space and the engine stops pushing network surplus into it.
  if pool > 0 then
    for i = 1, #all do
      if pool <= 0 then break end
      local T = transmitters[all[i]]
      if T and not T.link_down then
        local port = T.ports.export
        if port and port.valid then
          local space = (T.port_sizes.export or port.electric_buffer_size) - port.energy
          local give = math.min(space, pool)
          if give > 0 then
            port.energy = port.energy + give
            pool = pool - give
          end
        end
      end
    end
  end
  -- a residue can only survive when every donor port is full - the next tick's
  -- collection phase spends it first
  storage.pools[force_name] = math.max(pool, 0)
end

local function on_tick(event)
  if storage.selftest then finish_selftest(event.tick) end
  -- the Enable-if panel of an open transmitter follows the wiring live: the script
  -- wires (and with them the circuit network) lag the player's wires by up to a poll
  -- period, so the panel visibility is re-checked while a window is open
  if event.tick % 30 == 0 and next(storage.enable_guis) then
    for player_index, state in pairs(storage.enable_guis) do
      local player = game.get_player(player_index)
      local T = state.unit_number and storage.transmitters[state.unit_number] or nil
      if not (player and T and T.entity.valid) then
        storage.enable_guis[player_index] = nil
        if player then destroy_enable_gui(player) end
      else
        local wired = transmitter_is_wired(T.entity)
        if state.shown ~= wired then
          state.shown = wired
          if wired then
            build_enable_gui(player, T)
          else
            destroy_enable_gui(player)
          end
        end
      end
    end
  end
  local transmitters = storage.transmitters
  -- backwards: update_transmitter may unregister its own record (self-removal from
  -- the list being iterated is safe in this direction)
  for _, list in pairs(storage.by_force) do
    for i = #list, 1, -1 do
      local T = transmitters[list[i]]
      if T then
        update_transmitter(T, event.tick)
      end
    end
  end
  -- force changes detected during the pass tore their records down; rebuild them
  -- now that the registry is not being iterated
  for i = #deferred_registrations, 1, -1 do
    local entity = deferred_registrations[i]
    deferred_registrations[i] = nil
    if entity.valid then
      register_transmitter(entity)
    end
  end
  for force_name, list in pairs(storage.by_force) do
    if next(list) then
      ration_force(force_name)
    end
  end
  if tick_handler_dirty then
    update_tick_handler()
  end
end

-- the tick handler only runs while there is work: at least one transmitter or a
-- pending self-test. The registry mutators only set tick_handler_dirty; the handler
-- is refreshed once per event.
function update_tick_handler()
  tick_handler_dirty = false
  if next(storage.transmitters) or storage.selftest then
    script.on_event(defines.events.on_tick, on_tick)
  else
    script.on_event(defines.events.on_tick, nil)
  end
end

-- circuit "Enable if" GUI: a small frame anchored to the right of the native
-- accumulator window, holding the condition (signal, comparator, constant).
local ENABLE_FRAME_NAME = "spt_enable_frame"

-- the engine renders a "Circuit connection" section into the transmitter's own
-- window once it is wired; it duplicates the mod's Enable-if panel, so hide it.
-- Best effort: a silent no-op when the engine window is not exposed to Lua.
local function hide_native_circuit_section(player)
  pcall(function()
    local window = player.gui.screen.accumulator_gui
    if not window then return end
    local function walk(element, depth)
      if depth > 8 then return end
      for _, child in ipairs(element.children) do
        local ok, caption = pcall(function() return serpent.line(child.caption) end)
        if ok and caption and string.find(caption, "circuit-connection", 1, true) then
          child.visible = false
        end
        walk(child, depth + 1)
      end
    end
    walk(window, 1)
  end)
end

local function destroy_enable_gui(player)
  local frame = player.gui.relative[ENABLE_FRAME_NAME]
  if frame then frame.destroy() end
end

local function comparator_index(comparator)
  for index, choice in ipairs(COMPARATOR_CHOICES) do
    if choice == comparator then return index end
  end
  return 1
end

local function build_enable_gui(player, T)
  destroy_enable_gui(player)
  local tags = { unit_number = T.unit_number }
  local function add(parent, def)
    def.tags = tags
    return parent.add(def)
  end
  local frame = add(player.gui.relative, {
    type = "frame",
    name = ENABLE_FRAME_NAME,
    caption = { "spt-enable.title" },
    anchor = {
      gui = defines.relative_gui_type.accumulator_gui,
      position = defines.relative_gui_position.right,
    },
  })
  local flow = add(frame, { type = "flow", name = "spt_enable_flow", direction = "vertical" })
  local row = add(flow, { type = "flow", name = "spt_enable_row", direction = "horizontal" })
  local button = add(row, {
    type = "choose-elem-button",
    name = "spt_enable_signal",
    elem_type = "signal",
    tooltip = { "spt-enable.signal-tooltip" },
  })
  -- the icon only renders when the value is set after creation
  if T.enable_condition then
    button.elem_value = T.enable_condition.signal
  end
  add(row, {
    type = "drop-down",
    name = "spt_enable_comparator",
    items = COMPARATOR_GLYPHS,
    selected_index = T.enable_condition and comparator_index(T.enable_condition.comparator) or 1,
    tooltip = { "spt-enable.comparator-tooltip" },
  })
  add(row, {
    type = "textfield",
    name = "spt_enable_constant",
    numeric = true,
    text = T.enable_condition and tostring(T.enable_condition.constant) or "0",
    tooltip = { "spt-enable.constant-tooltip" },
  })
  local wire_row = add(flow, { type = "flow", name = "spt_enable_wire_row", direction = "horizontal" })
  add(wire_row, { type = "label", name = "spt_enable_wire_in_label", caption = { "spt-enable.wire-in" },
    tooltip = { "spt-enable.wire-in-tooltip" } })
  add(wire_row, {
    type = "drop-down",
    name = "spt_enable_wire_in",
    items = WIRE_ITEMS,
    selected_index = WIRE_INDEX[T.wire_in],
  })
  add(wire_row, { type = "label", name = "spt_enable_wire_out_label", caption = { "spt-enable.wire-out" },
    tooltip = { "spt-enable.wire-out-tooltip" } })
  add(wire_row, {
    type = "drop-down",
    name = "spt_enable_wire_out",
    items = WIRE_ITEMS,
    selected_index = WIRE_INDEX[T.wire_out],
  })
  add(flow, {
    type = "button",
    name = "spt_enable_clear",
    caption = { "spt-enable.clear" },
    tooltip = { "spt-enable.clear-tooltip" },
    enabled = T.enable_condition ~= nil,
  })
  hide_native_circuit_section(player)
end

script.on_event(defines.events.on_gui_opened, function(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  local entity = event.entity
  local T = entity and entity.valid and entity.name == TRANSMITTER_NAME
    and storage.transmitters[entity.unit_number] or nil
  if not T then
    -- opening anything else (or nothing) puts the stale frame away
    storage.enable_guis[event.player_index] = nil
    destroy_enable_gui(player)
    return
  end
  local state = { unit_number = T.unit_number }
  storage.enable_guis[event.player_index] = state
  if transmitter_is_wired(entity) then
    state.shown = true
    build_enable_gui(player, T)
  else
    -- an unwired transmitter shows no Enable-if panel (like the native section);
    -- the tick poll builds it when the transmitter gets wired
    state.shown = false
    destroy_enable_gui(player)
  end
end)

script.on_event(defines.events.on_gui_closed, function(event)
  local player = game.get_player(event.player_index)
  if player then destroy_enable_gui(player) end
  storage.enable_guis[event.player_index] = nil
end)

-- the transmitter is resolved from the widget's tags: player.opened is not
-- reliable while a choose-elem-button popup is on screen
local function transmitter_from_tags(element)
  local unit_number = element.tags.unit_number
  local T = storage.transmitters[unit_number]
  if T and T.entity and T.entity.valid then return T end
  return nil
end

local function refresh_clear_button(player, T)
  local frame = player.gui.relative[ENABLE_FRAME_NAME]
  if frame then
    frame.spt_enable_flow.spt_enable_clear.enabled = T.enable_condition ~= nil
  end
end

-- the constant of the currently open panel (0 when empty/unfilled)
local function field_constant(player)
  local frame = player.gui.relative[ENABLE_FRAME_NAME]
  if not frame then return 0 end
  local field = frame.spt_enable_flow.spt_enable_row.spt_enable_constant
  return field and tonumber(field.text) or 0
end

script.on_event(defines.events.on_gui_elem_changed, function(event)
  if event.element.name ~= "spt_enable_signal" then return end
  local player = game.get_player(event.player_index)
  local T = transmitter_from_tags(event.element)
  if not T then return end
  local value = event.element.elem_value
  if value then
    -- quality is not part of the condition: compare the plain signal
    local signal = { type = value.type or "item", name = value.name }
    if T.enable_condition then
      T.enable_condition.signal = signal
    else
      T.enable_condition = { signal = signal, comparator = ">", constant = field_constant(player) }
    end
  else
    T.enable_condition = nil -- no signal picked: the transmitter stays always enabled
  end
  -- the button renders the picked signal itself; just wake the clear button up
  refresh_clear_button(player, T)
end)

script.on_event(defines.events.on_gui_selection_state_changed, function(event)
  if event.element.name == "spt_enable_wire_in" or event.element.name == "spt_enable_wire_out" then
    local T = transmitter_from_tags(event.element)
    if not T then return end
    local choice = WIRE_CHOICES[event.element.selected_index]
    if event.element.name == "spt_enable_wire_in" then
      T.wire_in = choice
    else
      T.wire_out = choice
    end
    refresh_status_wiring(T)
    return
  end
  if event.element.name ~= "spt_enable_comparator" then return end
  local player = game.get_player(event.player_index)
  local T = transmitter_from_tags(event.element)
  if not T then return end
  local comparator = COMPARATOR_CHOICES[event.element.selected_index]
  local constant = field_constant(player)
  if not T.enable_condition then
    -- a comparator picked before a signal: fall back to the plain virtual zero
    T.enable_condition = {
      signal = { type = "virtual", name = "signal-grey" },
      comparator = comparator,
      constant = constant,
    }
  else
    T.enable_condition.comparator = comparator
  end
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
  if event.element.name ~= "spt_enable_constant" then return end
  local T = transmitter_from_tags(event.element)
  if not T then return end
  local constant = tonumber(event.element.text) or 0
  if T.enable_condition then
    T.enable_condition.constant = constant
  end
end)

script.on_event(defines.events.on_gui_click, function(event)
  if event.element.name ~= "spt_enable_clear" then return end
  local T = transmitter_from_tags(event.element)
  if not T then return end
  T.enable_condition = nil
  local player = game.get_player(event.player_index)
  if player then build_enable_gui(player, T) end
end)

-- applies a condition table from tags/paste; returns false for anything malformed
local function set_enable_condition_from_table(T, condition)
  if type(condition) ~= "table" then return false end
  local signal = condition.signal
  local comparator = condition.comparator
  if type(signal) ~= "table" or type(signal.name) ~= "string"
      or (signal.type ~= nil and type(signal.type) ~= "string")
      or not COMPARATOR_FUNCTIONS[comparator] or type(condition.constant) ~= "number" then
    return false
  end
  T.enable_condition = {
    signal = { type = signal.type or "item", name = signal.name },
    comparator = comparator,
    constant = condition.constant,
  }
  return true
end

-- applies a full settings snapshot; a nil condition clears it
function apply_enable_settings(T, condition, wire_in, wire_out)
  T.enable_condition = nil
  set_enable_condition_from_table(T, condition)
  T.wire_in = wire_choice(wire_in) or "both"
  T.wire_out = wire_choice(wire_out) or "both"
  -- a restored control behavior must not leave read_charge on (the mod never uses it)
  local behavior = T.entity and T.entity.valid and T.entity.get_control_behavior() or nil
  if behavior and behavior.read_charge then behavior.read_charge = false end
  refresh_status_wiring(T)
end

script.on_event(defines.events.on_entity_settings_pasted, function(event)
  local source = event.source
  local destination = event.destination
  if not (source and source.valid and destination and destination.valid) then return end
  if source.name ~= TRANSMITTER_NAME or destination.name ~= TRANSMITTER_NAME then return end
  local source_T = storage.transmitters[source.unit_number]
  local destination_T = storage.transmitters[destination.unit_number]
  if not destination_T then return end
  destination_T.enable_condition = copy_condition(source_T and source_T.enable_condition)
  destination_T.wire_in = source_T and source_T.wire_in or "both"
  destination_T.wire_out = source_T and source_T.wire_out or "both"
  -- wire_out may have changed: the script wires follow immediately, not on the poll
  refresh_status_wiring(destination_T)
end)

-- the event does not carry the blueprint item; it is resolved from the player the
-- same way for regular blueprints, the library and book pages
local function resolve_blueprint_from_player(player)
  if player.blueprint_to_setup and player.blueprint_to_setup.valid_for_read then
    return player.blueprint_to_setup
  end
  if player.cursor_stack and player.cursor_stack.valid_for_read and player.cursor_stack.is_blueprint then
    return player.cursor_stack
  end
  return nil
end

script.on_event(defines.events.on_player_setup_blueprint, function(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  local blueprint = resolve_blueprint_from_player(player)
  if not (blueprint and blueprint.is_blueprint_setup()) then return end
  local ok, entities = pcall(function() return blueprint.get_blueprint_entities() end)
  if not ok or not entities then return end
  local ok_mapping, mapping = pcall(function() return event.mapping.get() end)
  if not ok_mapping then return end
  for _, blueprint_entity in ipairs(entities) do
    if blueprint_entity.name == TRANSMITTER_NAME then
      local source = mapping[blueprint_entity.entity_number]
      if source and source.valid then
        local T = storage.transmitters[source.unit_number]
        -- blueprinting over ghosts: no placed record exists, the ghost itself carries
        -- the tags of the blueprint it was placed from
        local ghost_tags = (not T) and source.tags or nil
        local condition = (T and copy_condition(T.enable_condition))
          or (ghost_tags and copy_condition(ghost_tags[ENABLE_CONDITION_TAG])) or nil
        local wire_in = (T and T.wire_in)
          or (ghost_tags and wire_choice(ghost_tags[ENABLE_WIRE_IN_TAG])) or "both"
        local wire_out = (T and T.wire_out)
          or (ghost_tags and wire_choice(ghost_tags[ENABLE_WIRE_OUT_TAG])) or "both"
        blueprint.set_blueprint_entity_tags(blueprint_entity.entity_number, {
          [ENABLE_CONDITION_TAG] = condition,
          [ENABLE_WIRE_IN_TAG] = wire_in,
          [ENABLE_WIRE_OUT_TAG] = wire_out,
        })
      end
    end
  end
end)

-- built transmitters pick the condition and the wire choices back up from their
-- blueprint tags
local function on_transmitter_built(event)
  local entity = event.entity or event.created_entity
  if not (entity and entity.valid and entity.name == TRANSMITTER_NAME) then return end
  local T = storage.transmitters[entity.unit_number]
  if not T then return end
  -- when a robot (or the player) completes a ghost, the ghost's tags arrive on the
  -- EVENT; entity.tags is nil for entities built without a blueprint. Absent tag
  -- keys mean the defaults (no condition, both wires).
  local tags = event.tags or entity.tags
  if not tags then return end
  apply_enable_settings(T, tags[ENABLE_CONDITION_TAG], tags[ENABLE_WIRE_IN_TAG], tags[ENABLE_WIRE_OUT_TAG])
end

-- the handler itself checks the entity name, no event filters needed
for _, event_id in ipairs({
  defines.events.on_built_entity,
  defines.events.on_robot_built_entity,
  defines.events.on_space_platform_built_entity,
  defines.events.script_raised_built,
  defines.events.script_raised_revive,
}) do
  script.on_event(event_id, on_transmitter_built)
end

local function rescan()
  for _, surface in pairs(game.surfaces) do
    for _, entity in ipairs(surface.find_entities_filtered({ name = TRANSMITTER_NAME })) do
      register_transmitter(entity)
    end
  end
end

script.on_init(function()
  init_storage()
  verify_upkeep_prototypes()
  start_selftest()
  rescan()
  update_tick_handler()
end)

script.on_load(function()
  -- a save made by an older build of the mod lacks the newest storage fields (dev
  -- iterations without a version bump get neither on_init nor on_configuration_
  -- changed): the lazy init is idempotent and keeps every entry point covered
  init_storage()
  -- restore the dynamic tick handler according to the stored state
  update_tick_handler()
end)

script.on_configuration_changed(function()
  -- a save initialized by an older version lacks the newest storage fields
  -- (child_regs, force_index_by_name): on_init does not re-run for it
  init_storage()
  verify_upkeep_prototypes()
  -- a mod reload closes every window: no Enable-if panel is open, the stale shown
  -- flags would only mislead the tick poll
  storage.enable_guis = {}
  -- an update must not drop links: the hidden ports and the beam are kept alive with
  -- their charges (register re-adopts them), and the link state is carried over - a
  -- network without own generation could never relink from the grid alone. Old-format
  -- records are handled the same way: their ports adopt cleanly into the new schema.
  local snapshots = {}
  for unit_number, T in pairs(storage.transmitters) do
    snapshots[unit_number] = {
      link_down = T.link_down,
      ever_linked = T.ever_linked,
      paid_ticks = T.paid_ticks or 0,
      starve_ticks = T.starve_ticks or 0,
      machine_draw = T.machine_draw or 0,
      enable_condition = copy_condition(T.enable_condition),
      wire_in = T.wire_in or "both",
      wire_out = T.wire_out or "both",
    }
    unregister(T, true)
  end
  rescan()
  for unit_number, snap in pairs(snapshots) do
    local T = storage.transmitters[unit_number]
    if T then
      T.machine_draw = snap.machine_draw
      T.enable_condition = snap.enable_condition
      T.wire_in = snap.wire_in
      T.wire_out = snap.wire_out
      if not snap.link_down and T.link_down then
        set_link(T, true) -- re-lights the beam and clears the pin
      end
      T.ever_linked = snap.ever_linked or T.ever_linked
      T.paid_ticks = snap.paid_ticks
      T.starve_ticks = snap.starve_ticks
    end
  end
  update_tick_handler()
end)

-- the effect id is a global string: a conflicting mod reusing it must not be able to
-- register one of its own entities as a transmitter (the event does not support
-- event filters, so every script-trigger effect wakes this handler)
script.on_event(defines.events.on_script_trigger_effect, function(event)
  if event.effect_id == "spt-transmitter-created" then
    local entity = event.source_entity
    if entity and entity.valid and entity.name == TRANSMITTER_NAME then
      register_transmitter(entity)
      update_tick_handler()
    end
  end
end)

script.on_event(defines.events.on_object_destroyed, function(event)
  local unit_number = storage.destroy_regs[event.registration_number]
  if unit_number then
    local T = storage.transmitters[unit_number]
    if T then
      unregister(T)
      update_tick_handler()
    end
    return
  end
  -- a child port or the beam was destroyed (hostile mods, editor tools): the next
  -- recreate scan rebuilds it, the staggered sweep is the fallback
  unit_number = storage.child_regs[event.registration_number]
  if unit_number then
    storage.child_regs[event.registration_number] = nil
    local T = storage.transmitters[unit_number]
    if T then T.children_dirty = true end
  end
end)

local function refund_surface_energy(surface_index)
  -- the ports die with the surface and their buffer energy becomes unreadable:
  -- refund it to the pool while the entities are still valid
  for _, T in pairs(storage.transmitters) do
    if T.entity and T.entity.valid and T.entity.surface.index == surface_index then
      return_exchange_energy(T)
    end
  end
end

-- both events carry surface_index and both destroy the surface's entities afterwards
script.on_event({ defines.events.on_pre_surface_deleted, defines.events.on_pre_surface_cleared }, function(event)
  refund_surface_energy(event.surface_index)
end)

script.on_event(defines.events.on_surface_deleted, function()
  for _, T in pairs(storage.transmitters) do
    if not (T.entity and T.entity.valid) then
      unregister(T)
    end
  end
  update_tick_handler()
end)

script.on_event(defines.events.on_entity_cloned, function(event)
  local entity = event.destination
  if not (entity and entity.valid and entity.name == TRANSMITTER_NAME) then return end
  -- the clone carries copies of the hidden beam and ports: destroy them (the copied
  -- buffer energy is a duplication artifact and must not enter the pool) and let
  -- register_transmitter create a fresh set
  local surface = entity.surface
  for _, name in ipairs({ BEAM_NAME, HUM_NAME, IMPORT_PORT_NAME, EXPORT_PORT_NAME, STATUS_COMBINATOR_NAME, upkeep_port_name(entity.quality.name) }) do
    for _, orphan in ipairs(surface.find_entities_filtered({ name = name, position = entity.position, radius = 0.1 })) do
      if orphan.valid then orphan.destroy() end
    end
  end
  register_transmitter(entity)
  update_tick_handler()
end)

script.on_event(defines.events.on_forces_merged, function(event)
  -- pools are keyed by force name: the merged-away force no longer exists, so its
  -- name is resolved through the index map kept at registration time (otherwise the
  -- balance would strand under the dead force's name)
  for name, index in pairs(storage.force_index_by_name) do
    if index == event.source_index then
      storage.force_index_by_name[name] = nil
      local balance = storage.pools[name]
      if balance then
        storage.pools[name] = nil
        storage.pools[event.destination.name] = (storage.pools[event.destination.name] or 0) + balance
      end
      break
    end
  end
  storage.force_index_by_name[event.destination.name] = event.destination.index
end)

-- the pool is keyed by force name
remote.add_interface("space-power-transmitter", {
  pool = function(force_name)
    return storage.pools[force_name]
  end,
  pools = function()
    -- copy: callers must not mutate the live pool table
    local copy = {}
    for k, v in pairs(storage.pools) do copy[k] = v end
    return copy
  end,
  transmitter_count = function()
    local count = 0
    for _ in pairs(storage.transmitters) do
      count = count + 1
    end
    return count
  end,
  transmitter_info = function(unit_number)
    local T = storage.transmitters[unit_number]
    if not T then return nil end
    return {
      link_down = T.link_down,
      ever_linked = T.ever_linked,
      demand = T.demand,
      disabled = T.disabled or false,
      signal_state = T.signal_state and SIGNAL_NAME[T.signal_state] or nil,
      upkeep_buffer = T.ports.upkeep and T.ports.upkeep.valid and T.ports.upkeep.energy or nil,
      import_buffer = T.ports.import and T.ports.import.valid and T.ports.import.energy or nil,
      export_buffer = T.ports.export and T.ports.export.valid and T.ports.export.energy or nil,
    }
  end,
  debug_info = function(unit_number)
    local T = storage.transmitters[unit_number]
    if not T then return nil end
    local function port_info(port)
      if port and port.valid then
        return string.format("un=%d E=%.1f buf=%.1f pos=%.2f,%.2f surf=%s",
          port.unit_number, port.energy, port.electric_buffer_size or 0,
          port.position.x, port.position.y, port.surface.name)
      end
      return "invalid"
    end
    return string.format(
      "T un=%d force=%s q=%s link_down=%s needs=(%s,%s) demand=%s | import[%s] | export[%s] | upkeep[%s] | entity=%s",
      T.unit_number, tostring(T.force_name), tostring(T.quality), tostring(T.link_down),
      tostring(T.upkeep_need), tostring(T.machine_need), tostring(T.demand),
      port_info(T.ports and T.ports.import), port_info(T.ports and T.ports.export),
      port_info(T.ports and T.ports.upkeep),
      T.entity and T.entity.valid and (T.entity.surface.name .. " " .. T.entity.position.x .. "," .. T.entity.position.y) or "invalid")
  end,
  set_pool = function(force_name, value)
    if type(force_name) ~= "string" or type(value) ~= "number" then return false end
    storage.pools[force_name] = math.max(value, 0)
    return true
  end,
  set_enable_condition = function(unit_number, condition)
    local T = storage.transmitters[unit_number]
    if not T then return false end
    if condition == nil then
      T.enable_condition = nil
    elseif not set_enable_condition_from_table(T, condition) then
      return false
    end
    -- keep entity.tags in step: engine re-creations and ghost tags read them
    return true
  end,
  get_enable_condition = function(unit_number)
    local T = storage.transmitters[unit_number]
    if not T or not T.enable_condition then return nil end
    return copy_condition(T.enable_condition)
  end,
  get_enable_wires = function(unit_number)
    local T = storage.transmitters[unit_number]
    if not T then return nil end
    return { wire_in = T.wire_in, wire_out = T.wire_out }
  end,
})
