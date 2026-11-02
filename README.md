# matcha_vw_port

Voidware/Vape BedWars port for the [Matcha](https://huoadf.github.io/matcha-docs/) LuaVM. 59 modules, menus built with Matcha's own UI bindings (one tab per Vape category).

## Run

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/disorganizedware/matcha_vw_port/main/vape_matcha.lua"))()
```

Or copy `vape_matcha.lua` to your Matcha workspace and run `loadstring(readfile("vape_matcha.lua"))()`.

Stop with `_G.VapeStop()` or the Uninject button in the **Vape** tab.

## Layout

`vape_matcha.lua` is the built file: `port/00_core.lua`, `port/mods_a..e.lua` and `port/99_boot.lua` concatenated in that order.

- `00_core.lua`: module registry, UI tabs, entity list, inventory, remotes (`V.call`), block grid, memory WalkSpeed.
- `mods_*.lua`: the modules, each in its own `do ... end` block.

## Status

Tested in the BedWars training arena: Killaura, AutoBuy purchases, block placing/breaking, entity/bed/chest detection, ESPs. Everything else is untested in a real match.

Vape modules that only worked through hooks or client-module internals (InfiniteFly, KeepSprint, AutoCharge, ShopTierBypass, TrapDisabler, BetterDavey, AutoPlay, HitFix and the cosmetic Legit ones) aren't included.
