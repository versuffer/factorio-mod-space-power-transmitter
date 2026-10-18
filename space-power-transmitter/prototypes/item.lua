local item_sounds = require("__base__.prototypes.item_sounds")
local power = require("__space-power-transmitter__.common.power")

return {
  {
    type = "item",
    name = "space-power-transmitter",
    icon = "__space-power-transmitter__/graphics/icons/space-power-transmitter.png",
    subgroup = "energy",
    order = "q-c[space-power-transmitter]",
    inventory_move_sound = item_sounds.metal_large_inventory_move,
    pick_sound = item_sounds.metal_large_inventory_pickup,
    drop_sound = item_sounds.metal_large_inventory_move,
    place_result = "space-power-transmitter",
    stack_size = 1,
    weight = 1000000, -- one ton: exactly one transmitter per rocket
    localised_description = { "item-description.space-power-transmitter", power.watts_str(power.upkeep_watts()) },
  },
}
