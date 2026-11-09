# Transfer Speed Multiplier

Project Zomboid Build 42 mod. Moving items between containers takes the vanilla time divided by a sandbox option, in single player and on multiplayer servers.

## Why Java

In multiplayer the server times every transfer itself (`zombie.core.Transaction.getDuration`) and the client waits for the server's time, so a Lua mod cannot change it. Lua-only "faster actions" mods can only send several items in one request, which does nothing for single items or the floor. This mod patches the server's timing with ZombieBuddy, and wraps `ISInventoryTransferAction:new` for single player, where no server timing exists.

## Sandbox option

**Item transfer speed** (`TransferSpeedMultiplier.Multiplier`), 0.1 to 100, default 20. The time is the vanilla time divided by it: 2 is twice as fast, 1 is vanilla, 0.5 twice as slow. Traits (Dextrous, All Thumbs), gloves, weight and bag fullness still count as in vanilla.

## Requirements

- [ZombieBuddy](https://steamcommunity.com/sharedfiles/filedetails/?id=3619862853) enabled in the mod list
- Steam launch option `-agentlib:zbNative --`
- Multiplayer: the server needs ZombieBuddy (Java agent) and this mod; clients need them too because the mod lists ZombieBuddy as required.

## Install

- Steam Workshop: link added after the first upload.
- Manual: copy `Contents/mods/TransferSpeedMultiplier` to `%USERPROFILE%\Zomboid\mods\`.

## Compatibility

- Build 42.21. Tested in single player; multiplayer is not tested.
- Mods that also scale transfer time stack with it. TwisTonFire Faster Actions, for example, divides single-player times by its own speed and batches multiplayer transfers; with both on, the effects multiply.
- Can be added to or removed from an existing save; it changes no saved data.

## Test

`pzt live` (PZTestHarness) runs `tests/TransferSpeedMultiplier_Test.lua` in single player: the Lua times, the patched server duration (`Transaction.getDuration` called directly), and two real timed transfers.

## Support

If this mod helps you, you can support it via [PayPal](https://www.paypal.com/paypalme/TalkingHands619/3). It's optional; every feature stays free.
