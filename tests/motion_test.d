module motion_test;

import dtask.motion : Motion;

unittest
{
    Motion motion;
    assert(motion.enabled);
    assert(!motion.active(0));
    assert(motion.frame(0) == 16);
    assert(motion.progress(0) == 1);

    motion.start(1_000);
    assert(!motion.active(999));

    double previous = 0;
    double previousStep = 1;

    foreach (offset; 0 .. 256)
    {
        const now = 1_000 + offset;
        assert(motion.active(now));
        assert(motion.frame(now) == offset / 16);
        assert(motion.waitMillis(now) == 16 - offset % 16);
        const value = motion.progress(now);
        assert(value >= previous && value < 1);

        if (offset > 0)
        {
            const step = value - previous;
            assert(step > 0 && step <= previousStep);
            previousStep = step;
        }

        previous = value;
    }

    assert(motion.progress(1_000) == 0);
    assert(motion.progress(1_128) == 0.875);
    assert(!motion.active(1_256));
    assert(motion.frame(1_256) == 16);
    assert(motion.progress(1_256) == 1);
    assert(motion.frame(long.max) == 16);
    assert(motion.waitMillis(1_256) == 100);

    motion.start(2_000);
    assert(motion.active(2_000));
    assert(motion.frame(2_000) == 0);
}

unittest
{
    Motion motion;

    motion.start(200);
    motion.enabled = false;
    assert(!motion.active(250));
    assert(motion.frame(250) == 16);
    assert(motion.progress(250) == 1);
    assert(motion.waitMillis(250) == 100);

    motion.start(300);
    assert(!motion.active(300));
    motion.enabled = true;
    assert(motion.active(300));
    assert(motion.frame(300) == 0);
}

unittest
{
    Motion motion;
    motion.start(long.min);
    assert(motion.frame(long.min) == 0);
    assert(motion.frame(long.min + 255) == 15);
    assert(motion.frame(long.max) == 16);
    assert(motion.waitMillis(-1) == 100);
}
