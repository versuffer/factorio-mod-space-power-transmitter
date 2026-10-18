local power = require("__space-power-transmitter__.common.power")

local upkeep_watts = power.upkeep_watts()

local function upkeep_port_name(quality)
  return "spt-upkeep-port-" .. quality
end

local transmitter_picture = {
  layers = {
    {
      filename = "__space-power-transmitter__/graphics/entity/transmitter.png",
      width = 500,
      height = 364,
      scale = 0.5,
      shift = util.by_pixel(42, -20),
    },
    {
      filename = "__space-power-transmitter__/graphics/entity/transmitter-glow.png",
      width = 500,
      height = 364,
      scale = 0.5,
      shift = util.by_pixel(42, -20),
      draw_as_light = true,
      blend_mode = "additive",
      color = { 1, 1, 1, 0.3 },
    },
    {
      filename = "__space-power-transmitter__/graphics/entity/transmitter-shadow.png",
      priority = "high",
      width = 500,
      height = 364,
      scale = 0.5,
      shift = util.by_pixel(42, -20),
      draw_as_shadow = true,
    },
  },
}

local beam_picture = {
  layers = {
    {
      filename = "__space-power-transmitter__/graphics/entity/transmitter-beam.png",
      width = 500,
      height = 1455,
      scale = 0.5,
      -- same artwork as the transmitter structure: the identical x-shift keeps the
      -- emitter ring aligned with the transmitter body (26 left the beam 16px west)
      shift = util.by_pixel(42, -309),
      draw_as_glow = true,
      blend_mode = "additive",
    },
  },
}

local function power_str(value)
  return string.format("%.3fJ", value)
end

local function make_port(name, usage_priority, buffer_joules, input_watts, output_watts, role_key)
  local energy_source = {
    type = "electric",
    usage_priority = usage_priority,
    buffer_capacity = power_str(buffer_joules),
  }
  -- nil = no flow limit (the buffer capacity becomes the per-tick ceiling)
  if input_watts then
    energy_source.input_flow_limit = power_str(input_watts)
  end
  if output_watts then
    energy_source.output_flow_limit = power_str(output_watts)
  end
  return {
    type = "electric-energy-interface",
    name = name,
    localised_name = { "spt-port." .. role_key },
    localised_description = { "spt-port.port-description" },
    icons = {
      { icon = "__space-power-transmitter__/graphics/icons/space-power-transmitter.png", icon_size = 64 },
    },
    hidden = true,
    flags = {
      "not-on-map",
      "not-blueprintable",
      "not-deconstructable",
      "hide-alt-info",
      "not-flammable",
      "not-repairable",
      "not-upgradable",
      "no-copy-paste",
      "placeable-off-grid",
    },
    collision_mask = { layers = {} },
    selectable = false,
    energy_source = energy_source,
  }
end

local function make_upkeep_port(quality)
  local watts = upkeep_watts * power.QUALITY_MULTIPLIERS[quality]
  -- pure 1x-rate load: the engine applies input_flow_limit as raw joules per tick, so
  -- rate in joules equals watts / 60. The buffer holds two ticks of burn: an EEI load
  -- never draws more than its buffer space, so this keeps the demand at exactly the
  -- rate without exceeding 1x consumption. The outage tolerance is time-based
  -- hysteresis in control.lua, not an energy reserve.
  return make_port(upkeep_port_name(quality), "primary-input", watts / 30, watts / 60, 0, "port-upkeep")
end

local entities = {
  {
    type = "accumulator",
    name = "space-power-transmitter",
    icon = "__space-power-transmitter__/graphics/icons/space-power-transmitter.png",
    localised_description = { "entity-description.space-power-transmitter", power.watts_str(upkeep_watts) },
    flags = { "placeable-neutral", "player-creation" },
    minable = { mining_time = 0.4, result = "space-power-transmitter" },
    max_health = 500,
    corpse = "accumulator-remnants",
    dying_explosion = "accumulator-explosion",
    collision_box = { { -2.2, -2.2 }, { 2.2, 2.2 } },
    selection_box = { { -2.5, -2.5 }, { 2.5, 2.5 } },
    drawing_box_vertical_extension = 0.5,
    impact_category = "metal",
    -- pure node: the buffer is deliberately negligible, all grid mechanics live in the
    -- hidden ports; the accumulator type is used for its native click GUI
    energy_source = {
      type = "electric",
      buffer_capacity = "5kJ",
      usage_priority = "tertiary",
      input_flow_limit = "100kW",
      output_flow_limit = "100kW",
    },
    chargable_graphics = {
      picture = transmitter_picture,
    },
    created_effect = {
      type = "direct",
      action_delivery = {
        type = "instant",
        source_effects = {
          type = "script",
          effect_id = "spt-transmitter-created",
        },
      },
    },
  },
  {
    type = "simple-entity-with-owner",
    name = "spt-beam",
    render_layer = "light-effect",
    selectable = false,
    flags = {
      "not-on-map",
      "not-blueprintable",
      "not-deconstructable",
      "hide-alt-info",
      "not-flammable",
      "not-repairable",
      "not-upgradable",
      "no-copy-paste",
      "placeable-off-grid",
    },
    picture = beam_picture,
  },
  -- transformer pattern (Power Overload style): two hidden ports wired into the local
  -- grid, working simultaneously:
  --   spt-import-port  = tertiary source: grid energy covers the deficit TOGETHER with
  --                      the local accumulators (same priority tier: no reservation of
  --                      loads, so the accumulators discharge normally); never charges
  --                      (input flow 0 - surplus collection is the export port's job);
  --                      buffer 1 GJ = two-tick cushion + throughput ceiling (~60 GW/tick)
  --   spt-export-port  = ACCUMULATOR-type port: the engine splits the local surplus
  --                      between all accumulators of the grid proportionally to their
  --                      EMPTY SPACE, so this port charges from the true surplus while
  --                      letting local accumulators fill; on a local deficit it
  --                      discharges back into the local grid FIRST (the donor's own
  --                      reserve self-heals its link), and the script drains the rest
  --                      into the transit pool. As the port fills up it naturally
  --                      yields its share to the local accumulators (self-regulating
  --                      greed - no phantom consumption on balanced grids).
  -- ENGINE QUIRK (verified empirically): for electric-energy-interface input_flow_limit
  -- is applied as raw joules per tick, output_flow_limit as watts (divided by 60);
  -- accumulator-type entities use standard watt semantics.
  make_port("spt-import-port", "tertiary", 1e9, 0, nil, "port-import"),
  {
    type = "accumulator",
    name = "spt-export-port",
    localised_name = { "spt-port.port-export" },
    localised_description = { "spt-port.port-description" },
    icons = {
      { icon = "__space-power-transmitter__/graphics/icons/space-power-transmitter.png", icon_size = 64 },
    },
    hidden = true,
    flags = {
      "not-on-map",
      "not-blueprintable",
      "not-deconstructable",
      "hide-alt-info",
      "not-flammable",
      "not-repairable",
      "not-upgradable",
      "no-copy-paste",
      "placeable-off-grid",
    },
    collision_mask = { layers = {} },
    selectable = false,
    max_health = 100,
    energy_source = {
      type = "electric",
      buffer_capacity = power_str(1e9), -- 1 GJ: a self-heal reserve of about 1.7 seconds of upkeep at the default 600 MW, so a downed link can recover from its own reserve
      usage_priority = "tertiary", -- required for accumulator prototypes (vanilla accumulators use it too)
      input_flow_limit = "1TW",
      output_flow_limit = "1TW",
    },
    -- no chargable_graphics: the port sits at the transmitter's position and a
    -- picture here would render the whole transmitter sprite a second time
    -- (additive glow and shadow layers included)
  },
}

for _, quality in ipairs({ "normal", "uncommon", "rare", "epic", "legendary" }) do
  table.insert(entities, make_upkeep_port(quality))
end

data:extend(entities)
