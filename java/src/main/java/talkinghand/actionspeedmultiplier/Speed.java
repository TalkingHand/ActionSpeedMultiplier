package talkinghand.actionspeedmultiplier;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import zombie.SandboxOptions;
import zombie.characters.IsoPlayer;
import zombie.core.Transaction;
import zombie.core.TransactionManager;
import zombie.inventory.InventoryItem;
import zombie.inventory.ItemContainer;
import zombie.iso.IsoObject;
import zombie.iso.objects.IsoWorldInventoryObject;
import zombie.network.fields.ContainerID;
import zombie.network.fields.character.ConnectionPlayer;

/**
 * Transfer time in multiplayer: the server's duration divided by the sandbox multiplier.
 * A transaction of several items (a batch, BulkTransferSize) is timed by the sum of its items' times
 * instead of vanilla's maximum, so batches keep the vanilla total; vanilla's bundles of up to 20 light
 * items of one type still count as one item's time.
 */
public final class Speed {
    public static final double DEFAULT_MULTIPLIER = 20.0;
    public static final int DEFAULT_BULK = 20;
    /** Vanilla bundles up to 20 light items of one type into one item's time (checkQueueList, getDuration). */
    public static final int LIGHT_BUNDLE = 20;

    /** Tests only: true leaves the duration vanilla (maximum, undivided), to compare against. */
    public static boolean bypass;
    /** Tests only: true applies the batch sum but not the division. */
    public static boolean noDivide;

    /** How many times the patch changed a duration (tests and bug reports). */
    public static long applied;
    /** How many multi-item transactions were timed by the sum. */
    public static long batched;

    /** True while getDuration is called again for one entry of a batch: the patch leaves it alone. */
    private static final ThreadLocal<Boolean> measuring = ThreadLocal.withInitial(() -> Boolean.FALSE);

    private static Field entriesField;
    private static Field playerField;
    private static Field itemIdField;
    private static Field sourceIdField;
    private static Method getDurationMethod;
    private static boolean reflectFailed;

    private Speed() {}

    public static double multiplier() {
        return SandboxOptions.instance.getOptionByName("ActionSpeedMultiplier.TransferSpeed") instanceof SandboxOptions.DoubleSandboxOption option
            ? option.getValue()
            : DEFAULT_MULTIPLIER;
    }

    public static int bulkSize() {
        return SandboxOptions.instance.getOptionByName("ActionSpeedMultiplier.BulkTransferSize") instanceof SandboxOptions.IntegerSandboxOption option
            ? option.getValue()
            : DEFAULT_BULK;
    }

    /** Transaction.getDuration returns milliseconds (vanilla maxTime * 20); 0 stays 0 (instant transfers). */
    public static float duration(float vanilla) {
        if (bypass || vanilla <= 0.0F) {
            return vanilla;
        }
        double m = multiplier();
        if (!(m > 0.0)) {
            return vanilla;
        }
        applied++;
        return (float) (vanilla / m);
    }

    /** The patch's entry point (OnExit of Transaction.getDuration). */
    public static float duration(float vanilla, Object transaction) {
        if (bypass || measuring.get()) {
            return vanilla;
        }
        float base = batchSum(transaction, vanilla);
        return noDivide ? base : duration(base);
    }

    private static synchronized boolean reflect() {
        if (getDurationMethod != null) {
            return true;
        }
        if (reflectFailed) {
            return false;
        }
        try {
            Field entries = Transaction.class.getDeclaredField("entries");
            Field player = Transaction.class.getDeclaredField("player");
            Method getDuration = Transaction.class.getDeclaredMethod("getDuration");
            Class<?> entryClass = Class.forName("zombie.core.Transaction$TransactionEntry");
            Field itemId = entryClass.getDeclaredField("itemId");
            Field sourceId = entryClass.getDeclaredField("sourceId");
            entries.setAccessible(true);
            player.setAccessible(true);
            getDuration.setAccessible(true);
            itemId.setAccessible(true);
            sourceId.setAccessible(true);
            entriesField = entries;
            playerField = player;
            itemIdField = itemId;
            sourceIdField = sourceId;
            getDurationMethod = getDuration;
            return true;
        } catch (ReflectiveOperationException | RuntimeException e) {
            reflectFailed = true;
            System.out.println("[ActionSpeedMultiplier] batch timing off, Transaction fields not found: " + e);
            return false;
        }
    }

    /** The item an entry moves, found the way getDuration finds it; null if it can't be found. */
    private static InventoryItem itemOf(Object entry) throws IllegalAccessException {
        Integer id = (Integer) itemIdField.get(entry);
        ContainerID source = (ContainerID) sourceIdField.get(entry);
        if (source == null) {
            return null;
        }
        if (id != null && id != -1) {
            ItemContainer container = source.getContainer();
            return container != null ? container.getItemWithID(id) : null;
        }
        IsoObject object = source.getObject();
        return object instanceof IsoWorldInventoryObject world ? world.getItem() : null;
    }

    /**
     * Vanilla times a transaction by its slowest entry. For more than one entry (BulkTransferSize > 1)
     * this returns the entries' own durations added up: each entry is timed alone by the original
     * getDuration, the per-player light-item state is put back afterwards. Light items (<= 0.1) of one
     * full type count once per LIGHT_BUNDLE, as vanilla bundles them. Falls back to vanilla on any error.
     */
    @SuppressWarnings("unchecked")
    public static float batchSum(Object transaction, float vanilla) {
        if (vanilla <= 0.0F || !(transaction instanceof Transaction) || bulkSize() <= 1 || !reflect()) {
            return vanilla;
        }
        try {
            List<Object> entries = (List<Object>) entriesField.get(transaction);
            int n = entries.size();
            if (n <= 1) {
                return vanilla;
            }
            ConnectionPlayer connectionPlayer = (ConnectionPlayer) playerField.get(transaction);
            IsoPlayer player = connectionPlayer != null ? connectionPlayer.getPlayer() : null;
            TransactionManager.LightweightData light = player != null ? TransactionManager.getLightweightData(player) : null;
            String lastType = light != null ? light.lastItemFullType : null;
            int count = light != null ? light.itemsCount : 0;
            long lastTime = light != null ? light.itemsLastTransactionTime : 0L;

            List<Object> all = new ArrayList<>(entries);
            float[] times = new float[n];
            String[] lightType = new String[n];
            measuring.set(Boolean.TRUE);
            try {
                for (int i = 0; i < n; i++) {
                    entries.clear();
                    entries.add(all.get(i));
                    if (light != null) {
                        // neutral state: getDuration's "same light type within 2 s is free" rule does not fire
                        light.lastItemFullType = "";
                        light.itemsCount = 0;
                    }
                    times[i] = (Float) getDurationMethod.invoke(transaction);
                    InventoryItem item = itemOf(all.get(i));
                    if (item != null && Math.round(item.getWeight() * 1000.0F) <= 100 && item.getFullType() != null) {
                        lightType[i] = item.getFullType();
                    }
                }
            } finally {
                entries.clear();
                entries.addAll(all);
                measuring.set(Boolean.FALSE);
                if (light != null) {
                    light.lastItemFullType = lastType;
                    light.itemsCount = count;
                    light.itemsLastTransactionTime = lastTime;
                }
            }

            float total = 0.0F;
            Map<String, float[]> bundles = new HashMap<>(); // type -> {items in the open bundle, its max}
            for (int i = 0; i < n; i++) {
                if (lightType[i] == null) {
                    total += times[i];
                    continue;
                }
                float[] b = bundles.computeIfAbsent(lightType[i], k -> new float[2]);
                if (b[0] >= LIGHT_BUNDLE) {
                    total += b[1];
                    b[0] = 0.0F;
                    b[1] = 0.0F;
                }
                b[0]++;
                b[1] = Math.max(b[1], times[i]);
            }
            for (float[] b : bundles.values()) {
                if (b[0] > 0.0F) {
                    total += b[1];
                }
            }
            batched++;
            return total;
        } catch (ReflectiveOperationException | RuntimeException e) {
            System.out.println("[ActionSpeedMultiplier] batch timing failed, vanilla time used: " + e);
            return vanilla;
        }
    }
}
