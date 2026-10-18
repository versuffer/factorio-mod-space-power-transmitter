data:extend({
  {
    type = "double-setting",
    name = "spt-upkeep-power",
    setting_type = "startup",
    default_value = 600000, -- 600 MW
    minimum_value = 6000, -- 6 MW: the design minimum
    maximum_value = 1000000, -- 1 GW: the design maximum
    order = "a",
  },
})
