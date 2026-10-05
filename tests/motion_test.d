module motion_test;

import dtask.motion : Motion;

unittest
{
    Motion motion;
    assert(motion.enabled);
    assert(!motion.active(0));
    assert(motion.frame(0) == 64);
    assert(motion.progress(0) == 1);
    assert(motion.strength(0, 20, 48) == 0);

    motion.start(1_000);
    assert(!motion.active(999));

    double previous = 0;
    foreach (offset; 0 .. 1_024)
    {
        const now = 1_000 + offset;
        assert(motion.active(now));
        assert(motion.frame(now) == offset / 16);
        assert(motion.waitMillis(now) == 16 - offset % 16);
        const value = motion.progress(now);
        assert(value >= previous && value < 1);

        if (offset > 0)
            assert(value - previous == 1.0 / 1_024);

        previous = value;
    }

    assert(motion.progress(1_000) == 0);
    assert(motion.progress(1_512) == 0.5);
    assert(!motion.active(2_024));
    assert(motion.frame(2_024) == 64);
    assert(motion.progress(2_024) == 1);
    assert(motion.frame(long.max) == 64);
    assert(motion.waitMillis(2_024) == 100);

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
    assert(!motion.active(1_224));

    motion.start(2_000);
    motion.enabled = false;
    assert(!motion.active(2_050));
    assert(motion.frame(2_050) == 64);
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
    assert(motion.strength(2_612, 24, 48) == 0);
}

unittest
{
    Motion motion;
    motion.start(long.min);
    assert(motion.frame(long.min) == 0);
    assert(motion.frame(long.min + 1_023) == 63);
    assert(motion.frame(long.max) == 64);
    assert(motion.waitMillis(-1) == 100);
}

unittest
{
    Motion motion;
    motion.start(0);

    foreach (width; [1, 30, 47, 85, 120])
    {
        double previousPeak = -1;

        foreach (now; [256, 512, 768])
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

            assert(peak > 0.9);
            assert(peakCell > previousPeak);
            previousPeak = peakCell;
        }

        foreach (cell; 0 .. width)
        {
            assert(motion.strength(0, cell, width) == 0);
            assert(motion.strength(1_024, cell, width) == 0);
        }

        assert(motion.strength(512, width * 0.5, width) == 1);
        assert(motion.strength(512, width * 0.1, width) == 0);
        assert(motion.strength(512, width * 0.9, width) == 0);
        assert(motion.strength(512, -1, width) == 0);
        assert(motion.strength(512, width, width) == 0);

        double previous = 0;

        foreach (now; 0 .. 1_024)
        {
            const value = motion.strength(now, width * 0.5, width);
            const delta = value - previous;
            assert(delta < 0.02 && delta > -0.02);
            previous = value;
        }
    }

    assert(motion.strength(512, 0, 0) == 0);
    assert(motion.strength(512, 0, -1) == 0);
}
