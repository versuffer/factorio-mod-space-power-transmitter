-- Load-test fixtures: a 500 GW primary-output supply and a pure 400 GW
-- primary-input load. The load buffer is drained by the driver every tick, so
-- the engine refill (the engine applies an electric-energy-interface
-- input_flow_limit as joules per tick) is exactly the power the grid served
-- that tick - no script energy enters the measured network.
local HIDDEN = { "not-on-map", "not-blueprintable", "not-deconstructable" }

local SUPPLY_WATTS = 500e9
local DEMAND_WATTS = 400e9

local function joules(value)
  return string.format("%.3fJ", value)
end

data:extend({
  {
    type = "electric-energy-interface",
    name = "spt-loadtest-source",
    hidden = true,
    flags = HIDDEN,
    collision_mask = { layers = {} },
    selectable = false,
    max_health = 100,
    energy_source = {
      type = "electric",
      -- three ticks of production: the buffer must never cap the supply
      buffer_capacity = joules(SUPPLY_WATTS / 60 * 3),
      usage_priority = "primary-output",
    },
    energy_production = "500GW",
    picture = { filename = "__core__/graphics/empty.png", width = 1, height = 1 },
  },
  {
    type = "electric-energy-interface",
    name = "spt-loadtest-load",
    hidden = true,
    flags = HIDDEN,
    collision_mask = { layers = {} },
    selectable = false,
    max_health = 100,
    energy_source = {
      type = "electric",
      -- two ticks of demand, so the refill demand stays exactly one tick of burn
      buffer_capacity = joules(DEMAND_WATTS / 30),
      usage_priority = "primary-input",
      -- EEI quirk: this is JOULES PER TICK (demand watts / 60), same builder
      -- convention as the mod's upkeep ports
      input_flow_limit = joules(DEMAND_WATTS / 60),
    },
    picture = { filename = "__core__/graphics/empty.png", width = 1, height = 1 },
  },
})
