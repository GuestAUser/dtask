module dtask.visuals;

import dtask.motion : Motion;
import dtask.text : graphemeBoundaries, textWidth;
import dtask.theme : background, foreground, blend;
import std.array : appender;
import std.conv : to;
import std.utf : codeLength;

/**
 * Color a fitted, printable segment in a display-cell-positioned sheen.
 * A cluster gets one background, sampled at its center. Adjacent equal levels
 * share a color run; ASCII needs no per-cell conversions or width allocations.
 * The caller supplies the segment's offset within the complete swept surface.
 */
string shimmerInk(string text, string color, string surface, string sheen,
    ref const Motion motion, long now, int cell, int width)
{
    if (!motion.active(now))
        return background(surface) ~ foreground(color) ~ text;

    auto points = to!dstring(text);
    auto boundaries = graphemeBoundaries(points);
    auto output = appender!string();
    output.put(foreground(color));
    string[17] colors;
    int previous = -1;
    size_t byteOffset;
    size_t runStart;

    foreach (index; 0 .. boundaries.length - 1)
    {
        const first = boundaries[index];
        const last = boundaries[index + 1];
        const start = byteOffset;

        foreach (point; points[first .. last])
            byteOffset += codeLength!char(point);

        const cells = last == first + 1 && points[first] < 0x7f
            ? 1 : textWidth(text[start .. byteOffset]);
        const level = cast(int) (16 * motion.strength(now, cell + cells * 0.5, width) + 0.5);

        if (level != previous)
        {
            output.put(text[runStart .. start]);

            if (!colors[level].length)
                colors[level] = background(blend(surface, sheen, level * 0.20 / 16));

            output.put(colors[level]);
            runStart = start;
            previous = level;
        }

        cell += cells;
    }

    output.put(text[runStart .. $]);
    return output.data;
}

/**
 * Return an exact-width contiguous ASCII completion bar: '=' filled, '.' empty.
 * Widths of at least three include square brackets; smaller bars use all cells.
 * Nonpositive widths return an empty string, zero tasks leave the bar empty,
 * and completed values above total saturate at full. Fractions round down.
 */
string progressMeter(size_t completed, size_t total, int width)
{
    if (width <= 0)
    {
        return "";
    }

    auto cells = new char[width];
    cells[] = '.';

    const start = width >= 3 ? 1 : 0;
    const capacity = width >= 3 ? width - 2 : width;
    size_t filled;

    if (total != 0 && completed >= total)
    {
        filled = capacity;
    }
    else if (total != 0 && completed != 0)
    {
        /*
         * Count floor(capacity * completed / total) without an overflowing
         * product. Subtract before adding whenever the next fraction carries.
         * The loop is bounded by the output width, not the number of tasks.
         */
        size_t remainder;
        const complement = total - completed;

        foreach (_; 0 .. capacity)
        {
            if (remainder >= complement)
            {
                remainder -= complement;
                ++filled;
            }
            else
            {
                remainder += completed;
            }
        }
    }

    cells[start .. start + filled] = '=';

    if (width >= 3)
    {
        cells[0] = '[';
        cells[$ - 1] = ']';
    }

    return cast(string) cells;
}
