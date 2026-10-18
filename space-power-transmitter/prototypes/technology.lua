return {
  {
    type = "technology",
    name = "space-power-transmitter",
    icon = "__space-power-transmitter__/graphics/technology/space-power-transmitter.png",
    icon_size = 256,
    effects = {
      {
        type = "unlock-recipe",
        recipe = "space-power-transmitter",
      },
    },
    prerequisites = { "cryogenic-science-pack" },
    unit = {
      count = 2500,
      ingredients = {
        { "automation-science-pack", 1 },
        { "logistic-science-pack", 1 },
        { "military-science-pack", 1 },
        { "chemical-science-pack", 1 },
        { "production-science-pack", 1 },
        { "utility-science-pack", 1 },
        { "space-science-pack", 1 },
        { "metallurgic-science-pack", 1 },
        { "electromagnetic-science-pack", 1 },
        { "agricultural-science-pack", 1 },
        { "cryogenic-science-pack", 1 },
      },
      time = 60,
    },
  },
}
