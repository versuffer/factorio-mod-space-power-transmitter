-- Shared by the data stage (port prototypes) and the control stage (upkeep accounting):
-- port buffers and the script-side drain rate must agree exactly, so both stages read
-- the setting through this single module.
local M = {}

M.QUALITY_MULTIPLIERS = {
  ["normal"] = 1,
  ["uncommon"] = 5 / 6,
  ["rare"] = 4 / 6,
  ["epic"] = 3 / 6,
  ["legendary"] = 1 / 6,
}

-- the setting is given in kilowatts; the game UI enforces the same bounds
M.MIN_UPKEEP_KW = 6000
M.MAX_UPKEEP_KW = 1000000

-- Warnings are logged once: this module runs in both stages, and only the data stage
-- prints them (the control stage would duplicate the entries on every load).
local function log_warning(message)
  if data then log(message) end
end

-- Formats watts as a compact human string ("1 GW", "250 MW", "500 kW") for descriptions.
function M.watts_str(watts)
  if watts >= 1e9 then return string.format("%g GW", watts / 1e9) end
  if watts >= 1e6 then return string.format("%g MW", watts / 1e6) end
  return string.format("%g kW", watts / 1e3)
end

-- Reads the startup setting (kilowatts) and returns watts. The bounds are enforced by
-- the settings UI; the clamping here is a safety net for hand-edited mod-settings.dat.
function M.upkeep_watts()
  local kilowatts = settings.startup["spt-upkeep-power"].value
  if type(kilowatts) ~= "number" then
    log_warning("space-power-transmitter: spt-upkeep-power is not a number - falling back to 1GW")
    kilowatts = M.MAX_UPKEEP_KW
  end
  if kilowatts < M.MIN_UPKEEP_KW then
    log_warning("space-power-transmitter: spt-upkeep-power='" .. tostring(kilowatts)
      .. "' is below the minimum of " .. M.MIN_UPKEEP_KW .. " kW - clamping")
    kilowatts = M.MIN_UPKEEP_KW
  end
  if kilowatts > M.MAX_UPKEEP_KW then
    log_warning("space-power-transmitter: spt-upkeep-power='" .. tostring(kilowatts)
      .. "' is above the maximum of 1 GW - clamping")
    kilowatts = M.MAX_UPKEEP_KW
  end
  return kilowatts * 1000
end

return M
