module visuals_test;

import dtask.visuals;
import dtask.motion : Motion;
import dtask.text : fitText, textWidth;
import dtask.theme : defaultTheme, foreground, background;
import std.algorithm : canFind;
import std.conv : to;
import std.regex : replaceAll, regex;

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

unittest
{
    auto theme = defaultTheme();
    Motion motion;
    motion.start(0);
    const ansi = regex("\x1b\\[[0-9;]*m");
    const clusters = ["e\u0301", "\U0001f44d\U0001f3fd", "\U0001f469\u200d\U0001f4bb",
        "\U0001f468\u200d\U0001f469\u200d\U0001f467\u200d\U0001f466",
        "\U0001f1fa\U0001f1f8", "\u4e2d", "1\ufe0f\u20e3", "\u2764\ufe0f"];

    foreach (width; [20, 47, 85, 120])
    {
        foreach (cluster; clusters)
        {
            const text = fitText("AB" ~ cluster ~ "CD " ~ cluster, width);

            foreach (now; 0 .. 65)
            {
                auto colored = shimmerInk(text, theme.foreground, theme.selected, theme.accent,
                    motion, now * 16, 0, width);
                assert(colored.canFind(cluster));
                assert(replaceAll(colored, ansi, "") == text);
                assert(textWidth(replaceAll(colored, ansi, "")) == width);
            }

            /* Equal-width graphemes sample the same band, regardless of code points. */
            const cells = textWidth(cluster);
            const reference = cells == 1 ? "A" : "\u4e2d";
            auto first = shimmerInk(cluster, theme.foreground, theme.selected, theme.accent,
                motion, 512, width / 2, width);
            auto second = shimmerInk(reference, theme.foreground, theme.selected, theme.accent,
                motion, 512, width / 2, width);
            assert(first[0 .. $ - cluster.length] == second[0 .. $ - reference.length]);
        }
    }

    const text = "e\u0301\U0001f469\u200d\U0001f4bb";
    const plain = background(theme.selected) ~ foreground(theme.foreground) ~ text;
    assert(shimmerInk(text, theme.foreground, theme.selected, theme.accent,
        motion, 1_024, 0, 47) == plain);
    motion.enabled = false;
    assert(shimmerInk(text, theme.foreground, theme.selected, theme.accent,
        motion, 512, 0, 47) == plain);
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
