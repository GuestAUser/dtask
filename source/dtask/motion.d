module dtask.motion;

/** Clock-independent, interruptible 256 ms ease-out transition. */
struct Motion
{
    /** The UI owns this switch; disabled motion has no visual deadlines. */
    bool enabled = true;

    private bool started;
    private long startedAt;

    /** Start from the caller's captured current values, never from a queued frame. */
    void start(long nowMilliseconds)
    {
        started = true;
        startedAt = nowMilliseconds;
    }

    /** Whether the finite activity sweep is currently visible. */
    bool active(long nowMilliseconds) const
    {
        return enabled && started && nowMilliseconds >= startedAt &&
            elapsed(nowMilliseconds) < 256;
    }

    /** Sixteen millisecond presentation deadlines; 16 means settled. */
    uint frame(long nowMilliseconds) const
    {
        return active(nowMilliseconds) ? cast(uint) (elapsed(nowMilliseconds) / 16) : 16;
    }

    /** Continuous cubic ease-out, evaluated from elapsed time rather than frames. */
    double progress(long nowMilliseconds) const
    {
        if (!active(nowMilliseconds))
            return 1;

        const remaining = 1.0 - elapsed(nowMilliseconds) / 256.0;
        return 1.0 - remaining * remaining * remaining;
    }

    /** Next visual deadline, capped at 100 ms to keep terminal resize responsive. */
    int waitMillis(long nowMilliseconds) const
    {
        return active(nowMilliseconds) ? cast(int) (16 - elapsed(nowMilliseconds) % 16) : 100;
    }

    private ulong elapsed(long nowMilliseconds) const
    {
        /* Unsigned subtraction also preserves large synthetic clock spans. */
        return cast(ulong) nowMilliseconds - cast(ulong) startedAt;
    }
}
