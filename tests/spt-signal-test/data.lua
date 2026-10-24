-- A free-energy source for the surplus-collection test: secondary-output supply
-- (like a steam engine), producing 700 MW from nothing. The per-tick supply is
-- capped by the buffer (700 MW / 60 = 11.67 MJ per tick), so the buffer must
-- hold more than one tick of supply.
local HIDDEN = { "not-on-map", "not-blueprintable", "not-deconstructable" }

data:extend({
  {
    type = "electric-energy-interface",
    name = "spt-test-source",
    hidden = true,
    flags = HIDDEN,
    collision_mask = { layers = {} },
    selectable = false,
    max_health = 100,
    energy_source = {
      type = "electric",
      buffer_capacity = "20MJ",
      usage_priority = "secondary-output",
    },
    energy_production = "700MW",
    picture = { filename = "__core__/graphics/empty.png", width = 1, height = 1 },
  },
})
