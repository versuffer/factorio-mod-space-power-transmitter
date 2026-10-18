local TRANSMITTER_NAME = "space-power-transmitter"
local BEAM_NAME = "spt-beam"
local IMPORT_PORT_NAME = "spt-import-port"
local EXPORT_PORT_NAME = "spt-export-port"
local UPKEEP_PORT_PREFIX = "spt-upkeep-port-"

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
    -- no warning icon: the unlit beam is the down-link indicator
    T.link_down = true
    set_beam(T, false)
    notify_link_dropped(T)
    T.alert_refresh = 60
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
local function adopt_or_create(entity, name, create_smoke)
  local found
  for _, orphan in ipairs(entity.surface.find_entities_filtered({
      name = name,
      position = entity.position,
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
    position = entity.position,
    force = entity.force,
    create_build_effect_smoke = create_smoke,
  })
end

local function recreate_port(T, key)
  local entity = T.entity
  if not (entity and entity.valid) then return nil end
  -- something was recreated: the tile needs a duplicate scan
  T.rescan = true
  local name
  if key == "import" then
    name = IMPORT_PORT_NAME
  elseif key == "export" then
    name = EXPORT_PORT_NAME
  else
    name = upkeep_port_name(T.quality)
  end
  local port = adopt_or_create(entity, name)
  T.ports[key] = port
  track_child(T, key, port)
  if port then
    T.port_sizes[key] = port.electric_buffer_size
    if key == "import" then
      -- a fresh baseline: the adopted port's current charge must not read as a grid draw
      T.import_pending = port.energy
    end
  end
  return port
end

local function recreate_beam(T)
  local entity = T.entity
  if not (entity and entity.valid) then return nil end
  local beam = adopt_or_create(entity, BEAM_NAME, false)
  if beam then beam.render_to_forces = T.beam_active and {} or "neutral" end
  T.beam = beam
  track_child(T, "beam", beam)
  return beam
end

local function register_transmitter(entity)
  local unit_number = entity.unit_number
  if storage.transmitters[unit_number] then return end

  local quality = entity.quality.name
  -- adopt-or-create recovers untracked orphans left at the tile (a lost validity race
  -- or a foreign record's teardown): creating fresh duplicates would let the rescan
  -- pass destroy their banked energy instead of putting it back to work
  local ports = {
    import = adopt_or_create(entity, IMPORT_PORT_NAME),
    export = adopt_or_create(entity, EXPORT_PORT_NAME),
    upkeep = adopt_or_create(entity, upkeep_port_name(quality)),
  }
  -- prototype constants: reading electric_buffer_size crosses the C boundary, so the
  -- per-tick code reads the cached values
  local port_sizes = {}
  local children_dirty = false
  for _, key in ipairs(PORT_KEYS) do
    local port = ports[key]
    if port then
      port_sizes[key] = port.electric_buffer_size
    else
      children_dirty = true -- a failed create: the retry scan runs on the next tick
    end
  end
  local beam = adopt_or_create(entity, BEAM_NAME, false)
  if beam then
    beam.render_to_forces = "neutral"
  else
    children_dirty = true
  end

  local T = {
    entity = entity,
    unit_number = unit_number,
    force_index = entity.force.index,
    force_name = entity.force.name,
    quality = quality,
    rate = upkeep_rate_per_tick(quality),
    ports = ports,
    port_sizes = port_sizes,
    beam = beam,
    beam_active = false,
    link_down = true,
    ever_linked = false,
    paid_ticks = 0,
    starve_ticks = 0,
    upkeep_need = 0,
    machine_need = 0,
    machine_draw = 0,
    import_pending = ports.import and ports.import.energy or 0,
    demand = 0,
    rescan = true,
    children_dirty = children_dirty,
    child_regs = {},
    retry_backoff = CREATE_BACKOFF_MIN,
    destroy_reg = script.register_on_object_destroyed(entity),
  }
  storage.destroy_regs[T.destroy_reg] = unit_number
  storage.transmitters[unit_number] = T
  for _, key in ipairs(PORT_KEYS) do
    track_child(T, key, ports[key])
  end
  track_child(T, "beam", beam)
  -- pools are keyed by force name; this index map resolves the name back when the
  -- force is merged away (on_forces_merged only reports the source index)
  storage.force_index_by_name[T.force_name] = T.force_index
  local list = storage.by_force[T.force_name]
  if not list then
    list = {}
    storage.by_force[T.force_name] = list
  end
  list[#list + 1] = unit_number
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

-- keep_children: rebuild-only mode (on_configuration_changed) - the hidden ports and
-- the beam stay alive with their charges and register re-adopts them, so an update
-- drops no links (a network without own generation could never relink from the grid)
local function unregister(T, keep_children)
  local entity_valid = (T.entity and T.entity.valid) and true or false
  if not (keep_children and entity_valid) then
    return_exchange_energy(T)
    destroy_if_valid(T.beam)
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
  if not (keep_children and entity_valid) then
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
      local new_port = recreate_port(T, "upkeep")
      if new_port and reserve > 0 then
        new_port.energy = math.min(reserve, T.port_sizes.upkeep or new_port.electric_buffer_size)
      end
    end
  end

  -- missing ports and beam are recreated on a destruction report (children_dirty) or
  -- on a backoff, not every tick: in steady state no validity checks run here at all,
  -- and a persistently failing create (a blocking mod, a corrupted position) must not
  -- cost API calls per tick. The staggered sweep is the safety net for lost reports
  -- (it piggybacks on the force-check phase and never cuts a pending backoff short).
  if T.children_dirty
      or (T.retry_at and tick >= T.retry_at)
      or (not T.retry_at and phase_due) then
    -- the report is being handled now: a failing recreate must back off, not spin
    T.children_dirty = false
    local failed = false
    for _, key in ipairs(PORT_KEYS) do
      local port = T.ports[key]
      if not (port and port.valid) then
        if not recreate_port(T, key) then
          failed = true
        end
      end
    end
    local beam = T.beam
    if not (beam and beam.valid) then
      if not recreate_beam(T) then
        failed = true
      end
    end
    if failed then
      T.retry_backoff = math.min((T.retry_backoff or CREATE_BACKOFF_MIN) * 2, CREATE_BACKOFF_MAX)
      T.retry_at = tick + T.retry_backoff
    else
      T.retry_at = nil
      T.retry_backoff = nil
    end
  end

  -- destroy orphan duplicate ports and beams (prototype migrations and lost-validity
  -- races leave them behind); only after a registration or a recreate - in steady
  -- state this never runs. Orphans of a foreign force are not ours to destroy.
  if T.rescan then
    T.rescan = false
    for name, current in pairs({
      [IMPORT_PORT_NAME] = T.ports.import,
      [EXPORT_PORT_NAME] = T.ports.export,
      [upkeep_port_name(T.quality)] = T.ports.upkeep,
      [BEAM_NAME] = T.beam,
    }) do
      for _, orphan in ipairs(entity.surface.find_entities_filtered({
        name = name,
        position = entity.position,
        radius = 0.1,
      })) do
        if orphan.valid and orphan ~= current and orphan.force == entity.force then
          orphan.destroy()
        end
      end
    end
  end

  local upkeep_port = T.ports.upkeep
  if not (upkeep_port and upkeep_port.valid) then
    -- no upkeep port means no trustworthy measurements: zero out the needs so stale
    -- demand from an older tick cannot feed the rationing. The import baseline stays
    -- fresh: the grid may drain the buffer while it cannot be measured, and the next
    -- tick's draw must not read as a spike.
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

  -- custom alerts are one-shot for the engine: viewing the target surface (a click on
  -- the alert travels there) dismisses it. Vanilla-style, re-raise it every second
  -- while the link is down so the pin does not get silenced for good.
  if T.link_down then
    T.alert_refresh = (T.alert_refresh or 60) - 1
    if T.alert_refresh <= 0 then
      notify_link_dropped(T)
      T.alert_refresh = 60
    end
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
  -- (the floor from the harvest above is dipped only on shortage). Deterministic
  -- drain order matters only under scarcity, so the sort runs only then. Donor
  -- energies are read once: no engine update runs inside the tick, so the values
  -- cannot change between this scan and the drain.
  local remaining = total_demand - pool
  donor_count = 0
  local available = 0
  if remaining > 0 then
    table.sort(all)
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
  -- restore the dynamic tick handler according to the stored state
  update_tick_handler()
end)

script.on_configuration_changed(function()
  -- a save initialized by an older version lacks the newest storage fields
  -- (child_regs, force_index_by_name): on_init does not re-run for it
  init_storage()
  verify_upkeep_prototypes()
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
    }
  end
  for _, T in pairs(storage.transmitters) do
    unregister(T, true)
  end
  rescan()
  for unit_number, snap in pairs(snapshots) do
    local T = storage.transmitters[unit_number]
    if T then
      T.machine_draw = snap.machine_draw
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
  for _, name in ipairs({ BEAM_NAME, IMPORT_PORT_NAME, EXPORT_PORT_NAME, upkeep_port_name(entity.quality.name) }) do
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
})
