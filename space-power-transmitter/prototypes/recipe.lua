-- the hum machine's always-on recipe: no ingredients, no products, pure sound driver
-- (the modular-nuclear-reactor / Space Exploration fixed-recipe pattern)
data:extend({
  { type = "recipe-category", name = "spt-fixed-recipe" },
})

return {
  {
    type = "recipe",
    name = "space-power-transmitter",
    categories = { "electromagnetics" }, -- electromagnetic plant only
    energy_required = 160,
    ingredients = {
      { type = "item", name = "quantum-processor", amount = 150 },
      { type = "item", name = "supercapacitor", amount = 500 },
      { type = "item", name = "superconductor", amount = 500 },
      { type = "item", name = "tungsten-carbide", amount = 300 },
      { type = "item", name = "refined-concrete", amount = 1000 },
      { type = "fluid", name = "electrolyte", amount = 1000 },
    },
    results = { { type = "item", name = "space-power-transmitter", amount = 1 } },
    enabled = false,
  },
  {
    type = "recipe",
    name = "spt-hum-idle",
    icon = "__space-power-transmitter__/graphics/icons/space-power-transmitter.png",
    icon_size = 64,
    categories = { "spt-fixed-recipe" },
    energy_required = 1,
    ingredients = {},
    results = {},
    hidden = true,
    enabled = true,
  },
}
