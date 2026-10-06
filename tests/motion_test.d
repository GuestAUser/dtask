module motion_test;

import dtask.motion : Motion;

enum settled = Motion.duration / Motion.interval;

unittest
{
    Motion motion;
    assert(motion.enabled);
    assert(!motion.active(0));
    assert(motion.frame(0) == settled);
    assert(motion.progress(0) == 1);
    assert(motion.strength(0, 20, 48) == 0);

    motion.start(1_000);
    assert(!motion.active(999));

    double previous = -1;
    foreach (offset; 0 .. Motion.duration)
    {
        const now = 1_000 + offset;
        assert(motion.active(now));
        assert(motion.frame(now) == offset / Motion.interval);
        assert(motion.waitMillis(now) == Motion.interval - offset % Motion.interval);
        const value = motion.progress(now);
        assert(value > previous && value < 1);
        previous = value;
    }

    assert(motion.progress(1_000) == 0);
    assert(motion.progress(1_000 + Motion.duration / 2) == 0.5);
    assert(!motion.active(1_000 + Motion.duration));
    assert(motion.frame(1_000 + Motion.duration) == settled);
    assert(motion.progress(1_000 + Motion.duration) == 1);
    assert(motion.frame(long.max) == settled);
    assert(motion.waitMillis(1_000 + Motion.duration) == 100);

    motion.start(3_000);
    assert(motion.active(3_000));
    assert(motion.frame(3_000) == 0);
}

unittest
{
    Motion motion;

    motion.start(200);
    const progress = motion.progress(600);
    const strength = motion.strength(600, 20, 48);
    motion.start(600);
    assert(motion.progress(600) == progress);
    assert(motion.strength(600, 20, 48) == strength);
    assert(!motion.active(200 + Motion.duration));

    motion.start(2_000);
    motion.enabled = false;
    assert(!motion.active(2_050));
    assert(motion.frame(2_050) == settled);
    assert(motion.progress(2_050) == 1);
    assert(motion.waitMillis(2_050) == 100);
    assert(motion.strength(2_050, 20, 48) == 0);

    motion.stop();
    motion.enabled = true;
    assert(!motion.active(2_100));
    motion.start(2_100);
    assert(motion.active(2_100));
    assert(motion.frame(2_100) == 0);
    motion.stop();
    assert(motion.strength(2_700, 24, 48) == 0);
}

unittest
{
    Motion motion;
    motion.start(long.min);
    assert(motion.frame(long.min) == 0);
    assert(motion.frame(long.min + Motion.duration - 1) == settled - 1);
    assert(motion.frame(long.max) == settled);
    assert(motion.waitMillis(-1) == 100);
}

unittest
{
    Motion motion;
    motion.start(0);
    enum middle = Motion.duration / 2;

    foreach (width; [1, 6, 30, 47, 85, 120])
    {
        double previousPeak = -1;

        foreach (now; [Motion.duration / 4, middle, 3 * Motion.duration / 4])
        {
            double peak = 0;
            double peakCell = 0;

            foreach (cell; 0 .. width * 10)
            {
                const position = cell / 10.0;
                const value = motion.strength(now, position, width);
                assert(value >= 0 && value <= 1);

                if (value > peak)
                {
                    peak = value;
                    peakCell = position;
                }
            }

            assert(peak > 0.5);
            assert(peakCell > previousPeak);
            previousPeak = peakCell;
        }

        foreach (cell; 0 .. width)
        {
            assert(motion.strength(0, cell, width) == 0);
            assert(motion.strength(Motion.duration, cell, width) == 0);
        }

        assert(motion.strength(middle, width * 0.5, width) == 1);
        assert(motion.strength(middle, width * 0.5 - Motion.radius, width) == 0);
        assert(motion.strength(middle, width * 0.5 + Motion.radius, width) == 0);
        assert(motion.strength(middle, -1, width) == 0);
        assert(motion.strength(middle, width, width) == 0);

        double previous = 0;

        foreach (now; 0 .. Motion.duration)
        {
            const value = motion.strength(now, width * 0.5, width);
            assert(value - previous < 0.05 && previous - value < 0.05);
            previous = value;
        }
    }

    assert(motion.strength(middle, 0, 0) == 0);
    assert(motion.strength(middle, 0, -1) == 0);
}
