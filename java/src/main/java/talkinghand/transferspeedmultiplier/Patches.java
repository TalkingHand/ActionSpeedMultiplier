package talkinghand.transferspeedmultiplier;

import me.zed_0xff.zombie_buddy.Patch;

/**
 * In multiplayer the server times every item transfer itself (Transaction.getDuration, called from
 * setTimeData when it accepts a request) and sends the time to the client, which waits for it.
 * Lua cannot reach that number, so it is scaled here. Single player never builds a Transaction:
 * TransferSpeedMultiplier.lua scales ISInventoryTransferAction there.
 */
public final class Patches {
    private Patches() {}

    @Patch(className = "zombie.core.Transaction", methodName = "getDuration")
    public static class Duration {
        @Patch.OnExit
        public static void exit(@Patch.Return(readOnly = false) float ret) {
            ret = Speed.duration(ret);
        }
    }
}
