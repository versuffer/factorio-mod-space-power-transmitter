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
}
