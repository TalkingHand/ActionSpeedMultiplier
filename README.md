# Action Speed Multiplier

Project Zomboid Build 42 mod. Timed actions and item transfers take the vanilla time divided by two sandbox options, in single player and on multiplayer servers. Meant as a replacement for Lua-only "faster actions" mods, which cannot speed up item transfers on servers.

## Sandbox options

| Option | Range | Default | Applies to |
|---|---|---|---|
| **Action speed** (`ActionSpeedMultiplier.ActionSpeed`) | 0.1 - 100 | 20 | every timed action except item transfers: crafting, building, eating, reading, repairing, farming, animals... |
| **Item transfer speed** (`ActionSpeedMultiplier.TransferSpeed`) | 0.1 - 100 | 20 | moving items between containers, bags, vehicles and the floor, and picking items up from the ground |

The time is the vanilla time divided by the option: 2 is twice as fast, 1 is vanilla, 0.5 twice as slow. Vanilla modifiers (traits, moodles, wounded hands, gloves, weight, bag fullness) still count before the division.

## How

- **Actions:** every timed action's time goes through `ISBaseTimedAction:adjustMaxTime`, on the client and in single player (`create`) and on the server (`NetTimedAction.getDuration` calls `adjustMaxTime(getDuration())`). The mod divides there, so client and server agree. Actions that do part of their work on their own clock (`timePerLiter`, `timePerEgg`, `timePerDirt`, `timePerUse`: milking, shearing, eggs, cleaning hutches, watering) get those clocks divided too.
- **Item transfers on servers:** the server times them in Java (`zombie.core.Transaction.getDuration`) and the client only waits, so Lua cannot change them. The mod patches that method with ZombieBuddy.
- **Item transfers in single player:** `ISInventoryTransferAction:new` and `ISGrabItemAction:new` are wrapped.

## Requirements

- [ZombieBuddy](https://steamcommunity.com/sharedfiles/filedetails/?id=3619862853) enabled in the mod list
- Steam launch option `-agentlib:zbNative --`
- Multiplayer: the server needs ZombieBuddy (Java agent) and this mod; clients need them too because the mod lists ZombieBuddy as required.

## Install

- [Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3836872290) (subscribe, then enable ZombieBuddy and Action Speed Multiplier)
- Manual: copy `Contents/mods/ActionSpeedMultiplier` to `%USERPROFILE%\Zomboid\mods\`.

## Compatibility

- Build 42.21. Tested in single player; multiplayer is not tested.
- Marked incompatible with TwisTonFire Faster Actions: both divide action times, so together they would multiply.
- Other mods' timed actions are divided too when they go through `adjustMaxTime` (the normal way). An action that runs its own clock under another field name than `timePer...` may end before its work is done.
- Can be added to or removed from an existing save; it changes no saved data.

## Test

`pzt live` (PZTestHarness) runs `tests/ActionSpeedMultiplier_Test.lua` in single player: transfer and grab times, the patched server transfer duration (`Transaction.getDuration` called directly), `adjustMaxTime` for actions and their own clocks, and real timed runs of a transfer and of an action.

## Support

If this mod helps you, you can support it via [Ko-fi](https://ko-fi.com/talkinghands2285) or [PayPal](https://www.paypal.com/paypalme/TalkingHands619/3). It's optional; every feature stays free.

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/talkinghands2285)
