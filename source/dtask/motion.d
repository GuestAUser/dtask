module dtask.motion;

/** Clock-independent, finite spatial sweep, lasting just over one second. */
struct Motion
{
    enum duration = 1_024;
    enum interval = 16;

    /** The UI owns this switch; disabled motion has no visual deadlines. */
    bool enabled = true;

    private bool started;
    private long startedAt;

    /** Retarget a live sweep without jumping its band back to the left edge. */
    void start(long nowMilliseconds)
    {
        if (active(nowMilliseconds))
            return;

        started = true;
        startedAt = nowMilliseconds;
    }

    /** Discard the sweep when entering a still mode; never resume a stale band. */
    void stop()
    {
        started = false;
    }

    /** Whether the finite activity sweep is currently visible. */
    bool active(long nowMilliseconds) const
    {
        return enabled && started && nowMilliseconds >= startedAt &&
            elapsed(nowMilliseconds) < duration;
    }

    /** Sixteen millisecond presentation deadlines; duration / interval is settled. */
    uint frame(long nowMilliseconds) const
    {
        return active(nowMilliseconds) ? cast(uint) (elapsed(nowMilliseconds) / interval) : duration / interval;
    }

    /** Uniform travel in display cells, evaluated from time rather than frames. */
    double progress(long nowMilliseconds) const
    {
        if (!active(nowMilliseconds))
            return 1;

        return elapsed(nowMilliseconds) / cast(double) duration;
    }

    /** Compact, smooth band with zero strength and slope at both outer edges. */
    double strength(long nowMilliseconds, double cell, int width) const
    {
        if (!active(nowMilliseconds) || width <= 0 || cell < 0 || cell >= width)
            return 0;

        const radius = width * 0.16;
        const center = -radius + (width + 2 * radius) * progress(nowMilliseconds);
        const distance = (cell - center) / radius;

        if (distance <= -1 || distance >= 1)
            return 0;

        const shoulder = 1 - distance * distance;
        return shoulder * shoulder;
    }

    /** Next visual deadline, capped at 100 ms to keep terminal resize responsive. */
    int waitMillis(long nowMilliseconds) const
    {
        return active(nowMilliseconds) ? cast(int) (interval - elapsed(nowMilliseconds) % interval) : 100;
    }

    private ulong elapsed(long nowMilliseconds) const
    {
        /* Unsigned subtraction also preserves large synthetic clock spans. */
        return cast(ulong) nowMilliseconds - cast(ulong) startedAt;
    }
}
