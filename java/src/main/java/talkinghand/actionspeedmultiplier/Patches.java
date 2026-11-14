package talkinghand.actionspeedmultiplier;

import me.zed_0xff.zombie_buddy.Patch;

/**
 * In multiplayer the server times every item transfer itself (Transaction.getDuration, called from
 * setTimeData when it accepts a request) and sends the time to the client, which waits for it.
 * Lua cannot reach that number, so it is scaled here. A transaction of several items (a batch from
 * ActionSpeedMultiplier_Transfer.lua) is timed by the sum of its items instead of the slowest one
 * (Speed.batchSum). Single player never builds a Transaction: the Lua file times the actions there.
 */
public final class Patches {
    private Patches() {}

    @Patch(className = "zombie.core.Transaction", methodName = "getDuration")
    public static class Duration {
        @Patch.OnExit
        public static void exit(@Patch.This Object self, @Patch.Return(readOnly = false) float ret) {
            ret = Speed.duration(ret, self);
        }
    }
}
