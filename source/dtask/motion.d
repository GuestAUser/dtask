module dtask.motion;

/**
 * Clock-independent, finite glint that crosses a line of text once.
 * Time, not frame count, positions the glint, so a late frame never slows it.
 */
struct Motion
{
    /** Sweep length in milliseconds: slow enough to follow, short enough to settle. */
    enum duration = 1_200;
    /** Presentation interval in milliseconds; duration / interval means settled. */
    enum interval = 16;
    /** Glint half-width in display cells; strength and slope reach zero at its edges. */
    enum radius = 5.0;

    /** The UI owns this switch; disabled motion has no visual deadlines. */
    bool enabled = true;

    private bool started;
    private long startedAt;

    /** Retarget a live sweep without jumping its glint back to the start. */
    void start(long nowMilliseconds)
    {
        if (active(nowMilliseconds))
            return;

        started = true;
        startedAt = nowMilliseconds;
    }

    /** Discard the sweep when entering a still mode; never resume a stale glint. */
    void stop()
    {
        started = false;
    }

    /** Whether the finite sweep is currently visible. */
    bool active(long nowMilliseconds) const
    {
        return enabled && started && nowMilliseconds >= startedAt &&
            elapsed(nowMilliseconds) < duration;
    }

    /** Index of the current presentation interval; duration / interval when settled. */
    uint frame(long nowMilliseconds) const
    {
        return active(nowMilliseconds) ? cast(uint) (elapsed(nowMilliseconds) / interval) : duration / interval;
    }

    /** Linear sweep progress from 0 to 1, evaluated from time rather than frames. */
    double progress(long nowMilliseconds) const
    {
        if (!active(nowMilliseconds))
            return 1;

        return elapsed(nowMilliseconds) / cast(double) duration;
    }

    /**
     * Glint strength from 0 to 1 at a cell position within text width cells wide.
     * The center moves at constant speed from one radius before the first cell
     * to one radius past the last, so every glyph brightens and settles once.
     */
    double strength(long nowMilliseconds, double cell, int width) const
    {
        if (!active(nowMilliseconds) || width <= 0 || cell < 0 || cell >= width)
            return 0;

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
