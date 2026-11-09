package talkinghand.actionspeedmultiplier;

import zombie.SandboxOptions;

/** Transfer time in multiplayer: the server's vanilla duration divided by the sandbox multiplier. */
public final class Speed {
    public static final double DEFAULT_MULTIPLIER = 20.0;

    /** Tests only: true leaves the duration vanilla, to compare against. */
    public static boolean bypass;

    /** How many times the patch changed a duration (tests and bug reports). */
    public static long applied;

    private Speed() {}

    public static double multiplier() {
        return SandboxOptions.instance.getOptionByName("ActionSpeedMultiplier.TransferSpeed") instanceof SandboxOptions.DoubleSandboxOption option
            ? option.getValue()
            : DEFAULT_MULTIPLIER;
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
}
