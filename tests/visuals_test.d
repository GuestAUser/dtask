module visuals_test;

import dtask.visuals;

private void assertPrintable(string row, int width)
{
    assert(row.length == width);

    foreach (cell; row)
    {
        assert(cell >= ' ' && cell <= '~');
    }
}

private size_t filledCells(string meter)
{
    size_t filled;
    bool emptySeen;

    foreach (cell; meter)
    {
        if (cell == '=')
        {
            assert(!emptySeen);
            ++filled;
        }
        else if (cell == '.')
        {
            emptySeen = true;
        }
        else
        {
            assert(cell == '[' || cell == ']');
        }
    }

    return filled;
}

/* Test bar semantics, including clamping, rounding and overflow boundaries. */
unittest
{
    foreach (width; -3 .. 129)
    {
        const capacity = width >= 3 ? width - 2 : (width > 0 ? width : 0);

        foreach (total; 0 .. 13)
        {
            size_t previous;

            foreach (completed; 0 .. 16)
            {
                const meter = progressMeter(completed, total, width);
                assertPrintable(meter, width > 0 ? width : 0);

                if (width >= 3)
                {
                    assert(meter[0] == '[' && meter[$ - 1] == ']');
                }

                const capped = completed < total ? completed : total;
                const expected = total == 0 ? 0 : capacity * capped / total;
                const filled = filledCells(meter);

                assert(filled == expected);
                assert(filled >= previous);
                previous = filled;
            }
        }

        assert(filledCells(progressMeter(size_t.max, 0, width)) == 0);
        assert(filledCells(progressMeter(size_t.max, size_t.max, width)) == capacity);
        assert(filledCells(progressMeter(size_t.max, 1, width)) == capacity);
        assert(filledCells(progressMeter(1, size_t.max, width)) == 0);
        assert(filledCells(progressMeter(size_t.max - 1, size_t.max, width)) ==
            (capacity > 0 ? capacity - 1 : 0));
        assert(filledCells(progressMeter(size_t.max / 2, size_t.max, width)) ==
            (capacity > 0 ? (capacity - 1) / 2 : 0));
    }
}
