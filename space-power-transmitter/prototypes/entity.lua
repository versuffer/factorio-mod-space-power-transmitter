local power = require("__space-power-transmitter__.common.power")

-- core lualib (a no-op when space-age has already required it): provides the
-- circuit_connector_definitions table and default_circuit_wire_max_distance
require("circuit-connector-sprites")

local upkeep_watts = power.upkeep_watts()

local function upkeep_port_name(quality)
  return "spt-upkeep-port-" .. quality
end

local transmitter_picture = {
  layers = {
    {
      -- pre-colored texture (tools/make_tinted_transmitter.py): the blue hull
      -- and the white emissive parts are baked per-pixel, an engine tint would
      -- paint the glowing parts blue too
      filename = "__space-power-transmitter__/graphics/entity/transmitter-tinted.png",
      width = 500,
      height = 364,
      scale = 0.5,
      shift = util.by_pixel(42, -20),
    },
    {
      -- no static glow layer: a draw_as_light layer cannot be animated and
      -- draws above regular sprites; the glow comes from the beam entity's
      -- flicker layer while linked, unlinked transmitters stay dark
      filename = "__space-power-transmitter__/graphics/entity/transmitter-shadow-sharp.png",
      priority = "high",
      width = 500,
      height = 364,
      scale = 0.5,
      shift = util.by_pixel(42, -20),
      draw_as_shadow = true,
    },
  },
}

-- the beam entity animation: layer 1 - the beam column, layer 2 - the
-- transmitter glow flicker (the structure pulses in sync with the beam).
-- Both sheets (24 frames) come from tools/make_beam_animation.py and
-- tools/make_glow_flicker.py; layers share one clock: the first layer's
-- animation_speed drives all of them (1 s cycle at 0.4).
local function beam_anim()
  return {
    {
      layers = {
        {
          filenames = {
            "__space-power-transmitter__/graphics/entity/transmitter-beam-anim-1.png",
            "__space-power-transmitter__/graphics/entity/transmitter-beam-anim-2.png",
            "__space-power-transmitter__/graphics/entity/transmitter-beam-anim-3.png",
            "__space-power-transmitter__/graphics/entity/transmitter-beam-anim-4.png",
          },
          lines_per_file = 1,
          width = 500,
          height = 4077,
          frame_count = 24,
          line_length = 6,
          animation_speed = 0.4,
          scale = 0.5,
          -- printed by tools/make_beam_animation.py: the ring stays pinned to the
          -- structure while the column reaches 3x as high
          shift = util.by_pixel(42, -951),
          draw_as_glow = true,
          blend_mode = "additive",
        },
        {
          -- flicker overlay, modular-nuclear-reactor style: a plain additive
          -- draw_as_glow layer whose brightness pulse is baked into the frames
          -- (tools/make_glow_flicker.py). No draw_as_light here - nested light
          -- passes get dropped, glow is the flag proven to render in this entity.
          filenames = {
            "__space-power-transmitter__/graphics/entity/transmitter-glow-flicker-1.png",
            "__space-power-transmitter__/graphics/entity/transmitter-glow-flicker-2.png",
            "__space-power-transmitter__/graphics/entity/transmitter-glow-flicker-3.png",
            "__space-power-transmitter__/graphics/entity/transmitter-glow-flicker-4.png",
          },
          lines_per_file = 1,
          width = 500,
          height = 364,
          frame_count = 24,
          line_length = 6,
          scale = 0.5,
          shift = util.by_pixel(42, -21),
          draw_as_glow = true,
          blend_mode = "additive",
        },
      },
    },
  }
end

local beam_animation = beam_anim()

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
    -- native accumulator socket (same connector graphics as the vanilla accumulator):
    -- players attach circuit wires here; the hidden status combinator joins both
    -- connectors with script wires (control.lua)
    circuit_connector = circuit_connector_definitions["accumulator"],
    circuit_wire_max_distance = default_circuit_wire_max_distance,
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
    random_animation_offset = true,
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
    -- no collision: a default collision box here blocks super force build of
    -- transmitter blueprints over the existing entity
    collision_mask = { layers = {} },
    localised_name = { "entity-name.space-power-transmitter" },
    animations = beam_animation,
  },
  {
    -- sound driver: an invisible always-crafting machine (Space Exploration /
    -- modular-nuclear-reactor pattern) - a machine that "works" plays its
    -- working_sound, which the accumulator transmitter itself cannot do (its
    -- buffer is static). secondary-input + 1 kW: the hum plays only while the
    -- local network actually has power.
    type = "assembling-machine",
    name = "spt-hum",
    icon = "__space-power-transmitter__/graphics/icons/space-power-transmitter.png",
    icon_size = 64,
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
    crafting_categories = { "spt-fixed-recipe" },
    fixed_recipe = "spt-hum-idle",
    crafting_speed = 1,
    energy_source = {
      type = "electric",
      usage_priority = "secondary-input",
      buffer_capacity = "10kJ",
      drain = "0W",
    },
    energy_usage = "1kW",
    gui_consumption_field = false,
    graphics_set = {
      animation = {
        filename = "__space-power-transmitter__/graphics/entity/blank.png",
        width = 1,
        height = 1,
        frame_count = 1,
      },
    },
    working_sound = {
      -- vanilla idle hum (Space Exploration's workhorse ambient loop)
      sound = {
        filename = "__base__/sound/idle1.ogg",
        volume = 1.0,
      },
      apparent_volume = 4,
      fade_in_ticks = 20,
      fade_out_ticks = 20,
      max_sounds_per_type = 3,
    },
  },
  -- link status source: a hidden constant combinator at the transmitter's position
  -- broadcasting the link status virtual signals (see prototypes/signals.lua).
  -- control.lua joins its output to the transmitter's circuit connectors with
  -- script-origin wires (invisible, unremovable, wire color agnostic), so the
  -- signals appear on whatever network the player wires the transmitter into.
  -- No graphics of its own: the entity is never rendered and cannot be opened,
  -- the signal values are written by the script through the control behavior.
  {
    type = "constant-combinator",
    name = "spt-status-combinator",
    localised_name = { "entity-name.space-power-transmitter" },
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
    sprites = {
      filename = "__space-power-transmitter__/graphics/entity/blank.png",
      width = 1,
      height = 1,
    },
    -- without a positive reach the engine never allocates the output wire
    -- connectors, and the script wires (which ignore reach anyway) cannot attach
    circuit_wire_max_distance = default_circuit_wire_max_distance,
    -- required by the engine, unused here (the entity is never rendered and the
    -- script wires are invisible)
    activity_led_light_offsets = { { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 } },
    circuit_wire_connection_points = {
      { wire = { red = { 0, 0 }, green = { 0, 0 } }, shadow = { red = { 0, 0 }, green = { 0, 0 } } },
      { wire = { red = { 0, 0 }, green = { 0, 0 } }, shadow = { red = { 0, 0 }, green = { 0, 0 } } },
      { wire = { red = { 0, 0 }, green = { 0, 0 } }, shadow = { red = { 0, 0 }, green = { 0, 0 } } },
      { wire = { red = { 0, 0 }, green = { 0, 0 } }, shadow = { red = { 0, 0 }, green = { 0, 0 } } },
    },
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
