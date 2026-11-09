package talkinghand.transferspeedmultiplier;

import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;

import me.zed_0xff.zombie_buddy.Exposer;
import zombie.characters.IsoPlayer;
import zombie.core.Transaction;
import zombie.inventory.InventoryItem;
import zombie.inventory.ItemContainer;
import zombie.iso.IsoDirections;
import zombie.network.packets.ItemTransactionPacket;

/** Lua table TransferSpeedMultiplier, for the console and tests. */
@Exposer.LuaClass(name = "TransferSpeedMultiplier")
public class LuaApi {
    public static double multiplier() {
        return Speed.multiplier();
    }

    public static double applied() {
        return Speed.applied;
    }

    /**
     * The duration (ms) a server would give this transfer, built the way TransactionManager builds a
     * request. vanilla=true reads it with the patch bypassed. -1 when the private method can't be called.
     */
    public static double serverDuration(Object player, Object item, Object source, Object destination, boolean vanilla) {
        ItemTransactionPacket t = new ItemTransactionPacket();
        List<InventoryItem> items = new ArrayList<>();
        items.add((InventoryItem) item);
        t.set((IsoPlayer) player, items, (ItemContainer) source, (ItemContainer) destination, null, IsoDirections.N, 0.0F, 0.0F, 0.0F);
        boolean was = Speed.bypass;
        Speed.bypass = vanilla;
        try {
            Method m = Transaction.class.getDeclaredMethod("getDuration");
            m.setAccessible(true);
            return ((Float) m.invoke(t)).doubleValue();
        } catch (ReflectiveOperationException | RuntimeException e) {
            System.out.println("[TransferSpeedMultiplier] serverDuration failed: " + e);
            return -1.0;
        } finally {
            Speed.bypass = was;
        }
    }
}
