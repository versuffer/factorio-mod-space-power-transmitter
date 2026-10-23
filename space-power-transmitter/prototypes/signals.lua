-- Link status virtual signals broadcast by every transmitter's hidden status
-- combinator (spt-status-combinator, see prototypes/entity.lua and control.lua).
--   spt-link-up       = 1 - the link is healthy;
--   spt-link-failing  = 1 - the link is up, but the local network stopped paying the
--                           upkeep: the link drops within seconds unless power returns;
-- both absent (0) - the link is down (no energy is transferred, no signal relay).

local function status_signal(name, order)
  return {
    type = "virtual-signal",
    name = name,
    icons = {
      {
        icon = "__space-power-transmitter__/graphics/icons/" .. name .. ".png",
        icon_size = 64,
      },
    },
    order = order,
  }
end

return {
  status_signal("spt-link-up", "a"),
  status_signal("spt-link-failing", "b"),
}
