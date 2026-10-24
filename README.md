## Space Power Transmitter

Adds Space Power Transmitter that links any planet or space platform - even a moving one - to the common space power grid: bidirectional energy transfer through space over any distance, rationed by demand. Draws a constant upkeep to hold the link (600 MW by default, less at higher quality); the link drops if the local network cannot supply it and restores automatically once it can. Can be unlocked on Aquilo.

## New technologies

-   Space Power Transmitter (2500 of each science pack), unlocks after:
    -   Cryogenic science pack (researchable on Aquilo);

## New entities

-   Space Power Transmitter:
    -   Intended to be played in the late game;
    -   Production is expensive (crafted in the electromagnetic plant);
    -   Connects the local power network of its surface to the common space power grid;
    -   Energy flows in both directions between all linked surfaces of the force - through space, over any distance (moving space platforms included);
    -   Energy is rationed proportionally to demand when production falls short (upkeep first, machines second);
    -   Throughput is capped at ~60 GW per transmitter: the hidden import port holds a 1 GJ buffer that is refilled once per tick, so one transmitter pair can transfer at most 60 GW - add more transmitters on the network for more power;
    -   Draws a constant upkeep to hold the link (600 MW by default; uncommon, rare, epic and legendary quality draw 5/6, 4/6, 3/6 and 1/6 of that value);
    -   If the local network cannot supply the upkeep, the link drops (a custom alert with a map pin is raised); it recovers from local generation only and relinks automatically once enough power is available again;
    -   Can be wired into a circuit network: broadcasts its link status as virtual signals - `spt-link-up` is 1 while the link is healthy, `spt-link-failing` is 1 while the upkeep is not being paid (the link drops within seconds), and both absent means the link is down;
    -   Supports a circuit "Enable if" condition (panel beside the transmitter's window): while it is false the transmitter is off - no link, no upkeep drain; the condition transfers with the copy-paste tool and in blueprints;
    -   Weighs one ton: exactly one transmitter fits per rocket;

## Additional features

-   Upkeep power is configurable in settings (6 MW - 1 GW, set in kilowatts; changing it requires a restart);
-   Quality tiers reduce the upkeep drain;
-   The transmitter itself is a pure node: all grid mechanics run through hidden internal ports (visible in the electric network GUI as "Space Power Transmitter" entries); the ports are dynamic-priority interfaces, so they do not inflate the network's battery capacity;
-   The transmitter can be freely deconstructed and moved; the link state survives saving, loading and mod updates (a force change rebuilds the link);

## Existing saves

- Mod does not change vanilla entity or item properties;
- Safe to add to an existing save; removing the mod drops all links (banked energy is not refunded);
- Mod is mostly safe for using with existing save but it is ***STRONGLY RECOMMENDED*** to make backup before installing ***OR*** updating mod version;

## Compatibility

-   Requires Factorio: Space Age (base >= 2.1.22 and space-age >= 2.1.22);
-   Works well with Quality mod;

## Credits

The graphics are taken from the [Orbital Interlink](https://mods.factorio.com/mod/orbital-interlink) mod by [Kubius](https://mods.factorio.com/user/Kubius).

## Check other mods

- [Thruster Upgrades](https://mods.factorio.com/mod/thruster-upgrades)
- [Nuclear Thruster](https://mods.factorio.com/mod/nuclear-thruster)
- [Useful Cerys methane gas applications](https://mods.factorio.com/mod/cerys-methane-applications)
- [Modular Nuclear Reactor](https://mods.factorio.com/mod/modular-nuclear-reactor)

## Contacts

Would be glad to get suggestions for further mod improvements, bugfixes, etc. on my GitHub.
