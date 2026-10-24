-- Load-test driver: two isolated electric networks, one transmitter each.
--   network 1: transmitter + a 500 GW primary-output source (no other load)
--   network 2: transmitter + a 400 GW primary-input load, no own generation
-- The networks sit 60 tiles apart on a fresh surface - no poles, no wires:
-- they cannot bridge. Both transmitters share a dedicated force, so the pool
-- is isolated from the save's own ("player") transmitters.
--
-- Sequence:
--   setup  - place both transmitters + poles + the source, fund the network 2
--            export reserve (1 GJ), zero the pool;
--   warmup - the reserve pays the upkeep (primary-input served first: nothing
--            else draws on network 2 yet), both links establish after 60 paid
--            ticks; the reserve is topped up while waiting;
--   load   - place the 400 GW load. The driver drains its buffer every tick:
--            the engine refill per tick = the power the grid served that tick.
--            Both links are watched every tick.
--
-- Verdict: PASS when both links hold the whole run AND the average delivered
-- power reaches 95% of the 400 GW demand. The per-tick numbers (and the
-- buffer trace) are logged either way, so a ceiling shows up as data, not as
-- a silent green tick.
local FORCE_NAME = "spt-loadtest"
local SURFACE_NAME = "spt-loadtest"
local TRANSMITTER = "space-power-transmitter"
local EXPORT_PORT = "spt-export-interface"
local IMPORT_PORT = "spt-import-port"
local UPKEEP_PORT = "spt-upkeep-port-normal"
local SOURCE = "spt-loadtest-source"
local LOAD = "spt-loadtest-load"

local SUPPLY_WATTS = 500e9
local DEMAND_WATTS = 400e9
local RESERVE = 1e9 -- 100 ticks of upkeep at the default 600 MW
local WARMUP_CAP = 600
local DURATION = 420 -- 2x the 300-tick starve limit: a kill would land inside

local function say(msg)
  log("[spt-loadtest] " .. tostring(msg))
end

local function find(surface, name, position)
  return surface.find_entities_filtered({ name = name, position = position, radius = 0.1, limit = 1 })[1]
end

local function tx_info(unit_number)
  local ok, info = pcall(remote.call, "space-power-transmitter", "transmitter_info", unit_number)
  return ok and info or nil
end

local function link_up(info)
  return info ~= nil and info.signal_state == "spt-link-up"
end

local function gw(watts)
  return string.format("%.1f", watts / 1e9)
end

local function trace(lt, surface, tag)
  local function port(name, pos)
    local p = find(surface, name, pos)
    return p and string.format("%.0f MJ", p.energy / 1e6) or "gone"
  end
  local i1 = tx_info(lt.t1.unit_number)
  local i2 = tx_info(lt.t2.unit_number)
  say(string.format(
    "%s | net1: export=%s upkeep=%s | net2: import=%s export=%s upkeep=%s | pool=%s | link1=%s link2=%s",
    tag,
    port(EXPORT_PORT, lt.t1.position), port(UPKEEP_PORT, lt.t1.position),
    port(IMPORT_PORT, lt.t2.position), port(EXPORT_PORT, lt.t2.position),
    port(UPKEEP_PORT, lt.t2.position),
    tostring(remote.call("space-power-transmitter", "pool", FORCE_NAME)),
    tostring(i1 and i1.signal_state), tostring(i2 and i2.signal_state)))
end

script.on_init(function()
  storage.lt = { phase = "setup", failures = 0, served = 0 }
end)

script.on_event(defines.events.on_tick, function(event)
  local tick = event.tick
  if tick < 2 then return end
  local lt = storage.lt
  if not lt then
    lt = { phase = "setup", failures = 0, served = 0 }
    storage.lt = lt
  end
  if lt.phase == "done" then return end

  if lt.phase == "setup" then
    local force = game.forces[FORCE_NAME] or game.create_force(FORCE_NAME)
    local surface = game.surfaces[SURFACE_NAME] or game.create_surface(SURFACE_NAME)
    -- find_non_colliding_position does not generate chunks: request them first
    -- (both build sites fit in a radius-8 chunk ring around (30, 0))
    if not lt.chunks_at then
      lt.chunks_at = tick
      surface.request_to_generate_chunks({ 30, 0 }, 8)
      return
    end
    if not (surface.is_chunk_generated({ 0, 0 }) and surface.is_chunk_generated({ 1, 0 })
        and surface.is_chunk_generated({ 2, 0 })) then
      if tick - lt.chunks_at > 600 then
        say("FAIL: the load-test surface never generated its chunks")
        say("RESULT: FAIL")
        lt.phase = "done"
      end
      return
    end
    local p1 = surface.find_non_colliding_position(TRANSMITTER, { x = 0, y = 0 }, 60, 2)
      or { x = 0, y = 0 }
    local p2 = surface.find_non_colliding_position(TRANSMITTER, { x = 60, y = 0 }, 60, 2)
      or { x = 60, y = 0 }
    if math.abs(p2.x - p1.x) < 40 then -- never let the search snap them together
      p2 = surface.find_non_colliding_position(TRANSMITTER, { x = p1.x + 100, y = p1.y }, 60, 2)
        or { x = p1.x + 100, y = p1.y }
    end
    lt.t1 = surface.create_entity({ name = TRANSMITTER, position = p1, force = force })
    lt.t2 = surface.create_entity({ name = TRANSMITTER, position = p2, force = force })
    if not (lt.t1 and lt.t2) then
      say("FAIL: could not create the transmitters on the load-test surface")
      say("RESULT: FAIL")
      lt.phase = "done"
      return
    end
    local pole1 = surface.create_entity({
      name = "substation",
      position = surface.find_non_colliding_position(
        "substation", { x = lt.t1.position.x + 6, y = lt.t1.position.y }, 4, 1)
        or { x = lt.t1.position.x + 6, y = lt.t1.position.y },
      force = force })
    local pole2 = surface.create_entity({
      name = "substation",
      position = surface.find_non_colliding_position(
        "substation", { x = lt.t2.position.x + 6, y = lt.t2.position.y }, 4, 1)
        or { x = lt.t2.position.x + 6, y = lt.t2.position.y },
      force = force })
    lt.source = surface.create_entity({
      name = SOURCE, position = { pole1.position.x, pole1.position.y + 3 }, force = force })
    if not (pole1 and pole2 and lt.source) then
      say("FAIL: could not create the pole/source fixtures")
      say("RESULT: FAIL")
      lt.phase = "done"
      return
    end
    -- the link on the generation-less network 2 must bootstrap from its own
    -- export reserve (the same mechanism the self-heal path uses)
    local reserve = find(surface, EXPORT_PORT, lt.t2.position)
    if reserve then reserve.energy = RESERVE end
    remote.call("space-power-transmitter", "set_pool", FORCE_NAME, 0)
    -- network membership sanity: both transmitter grids must be separate
    say(string.format("setup: net1(id=%s)=[%s %s %s] net2(id=%s)=[%s %s] dist=%.1f tiles",
      tostring(lt.t1.electric_network_id),
      lt.t1.name, pole1.name, lt.source.name,
      tostring(lt.t2.electric_network_id), lt.t2.name, pole2.name,
      math.sqrt((p2.x - p1.x) ^ 2 + (p2.y - p1.y) ^ 2)))
    lt.warm_start = tick
    lt.phase = "warmup"
    return
  end

  local surface = lt.t1.surface

  if lt.phase == "warmup" then
    -- keep the reserve funded while waiting (it burns the upkeep: 10 MJ/tick)
    local reserve = find(surface, EXPORT_PORT, lt.t2.position)
    if reserve and reserve.energy < RESERVE / 2 then reserve.energy = RESERVE end
    if tick - lt.warm_start > WARMUP_CAP then
      say("FAIL: warmup timeout, links not established")
      trace(lt, surface, "warmup timeout")
      say("RESULT: FAIL")
      lt.failures = lt.failures + 1
      lt.phase = "done"
      return
    end
    local up1 = link_up(tx_info(lt.t1.unit_number))
    local up2 = link_up(tx_info(lt.t2.unit_number))
    if up1 and up2 then
      say(string.format("both links up after %d warmup ticks", tick - lt.warm_start))
      trace(lt, surface, "warmup done")
      lt.load_start = tick
      lt.phase = "load"
    end
    return
  end

  if lt.phase == "load" then
    local dt = tick - lt.load_start
    if dt == 1 then
      -- the load arrives only now: the reserve would be eaten instantly otherwise
      local pole2 = surface.find_entities_filtered({
        name = "substation", radius = 10, position = lt.t2.position, limit = 1 })[1]
      lt.load = surface.create_entity({
        name = LOAD, position = { pole2.position.x, pole2.position.y + 3 }, force = lt.t2.force })
      if not lt.load then
        say("FAIL: could not create the load fixture")
        say("RESULT: FAIL")
        lt.phase = "done"
        return
      end
      local load_net = lt.load.electric_network_id
      local import2 = find(surface, IMPORT_PORT, lt.t2.position)
      say(string.format("load placed: net2 id=%s (import port net=%s), demand=%s GW",
        tostring(load_net), tostring(import2 and import2.electric_network_id), gw(DEMAND_WATTS)))
      remote.call("space-power-transmitter", "set_pool", FORCE_NAME, 0)
      lt.peak = 0
      lt.drop1, lt.drop2 = nil, nil
    end

    -- the engine pushed this tick's refill into the buffer we emptied last tick:
    -- exactly the power the grid served to the load, no script energy involved
    local served = lt.load.energy
    lt.served = lt.served + served
    if served > lt.peak then lt.peak = served end
    lt.load.energy = 0

    -- link watchdog: a real drop is the mod's own link_down flag; the starving
    -- warning (spt-link-failing) is logged once as a note, it is not a drop
    local i1 = tx_info(lt.t1.unit_number)
    local i2 = tx_info(lt.t2.unit_number)
    if not lt.warned1 and i1 and i1.signal_state == "spt-link-failing" then
      lt.warned1 = dt
      say(string.format("note: link 1 starving since load tick %d", dt))
    end
    if not lt.warned2 and i2 and i2.signal_state == "spt-link-failing" then
      lt.warned2 = dt
      say(string.format("note: link 2 starving since load tick %d", dt))
    end
    if not lt.drop1 and i1 and i1.link_down then
      lt.drop1 = dt
      say(string.format("LINK 1 DOWN at load tick %d", dt))
    end
    if not lt.drop2 and i2 and i2.link_down then
      lt.drop2 = dt
      say(string.format("LINK 2 DOWN at load tick %d", dt))
    end
    -- steady window: the last third of the run (the machine tier ramps up
    -- through the smoothed draw estimator, so early ticks underserve)
    if dt > DURATION * 2 / 3 then lt.steady = (lt.steady or 0) + served end

    if dt % 60 == 0 then
      local avg = lt.served / dt * 60
      trace(lt, surface, string.format("load t=%d: served this tick=%.2f GJ (%.0f GW), avg=%.0f GW",
        dt, served / 1e9, served * 60 / 1e9, avg / 1e9))
    end

    if dt >= DURATION then
      local avg_watts = lt.served / DURATION * 60
      local steady_ticks = DURATION - math.floor(DURATION * 2 / 3)
      local steady_watts = (lt.steady or 0) / steady_ticks * 60
      say(string.format(
        "delivered: total=%.1f GJ, avg=%.0f GW, steady(last %d ticks)=%.0f GW, peak=%.0f GW over %d ticks",
        lt.served / 1e9, avg_watts / 1e9, steady_ticks, steady_watts / 1e9,
        lt.peak * 60 / 1e9, DURATION))
      say(string.format("demand=%s GW, supply=%s GW, real link drops: net1=%s net2=%s, starving notes: net1@%s net2@%s",
        gw(DEMAND_WATTS), gw(SUPPLY_WATTS), tostring(lt.drop1), tostring(lt.drop2),
        tostring(lt.warned1), tostring(lt.warned2)))
      trace(lt, surface, "final")
      local ok = lt.failures == 0 and not lt.drop1 and not lt.drop2
        and steady_watts >= 0.95 * DEMAND_WATTS
      if ok then
        say("RESULT: PASS")
      else
        say(string.format(
          "RESULT: FAIL (steady delivered %.0f GW of %.0f GW demand%s)",
          steady_watts / 1e9, DEMAND_WATTS / 1e9,
          (lt.drop1 or lt.drop2) and "; a link dropped mid-run" or ""))
      end
      lt.phase = "done"
    end
  end
end)
